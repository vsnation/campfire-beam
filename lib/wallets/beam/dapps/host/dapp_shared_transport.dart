/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../api/beam_api.dart';
import '../../rpc/beam_transport.dart';

/// One dApp page's view of the wallet's own core connection.
///
/// The wallet has one wallet-api connection, replaced on every public ↔
/// private node handover (`BeamWalletServices.transport` always forwards to
/// the current one). A `DappSession` was written for a connection of its
/// own; three things differ on a shared one, and this adapter handles them:
///
/// * **Event subscriptions.** `ev_subunsub` changes the subscriptions of
///   the whole connection: a dApp sending `ev_txs_changed: false` would
///   switch off the wallet's own transaction updates. Subscriptions are
///   therefore answered here and never forwarded. The wallet's connection
///   is subscribed to every event already; the session forwards only the
///   ones its page asked for, filtered to the page's own transactions and
///   addresses. Like the core (`v6_1_api_handle.cpp:67-110`), a newly
///   subscribed `ev_system_state`, `ev_sync_progress`, `ev_txs_changed` or
///   `ev_addrs_changed` is followed by a snapshot, read from
///   `wallet_status`, `tx_list` and `addr_list`.
/// * **Shader calls.** `invoke_contract` goes through [BeamApi]'s shader
///   lane for the shared connection, so a dApp's calls queue behind (never
///   between) the DEX, names, airdrop and minter screens' calls.
/// * **Handover.** [events] follows the connection that is current: when
///   the old connection's stream ends, it listens again after
///   [resubscribeDelay].
///
/// [close] stops this page's events; it never closes the shared connection.
class DappSharedTransport implements BeamTransport {
  DappSharedTransport(
    this.shared, {
    BeamApi? api,
    this.resubscribeDelay = const Duration(seconds: 1),
  }) : api = api ?? BeamApi(shared) {
    _out = StreamController<BeamEvent>.broadcast(
      onListen: _follow,
      onCancel: _stopFollowing,
    );
  }

  /// The wallet's connection (e.g. `BeamWalletServices.transport`).
  final BeamTransport shared;

  /// The API whose shader lane `invoke_contract` joins.
  final BeamApi api;

  final Duration resubscribeDelay;

  late final StreamController<BeamEvent> _out;
  StreamSubscription<BeamEvent>? _in;
  Timer? _retry;
  final _subscribed = <String>{};
  bool _closed = false;

  /// Events whose first subscription is followed by a snapshot.
  static const _snapshotted = {
    'ev_system_state',
    'ev_sync_progress',
    'ev_txs_changed',
    'ev_addrs_changed',
  };

  /// The fields of `wallet_status` that `fillSystemState` also writes
  /// (`v6_1_api_notify.cpp:20-39`).
  static const _stateKeys = [
    'current_height',
    'current_state_hash',
    'current_state_timestamp',
    'prev_state_hash',
    'is_in_sync',
  ];

  /// The events this page subscribed to.
  Set<String> get subscribed => Set.unmodifiable(_subscribed);

  @override
  Future<void> connect() async {}

  @override
  bool get isConnected => !_closed && shared.isConnected;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    switch (method) {
      case 'ev_subunsub':
        return _subUnsub(params);
      case 'invoke_contract':
        return _invoke(params, timeout);
      default:
        return shared.call(method, params, timeout);
    }
  }

  @override
  Stream<BeamEvent> get events => _out.stream;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stopFollowing();
    await _out.close();
  }

  // --------------------------------------------------------------- events

  bool _subUnsub(Map<String, Object?> params) {
    final added = <String>[];
    for (final e in params.entries) {
      if (e.value == true) {
        if (_subscribed.add(e.key)) added.add(e.key);
      } else {
        _subscribed.remove(e.key);
      }
    }
    // After the answer, as the core does: the session only starts
    // forwarding an event once the subscription call has returned.
    for (final name in added) {
      if (_snapshotted.contains(name)) unawaited(_snapshot(name));
    }
    return true;
  }

  Future<void> _snapshot(String name) async {
    await Future<void>.delayed(Duration.zero);
    try {
      final Map<String, Object?> data;
      switch (name) {
        case 'ev_txs_changed':
          final txs = await shared.call('tx_list', const {});
          data = {'change': 3, 'change_str': 'reset', 'txs': txs ?? const []};
        case 'ev_addrs_changed':
          final addrs = await shared.call('addr_list', const {'own': true});
          data = {
            'change': 3,
            'change_str': 'reset',
            'addrs': addrs ?? const [],
          };
        default:
          final status = await shared.call('wallet_status', const {});
          if (status is! Map) return;
          data = {
            if (name == 'ev_sync_progress') ...{
              'sync_requests_done': 0,
              'sync_requests_total': 0,
            },
            for (final k in _stateKeys)
              if (status.containsKey(k)) k: status[k],
          };
      }
      if (!_closed && _subscribed.contains(name)) {
        _out.add(BeamEvent(name, data));
      }
    } catch (_) {
      // No snapshot; live events still arrive.
    }
  }

  void _follow() {
    if (_closed || _in != null) return;
    _retry?.cancel();
    _retry = null;
    _in = shared.events.listen(
      (e) {
        if (!_closed) _out.add(e);
      },
      onError: (Object _) {},
      onDone: () {
        _in = null;
        if (_closed || !_out.hasListener) return;
        // The connection was replaced (node handover) or is restarting.
        _retry = Timer(resubscribeDelay, _follow);
      },
      cancelOnError: false,
    );
  }

  Future<void> _stopFollowing() async {
    _retry?.cancel();
    _retry = null;
    final sub = _in;
    _in = null;
    await sub?.cancel();
  }

  // --------------------------------------------------------------- shaders

  Future<Object?> _invoke(
    Map<String, Object?> params,
    Duration? timeout,
  ) async {
    final contract = params['contract'];
    final r = await api.invokeContract(
      createTx: params['create_tx'] == true,
      args: params['args'] as String?,
      contractBytes: contract is List ? contract.cast<int>() : null,
      priority: params['priority'] as int?,
      unique: params['unique'] as int?,
      timeout: timeout,
    );
    // The core's answer (`v6_api_parse.cpp:1033-1054`); it reports an
    // all-zero tx id for a `create_tx: false` call, which BeamApi maps to
    // null, so the zeros are put back.
    return {
      'output': r.output,
      'txid': r.txId ?? _zeroTxId,
      'raw_data': ?r.rawData,
    };
  }

  static final _zeroTxId = '0' * 32;
}
