/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

/// A connection to a BEAM wallet core that speaks wallet-api JSON-RPC 2.0.
///
/// Everything above this interface is transport-agnostic. The desktop
/// implementation talks to a `wallet-api` child process in TCP line mode; the
/// FFI implementation (phase 2) executes the same JSON in-process through
/// `IWalletApi::executeAPIRequest`. Both deliver the same `ev_*` events.
abstract class BeamTransport {
  /// Opens the connection. Completes once requests can be sent.
  Future<void> connect();

  bool get isConnected;

  /// Sends one request and completes with its `result`.
  ///
  /// Throws [BeamRpcException] when the core answers with an `error` object,
  /// and [TimeoutException] when no answer arrives within [timeout].
  /// Implementations add the per-launch ACL `key` to every request.
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]);

  /// Push notifications from the core: lines whose `id` starts with `ev_`
  /// (`ev_sync_progress`, `ev_txs_changed`, `ev_assets_changed`,
  /// `ev_connection_changed`, `ev_addrs_changed`, `ev_utxos_changed`,
  /// `ev_system_state`).
  Stream<BeamEvent> get events;

  /// Closes the connection and fails every pending request.
  Future<void> close();
}

/// One push notification from the wallet core.
class BeamEvent {
  const BeamEvent(this.name, this.data);

  /// The event id, e.g. `ev_sync_progress`.
  final String name;

  /// The event's `result` payload as decoded JSON.
  final Map<String, Object?> data;

  @override
  String toString() => 'BeamEvent($name)';
}

/// An `error` object returned by the wallet core.
class BeamRpcException implements Exception {
  const BeamRpcException(this.code, this.message, [this.data]);

  /// JSON-RPC error code. Notable values: -32021 user rejected (dApp consent),
  /// -32020 method not allowed for apps, -5 wallet locked.
  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'BeamRpcException($code): $message';
}
