/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../rpc/beam_transport.dart';
import '../rpc/tcp_line_transport.dart';
import 'beam_binaries.dart';
import 'beam_binaries_manifest.dart';
import 'beam_core_library.dart';
import 'beam_host.dart';
import 'beam_host_exception.dart';
import 'in_process_files.dart';
import 'process_host.dart'
    show BeamHostLog, BeamTransportFactory, ProcessHost, kBeamApiVersion;

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

/// [BeamHost] for iOS: BEAM's wallet-api runs inside the app process
/// (the project notes). An iOS app may not start child processes, so the core
/// is linked in as a library ([BeamCoreLibrary], scripts/beam/core/ios) and
/// `beam_wallet_api_run()` runs on a background isolate's thread.
///
/// Everything above the transport is the same as on the desktop: wallet-api
/// in TCP line mode on a random 127.0.0.1 port, a fresh 256-bit ACL key per
/// launch, the password in a 0600 `--config_file` that is deleted as soon as
/// wallet-api has read it, never on its command line, and the same flags as
/// [ProcessHost] (API 7.4, BANS shader at privilege 1, assets, Lelantus).
///
/// What differs, because there is no child process:
///
/// * One wallet-api per process. A second wallet cannot open until the first
///   is closed ([BeamHostError.walletInUse]).
/// * wallet-api's console is the app's stdout, so it runs at `warning`, like
///   its file log; nothing is read from it. Start-up is judged by the port
///   accepting, a failure by the exit status plus a password check
///   (`beam_wallet_api_check_wallet`).
/// * wallet-api resolves `./logs` and stray `wallet-api.cfg` /
///   `beam-common.cfg` against the process's current directory, so the host
///   sets it to `run/` for the start-up (strays removed first) and restores it
///   once the server listens.
/// * No beam-node (phones use public nodes), so no owner key and no rescan.
/// * Wallets are created in-process (`beam_wallet_api_init_wallet`, what
///   `beam-wallet restore` does); the password and words cross into native
///   memory only, wiped after the call.
///
/// Layout under [rootDir], every directory 0700:
///
/// ```
/// wallets/<id>/   wallet.db
/// run/            current directory during start-up; transient .s-* secret
///                 files; logs/ (BEAM's own file log, warnings and errors)
/// ```
class InProcessHost implements BeamHost {
  InProcessHost({
    required String rootDir,
    this._library,
    BeamCoreLibrary? Function()? openLibrary,
    this._transportFactory,
    BeamHostLog? log,
    this.startupTimeout = const Duration(seconds: 20),
    this.stopTimeout = const Duration(seconds: 15),
    this.setCurrentDirectory = _setCurrentDirectory,
  }) : rootDir = p.normalize(p.absolute(rootDir)),
       _openLibrary = openLibrary ?? FfiBeamCoreLibrary.open,
       _log = log ?? _noLog;

  final String rootDir;

  /// How long wallet-api may take to listen and answer `get_version`.
  final Duration startupTimeout;

  /// How long [InProcessSession.close] waits for wallet-api to return after
  /// the stop request (it is repeated meanwhile).
  final Duration stopTimeout;

  /// Changes the process's current directory and returns the previous one.
  /// Tests replace it; the app uses [Directory.current].
  final String Function(String path) setCurrentDirectory;

  final BeamTransportFactory? _transportFactory;
  final BeamHostLog _log;
  final BeamCoreLibrary? Function() _openLibrary;
  BeamCoreLibrary? _library;

  static String _setCurrentDirectory(String path) {
    final previous = Directory.current.path;
    Directory.current = path;
    return previous;
  }

  /// The one wallet-api of this process, across hosts (a host per root).
  static InProcessSession? _active;

  /// Completes when the session that was open last has fully stopped.
  static Future<void> _lastStopped = Future.value();

  /// Wallet directories with an operation or a session in progress (R8).
  static final Set<String> _busy = {};

  /// Whether the core's rules were checked in this process.
  static bool _consensusChecked = false;

  String get runDir => p.join(rootDir, 'run');
  String get logsDir => p.join(runDir, 'logs');
  String get walletsDir => p.join(rootDir, 'wallets');

  static String _dbPath(String walletDir) => p.join(walletDir, 'wallet.db');
  static String _normalize(String path) => p.normalize(p.absolute(path));

  // ---------------------------------------------------------------------------
  // Setup

  Future<void>? _prepared;

  Future<void> _prepare() =>
      _prepared ??= _doPrepare().catchError((Object e, StackTrace s) {
        _prepared = null;
        Error.throwWithStackTrace(e, s);
      });

  Future<void> _doPrepare() async {
    await InProcessFiles.ensurePrivateDir(rootDir);
    await InProcessFiles.ensurePrivateDir(runDir);
    await InProcessFiles.ensurePrivateDir(logsDir);
    await InProcessFiles.ensurePrivateDir(walletsDir);
    final removed = await InProcessFiles.sweep(runDir);
    if (removed > 0) {
      _log('Removed $removed secret file(s) left by an earlier run');
    }
  }

  /// The linked core, after a one-time check that it follows mainnet's
  /// current consensus (HF6), as [BeamBinaries.prepare] checks a binary.
  BeamCoreLibrary _core() {
    final lib = _library ??= _openLibrary();
    if (lib == null) {
      throw const BeamHostException(
        BeamHostError.binaryMissing,
        'The BEAM core is not part of this app build',
      );
    }
    if (!_consensusChecked) {
      final rules = lib.rulesSignature();
      if (!BeamBinaries.rulesIncludeHf6('Rules signature: $rules')) {
        throw const BeamHostException(
          BeamHostError.consensusMismatch,
          'The BEAM core does not report mainnet rules with HF6 '
          '($kBeamHf6RulesFork)',
        );
      }
      _consensusChecked = true;
      _log('BEAM core ${lib.version()} (in-process)');
    }
    return lib;
  }

  /// Claims [walletDir] for one operation or session (rule R8).
  static void _claim(String walletDir) {
    if (!_busy.add(walletDir)) {
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'This wallet is already open or busy',
      );
    }
  }

  Future<String> _existingWallet(String walletDir) async {
    final dir = _normalize(walletDir);
    if (!await File(_dbPath(dir)).exists()) {
      throw const BeamHostException(
        BeamHostError.walletNotFound,
        'No wallet.db in the wallet directory',
      );
    }
    await InProcessFiles.ensurePrivateDir(dir);
    return dir;
  }

  /// wallet-api reads `beam-common.cfg` and `wallet-api.cfg` from the current
  /// directory. Nothing legitimate puts them in run/; one could turn off the
  /// ACL or change the node.
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

  // ---------------------------------------------------------------------------
  // BeamHost

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) async {
    ProcessHost.validatePassword(password);
    ProcessHost.validateWords(words);
    await _prepare();
    final core = _core();
    final dir = _normalize(walletDir);
    await InProcessFiles.ensurePrivateDir(dir);
    final db = _dbPath(dir);
    _claim(dir);
    var ownsDb = false;
    try {
      if (await File(db).exists()) {
        throw const BeamHostException(
          BeamHostError.walletExists,
          'wallet.db already exists in the wallet directory',
        );
      }
      ownsDb = true;
      final rc = await core.initWallet(
        dbPath: db,
        password: password,
        phrase: words.join(';'),
      );
      switch (rc) {
        case BeamCoreWalletResult.ok:
          break;
        case BeamCoreWalletResult.exists:
          ownsDb = false;
          throw const BeamHostException(
            BeamHostError.walletExists,
            'wallet.db already exists in the wallet directory',
          );
        case BeamCoreWalletResult.invalidPhrase:
          throw const BeamHostException(
            BeamHostError.invalidInput,
            'The BEAM core rejected the seed phrase',
          );
        default:
          throw BeamHostException(
            BeamHostError.processFailed,
            'Creating the wallet failed (core result $rc)',
          );
      }
      if (!await File(db).exists()) {
        throw const BeamHostException(
          BeamHostError.processFailed,
          'Creating the wallet failed: no wallet.db afterwards',
        );
      }
      InProcessFiles.chmod(db, 0x180);
      ownsDb = false;
      _log('Created wallet.db in ${p.basename(dir)}');
    } catch (_) {
      if (ownsDb) await _deleteDb(db);
      rethrow;
    } finally {
      _busy.remove(dir);
    }
  }

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async {
    ProcessHost.validatePassword(password);
    ProcessHost.validateNode(node);
    await _prepare();
    final core = _core();
    final dir = await _existingWallet(walletDir);
    _claim(dir);
    try {
      await _waitForCoreIdle(core);
      await _removeStrayConfigs();
      return await _launch(
        core: core,
        walletDir: dir,
        password: password,
        node: node,
        requestBodies: requestBodies,
      );
    } catch (_) {
      _busy.remove(dir);
      rethrow;
    }
  }

  /// No private node on iOS, so the owner key is never needed, and it is not
  /// read: it would reveal every incoming payment. Same error as Android's
  /// [ProcessHost.exportOwnerKey].
  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async {
    throw const BeamHostException(
      BeamHostError.notOwnedNode,
      'Phones run no private node; the owner key is not read on iOS',
    );
  }

  /// A rescan needs the user's own node, which phones do not run.
  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) async {
    throw const BeamHostException(
      BeamHostError.notOwnedNode,
      'Rescan needs your own node holding the owner key, which this device '
      'does not run',
    );
  }

  /// Stops the open wallet-api, if any. For the app's shutdown path.
  static Future<void> shutdownAll() async {
    final session = _active;
    if (session != null) await session.close();
    await _lastStopped;
  }

  // ---------------------------------------------------------------------------
  // wallet-api

  /// Waits for the previous session to stop; then, if a wallet-api still runs
  /// (one started before a hot restart of the Dart side), stops it.
  Future<void> _waitForCoreIdle(BeamCoreLibrary core) async {
    final other = _active;
    if (other != null && !other.isClosed) {
      throw const BeamHostException(
        BeamHostError.walletInUse,
        'Another BEAM wallet is open; this device runs one at a time',
      );
    }
    await _lastStopped.timeout(stopTimeout, onTimeout: () {});
    if (!core.isRunning) return;
    _log('A BEAM core from an earlier session is still running; stopping it');
    final deadline = DateTime.now().add(stopTimeout);
    while (core.isRunning) {
      core.stop();
      if (DateTime.now().isAfter(deadline)) {
        throw const BeamHostException(
          BeamHostError.walletInUse,
          'The BEAM core from an earlier session did not stop',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  BeamTransport _transport(int port, String aclKey) {
    final factory = _transportFactory;
    if (factory != null) return factory(port: port, aclKey: aclKey);
    return TcpLineTransport(port: port, aclKey: aclKey, log: _log);
  }

  /// The command line, as [ProcessHost] passes it, minus anything secret.
  List<String> walletApiArgs({
    required String walletDir,
    required String configPath,
    required String aclPath,
    required BeamNodeEndpoint node,
    required int port,
    required bool requestBodies,
  }) => [
    '--wallet_path=${_dbPath(walletDir)}',
    '--config_file=$configPath',
    '--node_addr=$node',
    '--port=$port',
    '--use_http=0',
    '--tcp_max_line=$_tcpMaxLine',
    '--ip_whitelist=127.0.0.1',
    '--use_acl=1',
    '--acl_path=$aclPath',
    '--enable_assets',
    '--enable_lelantus',
    '--api_version=$kBeamApiVersion',
    '--request_bodies=${requestBodies ? 1 : 0}',
    // The in-process core is always Campfire's build (patch 0002). BANS needs
    // privilege 1; every other shader, including any dApp's, stays at 0.
    '--privileged_shader_sha256=${kBeamPrivilegedShaderSha256s.join(',')}',
    // The console is the app's stdout; at info it would carry every address
    // and amount. Warnings and errors only, like the file log.
    '--log_level=warning',
    '--file_log_level=warning',
    '--log_cleanup_days=3',
  ];

  Future<InProcessSession> _launch({
    required BeamCoreLibrary core,
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    required bool requestBodies,
  }) async {
    final port = await _freeLoopbackPort();
    final aclKey = _randomHex(32);
    File? cfg;
    File? acl;
    _CoreRun? run;
    BeamTransport? transport;
    String? previousDir;
    try {
      cfg = await InProcessFiles.writeSecret(runDir, 'pass=$password\n');
      // Exactly one line and no blank line: wallet-api refuses to start on
      // any line it cannot parse.
      acl = await InProcessFiles.writeSecret(
        runDir,
        '$aclKey:write\n',
        suffix: '.acl',
      );
      _log(
        'Starting wallet-api (in-process) for ${p.basename(walletDir)} on '
        '$node, port $port${requestBodies ? ', body requests on' : ''}',
      );
      previousDir = setCurrentDirectory(runDir);
      final started = DateTime.now();
      final thisRun = _CoreRun(
        core.run(
          walletApiArgs(
            walletDir: walletDir,
            configPath: cfg.path,
            aclPath: acl.path,
            node: node,
            port: port,
            requestBodies: requestBodies,
          ),
        ),
      );
      run = thisRun;

      // wallet-api reads its config and ACL, opens the database, and only
      // then listens. A port that accepts means start-up is over.
      while (true) {
        final code = thisRun.code;
        if (code != null) {
          throw await _startupFailure(core, code, walletDir, password, node);
        }
        if (await _accepts(port)) break;
        if (DateTime.now().difference(started) > startupTimeout) {
          throw BeamHostException(
            BeamHostError.timeout,
            'wallet-api did not start listening within '
            '${startupTimeout.inSeconds} s',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      setCurrentDirectory(previousDir);
      previousDir = null;
      await InProcessFiles.deleteSecret(cfg);
      await InProcessFiles.deleteSecret(acl);

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

      final session = InProcessSession._(
        host: this,
        core: core,
        walletDir: walletDir,
        password: password,
        node: node,
        requestBodies: requestBodies,
        transport: t,
        port: port,
        run: thisRun,
      );
      _active = session;
      _lastStopped = thisRun.done;
      unawaited(thisRun.done.then((_) => session._coreExited(thisRun.code!)));
      _log(
        'wallet-api is up on port $port '
        '(${DateTime.now().difference(started).inMilliseconds} ms)',
      );
      return session;
    } catch (_) {
      try {
        await transport?.close();
      } catch (_) {
        // Stopped next either way.
      }
      if (run != null) {
        _lastStopped = run.done;
        await _stopCore(core, run);
      }
      rethrow;
    } finally {
      if (previousDir != null) setCurrentDirectory(previousDir);
      await InProcessFiles.deleteSecret(cfg);
      await InProcessFiles.deleteSecret(acl);
    }
  }

  /// Asks wallet-api to stop until [run] has returned or [stopTimeout]
  /// passes. The request is repeated: one that arrives before wallet-api's
  /// event loop exists is kept by the core, but this also covers a run that
  /// had not begun yet. It is sent only while [run] is still going, because
  /// `beam_wallet_api_stop()` stops whatever runs, and the next session's run
  /// may follow this one.
  Future<bool> _stopCore(BeamCoreLibrary core, _CoreRun run) async {
    final deadline = DateTime.now().add(stopTimeout);
    while (!run.hasExited) {
      core.stop();
      if (DateTime.now().isAfter(deadline)) {
        _log(
          'wallet-api did not stop within ${stopTimeout.inSeconds} s; it '
          'keeps the wallet until it does',
        );
        return false;
      }
      await Future.any([
        run.done,
        Future<void>.delayed(const Duration(milliseconds: 100)),
      ]);
    }
    return true;
  }

  /// Why wallet-api returned [code] before it listened. Asks the core whether
  /// the password opens the wallet (the console that says so on the desktop
  /// is not readable in-process).
  Future<BeamHostException> _startupFailure(
    BeamCoreLibrary core,
    int code,
    String walletDir,
    String password,
    BeamNodeEndpoint node,
  ) async {
    if (code == kBeamCoreAlreadyRunning) {
      return const BeamHostException(
        BeamHostError.walletInUse,
        'Another BEAM wallet is open; this device runs one at a time',
      );
    }
    final check = await core.checkWallet(
      dbPath: _dbPath(walletDir),
      password: password,
    );
    if (check == BeamCoreWalletResult.wrongPassword) {
      return const BeamHostException(
        BeamHostError.wrongPassword,
        'The wallet password is wrong',
      );
    }
    if (check == BeamCoreWalletResult.notFound) {
      return const BeamHostException(
        BeamHostError.walletNotFound,
        'wallet-api found no wallet.db',
      );
    }
    if (check == BeamCoreWalletResult.ok && !await _resolves(node.host)) {
      return BeamHostException(
        BeamHostError.badNode,
        'wallet-api could not resolve the node address $node',
      );
    }
    return BeamHostException(
      BeamHostError.processFailed,
      'wallet-api stopped during start-up (exit $code)',
    );
  }

  static Future<bool> _resolves(String host) async {
    if (InternetAddress.tryParse(host) != null) return true;
    try {
      return (await InternetAddress.lookup(host)).isNotEmpty;
    } on SocketException {
      return false;
    }
  }

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
}

/// An open wallet: the in-process wallet-api and the transport to it.
class InProcessSession implements BeamSession {
  InProcessSession._({
    required this._host,
    required this._core,
    required this.walletDir,
    required this._password,
    required this.node,
    required this.requestBodies,
    required this.transport,
    required this.port,
    required this._run,
  });

  final InProcessHost _host;
  final BeamCoreLibrary _core;

  /// Held only so [switchNode] can restart wallet-api. Never logged, never
  /// in [toString].
  final String _password;
  final _CoreRun _run;
  Future<void>? _closing;

  final String walletDir;
  final bool requestBodies;

  /// Loopback port wallet-api listens on.
  final int port;

  @override
  final BeamTransport transport;

  @override
  final BeamNodeEndpoint node;

  bool get isClosed => _closing != null;

  /// Completes with wallet-api's exit status once it has returned (the wallet
  /// database is closed by then).
  Future<int> get exitCode => _run.exit;

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

  /// Closes the transport, asks wallet-api to stop and waits until it has
  /// returned (at most [InProcessHost.stopTimeout]; until then the wallet
  /// stays claimed, so nothing reopens a database that is still open).
  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    try {
      await transport.close();
    } catch (_) {
      // Closing a dead connection; wallet-api is stopped regardless.
    }
    final stopped = await _host._stopCore(_core, _run);
    if (stopped) {
      _release();
    } else {
      unawaited(_run.done.then((_) => _release()));
    }
  }

  void _release() {
    InProcessHost._busy.remove(walletDir);
    if (identical(InProcessHost._active, this)) InProcessHost._active = null;
  }

  void _coreExited(int code) {
    if (_closing != null) return;
    _host._log('wallet-api stopped unexpectedly (exit $code)');
    unawaited(close());
  }

  @override
  String toString() => 'InProcessSession($node, port $port)';
}

/// One `beam_wallet_api_run()` call. Whether it has returned is known
/// synchronously ([hasExited]): its first listener records the status, before
/// anything else that waits for it (another session's start included) runs.
class _CoreRun {
  _CoreRun(this.exit) {
    done = exit.then(
      (c) {
        code = c;
      },
      onError: (Object _) {
        code = kBeamCoreUncaughtException;
      },
    );
  }

  final Future<int> exit;

  /// Completes once the run has returned and [code] is set. Never fails.
  late final Future<void> done;

  /// The exit status, once the run has returned.
  int? code;

  bool get hasExited => code != null;
}
