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
