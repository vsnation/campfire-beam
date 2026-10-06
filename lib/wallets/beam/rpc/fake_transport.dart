/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'beam_connection_exception.dart';
import 'beam_transport.dart';

/// Computes a reply from the request params. May return a value, a Future,
/// or throw (e.g. a [BeamRpcException]).
typedef FakeHandler = FutureOr<Object?> Function(Map<String, Object?> params);

/// One request the code under test sent.
class FakeCall {
  const FakeCall(this.method, this.params, this.timeout);

  final String method;
  final Map<String, Object?> params;
  final Duration? timeout;

  @override
  String toString() => 'FakeCall($method)';
}

/// An in-memory [BeamTransport] for unit, widget and golden tests.
///
/// ```dart
/// final t = FakeTransport({
///   'wallet_status': jsonDecode(fixture('wallet_status')), // an envelope
///   'tx_send': (params) => {'txId': 'ab' * 16},             // a handler
///   'tx_cancel': const BeamRpcException(-32001, 'Invalid tx status'),
/// });
/// ```
///
/// A reply may be:
/// * a JSON-RPC envelope (a map with `"jsonrpc": "2.0"` and `result` or
///   `error`), as recorded from a real wallet-api: its `result` is returned or
///   its `error` thrown as [BeamRpcException];
/// * a [FakeHandler];
/// * an [Exception] or [Error], which is thrown;
/// * anything else, which is returned as the `result` unchanged.
///
/// A method with no reply throws `-32601 Method not found`, as the core does.
/// Every call is recorded in [calls], including failed ones.
class FakeTransport implements BeamTransport {
  FakeTransport([
    Map<String, Object?> replies = const {},
    this.latency = Duration.zero,
    bool connected = true,
  ]) : _replies = Map.of(replies),
       _connected = connected;

  final Map<String, Object?> _replies;

  /// Delay before each reply, to show loading states in widget tests.
  Duration latency;

  bool _connected;
  bool _closed = false;
  final _events = StreamController<BeamEvent>.broadcast();
  final List<FakeCall> calls = [];

  /// Sets or replaces the reply for [method].
  void reply(String method, Object? reply) => _replies[method] = reply;

  /// The calls made to [method], oldest first.
  List<FakeCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  /// The params of the most recent call to [method].
  Map<String, Object?> lastParams(String method) {
    final c = callsTo(method);
    if (c.isEmpty) throw StateError('no call to $method');
    return c.last.params;
  }

  /// Delivers an event to [events] listeners.
  void emit(String name, [Map<String, Object?> data = const {}]) {
    if (!name.startsWith('ev_')) {
      throw ArgumentError.value(name, 'name', 'events start with ev_');
    }
    _events.add(BeamEvent(name, data));
  }

  /// Delivers a recorded event envelope (`{"id": "ev_…", "result": {…}}`).
  void emitEnvelope(Map<String, Object?> envelope) {
    final result = envelope['result'];
    emit(
      envelope['id']! as String,
      result is Map ? result.cast<String, Object?>() : const {},
    );
  }

  /// Simulates the core going away: later calls fail with
  /// [BeamConnectionException] until [connect] is called again.
  void simulateDisconnect() => _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<BeamEvent> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (_closed) {
      throw const BeamConnectionException('transport is closed');
    }
    _connected = true;
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    calls.add(FakeCall(method, Map.unmodifiable(params), timeout));
    if (!_connected) {
      throw BeamConnectionException(
        _closed ? 'transport is closed' : 'not connected',
      );
    }
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (!_replies.containsKey(method)) {
      throw BeamRpcException(-32601, 'Method not found: $method');
    }
    final reply = _replies[method];
    if (reply is FakeHandler) return _unwrap(await reply(params));
    return _unwrap(reply);
  }

  static Object? _unwrap(Object? reply) {
    if (reply is Exception) throw reply;
    if (reply is Error) throw reply;
    if (reply is Map && reply['jsonrpc'] == '2.0') {
      if (reply.containsKey('error')) {
        final e = (reply['error'] as Map).cast<String, Object?>();
        throw BeamRpcException(
          e['code']! as int,
          e['message'] as String? ?? '',
          e['data'],
        );
      }
      if (reply.containsKey('result')) return reply['result'];
    }
    return reply;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _connected = false;
    await _events.close();
  }
}
