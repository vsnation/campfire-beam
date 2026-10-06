/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// What the "Node & sync" panel and the node status chip show, decided in
/// one pure place from the wallet's honest sync verdict and the private node
/// status. No Flutter here, so every state is unit-tested.
///
/// No jargon on purpose (USER_PSYCHOLOGY §1.5): no "explorer", "owner key",
/// "fast sync", "RPC", "wallet-api" or "beam-node".
library;

import '../host/beam_host.dart';
import '../sync/beam_sync_messages.dart';
import '../sync/beam_sync_state.dart';
import 'beam_node_disk.dart';
import 'beam_private_node_coordinator.dart';
import 'beam_private_node_messages.dart';

/// Everything the panel needs, at one moment.
class BeamNodePanelSnapshot {
  const BeamNodePanelSnapshot({
    required this.assessment,
    this.node,
    this.privateNodeSupported = false,
    this.privateNodeEnabled = false,
    this.privateNode,
    this.disk,
    this.coreProblem,
    this.busy = false,
  });

  /// The wallet's honest sync verdict (`BeamWallet.syncAssessment`).
  final BeamSyncAssessment assessment;

  /// The node the wallet is connected to now, when connected.
  final BeamNodeEndpoint? node;

  /// This device can run a private node (desktop).
  final bool privateNodeSupported;

  /// "Use my own private node".
  final bool privateNodeEnabled;

  /// The private node's state, once its coordinator runs.
  final BeamPrivateNodeStatus? privateNode;

  /// Disk numbers for the node (from the coordinator, or measured by the
  /// panel itself before it runs).
  final BeamNodeDiskCheck? disk;

  /// Why the wallet core could not start, in plain words, when it could not.
  final String? coreProblem;

  /// An action from the panel is in progress.
  final bool busy;

  BeamNodePanelSnapshot copyWith({
    BeamSyncAssessment? assessment,
    BeamNodeEndpoint? node,
    bool clearNode = false,
    bool? privateNodeSupported,
    bool? privateNodeEnabled,
    BeamPrivateNodeStatus? privateNode,
    bool clearPrivateNode = false,
    BeamNodeDiskCheck? disk,
    String? coreProblem,
    bool clearCoreProblem = false,
    bool? busy,
  }) => BeamNodePanelSnapshot(
    assessment: assessment ?? this.assessment,
    node: clearNode ? null : node ?? this.node,
    privateNodeSupported: privateNodeSupported ?? this.privateNodeSupported,
    privateNodeEnabled: privateNodeEnabled ?? this.privateNodeEnabled,
    privateNode: clearPrivateNode ? null : privateNode ?? this.privateNode,
    disk: disk ?? this.disk,
    coreProblem: clearCoreProblem ? null : coreProblem ?? this.coreProblem,
    busy: busy ?? this.busy,
  );

  @override
  bool operator ==(Object other) =>
      other is BeamNodePanelSnapshot &&
      other.assessment == assessment &&
      other.node == node &&
      other.privateNodeSupported == privateNodeSupported &&
      other.privateNodeEnabled == privateNodeEnabled &&
      other.privateNode == privateNode &&
      other.disk == disk &&
      other.coreProblem == coreProblem &&
      other.busy == busy;

  @override
  int get hashCode => Object.hash(
    assessment,
    node,
    privateNodeSupported,
    privateNodeEnabled,
    privateNode,
    disk,
    coreProblem,
    busy,
  );
}

/// Colour family of a line: green, yellow, red, or plain.
enum BeamNodeTone { good, busy, problem, neutral }

/// Which Beam girl moment goes with the private node's state (the UI maps
/// these to `BeamMoments`): small and secondary to the text.
enum BeamNodeMoment {
  /// Downloading or catching up.
  syncing,

  /// In use.
  ready,

  /// Back on a public node after something went wrong.
  fellBack,
}

/// The buttons the panel can show.
enum BeamNodePanelAction {
  /// Start again after a failure ([BeamPrivateNodeCoordinator.retry]).
  retry,

  /// Re-check now ([BeamPrivateNodeCoordinator.checkNow]).
  checkAgain,

  /// Start a node the user stopped ([BeamPrivateNodeCoordinator.retry]).
  start,

  /// [BeamPrivateNodeCoordinator.restart].
  restart,

  /// [BeamPrivateNodeCoordinator.stop].
  stop,

  /// Leave a private node that is not answering (stops it).
  usePublicNode,
}

/// Labels and texts for one snapshot.
class BeamNodePanelView {
  const BeamNodePanelView({
    required this.nodeTitle,
    this.nodeAddress,
    required this.syncTitle,
    this.syncDetail,
    required this.syncTone,
    this.heightLine,
    this.syncAction,
    required this.showPrivateNode,
    required this.toggleValue,
    required this.privateTitle,
    this.privateDetail,
    this.progress,
    required this.privateTone,
    this.diskLine,
    this.primaryAction,
    this.secondaryActions = const [],
    this.moment,
    required this.chipLabel,
    required this.chipTone,
  });

  /// "Public node" or "Your private node".
  final String nodeTitle;

  /// `host:port` of a public node; null for the private one.
  final String? nodeAddress;

  final String syncTitle;
  final String? syncDetail;
  final BeamNodeTone syncTone;

  /// "Block 4,068,266" (and "of 4,068,300" while behind).
  final String? heightLine;

  /// The one fix the sync card offers, when there is one the app can do.
  final BeamNodePanelAction? syncAction;

  final bool showPrivateNode;
  final bool toggleValue;

  /// "Downloading 43%", "Catching up 1,700 blocks", "Ready — switching",
  /// "Your private node is in use", ...
  final String privateTitle;
  final String? privateDetail;

  /// 0–1 while downloading.
  final double? progress;
  final BeamNodeTone privateTone;

  /// "Needs about 8 GB · 37 GB free".
  final String? diskLine;

  /// The panel's one primary button, when something needs doing.
  final BeamNodePanelAction? primaryAction;

  /// Quiet text buttons ("Restart", "Stop").
  final List<BeamNodePanelAction> secondaryActions;

  /// The sticker beside the private node's state, if any.
  final BeamNodeMoment? moment;

  final String chipLabel;
  final BeamNodeTone chipTone;
}

abstract final class BeamNodePanelText {
  static const String title = 'Node & sync';

  static const String toggleLabel = 'Use my own private node';

  /// What the private node gives, in one sentence.
  static const String toggleExplainer =
      "Sees offline and max-privacy payments, and doesn't depend on someone "
      "else's node.";

  /// What happens when it fails.
  static const String fallbackNote =
      'If it ever stops: back on a public node — your wallet keeps working.';

  static const String notOnThisDevice =
      'This device uses public nodes. A private node runs on the desktop '
      'app.';

  static String actionLabel(BeamNodePanelAction a) => switch (a) {
    BeamNodePanelAction.retry => 'Try again',
    BeamNodePanelAction.checkAgain => 'Check again',
    BeamNodePanelAction.start => 'Start private node',
    BeamNodePanelAction.restart => 'Restart',
    BeamNodePanelAction.stop => 'Stop',
    BeamNodePanelAction.usePublicNode => 'Use a public node',
  };
}

abstract final class BeamNodePanelModel {
  static BeamNodePanelView describe(BeamNodePanelSnapshot s) {
    final a = s.assessment;
    final onPrivate =
        (s.node?.isOwned ?? false) || a.node == BeamNodeKind.privateNode;
    final syncMessage = BeamSyncMessages.describe(a);
    final problem = s.coreProblem;

    final private = _private(s);
    return BeamNodePanelView(
      nodeTitle: s.node == null
          ? (problem == null ? 'Connecting…' : 'Not connected')
          : onPrivate
          ? 'Your private node'
          : 'Public node',
      nodeAddress: onPrivate ? null : s.node?.toString(),
      syncTitle: problem == null ? syncMessage.title : "Can't start the wallet",
      syncDetail: problem ?? syncMessage.detail,
      syncTone: problem != null ? BeamNodeTone.problem : _syncTone(a),
      heightLine: _height(a),
      syncAction:
          problem == null &&
              a.action == BeamSyncAction.usePublicNode &&
              s.privateNode != null
          ? BeamNodePanelAction.usePublicNode
          : null,
      showPrivateNode: s.privateNodeSupported,
      toggleValue: s.privateNodeEnabled,
      privateTitle: private.title,
      privateDetail: private.detail,
      progress: private.progress,
      privateTone: private.tone,
      // A disk refusal already says the numbers in its message.
      diskLine:
          s.privateNodeSupported &&
              s.privateNodeEnabled &&
              s.privateNode?.issue != BeamPrivateNodeIssue.notEnoughDisk &&
              s.privateNode?.issue != BeamPrivateNodeIssue.diskFull
          ? _diskLine(s)
          : null,
      primaryAction: private.primary,
      secondaryActions: private.secondary,
      moment: private.moment,
      chipLabel: _chipLabel(s, onPrivate),
      chipTone: problem != null ? BeamNodeTone.problem : _syncTone(a),
    );
  }

  static BeamNodeTone _syncTone(BeamSyncAssessment a) => switch (a) {
    BeamSynced() => BeamNodeTone.good,
    BeamSyncCatchingUp() || BeamSyncConnecting() => BeamNodeTone.busy,
    BeamSyncNotConnected() || BeamSyncStalled() => BeamNodeTone.problem,
  };

  static String? _height(BeamSyncAssessment a) {
    final h = a.walletHeight;
    if (h == null) return null;
    final n = a.networkHeight;
    final at = 'Block ${BeamSyncMessages.number(h)}';
    if (a is! BeamSynced && n != null && n > h) {
      return '$at of ${BeamSyncMessages.number(n)}';
    }
    return at;
  }

  static String? _diskLine(BeamNodePanelSnapshot s) {
    final d = s.disk ?? s.privateNode?.disk;
    if (d == null) {
      const policy = BeamNodeDiskPolicy();
      return _setupNeeds(policy.setupPeakBytes, policy.nodeBytes);
    }
    final free = '${formatBeamDiskSize(d.space.freeBytes)} free';
    final used = formatBeamDiskSize(d.space.nodeBytes);
    if (!d.freshNode) return 'Uses $used · $free';
    if (d.space.nodeBytes < 100 * 1024 * 1024) {
      return '${_setupNeeds(d.setupPeakBytes, d.nodeBytes)} · $free';
    }
    return 'Uses $used so far (up to '
        '${formatBeamDiskSize(d.setupPeakBytes)} while it sets up) · $free';
  }

  static String _setupNeeds(int peak, int settled) =>
      'Needs about ${formatBeamDiskSize(peak)} while it sets up, then about '
      '${formatBeamDiskSize(settled)}';

  static String _chipLabel(BeamNodePanelSnapshot s, bool onPrivate) {
    if (s.coreProblem != null) return 'Not connected';
    final a = s.assessment;
    switch (a) {
      case BeamSyncConnecting():
        return 'Connecting';
      case BeamSyncNotConnected():
        return 'Not connected';
      case BeamSyncStalled():
        return 'Not up to date';
      case BeamSyncCatchingUp():
        return 'Catching up';
      case BeamSynced():
        if (onPrivate) return 'Private node';
        final p = s.privateNode;
        final f = p?.finishingPercent;
        if (f != null) return 'Public node · private $f%';
        if (p?.phase == BeamPrivateNodePhase.downloading) {
          final pct = p!.percent;
          return pct == null
              ? 'Public node · private downloading'
              : 'Public node · private $pct%';
        }
        if (p?.phase == BeamPrivateNodePhase.catchingUp) {
          return 'Public node · private catching up';
        }
        return 'Public node';
    }
  }

  static _Private _private(BeamNodePanelSnapshot s) {
    if (!s.privateNodeSupported) {
      return const _Private(
        title: 'Not available on this device',
        detail: BeamNodePanelText.notOnThisDevice,
        tone: BeamNodeTone.neutral,
      );
    }
    final st = s.privateNode;
    if (!s.privateNodeEnabled &&
        (st == null || st.phase == BeamPrivateNodePhase.off)) {
      return const _Private(
        title: 'Off',
        detail: 'The wallet uses public nodes.',
        tone: BeamNodeTone.neutral,
      );
    }
    if (st == null || st.phase == BeamPrivateNodePhase.idle) {
      return _Private(
        title: 'Starting soon',
        detail: s.assessment.canSpend
            ? 'Your private node starts in a minute. The wallet works as '
                  'normal meanwhile.'
            : 'Your private node starts once your wallet is up to date.',
        tone: BeamNodeTone.neutral,
      );
    }
    final message = BeamPrivateNodeMessages.describe(st);
    final running = <BeamNodePanelAction>[
      BeamNodePanelAction.restart,
      BeamNodePanelAction.stop,
    ];
    const publicUntilReady =
        'The wallet uses a public node until your private node is ready, '
        'then switches by itself.';
    final finishing = st.finishingPercent;
    if (finishing != null &&
        (st.phase == BeamPrivateNodePhase.downloading ||
            st.phase == BeamPrivateNodePhase.catchingUp)) {
      return _Private(
        title: 'Finishing setup ($finishing%)',
        detail: 'This last step takes 5–10 minutes. $publicUntilReady',
        progress: finishing.clamp(0, 100) / 100,
        tone: BeamNodeTone.busy,
        secondary: running,
        moment: BeamNodeMoment.syncing,
      );
    }
    switch (st.phase) {
      case BeamPrivateNodePhase.off:
        // Turned on in the panel, not applied yet.
        return const _Private(
          title: 'Starting soon',
          detail: 'Your private node starts in a moment.',
          tone: BeamNodeTone.neutral,
        );
      case BeamPrivateNodePhase.idle:
      case BeamPrivateNodePhase.preparing:
        return _Private(
          title: 'Setting up',
          detail: message.detail,
          tone: BeamNodeTone.busy,
        );
      case BeamPrivateNodePhase.downloading:
        final pct = st.percent;
        return _Private(
          title: pct == null ? 'Downloading' : 'Downloading $pct%',
          detail:
              'The first download takes 1–2 hours; later starts take '
              'minutes. $publicUntilReady',
          progress: pct == null ? null : (pct.clamp(0, 100) / 100),
          tone: BeamNodeTone.busy,
          secondary: running,
          moment: BeamNodeMoment.syncing,
        );
      case BeamPrivateNodePhase.catchingUp:
        final behind = st.blocksBehind;
        return _Private(
          title: behind != null && behind > 0
              ? 'Catching up ${_blocks(behind)}'
              : 'Catching up',
          detail: publicUntilReady,
          tone: BeamNodeTone.busy,
          secondary: running,
          moment: BeamNodeMoment.syncing,
        );
      case BeamPrivateNodePhase.switching:
        return _Private(
          title: st.waitingForWallet
              ? 'Ready — switching after your payment'
              : 'Ready — switching',
          detail: message.detail,
          tone: BeamNodeTone.busy,
        );
      case BeamPrivateNodePhase.active:
        return st.privateReceiveAvailable
            ? _Private(
                title: 'Your private node is in use',
                detail: message.detail,
                tone: BeamNodeTone.good,
                secondary: running,
                moment: BeamNodeMoment.ready,
              )
            : _Private(
                title: message.title,
                detail: message.detail,
                tone: BeamNodeTone.busy,
                secondary: running,
              );
      case BeamPrivateNodePhase.cannotVerify:
      case BeamPrivateNodePhase.stuck:
      case BeamPrivateNodePhase.fellBehind:
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: BeamNodeTone.busy,
          primary: _actionFor(st),
          secondary: running,
          moment: st.phase == BeamPrivateNodePhase.fellBehind
              ? BeamNodeMoment.fellBack
              : null,
        );
      case BeamPrivateNodePhase.stopped:
        final byUser = st.issue == BeamPrivateNodeIssue.stoppedByUser;
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: byUser ? BeamNodeTone.neutral : BeamNodeTone.problem,
          primary: _actionFor(st),
          moment: byUser ? null : BeamNodeMoment.fellBack,
        );
      case BeamPrivateNodePhase.failed:
      case BeamPrivateNodePhase.ownNodeUnconfirmed:
      case BeamPrivateNodePhase.walletClosed:
        return _Private(
          title: message.title,
          detail: message.detail,
          tone: BeamNodeTone.problem,
          primary: _actionFor(st),
          moment: BeamNodeMoment.fellBack,
        );
    }
  }

  static BeamNodePanelAction? _actionFor(BeamPrivateNodeStatus st) =>
      switch (BeamPrivateNodeMessages.actionFor(st)) {
        BeamPrivateNodeAction.none => null,
        // The switch above the card turns it on.
        BeamPrivateNodeAction.turnOn => null,
        BeamPrivateNodeAction.retry => BeamNodePanelAction.retry,
        BeamPrivateNodeAction.checkAgain => BeamNodePanelAction.checkAgain,
        BeamPrivateNodeAction.start => BeamNodePanelAction.start,
      };

  static String _blocks(int n) =>
      n == 1 ? '1 block' : '${BeamSyncMessages.number(n)} blocks';
}

class _Private {
  const _Private({
    required this.title,
    this.detail,
    this.progress,
    required this.tone,
    this.primary,
    this.secondary = const [],
    this.moment,
  });

  final String title;
  final String? detail;
  final double? progress;
  final BeamNodeTone tone;
  final BeamNodePanelAction? primary;
  final List<BeamNodePanelAction> secondary;
  final BeamNodeMoment? moment;
}
