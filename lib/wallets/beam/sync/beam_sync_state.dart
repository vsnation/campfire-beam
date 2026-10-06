/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// The one place "synced" is decided for a BEAM wallet (project rules R5).
///
/// "Synced" — and with it, permission to spend — requires all of:
///
/// 1. `is_in_sync` from the core. That flag only means "the last block is at
///    most 600 s old" (`wallet/core/common.cpp:703`); it knows nothing about
///    forks.
/// 2. The tip is at most [BeamSyncRules.maxTipAge] old by the device clock,
///    checked here again (the flag in an event can be stale).
/// 3. The core has applied the headers it knows: `tip_height - current_height
///    <= maxHeaderLag`.
/// 4. When a fresh explorer is available, it is at most
///    [BeamSyncRules.maxExplorerLag] blocks ahead of the wallet.
/// 5. The wallet is past the hard-fork height when the chain is. A node frozen
///    at 3928665 (pre-HF6 rules) is out of consensus, whatever else it says.
/// 6. The core has reached its node in this session
///    (`ev_connection_changed.node_connected == true`). `is_in_sync` is
///    computed from the stored tip's age alone (`v6_1_api_handle.cpp:176`),
///    so a wallet reopened within ten minutes, or just moved to a node that
///    does not answer, reports it before hearing from any node. Not reported
///    yet (`null`) is not enough.
///
/// When no fresh explorer can confirm the height (none answers, its own tip
/// is old, or it lags the wallet), rules 1–3, 5 and 6 still have to pass and
/// the verdict is [BeamSynced] with [BeamSynced.verified] false: spending is
/// allowed, and the wording says the height could not be double-checked
/// (ARCHITECTURE.md §5, Sync). Blocking every send while a third-party
/// explorer is down would hand that explorer a switch over the wallet, and it
/// cannot put the wallet on a dead fork: the binaries are pinned to the HF6
/// rules and a forged chain needs mainnet proof of work.
///
/// No height constant ever *grants* "synced"; the fork height is only used
/// to deny it and to explain why.
///
/// Everything here is pure: same inputs, same answer. User-facing wording is
/// in `beam_sync_messages.dart`.
library;

import 'dart:math' as math;

import '../explorer/beam_explorer_client.dart';

/// First block of BEAM mainnet HF6 (2026-06-30). Pre-7.5.14493 binaries stop
/// at the block before it.
const int beamMainnetHf6Height = 3928666;

/// The wallet core's view of the chain, as the sync rules need it.
///
/// The wallet layer maps `wallet_status`, `ev_sync_progress`,
/// `ev_system_state` and `ev_connection_changed` into this; nothing here
/// depends on the RPC models.
class BeamWalletSyncInput {
  const BeamWalletSyncInput({
    required this.currentHeight,
    required this.currentStateTimestamp,
    required this.isInSync,
    this.headerTipHeight,
    this.nodeConnected,
    this.ownNode,
  });

  /// `current_height`: the last fully processed block, not the header tip.
  final int currentHeight;

  /// `current_state_timestamp` (block time of [currentHeight]), UTC.
  final DateTime? currentStateTimestamp;

  /// `is_in_sync` as the core reported it.
  final bool isInSync;

  /// `tip_height` from `ev_system_state` / `ev_sync_progress`: the newest
  /// header the core knows. Null when not reported yet.
  final int? headerTipHeight;

  /// `ev_connection_changed.node_connected`. Null when not reported yet in
  /// this session; only `true` allows [BeamSynced].
  final bool? nodeConnected;

  /// `ev_connection_changed.own_node`: the node holds this wallet's owner
  /// key. Null when not reported yet.
  final bool? ownNode;

  BeamWalletSyncInput copyWith({
    int? currentHeight,
    DateTime? currentStateTimestamp,
    bool? isInSync,
    int? headerTipHeight,
    bool? nodeConnected,
    bool? ownNode,
  }) => BeamWalletSyncInput(
    currentHeight: currentHeight ?? this.currentHeight,
    currentStateTimestamp: currentStateTimestamp ?? this.currentStateTimestamp,
    isInSync: isInSync ?? this.isInSync,
    headerTipHeight: headerTipHeight ?? this.headerTipHeight,
    nodeConnected: nodeConnected ?? this.nodeConnected,
    ownNode: ownNode ?? this.ownNode,
  );

  /// The same chain state with the connection unknown: what a new session
  /// (another wallet-api, maybe another node) knows until its core reports.
  BeamWalletSyncInput withoutConnection() => BeamWalletSyncInput(
    currentHeight: currentHeight,
    currentStateTimestamp: currentStateTimestamp,
    isInSync: isInSync,
    headerTipHeight: headerTipHeight,
  );

  @override
  bool operator ==(Object other) =>
      other is BeamWalletSyncInput &&
      other.currentHeight == currentHeight &&
      other.currentStateTimestamp == currentStateTimestamp &&
      other.isInSync == isInSync &&
      other.headerTipHeight == headerTipHeight &&
      other.nodeConnected == nodeConnected &&
      other.ownNode == ownNode;

  @override
  int get hashCode => Object.hash(
    currentHeight,
    currentStateTimestamp,
    isInSync,
    headerTipHeight,
    nodeConnected,
    ownNode,
  );

  @override
  String toString() =>
      'BeamWalletSyncInput(height: $currentHeight, '
      'ts: ${currentStateTimestamp?.toIso8601String()}, '
      'isInSync: $isInSync, headerTip: $headerTipHeight, '
      'connected: $nodeConnected, ownNode: $ownNode)';
}

/// Which kind of node the wallet core is pointed at.
enum BeamNodeKind {
  /// A public node run by someone else.
  publicNode,

  /// This app's own `beam-node`, holding the wallet's owner key.
  privateNode,
}

/// What the monitor has seen of the wallet's height over time. Without it the
/// rules judge a single snapshot.
class BeamSyncProgress {
  const BeamSyncProgress({
    required this.observingSince,
    this.heightLastAdvancedAt,
    this.blocksPerSecond,
  });

  /// When the monitor started watching this wallet/node pair.
  final DateTime observingSince;

  /// When `current_height` was last seen to increase, or null if not yet.
  final DateTime? heightLastAdvancedAt;

  /// Recent processing speed, when measurable.
  final double? blocksPerSecond;
}

/// Thresholds. The defaults are the project's rules; tests may tighten them.
class BeamSyncRules {
  const BeamSyncRules({
    this.maxTipAge = const Duration(minutes: 10),
    this.maxExplorerLag = 5,
    this.maxHeaderLag = 1,
    this.maxExplorerTipAge = const Duration(minutes: 10),
    this.stallAfter = const Duration(minutes: 5),
    this.clockTolerance = const Duration(minutes: 2),
    this.blockInterval = const Duration(seconds: 60),
    this.minConsensusHeight = beamMainnetHf6Height,
  });

  /// Oldest tip that still counts as current. The core uses 600 s too.
  final Duration maxTipAge;

  /// How many blocks a fresh explorer may be ahead of a "synced" wallet.
  final int maxExplorerLag;

  /// How many known-but-unapplied headers a "synced" wallet may have. One,
  /// so the moment between a header arriving and its block being applied
  /// does not flicker the state every minute.
  final int maxHeaderLag;

  /// An explorer whose own tip is older than this is not used as a check.
  final Duration maxExplorerTipAge;

  /// A wallet that is behind and has not advanced for this long is stalled
  /// rather than catching up (needs [BeamSyncProgress]).
  final Duration stallAfter;

  /// Device clock error tolerated before it is named as the problem.
  final Duration clockTolerance;

  /// BEAM's block target (`DA.Target_ms = 60'000`).
  final Duration blockInterval;

  /// First height of the current consensus rules (HF6 on mainnet).
  final int minConsensusHeight;
}

/// How the independent explorer check came out.
enum BeamExplorerCheck {
  /// A fresh explorer is within [BeamSyncRules.maxExplorerLag] of the wallet.
  agrees,

  /// A fresh explorer is further ahead than that: the wallet is behind.
  aheadOfWallet,

  /// A fresh explorer is further *behind* the wallet than that, so it cannot
  /// vouch for the wallet.
  behindWallet,

  /// The explorer answered, but its own tip is too old to use.
  stale,

  /// No explorer answered.
  unavailable,
}

/// Why a wallet that is behind is not expected to catch up by itself.
enum BeamStallReason {
  /// The newest block is too old and nothing newer is arriving.
  tipTooOld,

  /// Below the hard-fork height while the chain is past it: the node follows
  /// old consensus rules (the HF6 freeze at 3928665).
  stuckBelowHardFork,

  /// The core knows newer headers but has stopped applying them.
  headerAheadOfProcessed,

  /// The node looks current but independent explorers are well ahead.
  behindNetwork,

  /// The device clock is off, so tip ages cannot be judged.
  deviceClockWrong,
}

/// The next step the UI should offer.
enum BeamSyncAction {
  none,
  wait,
  tryAnotherNode,
  usePublicNode,
  checkInternet,
  reconnect,
  fixDeviceClock,
}

/// The verdict. Switch over the subclasses; only [BeamSynced] can spend.
sealed class BeamSyncAssessment {
  const BeamSyncAssessment({
    required this.node,
    required this.explorerCheck,
    this.walletHeight,
    this.networkHeight,
  });

  /// Which kind of node this verdict is about.
  final BeamNodeKind node;

  /// How the explorer cross-check came out.
  final BeamExplorerCheck explorerCheck;

  /// The wallet's processed height, when known.
  final int? walletHeight;

  /// Best independent estimate of the chain height (explorer, or the core's
  /// header tip), when known.
  final int? networkHeight;

  /// Whether sending, swapping and contract calls are allowed.
  bool get canSpend => false;

  /// What the user can do about it.
  BeamSyncAction get action;

  List<Object?> get _props;

  @override
  bool operator ==(Object other) =>
      other is BeamSyncAssessment &&
      other.runtimeType == runtimeType &&
      other.node == node &&
      other.explorerCheck == explorerCheck &&
      other.walletHeight == walletHeight &&
      other.networkHeight == networkHeight &&
      _listEquals(other._props, _props);

  @override
  int get hashCode => Object.hash(
    runtimeType,
    node,
    explorerCheck,
    walletHeight,
    networkHeight,
    Object.hashAll(_props),
  );

  @override
  String toString() =>
      '$runtimeType(node: ${node.name}, '
      'explorer: ${explorerCheck.name}, wallet: $walletHeight, '
      'network: $networkHeight, ${_props.join(', ')})';
}

/// No chain state yet: opening the wallet or reaching a node.
final class BeamSyncConnecting extends BeamSyncAssessment {
  const BeamSyncConnecting({
    required super.node,
    required super.explorerCheck,
    super.walletHeight,
    super.networkHeight,
  });

  @override
  BeamSyncAction get action => BeamSyncAction.wait;

  @override
  List<Object?> get _props => const [];
}

/// The core reports no connection to its node.
final class BeamSyncNotConnected extends BeamSyncAssessment {
  const BeamSyncNotConnected({
    required super.node,
    required super.explorerCheck,
    required this.networkReachable,
    super.walletHeight,
    super.networkHeight,
  });

  /// An explorer answered, so the internet works and the node is the
  /// problem.
  final bool networkReachable;

  @override
  BeamSyncAction get action => node == BeamNodeKind.privateNode
      ? BeamSyncAction.usePublicNode
      : networkReachable
      ? BeamSyncAction.tryAnotherNode
      : BeamSyncAction.checkInternet;

  @override
  List<Object?> get _props => [networkReachable];
}

/// Behind, and expected to catch up by itself.
final class BeamSyncCatchingUp extends BeamSyncAssessment {
  const BeamSyncCatchingUp({
    required super.node,
    required super.explorerCheck,
    required this.blockInterval,
    super.walletHeight,
    super.networkHeight,
    this.blocksBehind,
    this.eta,
  });

  /// Blocks between the wallet and [networkHeight], when known.
  final int? blocksBehind;

  /// Estimated time to catch up, from the observed speed, when known.
  final Duration? eta;

  /// Block target, for "about N minutes behind".
  final Duration blockInterval;

  /// How far behind in chain time ([blocksBehind] x block target).
  Duration? get timeBehind =>
      blocksBehind == null ? null : blockInterval * blocksBehind!;

  @override
  BeamSyncAction get action => BeamSyncAction.wait;

  @override
  List<Object?> get _props => [blocksBehind, eta, blockInterval];
}

/// Behind, and not expected to recover without the user doing something.
final class BeamSyncStalled extends BeamSyncAssessment {
  const BeamSyncStalled({
    required super.node,
    required super.explorerCheck,
    required this.reason,
    required this.blockInterval,
    required this.forkHeight,
    super.walletHeight,
    super.networkHeight,
    this.blocksBehind,
    this.tipAge,
    this.headerLag,
    this.deviceClockOffset,
  });

  final BeamStallReason reason;

  /// Blocks between the wallet and [networkHeight], when known.
  final int? blocksBehind;

  /// Age of the wallet's newest block by the device clock.
  final Duration? tipAge;

  /// Headers known but not applied, for
  /// [BeamStallReason.headerAheadOfProcessed].
  final int? headerLag;

  /// Device clock minus real time (positive: device ahead), for
  /// [BeamStallReason.deviceClockWrong].
  final Duration? deviceClockOffset;

  /// Block target, for "about N minutes behind".
  final Duration blockInterval;

  /// The consensus height the wallet failed to reach, for
  /// [BeamStallReason.stuckBelowHardFork].
  final int forkHeight;

  Duration? get timeBehind =>
      blocksBehind == null ? null : blockInterval * blocksBehind!;

  @override
  BeamSyncAction get action => switch (reason) {
    BeamStallReason.deviceClockWrong => BeamSyncAction.fixDeviceClock,
    BeamStallReason.headerAheadOfProcessed => BeamSyncAction.reconnect,
    BeamStallReason.tipTooOld ||
    BeamStallReason.stuckBelowHardFork ||
    BeamStallReason.behindNetwork =>
      node == BeamNodeKind.privateNode
          ? BeamSyncAction.usePublicNode
          : BeamSyncAction.tryAnotherNode,
  };

  @override
  List<Object?> get _props => [
    reason,
    blocksBehind,
    tipAge,
    headerLag,
    deviceClockOffset,
    blockInterval,
    forkHeight,
  ];
}

/// Following the chain, with the core connected to its node. Spending is
/// allowed.
///
/// [verified] is false in the degraded state: no fresh explorer could confirm
/// the height ([explorerCheck] says why), so only the core's own checks
/// passed — a connected node, a fresh tip and no unapplied headers. Spending
/// is still allowed then, and the wording says the height could not be
/// double-checked (see the library comment).
final class BeamSynced extends BeamSyncAssessment {
  const BeamSynced({
    required super.node,
    required super.explorerCheck,
    super.walletHeight,
    super.networkHeight,
  });

  bool get verified => explorerCheck == BeamExplorerCheck.agrees;

  @override
  bool get canSpend => true;

  @override
  BeamSyncAction get action => BeamSyncAction.none;

  @override
  List<Object?> get _props => const [];
}

enum _Motion {
  /// Height increased within [BeamSyncRules.stallAfter].
  advancing,

  /// Watched for less than [BeamSyncRules.stallAfter]; too early to call.
  watching,

  /// Watched for longer than that without the height increasing.
  stopped,

  /// No history: judge the snapshot alone.
  unknown,
}

/// Decides whether the wallet is following the chain.
///
/// * [wallet]: null until the core has reported anything.
/// * [explorer]: the latest independent tip, or null when no explorer
///   answered recently.
/// * [node]: where the core is pointed. `wallet.ownNode == true` also counts
///   as a private node.
/// * [progress]: history from the monitor; without it a snapshot is judged.
BeamSyncAssessment assessBeamSync({
  required BeamWalletSyncInput? wallet,
  required BeamExplorerStatus? explorer,
  required DateTime now,
  BeamNodeKind node = BeamNodeKind.publicNode,
  BeamSyncProgress? progress,
  BeamSyncRules rules = const BeamSyncRules(),
}) {
  final kind = (node == BeamNodeKind.privateNode || wallet?.ownNode == true)
      ? BeamNodeKind.privateNode
      : BeamNodeKind.publicNode;
  final explorerFresh =
      explorer != null && explorer.tipAgeAt(now) <= rules.maxExplorerTipAge;

  if (wallet == null) {
    return BeamSyncConnecting(
      node: kind,
      explorerCheck: _checkWithoutWallet(explorer, explorerFresh),
      networkHeight: explorer?.height,
    );
  }

  final headerTip = wallet.headerTipHeight;
  final networkHeight = _maxOrNull(explorer?.height, headerTip);

  if (wallet.nodeConnected == false) {
    return BeamSyncNotConnected(
      node: kind,
      explorerCheck: _checkWithoutWallet(explorer, explorerFresh),
      networkReachable: explorer != null,
      walletHeight: wallet.currentHeight > 0 ? wallet.currentHeight : null,
      networkHeight: networkHeight,
    );
  }

  final height = wallet.currentHeight;
  final ts = wallet.currentStateTimestamp;
  if ((height <= 0 || ts == null) && wallet.nodeConnected == true) {
    // Connected but no chain state of its own yet: a new or restored wallet
    // reading the chain from the start. With block bodies on (a restore
    // scan over a public node) that takes hours, so "connecting, a few
    // seconds" would be false for all of it.
    return BeamSyncCatchingUp(
      node: kind,
      explorerCheck: _checkWithoutWallet(explorer, explorerFresh),
      blockInterval: rules.blockInterval,
      networkHeight: networkHeight,
    );
  }
  if (height <= 0 || ts == null) {
    return BeamSyncConnecting(
      node: kind,
      explorerCheck: _checkWithoutWallet(explorer, explorerFresh),
      networkHeight: networkHeight,
    );
  }

  final tipAge = now.difference(ts);
  final tipFresh = tipAge <= rules.maxTipAge;
  final headerLag = headerTip == null ? null : headerTip - height;
  // networkHeight includes the header tip, so this covers headerLag too.
  final blocksBehind = networkHeight == null
      ? null
      : math.max(0, networkHeight - height);

  final BeamExplorerCheck check;
  if (explorer == null) {
    check = BeamExplorerCheck.unavailable;
  } else if (!explorerFresh) {
    check = BeamExplorerCheck.stale;
  } else if (explorer.height - height > rules.maxExplorerLag) {
    check = BeamExplorerCheck.aheadOfWallet;
  } else if (height - explorer.height > rules.maxExplorerLag) {
    check = BeamExplorerCheck.behindWallet;
  } else {
    check = BeamExplorerCheck.agrees;
  }

  // The chain is past the fork if anyone independent says so (a stale
  // explorer still proves the chain got that far), or if our own core has
  // seen headers past it.
  final fork = rules.minConsensusHeight;
  final chainPastFork =
      (explorer?.height ?? 0) >= fork || (headerTip ?? 0) >= fork;
  // Frozen exactly at the block before the fork, with an old tip: the HF6
  // signature, recognisable even when no explorer answers.
  final atForkBoundary = height == fork - 1 && !tipFresh;
  final belowFork = height < fork && (chainPastFork || atForkBoundary);

  final headerOk = headerLag == null || headerLag <= rules.maxHeaderLag;
  if (wallet.isInSync &&
      tipFresh &&
      headerOk &&
      check != BeamExplorerCheck.aheadOfWallet &&
      !belowFork) {
    // Everything the stored chain state can say is fine, but the core has
    // not reached a node in this session yet: its `is_in_sync` only means
    // the stored tip is recent. Wait for `node_connected == true`.
    if (wallet.nodeConnected != true) {
      return BeamSyncConnecting(
        node: kind,
        explorerCheck: check,
        walletHeight: height,
        networkHeight: networkHeight,
      );
    }
    return BeamSynced(
      node: kind,
      explorerCheck: check,
      walletHeight: height,
      networkHeight: networkHeight,
    );
  }

  BeamSyncStalled stalled(BeamStallReason reason, {Duration? clockOffset}) =>
      BeamSyncStalled(
        node: kind,
        explorerCheck: check,
        reason: reason,
        blockInterval: rules.blockInterval,
        forkHeight: fork,
        walletHeight: height,
        networkHeight: networkHeight,
        blocksBehind: blocksBehind,
        tipAge: tipAge,
        headerLag: headerLag,
        deviceClockOffset: clockOffset,
      );

  BeamSyncCatchingUp catchingUp() => BeamSyncCatchingUp(
    node: kind,
    explorerCheck: check,
    blockInterval: rules.blockInterval,
    walletHeight: height,
    networkHeight: networkHeight,
    blocksBehind: blocksBehind,
    eta: _eta(blocksBehind, progress, rules),
  );

  // 1. A wrong device clock breaks every age check, the core's included.
  //    Name it when a time check failed *and* the clock explains it: with
  //    the clock corrected, the tip would be current. (A node frozen for
  //    months on a device that is also 5 minutes off is a frozen node.)
  final timeCheckFailed = !wallet.isInSync || !tipFresh;
  final serverOffset = explorer?.deviceClockOffset;
  final tipInFuture = -tipAge; // positive when the tip is "in the future"
  if (timeCheckFailed) {
    if (serverOffset != null &&
        serverOffset.abs() > rules.clockTolerance &&
        tipAge - serverOffset <= rules.maxTipAge) {
      return stalled(
        BeamStallReason.deviceClockWrong,
        clockOffset: serverOffset,
      );
    }
    if (tipInFuture > rules.clockTolerance) {
      // The device is behind by at least this much.
      return stalled(
        BeamStallReason.deviceClockWrong,
        clockOffset: -tipInFuture,
      );
    }
  }

  final motion = _motionOf(progress, now, rules);
  final nodeKnowsMore = headerLag != null && headerLag > rules.maxHeaderLag;

  // 2. Frozen below the hard fork while the chain moved on, and our core has
  //    seen no header past it.
  if (belowFork && !tipFresh && (headerTip ?? 0) < fork) {
    if (atForkBoundary ||
        motion == _Motion.stopped ||
        motion == _Motion.unknown) {
      return stalled(BeamStallReason.stuckBelowHardFork);
    }
  }

  // 3. Headers known, but the core has stopped applying them.
  if (nodeKnowsMore && motion == _Motion.stopped) {
    return stalled(BeamStallReason.headerAheadOfProcessed);
  }

  // 4. Old tip (or the core says so) and nothing newer known.
  if (!tipFresh) {
    if (motion == _Motion.advancing ||
        motion == _Motion.watching ||
        nodeKnowsMore) {
      return catchingUp();
    }
    return stalled(BeamStallReason.tipTooOld);
  }

  // 5. The tip is fresh and the core looks current, yet a fresh explorer is
  //    well ahead: our node is on its own.
  if (check == BeamExplorerCheck.aheadOfWallet &&
      wallet.isInSync &&
      !nodeKnowsMore &&
      motion == _Motion.stopped) {
    return stalled(BeamStallReason.behindNetwork);
  }

  // Fresh tip, but the core's flag is still false, headers are being
  // applied, or the explorer is ahead and we have not watched long enough to
  // call it a stall.
  return catchingUp();
}

/// With no wallet height there is nothing to compare, so `agrees` here only
/// means a fresh explorer answered.
BeamExplorerCheck _checkWithoutWallet(
  BeamExplorerStatus? explorer,
  bool fresh,
) => explorer == null
    ? BeamExplorerCheck.unavailable
    : fresh
    ? BeamExplorerCheck.agrees
    : BeamExplorerCheck.stale;

_Motion _motionOf(BeamSyncProgress? p, DateTime now, BeamSyncRules rules) {
  if (p == null) return _Motion.unknown;
  final advanced = p.heightLastAdvancedAt;
  if (advanced != null && now.difference(advanced) <= rules.stallAfter) {
    return _Motion.advancing;
  }
  if (now.difference(p.observingSince) < rules.stallAfter) {
    return _Motion.watching;
  }
  return _Motion.stopped;
}

/// Time to close [behind] blocks at the observed speed, minus the chain's own
/// growth (one block per [BeamSyncRules.blockInterval]). Null when the speed
/// is unknown or not faster than the chain.
Duration? _eta(int? behind, BeamSyncProgress? p, BeamSyncRules rules) {
  final speed = p?.blocksPerSecond;
  if (behind == null || behind <= 0 || speed == null) return null;
  final chainSpeed = 1 / rules.blockInterval.inMicroseconds * 1e6;
  final net = speed - chainSpeed;
  if (net <= 0) return null;
  return Duration(seconds: (behind / net).ceil());
}

int? _maxOrNull(int? a, int? b) =>
    a == null ? b : (b == null ? a : math.max(a, b));

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
