/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../host/beam_host.dart';
import '../rpc/beam_transport.dart';

/// "Busy" flag for node switches (project rules R11): while a send, swap, claim
/// or dApp approval is open, nothing may restart wallet-api under it.
///
/// Money flows take a [BeamGateLease] for as long as they are open; every
/// node switch and every pause of the wallet waits in [whenIdle] until all
/// leases are released (or have expired, so a confirm screen that was left
/// without a decision cannot block the node forever).
class BeamNodeSwitchGate {
  BeamNodeSwitchGate({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<int, _Hold> _holds = {};
  int _nextId = 0;
  final List<Completer<void>> _waiters = [];
  Timer? _expiry;
  bool _disposed = false;

  /// The wallet closed this gate; leases taken now are inert.
  bool get isDisposed => _disposed;

  /// True while at least one lease is held.
  bool get isBusy {
    _dropExpired();
    return _holds.isNotEmpty;
  }

  /// Why the gate is busy, for logs ("send", "confirm send", ...).
  List<String> get reasons {
    _dropExpired();
    return [for (final h in _holds.values) h.reason];
  }

  /// Marks the wallet busy until the lease is released or [maxHold] has
  /// passed. After [dispose] the lease is inert.
  BeamGateLease hold(String reason, {Duration? maxHold}) {
    final id = _nextId++;
    if (_disposed) return BeamGateLease._(this, id, inert: true);
    _holds[id] = _Hold(reason, maxHold == null ? null : _now().add(maxHold));
    _scheduleExpiry();
    return BeamGateLease._(this, id);
  }

  /// Completes once no lease is held (at once when idle or disposed).
  Future<void> whenIdle() {
    if (_disposed || !isBusy) return Future.value();
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// Releases every lease and every waiter; later leases are inert. Used when
  /// the wallet closes.
  void dispose() {
    _disposed = true;
    _holds.clear();
    _expiry?.cancel();
    _expiry = null;
    _wakeWaiters();
  }

  void _release(int id) {
    if (_holds.remove(id) == null) return;
    _scheduleExpiry();
    if (_holds.isEmpty) _wakeWaiters();
  }

  void _dropExpired() {
    final now = _now();
    final before = _holds.length;
    _holds.removeWhere(
      (_, h) => h.expires != null && !now.isBefore(h.expires!),
    );
    if (before != _holds.length && _holds.isEmpty) _wakeWaiters();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    _expiry = null;
    DateTime? next;
    for (final h in _holds.values) {
      final e = h.expires;
      if (e != null && (next == null || e.isBefore(next))) next = e;
    }
    if (next == null) return;
    final wait = next.difference(_now());
    _expiry = Timer(wait.isNegative ? Duration.zero : wait, () {
      _dropExpired();
      _scheduleExpiry();
    });
  }

  void _wakeWaiters() {
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
  }
}

class _Hold {
  _Hold(this.reason, this.expires);

  final String reason;
  final DateTime? expires;
}

/// One hold on a [BeamNodeSwitchGate]. Releasing twice is harmless.
class BeamGateLease {
  BeamGateLease._(this._gate, this._id, {bool inert = false})
    : _released = inert;

  final BeamNodeSwitchGate _gate;
  final int _id;
  bool _released;

  bool get isActive => !_released && _gate._holds.containsKey(_id);

  void release() {
    if (_released) return;
    _released = true;
    _gate._release(_id);
  }
}

/// The [BeamHost] the wallet opens through, and the one its
/// `BeamPrivateNodeCoordinator` gets.
///
/// The coordinator itself takes the stored owner key (no pause), waits for
/// the gate before every switch it makes, and is told whether to request
/// block bodies (B-NODE-2b), so this host only has to:
///
/// * store the key a real [exportOwnerKey] returns, so a wallet that had no
///   stored key pauses for it at most once;
/// * hand out [BeamGatedSession]s, so the wallet's own node changes (a dead
///   public node, a node picked in settings) also wait until the wallet is
///   not busy;
/// * after [close], open nothing new: a session that finishes opening
///   afterwards is closed at once, so a coordinator still running after the
///   wallet closed cannot leave a wallet-api behind.
class BeamCoordinatorHost implements BeamHost {
  BeamCoordinatorHost({
    required this.inner,
    required this.gate,
    required this._storeOwnerKey,
  });

  final BeamHost inner;
  final BeamNodeSwitchGate gate;
  final Future<void> Function(String key) _storeOwnerKey;
  bool _closed = false;

  /// How many times the real `export_owner_key` ran through this host.
  int realExports = 0;

  bool get isClosed => _closed;

  void close() => _closed = true;

  /// Wraps [session] so switches and closes wait for the gate.
  BeamGatedSession wrap(BeamSession session) =>
      session is BeamGatedSession ? session : BeamGatedSession._(session, this);

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) =>
      inner.initWallet(walletDir: walletDir, password: password, words: words);

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async {
    if (_closed) throw StateError('The wallet is closed');
    final session = await inner.openWallet(
      walletDir: walletDir,
      password: password,
      node: node,
      requestBodies: requestBodies,
    );
    if (_closed) {
      await session.close();
      throw StateError('The wallet is closed');
    }
    return wrap(session);
  }

  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async {
    realExports++;
    final key = await inner.exportOwnerKey(
      walletDir: walletDir,
      password: password,
    );
    await _storeOwnerKey(key);
    return key;
  }

  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) => inner.rescan(walletDir: walletDir, password: password, node: node);
}

/// A session whose [switchNode] and [close] wait until the wallet is not
/// busy (see [BeamNodeSwitchGate]).
class BeamGatedSession implements BeamSession {
  BeamGatedSession._(this.inner, this._host);

  final BeamSession inner;
  final BeamCoordinatorHost _host;

  @override
  BeamTransport get transport => inner.transport;

  @override
  BeamNodeEndpoint get node => inner.node;

  @override
  Future<BeamSession> switchNode(BeamNodeEndpoint node) async {
    await _host.gate.whenIdle();
    if (_host.isClosed) {
      await inner.close();
      throw StateError('The wallet is closed');
    }
    final next = await inner.switchNode(node);
    if (_host.isClosed) {
      await next.close();
      throw StateError('The wallet is closed');
    }
    return _host.wrap(next);
  }

  @override
  Future<void> close() async {
    await _host.gate.whenIdle();
    await inner.close();
  }

  /// Closes without waiting for the gate (the wallet itself is closing).
  Future<void> closeNow() => inner.close();

  @override
  Future<void> get stopped => inner.stopped;

  @override
  String toString() => 'BeamGatedSession($inner)';
}
