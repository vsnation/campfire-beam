/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'beam_core_node_status.dart';

/// `beam_wallet_api_run()` results beyond wallet-api's own exit status
/// (0 stopped normally, 1 unsupported API version, -1 failed).
const int kBeamCoreAlreadyRunning = -100;
const int kBeamCoreUncaughtException = -101;

/// `beam_wallet_api_init_wallet()` / `beam_wallet_api_check_wallet()` results
/// (scripts/beam/core/ios/src/beam_wallet_api.h).
abstract final class BeamCoreWalletResult {
  static const int ok = 0;
  static const int exists = 1;
  static const int notFound = 2;
  static const int wrongPassword = 3;
  static const int invalidPhrase = 4;
  static const int failed = 5;
}

/// The BEAM core linked into the app (iOS), where an app may not start child
/// processes: BEAM's wallet-api built as a library, its `main()` exported as
/// `beam_wallet_api_run()` (scripts/beam/core/ios, patch 0101).
///
/// One wallet-api runs per process. [InProcessHost] is the only user.
abstract class BeamCoreLibrary {
  /// "7.5.14493 (beam-7.5.14493-campfire)".
  String version();

  /// The consensus rules this core follows, as wallet-api logs them after
  /// `Rules signature: `.
  String rulesSignature();

  /// True while a wallet-api runs in this process (also one started before a
  /// hot restart of the Dart side).
  bool get isRunning;

  /// Runs wallet-api with [args] (no argv[0]) on a thread of its own until
  /// [stop] is called or it fails, and completes with its exit status.
  /// Relative paths resolve against the process's current directory when it
  /// starts.
  Future<int> run(List<String> args);

  /// Asks the running wallet-api to stop. Returns at once; [run]'s future
  /// completes once the wallet database is closed. A no-op when idle.
  void stop();

  /// Creates `wallet.db` at [dbPath] from 12 words (`;`-separated), the way
  /// `beam-wallet restore` does. Returns a [BeamCoreWalletResult] code. The
  /// secrets cross into native memory only, which is wiped after the call.
  Future<int> initWallet({
    required String dbPath,
    required String password,
    required String phrase,
  });

  /// Opens and closes `wallet.db` to tell a wrong password from other
  /// start-up failures. Returns a [BeamCoreWalletResult] code.
  Future<int> checkWallet({required String dbPath, required String password});
}

/// What `libbeam_core` (desktop and Android, scripts/beam/core/lib) adds to
/// the iOS core: one logger for the process, the owner key, the private node
/// as a thread of the app (as BEAM's own desktop wallet runs it), and SOCKS5
/// for Tor in wallet-api and the node. iOS has none of these.
abstract interface class BeamCoreIntegrated {
  /// `beam_core_init`: the process's one BEAM logger. Files in [logDir]
  /// (0700, files 0600). Returns 0, or 1 when it was already set up.
  int initLogging({String? logDir, int consoleLevel = 4, int fileLevel = 4});

  /// The owner key of the closed wallet at [dbPath], encrypted with
  /// [password] (`beam-wallet export_owner_key`). `code` is a
  /// [BeamCoreWalletResult]; `key` is set when it is ok.
  Future<({int code, String? key})> exportOwnerKey({
    required String dbPath,
    required String password,
  });

  /// Starts the node on a thread of its own: storage [nodeDbPath], P2P on
  /// 127.0.0.1:[port], [peers] (`host:port`; IPv4 only with [socksProxy]),
  /// the wallet's owner key. Returns a `BeamCoreNodeError` code (0 = the
  /// thread runs; later failures show in [nodeStatus]).
  Future<int> startNode({
    required String nodeDbPath,
    required int port,
    required List<String> peers,
    required String ownerKey,
    required String password,
    int verificationThreads = -1,
    String? socksProxy,
  });

  /// Asks the node to stop; returns at once ([nodeStatus] shows when).
  void stopNode();

  BeamCoreNodeStatus nodeStatus();

  /// `beam_wallet_api_start`: a wallet-api instance on a thread of its own,
  /// next to any others (one per open wallet, as the child processes were).
  /// Completes once its server listens with a handle > 0, or with a
  /// negative [BeamCoreInstance] error.
  Future<int> startInstance(List<String> args);

  /// Asks the instance to stop; returns at once.
  void stopInstance(int handle);

  /// The instance's [BeamCoreInstance] state, and wallet-api's exit status
  /// once it has ended.
  ({int state, int exitStatus}) instanceState(int handle);

  /// Instances that have not ended yet (must be 0 before the app exits).
  int instanceCount();
}

/// `beam_wallet_api_start()` errors and `beam_wallet_api_instance_state()`
/// states (beam_core.h).
abstract final class BeamCoreInstance {
  static const startFailed = -1;
  static const badApiVersion = -2;
  static const notServing = -3;
  static const noListen = -4;
  static const uncaughtException = -101;
  static const timeout = -102;
  static const threadFailed = -103;

  static const unknown = -1;
  static const starting = 0;
  static const running = 1;
  static const stopping = 2;
  static const stopped = 3;
  static const failed = 4;

  static bool hasEnded(int state) =>
      state == stopped || state == failed || state == unknown;
}

/// Where the core is: a framework embedded in the app, or the app binary
/// itself when the library is linked statically.
const List<String?> kBeamCoreLibraryCandidates = [
  'BeamCore.framework/BeamCore', // ios/BeamCore pod (use_frameworks!)
  null, // the process image
];

/// [BeamCoreLibrary] over `dart:ffi`.
///
/// Blocking calls ([run], [initWallet], [checkWallet]) execute in short-lived
/// isolates, each opening the same library, so the UI isolate never waits on
/// the core. [stop], [isRunning], [version] and [rulesSignature] return at
/// once and are called directly.
final class FfiBeamCoreLibrary implements BeamCoreLibrary {
  FfiBeamCoreLibrary._(this._location, DynamicLibrary lib)
    : _stop = lib.lookupFunction<Void Function(), void Function()>(
        'beam_wallet_api_stop',
      ),
      _isRunning = lib.lookupFunction<Int32 Function(), int Function()>(
        'beam_wallet_api_is_running',
      ),
      _version = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'beam_wallet_api_version',
          ),
      _rules = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'beam_wallet_api_rules_signature',
          );

  /// Finds the core among [candidates] (null = the process image). Returns
  /// null when no candidate exports `beam_wallet_api_run`.
  static FfiBeamCoreLibrary? open({
    List<String?> candidates = kBeamCoreLibraryCandidates,
  }) {
    for (final location in candidates) {
      final DynamicLibrary lib;
      try {
        lib = _load(location);
      } on ArgumentError {
        continue;
      }
      if (lib.providesSymbol('beam_wallet_api_run')) {
        return FfiBeamCoreLibrary._(location, lib);
      }
    }
    return null;
  }

  final String? _location;
  final void Function() _stop;
  final int Function() _isRunning;
  final Pointer<Utf8> Function() _version;
  final Pointer<Utf8> Function() _rules;

  /// The candidate the core was found in (null: the process image).
  String? get location => _location;

  /// The desktop/Android additions, when this core has them.
  late final BeamCoreIntegrated? integrated = () {
    final lib = _load(_location);
    return lib.providesSymbol('beam_node_start') &&
            lib.providesSymbol('beam_core_init') &&
            lib.providesSymbol('beam_wallet_api_start')
        ? _FfiIntegrated(_location, lib)
        : null;
  }();

  static DynamicLibrary _load(String? location) => location == null
      ? DynamicLibrary.process()
      : DynamicLibrary.open(location);

  @override
  String version() => _version().toDartString();

  @override
  String rulesSignature() => _rules().toDartString();

  @override
  bool get isRunning => _isRunning() != 0;

  @override
  void stop() => _stop();

  @override
  Future<int> run(List<String> args) {
    final location = _location;
    final copy = List<String>.of(args);
    return Isolate.run(
      () => _runBlocking(location, copy),
      debugName: 'beam-wallet-api',
    );
  }

  @override
  Future<int> initWallet({
    required String dbPath,
    required String password,
    required String phrase,
  }) {
    final location = _location;
    return Isolate.run(
      () => _initBlocking(location, dbPath, password, phrase),
      debugName: 'beam-init-wallet',
    );
  }

  @override
  Future<int> checkWallet({required String dbPath, required String password}) {
    final location = _location;
    return Isolate.run(
      () => _checkBlocking(location, dbPath, password),
      debugName: 'beam-check-wallet',
    );
  }

  // ---------------------------------------------------------------------------
  // Isolate entry points: top-level-safe, they capture only strings.

  static int _runBlocking(String? location, List<String> args) {
    final run = _load(location)
        .lookupFunction<
          Int32 Function(Int32, Pointer<Pointer<Utf8>>),
          int Function(int, Pointer<Pointer<Utf8>>)
        >('beam_wallet_api_run');
    final all = ['wallet-api', ...args];
    final argv = calloc<Pointer<Utf8>>(all.length + 1);
    final owned = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < all.length; i++) {
        final s = all[i].toNativeUtf8(allocator: calloc);
        owned.add(s);
        argv[i] = s;
      }
      argv[all.length] = nullptr;
      return run(all.length, argv);
    } finally {
      owned.forEach(calloc.free);
      calloc.free(argv);
    }
  }

  static int _initBlocking(
    String? location,
    String dbPath,
    String password,
    String phrase,
  ) {
    final init = _load(location)
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
        >('beam_wallet_api_init_wallet');
    final path = dbPath.toNativeUtf8(allocator: calloc);
    final pass = _secret(password);
    final words = _secret(phrase);
    try {
      return init(path, pass.pointer, words.pointer);
    } finally {
      calloc.free(path);
      pass.wipeAndFree();
      words.wipeAndFree();
    }
  }

  static int _checkBlocking(String? location, String dbPath, String password) {
    final check = _load(location)
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('beam_wallet_api_check_wallet');
    final path = dbPath.toNativeUtf8(allocator: calloc);
    final pass = _secret(password);
    try {
      return check(path, pass.pointer);
    } finally {
      calloc.free(path);
      pass.wipeAndFree();
    }
  }

  /// Copies [value] as NUL-terminated UTF-8 into native memory and wipes the
  /// intermediate Dart bytes.
  static _NativeSecret _secret(String value) {
    final bytes = utf8.encode(value);
    final p = calloc<Uint8>(bytes.length + 1);
    p.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    bytes.fillRange(0, bytes.length, 0);
    return _NativeSecret(p, bytes.length + 1);
  }
}

/// A NUL-terminated copy of a secret in native memory.
final class _NativeSecret {
  _NativeSecret(this._bytes, this._length);

  final Pointer<Uint8> _bytes;
  final int _length;

  Pointer<Utf8> get pointer => _bytes.cast<Utf8>();

  void wipeAndFree() {
    _bytes.asTypedList(_length).fillRange(0, _length, 0);
    calloc.free(_bytes);
  }
}

/// `beam_node_status` (beam_core.h). Field order and types as in C; Dart
/// lays out the padding the same way (384 bytes on 64-bit targets).
final class BeamNodeStatusC extends Struct {
  @Uint32()
  external int size;
  @Uint32()
  external int version;
  @Int32()
  external int state;
  @Int32()
  external int error;
  @Array(160)
  external Array<Uint8> errorDetail;
  @Int32()
  external int port;
  @Int32()
  external int viaProxy;
  @Uint64()
  external int startedAtMs;
  @Uint64()
  external int updatedAtMs;
  @Uint64()
  external int tipHeight;
  @Uint64()
  external int tipTimestamp;
  @Uint64()
  external int tipChangedAtMs;
  @Uint64()
  external int initialTipHeight;
  @Int32()
  external int hasInitialTip;
  @Int32()
  external int peersConnected;
  @Int32()
  external int peersWithTip;
  @Int32()
  external int peersKnown;
  @Int32()
  external int updatedFromPeers;
  @Uint64()
  external int bestPeerHeight;
  @Uint64()
  external int bestPeerTimestamp;
  @Uint64()
  external int syncDone;
  @Uint64()
  external int syncTotal;
  @Int32()
  external int syncPercent;
  @Int32()
  external int synced;
  @Int32()
  external int txReplicationOn;
  @Int32()
  external int syncError;
  @Uint32()
  external int syncErrorCount;
  @Int32()
  external int fastSyncActive;
  @Int32()
  external int fastSyncDone;
  @Uint64()
  external int fastSyncTarget;
  @Uint32()
  external int fastSyncRetries;
  @Uint64()
  external int initDone;
  @Uint64()
  external int initTotal;
  @Int32()
  external int longStep;
  @Int32()
  external int longStepPercent;
  @Uint64()
  external int longStepDone;
  @Uint64()
  external int longStepTotal;
  @Int32()
  external int ownerKeySet;
  @Int32()
  external int ownerAccounts;
}

/// Reads a C status struct into Dart values.
BeamCoreNodeStatus beamNodeStatusFromC(BeamNodeStatusC c) {
  final detail = <int>[];
  for (var i = 0; i < 160; i++) {
    final b = c.errorDetail[i];
    if (b == 0) break;
    detail.add(b);
  }
  return BeamCoreNodeStatus(
    state: c.state,
    error: c.error,
    errorDetail: utf8.decode(detail, allowMalformed: true),
    port: c.port,
    viaProxy: c.viaProxy != 0,
    tipHeight: c.tipHeight,
    tipTimestamp: c.tipTimestamp,
    tipChangedAtMs: c.tipChangedAtMs,
    initialTipHeight: c.hasInitialTip != 0 ? c.initialTipHeight : null,
    peersConnected: c.peersConnected,
    peersWithTip: c.peersWithTip,
    updatedFromPeers: c.updatedFromPeers != 0,
    bestPeerHeight: c.bestPeerHeight,
    syncPercent: c.syncPercent,
    synced: c.synced != 0,
    txReplicationOn: c.txReplicationOn != 0,
    syncError: c.syncError,
    fastSyncActive: c.fastSyncActive != 0,
    fastSyncDone: c.fastSyncDone != 0,
    fastSyncTarget: c.fastSyncTarget,
    fastSyncRetries: c.fastSyncRetries,
    longStep: c.longStep,
    longStepPercent: c.longStepPercent,
    ownerKeySet: c.ownerKeySet != 0,
    ownerAccounts: c.ownerAccounts,
  );
}

final class _FfiIntegrated implements BeamCoreIntegrated {
  _FfiIntegrated(this._location, DynamicLibrary lib)
    : _init = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32),
            int Function(Pointer<Utf8>, int, int)
          >('beam_core_init'),
      _stopNode = lib.lookupFunction<Void Function(), void Function()>(
        'beam_node_stop',
      ),
      _status = lib
          .lookupFunction<
            Int32 Function(Pointer<BeamNodeStatusC>),
            int Function(Pointer<BeamNodeStatusC>)
          >('beam_node_get_status'),
      _stopInstance = lib
          .lookupFunction<Void Function(Int64), void Function(int)>(
            'beam_wallet_api_stop_instance',
          ),
      _instanceState = lib
          .lookupFunction<
            Int32 Function(Int64, Pointer<Int32>),
            int Function(int, Pointer<Int32>)
          >('beam_wallet_api_instance_state'),
      _instanceCount = lib.lookupFunction<Int32 Function(), int Function()>(
        'beam_wallet_api_instance_count',
      );

  final String? _location;
  final int Function(Pointer<Utf8>, int, int) _init;
  final void Function() _stopNode;
  final int Function(Pointer<BeamNodeStatusC>) _status;
  final void Function(int) _stopInstance;
  final int Function(int, Pointer<Int32>) _instanceState;
  final int Function() _instanceCount;

  @override
  Future<int> startInstance(List<String> args) {
    final location = _location;
    final copy = List<String>.of(args);
    return Isolate.run(
      () => _startInstanceBlocking(location, copy),
      debugName: 'beam-wallet-api-start',
    );
  }

  @override
  void stopInstance(int handle) => _stopInstance(handle);

  @override
  ({int state, int exitStatus}) instanceState(int handle) {
    final status = calloc<Int32>();
    try {
      final state = _instanceState(handle, status);
      return (state: state, exitStatus: status.value);
    } finally {
      calloc.free(status);
    }
  }

  @override
  int instanceCount() => _instanceCount();

  static int _startInstanceBlocking(String? location, List<String> args) {
    final start = FfiBeamCoreLibrary._load(location)
        .lookupFunction<
          Int64 Function(Int32, Pointer<Pointer<Utf8>>),
          int Function(int, Pointer<Pointer<Utf8>>)
        >('beam_wallet_api_start');
    final all = ['wallet-api', ...args];
    final argv = calloc<Pointer<Utf8>>(all.length + 1);
    final owned = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < all.length; i++) {
        final s = all[i].toNativeUtf8(allocator: calloc);
        owned.add(s);
        argv[i] = s;
      }
      argv[all.length] = nullptr;
      return start(all.length, argv);
    } finally {
      owned.forEach(calloc.free);
      calloc.free(argv);
    }
  }

  @override
  int initLogging({String? logDir, int consoleLevel = 4, int fileLevel = 4}) {
    final dir = (logDir ?? '').toNativeUtf8(allocator: calloc);
    try {
      return _init(dir, consoleLevel, fileLevel);
    } finally {
      calloc.free(dir);
    }
  }

  @override
  Future<({int code, String? key})> exportOwnerKey({
    required String dbPath,
    required String password,
  }) {
    final location = _location;
    return Isolate.run(
      () => _exportBlocking(location, dbPath, password),
      debugName: 'beam-export-owner-key',
    );
  }

  @override
  Future<int> startNode({
    required String nodeDbPath,
    required int port,
    required List<String> peers,
    required String ownerKey,
    required String password,
    int verificationThreads = -1,
    String? socksProxy,
  }) {
    final location = _location;
    final peersCsv = peers.join(',');
    return Isolate.run(
      () => _startNodeBlocking(
        location,
        nodeDbPath,
        port,
        peersCsv,
        ownerKey,
        password,
        verificationThreads,
        socksProxy,
      ),
      debugName: 'beam-node-start',
    );
  }

  @override
  void stopNode() => _stopNode();

  @override
  BeamCoreNodeStatus nodeStatus() {
    final out = calloc<BeamNodeStatusC>();
    try {
      out.ref.size = sizeOf<BeamNodeStatusC>();
      if (_status(out) != 0) return const BeamCoreNodeStatus();
      return beamNodeStatusFromC(out.ref);
    } finally {
      calloc.free(out);
    }
  }

  static ({int code, String? key}) _exportBlocking(
    String? location,
    String dbPath,
    String password,
  ) {
    final export = FfiBeamCoreLibrary._load(location)
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int)
        >('beam_wallet_api_export_owner_key');
    const capacity = 512;
    final path = dbPath.toNativeUtf8(allocator: calloc);
    final pass = FfiBeamCoreLibrary._secret(password);
    final out = calloc<Uint8>(capacity);
    try {
      final code = export(path, pass.pointer, out.cast<Utf8>(), capacity);
      if (code != BeamCoreWalletResult.ok) return (code: code, key: null);
      return (code: code, key: out.cast<Utf8>().toDartString());
    } finally {
      out.asTypedList(capacity).fillRange(0, capacity, 0);
      calloc.free(out);
      calloc.free(path);
      pass.wipeAndFree();
    }
  }

  static int _startNodeBlocking(
    String? location,
    String nodeDbPath,
    int port,
    String peersCsv,
    String ownerKey,
    String password,
    int verificationThreads,
    String? socksProxy,
  ) {
    final start = FfiBeamCoreLibrary._load(location)
        .lookupFunction<
          Int32 Function(
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Int32,
            Pointer<Utf8>,
          ),
          int Function(
            Pointer<Utf8>,
            int,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            int,
            Pointer<Utf8>,
          )
        >('beam_node_start');
    final db = nodeDbPath.toNativeUtf8(allocator: calloc);
    final peers = peersCsv.toNativeUtf8(allocator: calloc);
    final key = FfiBeamCoreLibrary._secret(ownerKey);
    final pass = FfiBeamCoreLibrary._secret(password);
    final proxy = (socksProxy ?? '').toNativeUtf8(allocator: calloc);
    try {
      return start(
        db,
        port,
        peers,
        key.pointer,
        pass.pointer,
        verificationThreads,
        proxy,
      );
    } finally {
      calloc.free(db);
      calloc.free(peers);
      calloc.free(proxy);
      key.wipeAndFree();
      pass.wipeAndFree();
    }
  }
}
