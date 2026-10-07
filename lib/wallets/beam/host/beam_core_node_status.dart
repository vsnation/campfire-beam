/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../node/beam_node_progress.dart';

/// `beam_node_status.state` (scripts/beam/core/lib/src/beam_core.h).
abstract final class BeamCoreNodeState {
  static const idle = 0;
  static const starting = 1;
  static const running = 2;
  static const stopping = 3;
  static const stopped = 4;
  static const failed = 5;
}

/// `beam_node_start()` results and `beam_node_status.error`.
abstract final class BeamCoreNodeError {
  static const ok = 0;
  static const alreadyRunning = 1;
  static const invalidArgument = 2;
  static const badOwnerKey = 3;
  static const hostnameRefused = 4;
  static const threadFailed = 5;
  static const portInUse = 20;
  static const dbCorrupt = 21;
  static const dbIncompatible = 22;
  static const diskFull = 23;
  static const storage = 24;
  static const noPeers = 25;
  static const failed = 26;
  static const dbInUse = 27;
}

/// `beam_node_status.long_step`.
abstract final class BeamCoreNodeStep {
  static const none = 0;
  static const raisingFossil = 1;
}

/// `beam_node_status.sync_error`.
abstract final class BeamCoreNodeSyncError {
  static const none = 0;
  static const timeDiff = 2;
}

/// One snapshot of the integrated node (`beam_node_get_status`), as plain
/// Dart values. Heights are block numbers; `*Ms` are Unix milliseconds of
/// this device's clock.
class BeamCoreNodeStatus {
  const BeamCoreNodeStatus({
    this.state = BeamCoreNodeState.idle,
    this.error = 0,
    this.errorDetail = '',
    this.port = 0,
    this.viaProxy = false,
    this.tipHeight = 0,
    this.tipTimestamp = 0,
    this.tipChangedAtMs = 0,
    this.initialTipHeight,
    this.peersConnected = 0,
    this.peersWithTip = 0,
    this.updatedFromPeers = false,
    this.bestPeerHeight = 0,
    this.syncPercent = -1,
    this.synced = false,
    this.txReplicationOn = false,
    this.syncError = BeamCoreNodeSyncError.none,
    this.fastSyncActive = false,
    this.fastSyncDone = false,
    this.fastSyncTarget = 0,
    this.fastSyncRetries = 0,
    this.longStep = BeamCoreNodeStep.none,
    this.longStepPercent = -1,
    this.ownerKeySet = false,
    this.ownerAccounts = -1,
  });

  final int state;
  final int error;
  final String errorDetail;
  final int port;
  final bool viaProxy;
  final int tipHeight;
  final int tipTimestamp;
  final int tipChangedAtMs;
  final int? initialTipHeight;
  final int peersConnected;
  final int peersWithTip;
  final bool updatedFromPeers;
  final int bestPeerHeight;
  final int syncPercent;
  final bool synced;
  final bool txReplicationOn;
  final int syncError;
  final bool fastSyncActive;
  final bool fastSyncDone;
  final int fastSyncTarget;
  final int fastSyncRetries;
  final int longStep;
  final int longStepPercent;
  final bool ownerKeySet;
  final int ownerAccounts;

  bool get isEnded =>
      state == BeamCoreNodeState.stopped || state == BeamCoreNodeState.failed;
}

/// [status] as the coordinator's [BeamNodeProgress] (the same model the
/// child-process node's log parser fills). [previous] keeps what the node
/// reports only while it lasts (the fast-sync target, peers seen).
BeamNodeProgress beamNodeProgressFrom(
  BeamCoreNodeStatus status,
  BeamNodeProgress previous, {
  bool stopRequested = false,
}) {
  final BeamNodePhase phase;
  BeamNodeError? error;
  if (status.state == BeamCoreNodeState.stopped) {
    phase = BeamNodePhase.stopped;
  } else if (status.state == BeamCoreNodeState.failed) {
    phase = stopRequested ? BeamNodePhase.stopped : BeamNodePhase.error;
    error = stopRequested ? null : beamNodeErrorFrom(status.error);
  } else if (status.synced && status.tipHeight > 0) {
    // The node's own "synced" (done == total, fast sync over, a peer told
    // its tip), computed live; the coordinator still checks the explorer.
    phase = BeamNodePhase.txReplicationOn;
  } else if (status.fastSyncActive) {
    phase = BeamNodePhase.fastSyncDownloading;
  } else if (status.tipHeight > 0 && status.updatedFromPeers) {
    phase = BeamNodePhase.catchingUp;
  } else {
    phase = BeamNodePhase.starting;
  }
  return BeamNodeProgress(
    phase: phase,
    percent: status.syncPercent >= 0
        ? status.syncPercent.clamp(0, 100)
        : previous.percent,
    myTipHeight: status.tipHeight > 0 ? status.tipHeight : null,
    myTipAt: status.tipChangedAtMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(status.tipChangedAtMs)
        : previous.myTipAt,
    initialTipHeight: status.initialTipHeight,
    fastSyncTarget: status.fastSyncTarget > 0
        ? status.fastSyncTarget
        : previous.fastSyncTarget,
    fastSyncFailures: status.fastSyncRetries,
    peersSeen: status.peersWithTip > previous.peersSeen
        ? status.peersWithTip
        : previous.peersSeen,
    ownerAccounts: status.ownerAccounts >= 0 ? status.ownerAccounts : null,
    error: error,
    errorDetail: error == null || status.errorDetail.isEmpty
        ? null
        : status.errorDetail,
    finishingPercent:
        status.longStep != BeamCoreNodeStep.none && status.longStepPercent >= 0
        ? status.longStepPercent.clamp(0, 100)
        : null,
  );
}

/// A failed node's error code as the coordinator's [BeamNodeError].
BeamNodeError beamNodeErrorFrom(int code) => switch (code) {
  BeamCoreNodeError.badOwnerKey => BeamNodeError.ownerKeyRejected,
  BeamCoreNodeError.portInUse => BeamNodeError.portUnavailable,
  BeamCoreNodeError.dbCorrupt ||
  BeamCoreNodeError.dbIncompatible => BeamNodeError.corrupted,
  BeamCoreNodeError.dbInUse => BeamNodeError.nodeInUse,
  _ => BeamNodeError.exited,
};
