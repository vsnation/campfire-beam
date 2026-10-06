/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:path/path.dart' as p;

import '../rpc/beam_transport.dart';
import '../rpc/tcp_line_transport.dart';
import 'beam_binaries.dart';
import 'beam_binaries_manifest.dart';
import 'beam_host.dart';
import 'beam_host_exception.dart';
import 'secret_file.dart';

/// Builds the transport for a freshly started wallet-api on 127.0.0.1.
typedef BeamTransportFactory = BeamTransport Function({
  required int port,
  required String aclKey,
});

/// Receives operational log lines. They never contain a secret.
typedef BeamHostLog = void Function(String message);

/// The wallet-api JSON-RPC version every launch pins, so a binary upgrade
/// cannot silently change response shapes (research/02 §1.1).
const String kBeamApiVersion = '7.4';

/// wallet-api's TCP line limit. A contract shader is ~150 KB of JSON.
const int _tcpMaxLine = 16777216;

final Random _random = Random.secure();

String _randomHex(int bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

void _noLog(String _) {}

/// [BeamHost] for desktop: runs the pinned `beam-wallet` and `wallet-api`
/// binaries as child processes (Transport A).
///
/// Layout under [rootDir], every directory 0700:
///
/// ```
/// bin/            binaries (unless BEAM_BIN_DIR is set)
/// wallets/<id>/   wallet.db, .wallet.lock
/// run/            wallet-api CWD; transient .s-* secret files; logs/
/// node/           beam-node CWD (managed elsewhere; swept here)
/// ```
///
/// Secrets reach the binaries only through 0600 `--config_file`s that are
/// deleted as soon as the child has opened them, never through argv.
/// wallet-api runs in TCP line mode on a random loopback port with a fresh
/// 256-bit ACL key and `--ip_whitelist=127.0.0.1`. The stock binary still
/// binds 0.0.0.0; the loopback-patched build (task B-BIN-1) closes that.
class ProcessHost implements BeamHost {
  ProcessHost({
    required String rootDir,
    BeamBinaries? binaries,
    this._transportFactory,
    BeamHostLog? log,
    this.startupTimeout = const Duration(seconds: 20),
    this.cliTimeout = const Duration(minutes: 2),
    this.rescanTimeout = const Duration(minutes: 30),
    this._ensureBinaries,
  }) : rootDir = p.normalize(p.absolute(rootDir)),
       binaries = binaries ?? BeamBinaries.locate(beamRoot: rootDir),
       _log = log ?? _noLog;

  final String rootDir;
  final BeamBinaries binaries;

  /// How long wallet-api may take to listen and answer `get_version`.
  final Duration startupTimeout;

  /// Limit for `beam-wallet restore` and `export_owner_key`.
  final Duration cliTimeout;

  /// Limit for `beam-wallet rescan`.
  final Duration rescanTimeout;

  final BeamTransportFactory? _transportFactory;
  final BeamHostLog _log;

  /// Puts the binaries in place before the first operation, e.g. copying
  /// the ones bundled with the app into `bin/`
  /// (`installBundledBeamBinaries`). They are still verified before every
  /// launch.
  final Future<void> Function()? _ensureBinaries;

  /// Every open session of every host in this process.
  static final Set<ProcessSession> _sessions = {};

  String get runDir => p.join(rootDir, 'run');
  String get logsDir => p.join(runDir, 'logs');
  String get nodeDir => p.join(rootDir, 'node');
  String get walletsDir => p.join(rootDir, 'wallets');

  static final RegExp _walletIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static final RegExp _wordPattern = RegExp(r'^[a-z]+$');
  static final RegExp _hostPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-]*$');

  /// `<root>/wallets/<walletId>`. Throws for an id that is not a plain name.
  String walletDirFor(String walletId) {
    if (!_walletIdPattern.hasMatch(walletId)) {
      throw const BeamHostException(
        BeamHostError.invalidInput,
        'Wallet id must be 1-64 letters, digits, "-" or "_"',
      );
    }
    return p.join(walletsDir, walletId);
  }

  // ---------------------------------------------------------------------------
  // Validation

  /// Rejects a password BEAM would store differently from what was typed
  /// (`#` starts a comment, surrounding whitespace is trimmed), or that
  /// could inject a config line. Never echoes the password.
  static void validatePassword(String password) {
    checkConfigValue('password', password);
    // SecString::MAX_SIZE is 4096 and silently truncates.
    if (utf8.encode(password).length >= 4096) {
      throw const BeamHostException(
        BeamHostError.invalidInput,
        'Password is longer than BEAM accepts',
      );
    }
  }

  /// Requires 12 lowercase BIP39 words with a valid checksum. BEAM checks
  /// neither the checksum nor, before logging it, the phrase: its CLI logs a
  /// rejected phrase in full. Never echoes a word.
  static void validateWords(List<String> words) {
    if (words.length != 12) {
      throw BeamHostException(
        BeamHostError.invalidInput,
        'A BEAM seed phrase has 12 words, got ${words.length}',
      );
    }
    if (!words.every(_wordPattern.hasMatch)) {
      throw const BeamHostException(
        BeamHostError.invalidInput,
        'Seed words must be lowercase letters a-z only',
      );
    }
    if (!bip39.validateMnemonic(words.join(' '))) {
      throw const BeamHostException(
        BeamHostError.invalidInput,
        'Not a valid BIP39 phrase (unknown word or wrong checksum)',
      );
    }
  }

  /// Rejects a node address that is not a plain host name or IPv4 address
  /// with a port.
  static void validateNode(BeamNodeEndpoint node) {
    if (!_hostPattern.hasMatch(node.host) ||
        node.port <= 0 ||
        node.port > 65535) {
      throw BeamHostException(
        BeamHostError.badNode,
        'Not a usable node address: $node',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Setup

  Future<void>? _prepared;

  /// Creates the 0700 layout and sweeps secret files left by a crash. Runs
  /// once per host; retried if it failed.
  Future<void> _prepare() =>
      _prepared ??= _doPrepare().catchError((Object e, StackTrace s) {
        _prepared = null;
        Error.throwWithStackTrace(e, s);
      });

  Future<void> _doPrepare() async {
    await ensurePrivateDir(rootDir);
    await ensurePrivateDir(runDir);
    await ensurePrivateDir(logsDir);
    await ensurePrivateDir(nodeDir);
    await ensurePrivateDir(walletsDir);
    await _ensureBinaries?.call();
    final removed = await SecretFiles.sweep([runDir, nodeDir]);
    if (removed > 0) {
      _log('Removed $removed secret file(s) left by an earlier run');
    }
    await _pruneLogs();
  }

  Future<void> _pruneLogs() async {
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    await for (final entity in Directory(logsDir).list()) {
      final name = p.basename(entity.path);
      if (entity is! File ||
          !name.startsWith('wallet-api-') ||
          !name.endsWith('.log')) {
        continue;
      }
      try {
        if ((await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      } on FileSystemException {
        // Next start tries again.
      }
    }
  }

  /// BEAM binaries read `beam-common.cfg` and `wallet-api.cfg` from their
  /// working directory. Nothing legitimate puts them in run/, and one could
  /// turn off the ACL or change the node.
  Future<void> _removeStrayConfigs() async {
    for (final name in const [
      'beam-common.cfg',
      'wallet-api.cfg',
      'beam-wallet.cfg',
    ]) {
      final file = File(p.join(runDir, name));
      if (await file.exists()) {
        _log('Removing unexpected $name from the run directory');
        await file.delete();
      }
    }
  }

  static String _dbPath(String walletDir) => p.join(walletDir, 'wallet.db');

  static String _normalize(String path) => p.normalize(p.absolute(path));

  Future<String> _existingWallet(String walletDir) async {
    final dir = _normalize(walletDir);
    if (!await File(_dbPath(dir)).exists()) {
      throw const BeamHostException(
        BeamHostError.walletNotFound,
        'No wallet.db in the wallet directory',
      );
    }
    await ensurePrivateDir(dir);
    return dir;
  }

  // ---------------------------------------------------------------------------
  // BeamHost

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) async {
    validatePassword(password);
    validateWords(words);
    await _prepare();
    final dir = _normalize(walletDir);
    await ensurePrivateDir(dir);
    final db = _dbPath(dir);
    final lock = await _WalletLock.acquire(dir, _log);
    var ownsDb = false;
    try {
      if (await File(db).exists()) {
        throw const BeamHostException(
          BeamHostError.walletExists,
          'wallet.db already exists in the wallet directory',
        );
      }
      ownsDb = true;
      final phrase = words.join(';');
      final result = await _runCli(
        command: 'restore',
        dbPath: db,
        config: {'pass': password, 'seed_phrase': phrase},
        secrets: [password, phrase, words.join(' ')],
        lock: lock,
        timeout: cliTimeout,
      );
      final created =
          result.exitCode == 0 &&
          result.saw('wallet successfully created') &&
          await File(db).exists();
      if (!created) {
        throw _cliFailure(result, 'Creating the wallet failed');
      }
      await setOwnerOnly(db);
      ownsDb = false;
      _log('Created wallet.db in ${p.basename(dir)}');
    } catch (_) {
      if (ownsDb) await _deleteDb(db);
      rethrow;
    } finally {
      await lock.release();
    }
  }

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async {
    validatePassword(password);
    validateNode(node);
    await _prepare();
    final dir = await _existingWallet(walletDir);
    final lock = await _WalletLock.acquire(dir, _log);
    try {
      final exe = await binaries.prepare(
        BeamBinary.walletApi,
        scratchParent: runDir,
      );
      await _removeStrayConfigs();
      for (var attempt = 1; ; attempt++) {
        try {
          return await _launchWalletApi(
            exe: exe,
            walletDir: dir,
            password: password,
            node: node,
            requestBodies: requestBodies,
            lock: lock,
          );
        } on _PortTaken {
          if (attempt >= 3) {
            throw const BeamHostException(
              BeamHostError.processFailed,
              'wallet-api could not bind a free port in 3 attempts',
            );
          }
          _log('wallet-api port was taken by another process; retrying');
        }
      }
    } catch (_) {
      await lock.release();
      rethrow;
    }
  }

  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async {
    validatePassword(password);
    await _prepare();
    final dir = await _existingWallet(walletDir);
    final lock = await _WalletLock.acquire(dir, _log);
    try {
      final result = await _runCli(
        command: 'export_owner_key',
        dbPath: _dbPath(dir),
        config: {'pass': password},
        secrets: [password],
        lock: lock,
        timeout: cliTimeout,
      );
      final key = result.firstGroup(RegExp(r'Owner Viewer key:\s*(\S+)'));
      if (key == null || key.isEmpty) {
        throw _cliFailure(result, 'Exporting the owner key failed');
      }
      return key;
    } finally {
      await lock.release();
    }
  }

  /// Runs `beam-wallet rescan` until the wallet reports its synced state
  /// (`Current state is …`), then stops it gracefully.
  ///
  /// The rescan clears the wallet's coins and event height in `wallet.db`
  /// immediately; the coins come back from the owned node's events. If this
  /// is interrupted, the next session on the owned node finishes the job.
  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) async {
    if (!node.isOwned) {
      throw const BeamHostException(
        BeamHostError.notOwnedNode,
        'Rescan needs your own node holding the owner key. Without one the '
        'wallet would download every block since genesis.',
      );
    }
    validatePassword(password);
    validateNode(node);
    await _prepare();
    final dir = await _existingWallet(walletDir);
    final lock = await _WalletLock.acquire(dir, _log);
    try {
      final result = await _runCli(
        command: 'rescan',
        dbPath: _dbPath(dir),
        config: {'pass': password},
        secrets: [password],
        lock: lock,
        timeout: rescanTimeout,
        extraArgs: ['--node_addr=$node'],
        stopWhen: (line) => line.contains('Current state is'),
      );
      if (!result.stoppedOnMarker) {
        throw _cliFailure(result, 'Rescan failed');
      }
    } finally {
      await lock.release();
    }
  }

  /// Stops every wallet-api and beam-wallet started by any [ProcessHost] in
  /// this process and deletes every remaining secret file. Call before the
  /// app exits (Campfire's desktop quit path calls `exit(0)`).
  static Future<void> shutdownAll() async {
    for (final session in List.of(_sessions)) {
      try {
        await session.close();
      } catch (_) {
        // Keep going: the children below are stopped regardless.
      }
    }
    await _Child.stopAll();
    await SecretFiles.deleteAll();
  }

  // ---------------------------------------------------------------------------
  // beam-wallet

  Future<_CliResult> _runCli({
    required String command,
    required String dbPath,
    required Map<String, String> config,
    required List<String> secrets,
    required _WalletLock lock,
    required Duration timeout,
    List<String> extraArgs = const [],
    bool Function(String line)? stopWhen,
  }) async {
    final exe = await binaries.prepare(
      BeamBinary.wallet,
      scratchParent: runDir,
    );
    // A fresh 0700 working directory per command: beam-wallet writes logs/
    // into its CWD, and it logs a rejected seed phrase in full. The
    // directory, its logs and the config file go when the command ends.
    final scratch = await SecretFile.createDir(runDir);
    SecretFile? cfg;
    _Child? child;
    try {
      final configFile = await SecretFile.writeConfig(scratch.path, config);
      cfg = configFile;
      final cfgName = p.basename(configFile.path);
      final result = _CliResult(secrets);
      final started = await _Child.start(
        exe,
        [
          command,
          '--wallet_path=$dbPath',
          '--config_file=${configFile.path}',
          '--log_level=info',
          '--file_log_level=error',
          ...extraArgs,
        ],
        workingDirectory: scratch.path,
        name: BeamBinary.wallet.id,
        onLine: (line, self) {
          // Printed after the file is open, so unlinking it now is safe.
          if (line.startsWith('Reading config from') &&
              line.contains(cfgName)) {
            configFile.deleteSync();
          }
          result.lines.add(line);
          if (!result.stoppedOnMarker && stopWhen != null && stopWhen(line)) {
            result.stoppedOnMarker = true;
            unawaited(self.stop());
          }
        },
      );
      child = started;
      await lock.setChild(started.pid, BeamBinary.wallet.fileName);
      try {
        result.exitCode = await started.exitCode.timeout(timeout);
      } on TimeoutException {
        await started.stop();
        throw BeamHostException(
          BeamHostError.timeout,
          'beam-wallet $command did not finish in ${timeout.inSeconds} s',
        );
      }
      return result;
    } finally {
      await child?.stop();
      await cfg?.delete();
      await scratch.delete();
    }
  }

  BeamHostException _cliFailure(_CliResult r, String what) {
    if (r.saw('Please check your password') ||
        r.saw('File is not a database')) {
      return const BeamHostException(
        BeamHostError.wrongPassword,
        'The wallet password is wrong',
      );
    }
    if (r.saw('already initialized')) {
      return const BeamHostException(
        BeamHostError.walletExists,
        'wallet.db already exists in the wallet directory',
      );
    }
    if (r.saw('Please initialize your wallet first')) {
      return const BeamHostException(
        BeamHostError.walletNotFound,
        'No wallet.db in the wallet directory',
      );
    }
    if (r.saw('Invalid seed phrase') || r.saw('provide a valid seed phrase')) {
      return const BeamHostException(
        BeamHostError.invalidInput,
        'beam-wallet rejected the seed phrase',
      );
    }
    if (r.saw('unable to resolve')) {
      return const BeamHostException(
        BeamHostError.badNode,
        'The node address could not be resolved',
      );
    }
    return BeamHostException(
      BeamHostError.processFailed,
      '$what (exit ${r.exitCode}): ${r.diagnostic}',
    );
  }

  static Future<void> _deleteDb(String db) async {
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final file = File('$db$suffix');
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Best effort; a later initWallet reports walletExists.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // wallet-api

  BeamTransport _transport(int port, String aclKey) {
    final factory = _transportFactory;
    if (factory != null) return factory(port: port, aclKey: aclKey);
    return TcpLineTransport(port: port, aclKey: aclKey, log: _log);
  }

  Future<ProcessSession> _launchWalletApi({
    required String exe,
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    required bool requestBodies,
    required _WalletLock lock,
  }) async {
    final port = await _freeLoopbackPort();
    final aclKey = _randomHex(32);
    final secrets = [password, aclKey];
    SecretFile? cfg;
    SecretFile? acl;
    _ChildLog? log;
    _Child? child;
    BeamTransport? transport;
    try {
      final configFile = await SecretFile.writeConfig(runDir, {
        'pass': password,
      });
      cfg = configFile;
      // Exactly one line and no blank line: wallet-api refuses to start on
      // any line it cannot parse.
      final aclFile = await SecretFile.write(
        runDir,
        '$aclKey:write\n',
        suffix: '.acl',
      );
      acl = aclFile;
      final childLog = _ChildLog(
        await createPrivateFile(
          p.join(logsDir, 'wallet-api-${_stamp()}-$port.log'),
        ),
      );
      log = childLog;

      final state = _StartupState();
      final cfgName = p.basename(configFile.path);
      _log(
        'Starting wallet-api for ${p.basename(walletDir)} on $node, '
        'port $port${requestBodies ? ', body requests on' : ''}',
      );
      final started = await _Child.start(
        exe,
        [
          '--wallet_path=${_dbPath(walletDir)}',
          '--config_file=${configFile.path}',
          '--node_addr=$node',
          '--port=$port',
          '--use_http=0',
          '--tcp_max_line=$_tcpMaxLine',
          '--ip_whitelist=127.0.0.1',
          '--use_acl=1',
          '--acl_path=${aclFile.path}',
          '--enable_assets',
          '--enable_lelantus',
          '--api_version=$kBeamApiVersion',
          '--request_bodies=${requestBodies ? 1 : 0}',
          // Only the Campfire build knows this flag; the stock binary
          // refuses to start with it. BANS needs privilege 1 to claim name
          // payments; every other shader, including any dApp's, stays at 0.
          if (binaries.isCampfireBuild(BeamBinary.walletApi))
            '--privileged_shader_sha256='
                '${kBeamPrivilegedShaderSha256s.join(',')}',
          '--log_level=info',
          '--file_log_level=info',
          '--log_cleanup_days=3',
        ],
        workingDirectory: runDir,
        name: BeamBinary.walletApi.id,
        onLine: (line, self) {
          final safe = _sanitize(line, secrets);
          childLog.add(safe);
          state.remember(safe);
          if (line.startsWith('Reading config from') &&
              line.contains(cfgName)) {
            configFile.deleteSync();
          } else if (line.contains('ACL file successfully loaded')) {
            aclFile.deleteSync();
          } else if (line.contains('Start server on')) {
            state.serverStartedAt ??= DateTime.now();
          } else if (line.contains('cannot start server')) {
            state.portTaken = true;
          } else if (line.contains('File is not a database')) {
            state.wrongPassword = true;
          } else if (line.contains('Wallet not found')) {
            state.walletMissing = true;
          } else if (line.contains('unable to resolve node address')) {
            state.badNode = true;
          }
        },
      );
      child = started;
      unawaited(started.exitCode.then((_) => childLog.close()));
      await lock.setChild(started.pid, BeamBinary.walletApi.fileName);

      await _waitUntilListening(started, state, port, node);

      final t = _transport(port, aclKey);
      transport = t;
      await t.connect();
      final version = await t.call(
        'get_version',
        const {},
        const Duration(seconds: 10),
      );
      final apiVersion = version is Map ? version['api_version'] : null;
      if (apiVersion != null && apiVersion != kBeamApiVersion) {
        throw BeamHostException(
          BeamHostError.processFailed,
          'wallet-api speaks API $apiVersion, expected $kBeamApiVersion',
        );
      }
      await configFile.delete();
      await aclFile.delete();

      final session = ProcessSession._(
        host: this,
        walletDir: walletDir,
        password: password,
        node: node,
        requestBodies: requestBodies,
        transport: t,
        port: port,
        child: started,
        lock: lock,
        log: childLog,
      );
      _sessions.add(session);
      unawaited(started.exitCode.then(session._childExited));
      _log('wallet-api is up on port $port (pid ${started.pid})');
      return session;
    } catch (_) {
      try {
        await transport?.close();
      } catch (_) {
        // The process is stopped next either way.
      }
      await child?.stop();
      await log?.close();
      rethrow;
    } finally {
      await cfg?.delete();
      await acl?.delete();
    }
  }

  Future<void> _waitUntilListening(
    _Child child,
    _StartupState state,
    int port,
    BeamNodeEndpoint node,
  ) async {
    final deadline = DateTime.now().add(startupTimeout);
    while (true) {
      if (state.portTaken) {
        await child.stop();
        throw const _PortTaken();
      }
      if (child.hasExited) {
        throw _startupFailure(state, await child.exitCode, node);
      }
      final startedAt = state.serverStartedAt;
      // A bind error is logged right after "Start server on". Give it a
      // moment to arrive before trusting whatever accepts on the port.
      if (startedAt != null &&
          DateTime.now().difference(startedAt) >
              const Duration(milliseconds: 300) &&
          await _accepts(port) &&
          !state.portTaken) {
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        await child.stop();
        throw BeamHostException(
          BeamHostError.timeout,
          'wallet-api did not start listening within '
          '${startupTimeout.inSeconds} s: ${state.diagnostic}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  BeamHostException _startupFailure(
    _StartupState state,
    int exitCode,
    BeamNodeEndpoint node,
  ) {
    if (state.wrongPassword) {
      return const BeamHostException(
        BeamHostError.wrongPassword,
        'The wallet password is wrong',
      );
    }
    if (state.walletMissing) {
      return const BeamHostException(
        BeamHostError.walletNotFound,
        'wallet-api found no wallet.db',
      );
    }
    if (state.badNode) {
      return BeamHostException(
        BeamHostError.badNode,
        'wallet-api could not resolve the node address $node',
      );
    }
    return BeamHostException(
      BeamHostError.processFailed,
      'wallet-api exited with code $exitCode: ${state.diagnostic}',
    );
  }

  /// A port the OS says is free on loopback. wallet-api binds it moments
  /// later; if something else takes it first, wallet-api logs
  /// "cannot start server" and the launch is retried on a new port.
  static Future<int> _freeLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  static Future<bool> _accepts(int port) async {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    }
  }

  static String _stamp() {
    final t = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

/// An open wallet: one wallet-api process and the transport to it.
class ProcessSession implements BeamSession {
  ProcessSession._({
    required this._host,
    required this.walletDir,
    required this._password,
    required this.node,
    required this.requestBodies,
    required this.transport,
    required this.port,
    required this._child,
    required this._lock,
    required this._log,
  });

  final ProcessHost _host;

  /// Held only so [switchNode] can restart wallet-api. Never logged, never
  /// in [toString].
  final String _password;
  final _Child _child;
  final _WalletLock _lock;
  final _ChildLog _log;
  Future<void>? _closing;

  final String walletDir;
  final bool requestBodies;

  /// Loopback port wallet-api listens on.
  final int port;

  @override
  final BeamTransport transport;

  @override
  final BeamNodeEndpoint node;

  /// wallet-api's process id.
  int get pid => _child.pid;

  bool get isClosed => _closing != null;

  /// Completes when wallet-api has exited, for any reason.
  Future<void> get done => _child.exitCode.then((_) {});

  /// Stops this wallet-api and starts a new one on [node] with the same
  /// password and body-request setting. wallet-api has no runtime node
  /// switch. This session is closed even if the new one fails to open.
  @override
  Future<BeamSession> switchNode(BeamNodeEndpoint node) async {
    if (isClosed) throw StateError('Session is closed');
    ProcessHost.validateNode(node);
    await close();
    return _host.openWallet(
      walletDir: walletDir,
      password: _password,
      node: node,
      requestBodies: requestBodies,
    );
  }

  /// Closes the transport, sends SIGTERM (wallet-api shuts down cleanly on
  /// it), sends SIGKILL after 5 s, and releases the wallet lock.
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await transport.close();
    } catch (_) {
      // Closing a dead connection; the process is stopped regardless.
    }
    await _child.stop();
    await _log.close();
    await _lock.release();
    ProcessHost._sessions.remove(this);
  }

  void _childExited(int code) {
    if (_closing != null) return;
    _host._log('wallet-api exited unexpectedly (code $code)');
    unawaited(close());
  }

  @override
  String toString() => 'ProcessSession($node, port $port)';
}

// -----------------------------------------------------------------------------
// Internals

class _PortTaken implements Exception {
  const _PortTaken();
}

/// Withholds lines that may carry a secret and blanks literal secrets.
String _sanitize(String line, Iterable<String> secrets) {
  final lower = line.toLowerCase();
  if (lower.contains('seed') ||
      lower.contains('phrase') ||
      lower.contains('owner viewer key') ||
      lower.contains('owner_key') ||
      lower.contains('pass=')) {
    return '[line withheld]';
  }
  var out = line;
  for (final secret in secrets) {
    if (secret.isNotEmpty) out = out.replaceAll(secret, '[redacted]');
  }
  return out;
}

/// The last few sanitized lines, for error messages.
String _diagnosticOf(Iterable<String> sanitizedLines) {
  final useful = sanitizedLines
      .where((l) => l.trim().isNotEmpty && !l.startsWith('\t'))
      .toList();
  final tail = useful.length > 6 ? useful.sublist(useful.length - 6) : useful;
  return tail.isEmpty ? '(no output)' : tail.join(' | ');
}

class _CliResult {
  _CliResult(this._secrets);

  final List<String> _secrets;

  /// Raw output. Kept in memory only, for the duration of one command.
  final List<String> lines = [];
  int exitCode = -1;
  bool stoppedOnMarker = false;

  bool saw(String text) {
    final needle = text.toLowerCase();
    return lines.any((l) => l.toLowerCase().contains(needle));
  }

  String? firstGroup(RegExp pattern) {
    for (final line in lines) {
      final match = pattern.firstMatch(line);
      if (match != null) return match.group(1);
    }
    return null;
  }

  String get diagnostic =>
      _diagnosticOf(lines.map((l) => _sanitize(l, _secrets)));
}

class _StartupState {
  final Queue<String> _recent = Queue();
  DateTime? serverStartedAt;
  bool portTaken = false;
  bool wrongPassword = false;
  bool walletMissing = false;
  bool badNode = false;

  void remember(String sanitizedLine) {
    _recent.add(sanitizedLine);
    if (_recent.length > 40) _recent.removeFirst();
  }

  String get diagnostic => _diagnosticOf(_recent);
}

/// A child's sanitized console output in a 0600 file under run/logs.
class _ChildLog {
  _ChildLog(File file) : _sink = file.openWrite(mode: FileMode.append) {
    _sink.done.ignore();
  }

  final IOSink _sink;
  bool _closed = false;

  void add(String line) {
    if (!_closed) _sink.writeln(line);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _sink.close();
    } catch (_) {
      // A log that cannot be flushed is not worth failing a close over.
    }
  }
}

/// A child process with merged, line-split output.
class _Child {
  _Child._(this._process, this.name);

  static final Set<_Child> _live = {};

  final Process _process;
  final String name;
  late final Future<int> exitCode;
  bool _exited = false;

  int get pid => _process.pid;

  /// True once the process has exited and all its output was delivered.
  bool get hasExited => _exited;

  static Future<_Child> start(
    String exe,
    List<String> args, {
    required String workingDirectory,
    required String name,
    required void Function(String line, _Child self) onLine,
  }) async {
    final Process process;
    try {
      process = await Process.start(
        exe,
        args,
        workingDirectory: workingDirectory,
      );
    } on ProcessException catch (e) {
      throw BeamHostException(
        BeamHostError.processFailed,
        'Could not start $name: ${e.message}',
      );
    }
    final child = _Child._(process, name);
    _live.add(child);
    // EOF on stdin: should a config file ever go missing, BEAM's password
    // prompt reads nothing instead of waiting forever.
    process.stdin.done.ignore();
    process.stdin.close().ignore();

    void handle(String line) {
      try {
        onLine(line, child);
      } catch (_) {
        // A failing observer must not take down the output pump.
      }
    }

    const decoder = Utf8Decoder(allowMalformed: true);
    final out = process.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(handle)
        .asFuture<void>();
    final err = process.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(handle)
        .asFuture<void>();
    child.exitCode = process.exitCode.then((code) async {
      await Future.wait([out, err])
          .timeout(const Duration(seconds: 2), onTimeout: () => const []);
      child._exited = true;
      _live.remove(child);
      return code;
    });
    return child;
  }

  /// SIGTERM, then SIGKILL after [grace]. Returns the exit code.
  Future<int> stop({Duration grace = const Duration(seconds: 5)}) async {
    if (!_exited) {
      _process.kill(ProcessSignal.sigterm);
      try {
        return await exitCode.timeout(grace);
      } on TimeoutException {
        _process.kill(ProcessSignal.sigkill);
      }
    }
    return exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }

  static Future<void> stopAll() =>
      Future.wait(List.of(_live).map((c) => c.stop()));
}

/// One holder per wallet.db (rule R8), across sessions, hosts and
/// processes.
///
/// In this process: a set of held directories. Across processes:
/// `<walletDir>/.wallet.lock`, created exclusively, recording this process
/// and the child that has the database open. A lock whose owner is gone is
/// stale; if its child is still running (an orphan of a crash) it is
/// stopped before the wallet is opened again.
class _WalletLock {
  _WalletLock._(this.dir, this._file);

  static final Set<String> _held = {};
  static const String fileName = '.wallet.lock';

  final String dir;
  final File _file;
  bool _released = false;
  int? _childPid;
  String? _childExe;

  static Future<_WalletLock> acquire(String walletDir, BeamHostLog log) async {
    final dir = p.normalize(p.absolute(walletDir));
    if (_held.contains(dir)) {
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'This wallet is already open',
      );
    }
    _held.add(dir);
    try {
      final file = File(p.join(dir, fileName));
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await file.create(exclusive: true);
          final lock = _WalletLock._(dir, file);
          await lock._write();
          return lock;
        } on FileSystemException {
          if (!await file.exists()) rethrow;
          if (await _holderIsLive(file, log)) break;
          try {
            await file.delete();
          } on FileSystemException {
            // Raced with another remover; the next create decides.
          }
        }
      }
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'Another process is using this wallet',
      );
    } catch (_) {
      _held.remove(dir);
      rethrow;
    }
  }

  Future<void> _write() => _file.writeAsString(
    jsonEncode({
      'pid': pid,
      'exe': p.basename(Platform.resolvedExecutable),
      'child': _childPid,
      'childExe': _childExe,
    }),
    flush: true,
  );

  Future<void> setChild(int childPid, String childExe) async {
    _childPid = childPid;
    _childExe = childExe;
    if (!_released) await _write();
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.delete();
    } on FileSystemException {
      // Already gone.
    }
    _held.remove(dir);
  }

  static Future<bool> _holderIsLive(File file, BeamHostLog log) async {
    Map<String, Object?>? info;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) info = decoded;
    } on FormatException {
      info = null;
    } on FileSystemException {
      return false;
    }
    if (info == null) {
      // Being written by another process right now, or garbage.
      final age = DateTime.now().difference(await file.lastModified());
      return age < const Duration(seconds: 10);
    }

    final owner = info['pid'];
    final ownerExe = info['exe'];
    final ownerAlive =
        owner is int &&
        owner != pid &&
        await _pidRunning(owner, ownerExe is String ? ownerExe : null);
    if (ownerAlive) return true;

    final child = info['child'];
    final childExeValue = info['childExe'];
    final childExe = childExeValue is String ? childExeValue : null;
    if (child is int && childExe != null) {
      if (await _pidRunning(child, childExe)) {
        log('Stopping $childExe (pid $child) left running by an earlier run');
        await _terminate(child, childExe);
        return _pidRunning(child, childExe);
      }
    }
    return false;
  }

  static Future<void> _terminate(int target, String exe) async {
    Process.killPid(target, ProcessSignal.sigterm);
    for (var i = 0; i < 25; i++) {
      if (!await _pidRunning(target, exe)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    Process.killPid(target, ProcessSignal.sigkill);
    for (var i = 0; i < 10; i++) {
      if (!await _pidRunning(target, exe)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Whether [target] runs and, if [exe] is given, is that executable (so a
  /// recycled pid is not mistaken for the holder).
  static Future<bool> _pidRunning(int target, String? exe) async {
    if (target <= 0) return false;
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', [
        '/FI',
        'PID eq $target',
        '/FO',
        'CSV',
        '/NH',
      ]);
      final out = '${result.stdout}';
      if (!out.contains('"$target"')) return false;
      return exe == null || out.toLowerCase().contains(exe.toLowerCase());
    }
    final ps = File('/bin/ps').existsSync() ? '/bin/ps' : 'ps';
    final result = await Process.run(ps, ['-p', '$target', '-o', 'comm=']);
    final out = '${result.stdout}'.trim();
    if (result.exitCode != 0 || out.isEmpty) return false;
    if (exe == null) return true;
    final name = p.basename(out);
    // Linux truncates comm to 15 characters.
    return name == exe || (name.length >= 15 && exe.startsWith(name));
  }
}
