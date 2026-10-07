/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../host/beam_binaries.dart';
import '../host/beam_host.dart';
import '../host/beam_host_exception.dart';
import '../host/process_host.dart';
import '../host/secret_file.dart';
import 'beam_node_progress.dart';

/// Peers a fresh mainnet `beam-node` is pointed at: BEAM's current defaults
/// (`wallet/core/default_peers.cpp:46-47`). Checked 2026-10-06: both
/// resolve (4 addresses each) and accept TCP on 8100. LightWallet's
/// `ap-node01` no longer resolves.
const List<String> kBeamMainnetNodePeers = [
  'eu-nodes.mainnet.beam.mw:8100',
  'us-nodes.mainnet.beam.mw:8100',
];

/// How long beam-node gets to stop after SIGTERM before SIGKILL. Measured
/// 2026-10-06: during its post-fast-sync "Raising Fossil" step the node
/// ignored SIGTERM for more than 10 s, and a kill there risks its database.
/// (wallet-api keeps its own shorter grace.)
const Duration kBeamNodeStopGrace = Duration(seconds: 45);

/// A node failure with a typed reason. [message] never holds a secret.
class BeamNodeException implements Exception {
  const BeamNodeException(this.kind, this.message);

  final BeamNodeError kind;
  final String message;

  @override
  String toString() => 'BeamNodeException(${kind.name}): $message';
}

/// A private node that keeps its storage in a directory (the coordinator
/// measures that directory's disk).
abstract interface class BeamNodeStorage {
  String get nodeDir;
}

/// What the handover coordinator needs from a private node.
/// [BeamNodeProcess] is the desktop implementation.
abstract interface class BeamPrivateNode {
  /// P2P port on 127.0.0.1, once started.
  int? get port;

  BeamNodeProgress get progress;

  /// Every change of [progress]. Broadcast.
  Stream<BeamNodeProgress> get progressStream;

  /// Starts the node holding [ownerKey]. Completes once the node has read
  /// (and this has deleted) its config file and has either listed the owned
  /// account or kept running for the start-up window. Throws
  /// [BeamNodeException] or [BeamHostException]; a node that does not take
  /// the key is stopped, never left running keyless.
  Future<void> start({required String ownerKey, required String password});

  /// Stops the node. Safe to call more than once.
  Future<void> stop();
}

/// Runs the pinned `beam-node` with fast sync and the wallet's owner key.
///
/// Layout under `<rootDir>/node`, 0700 (the same `node/` that
/// [ProcessHost] creates and sweeps):
///
/// ```
/// node.db, node-utxo-image.bin   BEAM storage (CWD-relative)
/// .node.lock                     which process runs a node on this storage
/// .s-*.cfg                       owner_key + pass, 0600, deleted on read
/// logs/                          0700: campfire-node-*.log (redacted, 0600)
///                                and BEAM's own node_*.log (warnings only)
/// ```
///
/// * Secrets go only into the 0600 `--config_file`, unlinked as soon as the
///   node prints `Reading config from`. Never argv, never a log.
/// * The owner key is not kept: [start] writes it to that file and drops it.
/// * Console lines are parsed into [progressStream] and written to a 0600
///   log after [BeamNodeLogRedactor].
/// * A `beam-node` left running on this storage by a crashed app is found
///   through `.node.lock` and stopped before a new one starts.
class BeamNodeProcess implements BeamPrivateNode, BeamNodeStorage {
  BeamNodeProcess({
    required String rootDir,
    required this.binaries,
    this.peers = kBeamMainnetNodePeers,
    BeamHostLog? log,
    this.configReadTimeout = const Duration(seconds: 30),
    this.startupWindow = const Duration(seconds: 30),
    this.stopGrace = kBeamNodeStopGrace,
    this.maxLogBytes = 8 * 1024 * 1024,
    DateTime Function()? now,
  }) : rootDir = p.normalize(p.absolute(rootDir)),
       _log = log ?? _noLog,
       _now = now ?? DateTime.now;

  final String rootDir;
  final BeamBinaries binaries;

  /// `host:port` peers passed as `--peer`.
  final List<String> peers;

  /// How long the node may take to print `Reading config from`.
  final Duration configReadTimeout;

  /// After the config was read, how long [start] waits for the owned
  /// account listing (or an error) before returning.
  final Duration startupWindow;

  /// Time between SIGTERM and SIGKILL ([kBeamNodeStopGrace]).
  final Duration stopGrace;

  /// The redacted console log rolls over to a new file past this size.
  final int maxLogBytes;

  final BeamHostLog _log;
  final DateTime Function() _now;

  static final Set<BeamNodeProcess> _live = {};

  @override
  String get nodeDir => p.join(rootDir, 'node');
  String get logsDir => p.join(nodeDir, 'logs');

  /// Storage name, relative to [nodeDir] (the node's CWD).
  static const String storageName = 'node.db';

  final _progressController = StreamController<BeamNodeProgress>.broadcast();
  late final BeamNodeLogParser _parser = BeamNodeLogParser(now: _now);
  BeamNodeProgress _progress = const BeamNodeProgress();
  Process? _process;
  _NodeLock? _lock;
  _RotatingLog? _console;
  SecretFile? _config;
  int? _port;
  bool _started = false;
  bool _stopRequested = false;
  Future<void>? _stopping;
  final Completer<int> _exit = Completer<int>();

  @override
  int? get port => _port;

  int? get pid => _process?.pid;

  @override
  BeamNodeProgress get progress => _progress;

  @override
  Stream<BeamNodeProgress> get progressStream => _progressController.stream;

  bool get isRunning => _process != null && !_exit.isCompleted;

  /// Completes with the exit code once the node has exited.
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    if (_started) throw StateError('BeamNodeProcess is single-use');
    _started = true;
    if (ownerKey.isEmpty) {
      // A keyless node cannot see offline or max-privacy payments, and
      // nothing here may pretend otherwise (LightWallet serve.py:877-883).
      throw const BeamNodeException(
        BeamNodeError.ownerKeyRejected,
        'A private node needs the owner key; a keyless node is never started',
      );
    }
    checkConfigValue('owner_key', ownerKey);
    ProcessHost.validatePassword(password);
    for (final peer in peers) {
      ProcessHost.validateNode(BeamNodeEndpoint.parse(peer));
    }

    try {
      await ensurePrivateDir(rootDir);
      await ensurePrivateDir(nodeDir);
      await ensurePrivateDir(logsDir);
      await _pruneLogs();
      _lock = await _NodeLock.acquire(nodeDir, _log);
      final exe = await binaries.prepare(
        BeamBinary.node,
        scratchParent: nodeDir,
      );
      await _removeStrayConfigs();
      await _launch(exe, ownerKey, password);
    } catch (_) {
      await _cleanup();
      rethrow;
    }
  }

  Future<void> _launch(String exe, String ownerKey, String password) async {
    final port = await _freePort();
    final config = await SecretFile.writeConfig(nodeDir, {
      'owner_key': ownerKey,
      'pass': password,
    });
    _config = config;
    final cfgName = p.basename(config.path);
    // The key is not handed to the redactor, so nothing keeps it once the
    // config file is written; its base64 shape is redacted regardless.
    final redactor = BeamNodeLogRedactor([password]);
    final console =
        _console ??= await _RotatingLog.open(logsDir, maxLogBytes, _log);
    final configRead = Completer<void>();
    final settled = Completer<void>();

    final args = [
      '--port=$port',
      '--storage=$storageName',
      '--fast_sync=1',
      for (final peer in peers) '--peer=$peer',
      '--config_file=${config.path}',
      '--stratum_port=0',
      '--websocket_port=0',
      '--log_level=info',
      // BEAM's own file log stays at warnings: the info-level owned
      // accounts listing then reaches only the redacted console log.
      '--file_log_level=warning',
      '--log_cleanup_days=3',
    ];
    _log(
      'Starting beam-node on port $port, peers ${peers.join(', ')}, '
      'storage ${p.join(p.basename(nodeDir), storageName)}',
    );

    final Process process;
    // The last hash, right before the exec of the same path: nothing else
    // sits between the check and the launch.
    await binaries.verifyUnchanged(BeamBinary.node);
    try {
      process = await Process.start(exe, args, workingDirectory: nodeDir);
    } on ProcessException catch (e) {
      throw BeamHostException(
        BeamHostError.processFailed,
        'Could not start beam-node: ${e.message}',
      );
    }
    _process = process;
    _port = port;
    _live.add(this);
    process.stdin.done.ignore();
    process.stdin.close().ignore();
    await _lock?.setChild(process.pid);

    void onLine(String raw) {
      try {
        if (!configRead.isCompleted &&
            raw.startsWith('Reading config from') &&
            raw.contains(cfgName)) {
          // Printed after the file is open, so unlinking it now is safe.
          config.deleteSync();
          configRead.complete();
        }
        final safe = redactor.redact(raw);
        if (safe != null) console.add(safe);
        final next = _parser.add(raw);
        if (next != null) _publish(next);
        if (!settled.isCompleted &&
            (next?.ownerAccounts != null || _parser.progress.isEnded)) {
          settled.complete();
        }
      } catch (_) {
        // A failing observer must not stop the output pump.
      }
    }

    const decoder = Utf8Decoder(allowMalformed: true);
    final out = process.stdout
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(onLine)
        .asFuture<void>();
    final err = process.stderr
        .transform(decoder)
        .transform(const LineSplitter())
        .listen(onLine)
        .asFuture<void>();
    unawaited(
      process.exitCode.then((code) async {
        await Future.wait([out, err]).timeout(
          const Duration(seconds: 2),
          onTimeout: () => const [],
        );
        _onExit(code);
      }),
    );

    // 1. The config must be read, then it is gone.
    final read = await Future.any<bool>([
      configRead.future.then((_) => true),
      _exit.future.then((_) => false),
    ]).timeout(configReadTimeout, onTimeout: () => false);
    if (!read) {
      final error = _exit.isCompleted
          ? 'beam-node exited before reading its config'
          : 'beam-node did not read its config within '
                '${configReadTimeout.inSeconds} s';
      _publish(_parser.fail(BeamNodeError.configNotRead, error));
      await stop();
      throw BeamNodeException(BeamNodeError.configNotRead, error);
    }
    await config.delete();

    // 2. The owner key must be accepted. BEAM exits with code 0 when it
    // rejects one, so the log decides.
    await Future.any<void>([
      settled.future,
      _exit.future.then((_) {}),
    ]).timeout(startupWindow, onTimeout: () {});
    final now = _parser.progress;
    if (now.error != null || _exit.isCompleted) {
      await stop();
      final kind = now.error ?? BeamNodeError.exited;
      throw BeamNodeException(
        kind,
        now.errorDetail ?? 'beam-node exited during start-up',
      );
    }
    _log(
      'beam-node is up on port $port (pid ${process.pid})'
      '${now.ownerAccounts == null ? '' : ', owner key accepted'}',
    );
  }

  void _publish(BeamNodeProgress next) {
    if (next == _progress) return;
    _progress = next;
    if (!_progressController.isClosed) _progressController.add(next);
  }

  void _onExit(int code) {
    final requested = _stopRequested;
    final before = _parser.progress;
    final last = _parser.finish(exitCode: code, requested: requested);
    if (!requested) {
      _log(
        'beam-node exited unexpectedly (code $code'
        '${before.error == null ? '' : ', ${before.error!.name}'})',
      );
    }
    _publish(last);
    if (!_exit.isCompleted) _exit.complete(code);
    _live.remove(this);
    unawaited(_cleanup());
  }

  /// SIGTERM, then SIGKILL after [stopGrace].
  @override
  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _stopRequested = true;
    final process = _process;
    if (process != null && !_exit.isCompleted) {
      process.kill(ProcessSignal.sigterm);
      try {
        await _exit.future.timeout(stopGrace);
      } on TimeoutException {
        _log('beam-node ignored SIGTERM; killing it');
        process.kill(ProcessSignal.sigkill);
        await _exit.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => -1,
        );
      }
    }
    await _cleanup();
    _live.remove(this);
    if (!_progressController.isClosed && _exit.isCompleted) {
      await _progressController.close();
    }
  }

  Future<void> _cleanup() async {
    await _config?.delete();
    if (_exit.isCompleted || _process == null) {
      await _lock?.release();
      await _console?.close();
      await _privatizeBeamLogs();
    }
  }

  /// Stops every node started in this process. Call before the app exits.
  static Future<void> stopAll() =>
      Future.wait(List.of(_live).map((n) => n.stop()));

  /// BEAM reads `beam-node.cfg` / `beam-common.cfg` from its CWD. Nothing
  /// legitimate puts one in node/, and one could add peers or keys.
  Future<void> _removeStrayConfigs() async {
    for (final name in const ['beam-node.cfg', 'beam-common.cfg']) {
      final file = File(p.join(nodeDir, name));
      if (await file.exists()) {
        _log('Removing unexpected $name from the node directory');
        await file.delete();
      }
    }
  }

  /// BEAM creates its own log files with the default umask. logs/ is 0700
  /// regardless; this tightens the files too.
  Future<void> _privatizeBeamLogs() async {
    if (Platform.isWindows) return;
    try {
      await for (final entity in Directory(logsDir).list()) {
        if (entity is File && p.basename(entity.path).startsWith('node_')) {
          final mode = await posixMode(entity.path);
          if (mode != null && mode != 0x180) await setOwnerOnly(entity.path);
        }
      }
    } catch (_) {
      // Best effort; the directory is private either way.
    }
  }

  Future<void> _pruneLogs() async {
    final cutoff = _now().subtract(const Duration(days: 3));
    await for (final entity in Directory(logsDir).list()) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith(_RotatingLog.prefix)) {
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

  /// A port free on every interface: stock beam-node binds 0.0.0.0
  /// (`beam/cli.cpp:393`) until the loopback-patched build (B-BIN-1).
  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  @override
  String toString() =>
      'BeamNodeProcess(port $_port, ${_progress.phase.name})';
}

void _noLog(String _) {}

final Random _random = Random();

/// The redacted console log: 0600 files under node/logs, rolled over at a
/// size limit, at most [_keep] files.
///
/// Lines that arrive while a new file is being created wait in a backlog
/// and go into the new file, in order; the old file stays the target until
/// the new one exists, so a failed roll loses nothing.
class _RotatingLog {
  _RotatingLog._(this._dir, this._maxBytes, this._log);

  static const String prefix = 'campfire-node-';
  static const int _keep = 4;
  static const int _maxBacklog = 10000;

  final String _dir;
  final int _maxBytes;
  final BeamHostLog _log;
  IOSink? _sink;
  int _bytes = 0;
  int _serial = 0;
  bool _closed = false;
  bool _rolling = false;
  final List<String> _backlog = [];
  Future<void> _pending = Future.value();

  static Future<_RotatingLog> open(
    String dir,
    int maxBytes,
    BeamHostLog log,
  ) async {
    final l = _RotatingLog._(dir, maxBytes, log);
    await l._roll();
    return l;
  }

  /// Creates the next file and makes it the target, then closes the old
  /// one and trims old files.
  Future<void> _roll() async {
    final t = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
    // A random part, so two launches in the same second never collide on
    // the exclusive create.
    final tag = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final file = await createPrivateFile(
      p.join(_dir, '$prefix$stamp-${_serial++}-$tag.log'),
    );
    final sink = file.openWrite(mode: FileMode.append);
    sink.done.ignore();
    final old = _sink;
    _sink = sink;
    _bytes = 0;
    if (old != null) await old.close().catchError((Object _) {});
    await _trim();
  }

  Future<void> _trim() async {
    final files = <File>[];
    await for (final e in Directory(_dir).list()) {
      if (e is File && p.basename(e.path).startsWith(prefix)) files.add(e);
    }
    if (files.length <= _keep) return;
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files.take(files.length - _keep)) {
      try {
        await f.delete();
      } on FileSystemException {
        // Next roll tries again.
      }
    }
  }

  void add(String line) {
    if (_closed) return;
    if (_rolling) {
      if (_backlog.length < _maxBacklog) _backlog.add(line);
      return;
    }
    _write(line);
  }

  void _write(String line) {
    final sink = _sink;
    if (sink == null) return;
    sink.writeln(line);
    _bytes += line.length + 1;
    if (_bytes > _maxBytes && !_rolling) {
      _rolling = true;
      _pending = _pending.then((_) => _rollThenDrain());
    }
  }

  Future<void> _rollThenDrain() async {
    try {
      await _roll();
    } catch (e) {
      // Keep writing to the old file; try again after another _maxBytes.
      _bytes = 0;
      _log('Could not roll the node log over: $e');
    }
    _rolling = false;
    final waiting = List.of(_backlog);
    _backlog.clear();
    for (final line in waiting) {
      if (_rolling) {
        _backlog.add(line);
      } else {
        _write(line);
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    // Let a roll in flight finish and drain its backlog first.
    while (_rolling) {
      await _pending;
    }
    _closed = true;
    try {
      await _sink?.close();
    } catch (_) {
      // A log that cannot be flushed is not worth failing a stop over.
    }
  }
}

/// One `beam-node` per storage, across app instances.
///
/// `<nodeDir>/.node.lock` records this process and the node it started. On
/// the next start, a lock whose owner is gone is stale; if its node is still
/// running (the app crashed) that node is stopped first. A node is
/// recognised by pid **and** command line, so a recycled pid is never
/// killed.
class _NodeLock {
  _NodeLock._(this._dir, this._file);

  static final Set<String> _held = {};
  static const String fileName = '.node.lock';

  final String _dir;
  final File _file;
  bool _released = false;

  static Future<_NodeLock> acquire(String nodeDir, BeamHostLog log) async {
    final dir = p.normalize(p.absolute(nodeDir));
    if (_held.contains(dir)) {
      throw const BeamNodeException(
        BeamNodeError.nodeInUse,
        'A private node is already running on this storage',
      );
    }
    _held.add(dir);
    try {
      final file = File(p.join(dir, fileName));
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          await file.create(exclusive: true);
          final lock = _NodeLock._(dir, file);
          await lock._write(null);
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
      throw const BeamNodeException(
        BeamNodeError.nodeInUse,
        'Another app instance is running a private node on this storage',
      );
    } catch (_) {
      _held.remove(dir);
      rethrow;
    }
  }

  Future<void> _write(int? child) => _file.writeAsString(
    jsonEncode({
      'pid': pid,
      'exe': p.basename(Platform.resolvedExecutable),
      'child': child,
      'childExe': BeamBinary.node.id,
      'storage': BeamNodeProcess.storageName,
    }),
    flush: true,
  );

  Future<void> setChild(int childPid) async {
    if (!_released) await _write(childPid);
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _file.delete();
    } on FileSystemException {
      // Already gone.
    }
    _held.remove(_dir);
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
      final age = DateTime.now().difference(await file.lastModified());
      return age < const Duration(seconds: 10);
    }
    final owner = info['pid'];
    final ownerExe = info['exe'];
    if (owner is int && owner != pid && ownerExe is String) {
      final command = await _commandOf(owner);
      if (command != null && command.contains(ownerExe)) return true;
    }
    final child = info['child'];
    if (child is int && await _isOurNode(child)) {
      log('Stopping beam-node (pid $child) left running by an earlier run');
      await _terminate(child);
      return _isOurNode(child);
    }
    return false;
  }

  /// [target] is a beam-node started on this storage by this class.
  static Future<bool> _isOurNode(int target) async {
    final command = await _commandOf(target);
    return command != null &&
        command.contains(BeamBinary.node.id) &&
        command.contains('--storage=${BeamNodeProcess.storageName}') &&
        command.contains('--fast_sync=1');
  }

  /// The full command line of [target], or null if it is not running.
  static Future<String?> _commandOf(int target) async {
    if (target <= 0) return null;
    if (Platform.isWindows) {
      final r = await Process.run('tasklist', [
        '/FI',
        'PID eq $target',
        '/FO',
        'CSV',
        '/NH',
      ]);
      final out = '${r.stdout}';
      return out.contains('"$target"') ? out : null;
    }
    final ps = File('/bin/ps').existsSync() ? '/bin/ps' : 'ps';
    final r = await Process.run(ps, ['-ww', '-p', '$target', '-o', 'command=']);
    final out = '${r.stdout}'.trim();
    return r.exitCode == 0 && out.isNotEmpty ? out : null;
  }

  static Future<void> _terminate(int target) async {
    Process.killPid(target, ProcessSignal.sigterm);
    // The same grace as a normal stop (kBeamNodeStopGrace), in 200 ms steps.
    final steps = kBeamNodeStopGrace.inMilliseconds ~/ 200;
    for (var i = 0; i < steps; i++) {
      if (!await _isOurNode(target)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    Process.killPid(target, ProcessSignal.sigkill);
    for (var i = 0; i < 10; i++) {
      if (!await _isOurNode(target)) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
