/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../models/beam_json.dart';
import '../models/beam_wallet_status.dart';
import '../rpc/beam_transport.dart';
import '../sync/beam_sync_state.dart';

/// Block-body scan progress (`ev_sync_progress.sync_requests_*`), for the
/// "Scanning for your coins…" state of a restored wallet.
class BeamScanProgress {
  const BeamScanProgress(this.done, this.total);

  final int done;
  final int total;

  /// 0..1, or null when the core reports nothing to do.
  double? get fraction => total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is BeamScanProgress && other.done == done && other.total == total;

  @override
  int get hashCode => Object.hash(done, total);
}

/// Folds `wallet_status` answers and `ev_*` pushes into the
/// [BeamWalletSyncInput]s the sync monitor judges.
///
/// The core reports the chain state in three places (`wallet_status`,
/// `ev_sync_progress`, `ev_system_state`) and the node connection in a
/// fourth (`ev_connection_changed`); this keeps the newest of each.
class BeamSyncTracker {
  final _controller = StreamController<BeamWalletSyncInput>.broadcast();

  BeamWalletSyncInput? _input;
  bool? _nodeConnected;
  bool? _ownNode;
  BeamScanProgress? _scan;

  /// Every new input. Broadcast.
  Stream<BeamWalletSyncInput> get inputs => _controller.stream;

  BeamWalletSyncInput? get current => _input;

  /// `ev_connection_changed.node_connected`, when reported.
  bool? get nodeConnected => _nodeConnected;

  /// `ev_connection_changed.own_node`, when reported.
  bool? get ownNode => _ownNode;

  /// The latest body-scan progress, when the core reported one.
  BeamScanProgress? get scanProgress => _scan;

  void onStatus(BeamWalletStatus s) => _update(
    currentHeight: s.currentHeight,
    timestamp: s.currentStateTimestamp,
    isInSync: s.isInSync,
  );

  /// Takes any event; ignores the ones that say nothing about sync.
  void onEvent(BeamEvent e) {
    final d = e.data;
    switch (e.name) {
      case 'ev_sync_progress':
        final done = _int(d, 'sync_requests_done');
        final total = _int(d, 'sync_requests_total');
        if (done != null && total != null) {
          _scan = BeamScanProgress(done, total);
        }
        _fromSystemState(d);
      case 'ev_system_state':
        _fromSystemState(d);
      case 'ev_connection_changed':
        final connected = d['node_connected'];
        final own = d['own_node'];
        if (connected is bool) _nodeConnected = connected;
        if (own is bool) _ownNode = own;
        final input = _input;
        if (input != null) {
          _emit(
            BeamWalletSyncInput(
              currentHeight: input.currentHeight,
              currentStateTimestamp: input.currentStateTimestamp,
              isInSync: input.isInSync,
              headerTipHeight: input.headerTipHeight,
              nodeConnected: _nodeConnected,
              ownNode: _ownNode,
            ),
          );
        }
    }
  }

  /// A new session (another wallet-api, maybe another node): what the old
  /// one said about its connection no longer holds. The last chain state is
  /// kept but re-emitted without the connection, so the sync verdict waits
  /// for the new core's `node_connected`, and that report is not swallowed
  /// as a repeat of the old session's input.
  void resetConnection() {
    _nodeConnected = null;
    _ownNode = null;
    _scan = null;
    final input = _input;
    if (input != null) _emit(input.withoutConnection());
  }

  Future<void> dispose() => _controller.close();

  void _fromSystemState(Map<String, Object?> d) {
    final height = _int(d, 'current_height');
    if (height == null) return;
    final inSync = d['is_in_sync'];
    _update(
      currentHeight: height,
      timestamp: _int(d, 'current_state_timestamp'),
      isInSync: inSync is bool ? inSync : _input?.isInSync ?? false,
      tipHeight: _int(d, 'tip_height'),
    );
  }

  void _update({
    required int currentHeight,
    required int? timestamp,
    required bool isInSync,
    int? tipHeight,
  }) {
    final previous = _input;
    _emit(
      BeamWalletSyncInput(
        currentHeight: currentHeight,
        currentStateTimestamp: timestamp == null
            ? previous?.currentStateTimestamp
            : BeamJson.unixSeconds(timestamp),
        isInSync: isInSync,
        // wallet_status has no tip; keep the last one unless we went past it.
        headerTipHeight:
            tipHeight ??
            (previous?.headerTipHeight != null &&
                    previous!.headerTipHeight! >= currentHeight
                ? previous.headerTipHeight
                : null),
        nodeConnected: _nodeConnected,
        ownNode: _ownNode,
      ),
    );
  }

  void _emit(BeamWalletSyncInput next) {
    if (next == _input) return;
    _input = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  static int? _int(Map<String, Object?> d, String key) {
    final v = d[key];
    return v is int ? v : null;
  }
}
