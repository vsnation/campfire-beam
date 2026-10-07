/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import '../explorer/beam_explorer_client.dart';
import '../host/beam_host.dart';
import '../host/beam_host_exception.dart';
import '../host/process_host.dart';
import '../rpc/beam_transport.dart';
import '../sync/beam_sync_state.dart' show beamMainnetHf6Height;
import 'beam_node_disk.dart';
import 'beam_node_process.dart';
import 'beam_node_progress.dart';

/// Reads the wallet password from Campfire's secure storage when needed, so
/// the coordinator never keeps it in a field.
typedef BeamPasswordProvider = Future<String> Function();

/// Reads the owner key the wallet stored while it was closed anyway
/// (project rules R11), or null when there is none.
typedef BeamOwnerKeyProvider = Future<String?> Function();

/// Completes once no send, swap, claim or dApp approval is open.
typedef BeamIdleWaiter = Future<void> Function();

/// Makes a fresh, unstarted private node. [BeamNodeProcess] is single-use,
/// so every (re)start asks for a new one.
typedef BeamPrivateNodeFactory = BeamPrivateNode Function();

/// Public nodes the wallet falls back to, in order (after the one it was
/// opened on). The `*-nodes` names are BEAM's current DNS pools; the
/// numbered hosts are single servers inside them, useful when a pool name
/// resolves to a dead address. All four resolved and accepted TCP on
/// 2026-10-06.
const List<BeamNodeEndpoint> kBeamPublicWalletNodes = [
  BeamNodeEndpoint('eu-nodes.mainnet.beam.mw', 8100),
  BeamNodeEndpoint('us-nodes.mainnet.beam.mw', 8100),
  BeamNodeEndpoint('eu-node01.mainnet.beam.mw', 8100),
  BeamNodeEndpoint('us-node01.mainnet.beam.mw', 8100),
];

/// The persisted "Use a private node" preference (hook for the settings
/// UI). When it reads `false` the coordinator does nothing at all.
abstract interface class BeamPrivateNodeSetting {
  Future<bool> read();
}

/// A setting with a fixed value.
class BeamFixedPrivateNodeSetting implements BeamPrivateNodeSetting {
  const BeamFixedPrivateNodeSetting(this.enabled);

  /// On for desktop, off elsewhere: phones cannot run `beam-node`
  /// (ARCHITECTURE.md §4, mobile uses body requests).
  factory BeamFixedPrivateNodeSetting.platformDefault() =>
      BeamFixedPrivateNodeSetting(
        Platform.isMacOS || Platform.isLinux || Platform.isWindows,
      );

  final bool enabled;

  @override
  Future<bool> read() async => enabled;
}

/// A setting read through a callback (e.g. Campfire's prefs).
class BeamCallbackPrivateNodeSetting implements BeamPrivateNodeSetting {
  const BeamCallbackPrivateNodeSetting(this._read);

  final Future<bool> Function() _read;

  @override
  Future<bool> read() => _read();
}

/// Where the private-node handover is.
enum BeamPrivateNodePhase {
  /// The "Use a private node" setting is off.
  off,

  /// Not started yet.
  idle,

  /// The wallet is paused for a moment to read its owner key.
  preparing,

  /// The node is fast-syncing; the wallet runs on a public node.
  downloading,

  /// The node is past fast sync but not at the tip yet.
  catchingUp,

  /// The node says it is synced but no independent source can confirm it,
  /// so the wallet stays on the public node.
  cannotVerify,

  /// The node says it is synced but is not: below the hard fork, or not
  /// advancing. The wallet stays on the public node.
  stuck,

  /// The wallet is being moved to the private node.
  switching,

  /// The wallet runs on the private node and the core confirmed it holds
  /// this wallet's key (`own_node == true`).
  active,

  /// The wallet moved to the node but the core never confirmed the key; it
  /// is back on a public node.
  ownNodeUnconfirmed,

  /// The node could not be set up; see [BeamPrivateNodeStatus.issue].
  failed,

  /// The node stopped; the wallet is on a public node.
  stopped,

  /// The node fell behind while in use; the wallet is back on a public node
  /// until it catches up.
  fellBehind,

  /// The wallet could not be reopened on any node.
  walletClosed,
}

/// The specific reason behind a phase.
enum BeamPrivateNodeIssue {
  /// The node refused the owner key (or would have run without it).
  keyRejected,

  /// `export_owner_key` failed.
  keyExportFailed,

  /// beam-node did not start.
  nodeStartFailed,

  /// Another app instance runs a node on the same storage.
  nodeInUse,

  /// The beam-node binary failed verification.
  binaryProblem,

  /// No explorer answered with a fresh tip.
  explorerUnavailable,

  /// The explorer is behind the node, so it cannot vouch for it.
  explorerBehind,

  /// The node is below the HF6 height while the chain is past it.
  belowHardFork,

  /// The node's tip stopped advancing.
  notAdvancing,

  /// beam-node exited.
  nodeExited,

  /// Moving the wallet to the node failed.
  switchFailed,

  /// `own_node` was true and then stayed false.
  ownNodeLost,

  /// The wallet moved to the node but could not send within
  /// [BeamPrivateNodeCoordinator.walletReadyTimeout]: the node answered
  /// `own_node` but did not serve the wallet (a node busy with "Raising
  /// Fossil" right after fast sync looks like this). Back on a public node;
  /// the switch is tried again later.
  notServingWallet,

  /// Not started: the disk has too little free space for the node
  /// ([BeamPrivateNodeStatus.disk] has the numbers).
  notEnoughDisk,

  /// Stopped while running because free space ran low.
  diskFull,

  /// The user stopped the node from the node panel.
  stoppedByUser,
}

/// One snapshot of the coordinator, for the node panel and the receive
/// screen. Wording is in `beam_private_node_messages.dart`.
class BeamPrivateNodeStatus {
  const BeamPrivateNodeStatus({
    required this.phase,
    this.issue,
    this.percent,
    this.nodeHeight,
    this.networkHeight,
    this.onPrivateNode = false,
    this.privateReceiveAvailable = false,
    this.lastPause,
    this.disk,
    this.waitingForWallet = false,
    this.finishingPercent,
  });

  final BeamPrivateNodePhase phase;

  /// While catching up: the node's last setup step ("Raising Fossil", 5–10
  /// minutes after fast sync), 0-100. Null otherwise.
  final int? finishingPercent;
  final BeamPrivateNodeIssue? issue;

  /// The last disk measurement for the node, when one was made.
  final BeamNodeDiskCheck? disk;

  /// A node switch is due but waits for a payment, swap, claim or approval
  /// that is still open.
  final bool waitingForWallet;

  /// Node download progress, 0-100, while downloading.
  final int? percent;

  /// The node's newest tip height.
  final int? nodeHeight;

  /// A fresh independent tip height, when known.
  final int? networkHeight;

  /// The wallet is pointed at the private node right now.
  final bool onPrivateNode;

  /// Offline and max-privacy receive may be offered: true only while the
  /// core reports `own_node == true` for the private node.
  final bool privateReceiveAvailable;

  /// How long the wallet was last paused (owner key read or node switch).
  final Duration? lastPause;

  int? get blocksBehind {
    final n = networkHeight;
    final h = nodeHeight;
    return n == null || h == null ? null : n - h;
  }

  @override
  bool operator ==(Object other) =>
      other is BeamPrivateNodeStatus &&
      other.phase == phase &&
      other.issue == issue &&
      other.percent == percent &&
      other.nodeHeight == nodeHeight &&
      other.networkHeight == networkHeight &&
      other.onPrivateNode == onPrivateNode &&
      other.privateReceiveAvailable == privateReceiveAvailable &&
      other.lastPause == lastPause &&
      other.disk == disk &&
      other.waitingForWallet == waitingForWallet &&
      other.finishingPercent == finishingPercent;

  @override
  int get hashCode => Object.hash(
    phase,
    issue,
    percent,
    nodeHeight,
    networkHeight,
    onPrivateNode,
    privateReceiveAvailable,
    lastPause,
    disk,
    waitingForWallet,
    finishingPercent,
  );

  @override
  String toString() =>
      'BeamPrivateNodeStatus(${phase.name}'
      '${issue == null ? '' : ', ${issue!.name}'}'
      '${percent == null ? '' : ', $percent%'}'
      '${finishingPercent == null ? '' : ', finishing $finishingPercent%'}'
      '${nodeHeight == null ? '' : ', node $nodeHeight'}'
      '${networkHeight == null ? '' : ', network $networkHeight'}'
      '${onPrivateNode ? ', on private node' : ''}'
      '${privateReceiveAvailable ? ', private receive' : ''}'
      '${waitingForWallet ? ', waiting for the wallet' : ''}'
      '${disk == null ? '' : ', $disk'})';
}

/// Public node now, private node soon (ARCHITECTURE.md §4).
///
/// 1. The wallet is already open on a public node ([session]).
/// 2. [start] checks there is room on disk for the node (it refuses below
///    [diskPolicy], never filling the disk), takes the owner key the wallet
///    stored at create/restore ([storedOwnerKey], no pause at all, R11) — or,
///    for a wallet without one, pauses it briefly (close, `export_owner_key`,
///    reopen on the same public node) — and starts a private `beam-node`
///    with the key. The key lives in a local variable until the node has
///    read its config.
/// 3. The wallet moves to the node only when the node logged
///    `Tx replication is ON` after its last fast-sync line, is not in a
///    long step ("Raising Fossil"), **and** its newest `My Tip:` is within
///    [readyWithinBlocks] of a fresh explorer height — continuously for
///    [readyHoldFor] (owner, 2026-10-07: a new wallet sat "syncing", unable
///    to send, on a node that was not ready yet). No explorer, no handover.
/// 4. After the move, `ev_connection_changed.own_node == true` must arrive
///    within [ownNodeTimeout], or the wallet goes back to a public node.
///    [BeamPrivateNodeStatus.privateReceiveAvailable] is true only while it
///    holds.
/// 5. A node that dies, or falls more than [failoverBehindBlocks] behind on
///    two checks in a row, sends the wallet back to a public node.
/// 6. If the wallet cannot send within [walletReadyTimeout] of the move
///    ([walletCanSend]), it goes back to a public node too, and the next
///    switch waits [retryAfterNotServing]: the wallet never sits on a node
///    that does not serve it.
///
/// A node that does not take the owner key is stopped; the coordinator
/// never runs a keyless node.
///
/// No switch interrupts a money flow: with [whenIdle], every step that
/// replaces the wallet's session (the key pause, the handover, the move
/// back to a public node) first waits until no send, swap, claim or dApp
/// approval is open, and says so in [BeamPrivateNodeStatus.waitingForWallet].
///
/// The wallet layer must follow [sessions]: every pause and switch replaces
/// the session (and its transport). `null` means the wallet is closed right
/// now.
///
/// While it lives, a coordinator can be found by its wallet directory
/// ([forWalletDir]), so the node panel can drive it.
class BeamPrivateNodeCoordinator {
  BeamPrivateNodeCoordinator({
    required this.host,
    required BeamSession session,
    required this.walletDir,
    required this._password,
    required this._explorer,
    required this._nodeFactory,
    BeamPrivateNodeSetting? setting,
    List<BeamNodeEndpoint> publicNodes = kBeamPublicWalletNodes,
    BeamHostLog? log,
    this._storedOwnerKey,
    this._whenIdle,
    bool Function()? requestBodies,
    this._diskProbe,
    this.diskPolicy = const BeamNodeDiskPolicy(),
    this.diskCheckInterval = const Duration(seconds: 30),
    this.readyWithinBlocks = 5,
    this.failoverBehindBlocks = 10,
    this.ownNodeTimeout = const Duration(seconds: 90),
    this.checkInterval = const Duration(seconds: 20),
    this.maxExplorerTipAge = const Duration(minutes: 10),
    this.stallAfter = const Duration(minutes: 15),
    this.readyHoldFor = const Duration(seconds: 60),
    this.walletReadyTimeout = const Duration(minutes: 2),
    this.retryAfterNotServing = const Duration(minutes: 10),
    this._walletCanSend,
    DateTime Function()? now,
  }) : setting = setting ?? BeamFixedPrivateNodeSetting.platformDefault(),
       _session = session,
       _publicNodes = List.unmodifiable(publicNodes),
       assert(publicNodes.isNotEmpty, 'at least one public node'),
       _lastPublic = session.node.isOwned ? publicNodes.first : session.node,
       // Without a provider, keep what the first session was opened with
       // (only a raw ProcessSession can tell).
       _requestBodies =
           requestBodies ??
           _constantly(session is ProcessSession && session.requestBodies),
       _log = log ?? _noLog,
       _now = now ?? DateTime.now {
    _running[walletDir] = this;
    _notifyRegistry();
  }

  static final Map<String, BeamPrivateNodeCoordinator> _running = {};
  static final StreamController<void> _registryChanges =
      StreamController<void>.broadcast();

  /// The live coordinator of the wallet in [walletDir], if any.
  static BeamPrivateNodeCoordinator? forWalletDir(String walletDir) =>
      _running[walletDir];

  /// Fires whenever a coordinator starts or is disposed. Broadcast.
  static Stream<void> get registryChanges => _registryChanges.stream;

  static void _notifyRegistry() {
    if (!_registryChanges.isClosed) _registryChanges.add(null);
  }

  static bool Function() _constantly(bool value) => () => value;

  final BeamHost host;
  final String walletDir;

  /// Room the node needs on disk.
  final BeamNodeDiskPolicy diskPolicy;

  /// How often a running node's disk is measured again.
  final Duration diskCheckInterval;

  /// "Use a private node". Defaults to on for desktop, off elsewhere.
  final BeamPrivateNodeSetting setting;

  /// Handover needs the node's tip within this many blocks of the explorer.
  final int readyWithinBlocks;

  /// While in use, the node may fall this far behind before failover.
  final int failoverBehindBlocks;

  /// How long to wait for `own_node == true` after moving the wallet.
  final Duration ownNodeTimeout;

  /// How often readiness and health are checked against the explorer.
  final Duration checkInterval;

  /// An explorer tip older than this is not a "fresh" height.
  final Duration maxExplorerTipAge;

  /// A node behind the network whose tip has not moved for this long is
  /// reported as stuck rather than catching up.
  final Duration stallAfter;

  /// How long the node must stay ready before the wallet moves to it.
  final Duration readyHoldFor;

  /// How long after the move the wallet may take to be able to send.
  final Duration walletReadyTimeout;

  /// After a node did not serve the wallet, how long until the next switch.
  final Duration retryAfterNotServing;

  /// Whether the wallet can send now (its honest sync verdict). Null: not
  /// checked.
  final bool Function()? _walletCanSend;

  final BeamPasswordProvider _password;
  final BeamNetworkTipSource _explorer;
  final BeamPrivateNodeFactory _nodeFactory;
  final List<BeamNodeEndpoint> _publicNodes;
  final BeamOwnerKeyProvider? _storedOwnerKey;
  final BeamIdleWaiter? _whenIdle;
  final bool Function() _requestBodies;
  final BeamNodeDiskProbe? _diskProbe;
  final BeamHostLog _log;
  final DateTime Function() _now;

  BeamSession? _session;
  BeamNodeEndpoint _lastPublic;
  BeamPrivateNode? _node;
  BeamNodeDiskProbe? _nodeDiskProbe;
  DateTime? _lastDiskCheck;

  /// The user's choice from the node panel, for this run ([setEnabled]).
  bool? _enabledOverride;
  DateTime? _nodeStartedAt;
  StreamSubscription<BeamNodeProgress>? _nodeSub;
  StreamSubscription<BeamEvent>? _ownNodeSub;
  Timer? _timer;
  Timer? _ownNodeGrace;
  Timer? _walletReadyTimer;
  DateTime? _readySince;
  DateTime? _noSwitchBefore;
  bool _checkQueued = false;
  int _behindStrikes = 0;
  bool _disposed = false;
  Duration? _lastPause;

  BeamPrivateNodeStatus _status = const BeamPrivateNodeStatus(
    phase: BeamPrivateNodePhase.idle,
  );
  final _statusController = StreamController<BeamPrivateNodeStatus>.broadcast();
  final _sessionController = StreamController<BeamSession?>.broadcast();
  Future<void> _queue = Future.value();

  /// The wallet's current session, or null while it is closed.
  BeamSession? get session => _session;

  /// Every session change. Broadcast.
  Stream<BeamSession?> get sessions => _sessionController.stream;

  BeamPrivateNodeStatus get status => _status;

  /// Status changes. Broadcast.
  Stream<BeamPrivateNodeStatus> get statuses => _statusController.stream;

  /// Gate for offline / max-privacy receive (task B-ADDR-1).
  bool get privateReceiveAvailable => _status.privateReceiveAvailable;

  bool get _onPrivate => _session?.node.isOwned ?? false;

  /// Reads [setting]; when on, starts the private node in the background.
  /// Completes once the node is running (or setting it up failed); the
  /// handover happens later on its own.
  Future<void> start() => _serial(() async {
    if (_disposed || _node != null || _status.phase == _Phase.preparing) {
      return;
    }
    if (!await _settingOn()) {
      _set(_Phase.off);
      return;
    }
    await _bringUp();
  });

  /// Starts over after [BeamPrivateNodePhase.failed], `stopped`,
  /// `ownNodeUnconfirmed` or `walletClosed`.
  Future<void> retry() => _serial(() async {
    if (_disposed) return;
    if (!await _settingOn()) {
      _set(_Phase.off);
      return;
    }
    if (_session == null && !await _reopenPublic()) {
      _set(_Phase.walletClosed);
      return;
    }
    if (_node != null) {
      // Running: just check again (e.g. "Check again" after cannotVerify).
      await _check();
      return;
    }
    await _bringUp();
  });

  /// Re-checks readiness or health now, instead of at the next tick.
  Future<void> checkNow() => _serial(_check);

  /// Re-reads [setting]: off moves the wallet to a public node and stops the
  /// node; on starts it if it is not running.
  Future<void> applySetting() => _serial(() async {
    if (_disposed) return;
    if (await _settingOn()) {
      if (_node == null && _status.phase == _Phase.off) await _bringUp();
      return;
    }
    if (_onPrivate) await _moveToPublic();
    await _stopNode();
    _set(_Phase.off);
  });

  /// The node panel's "Use my own private node" switch. The choice wins over
  /// [setting] for as long as this coordinator lives (the panel stores it
  /// for the next run), then it is applied like [applySetting].
  Future<void> setEnabled(bool enabled) {
    _enabledOverride = enabled;
    return applySetting();
  }

  /// Stops the node and starts it again (the wallet goes to a public node
  /// first if it was on the private one). The node keeps its database, so
  /// it only catches up the blocks since it stopped.
  Future<void> restart() => _serial(() async {
    if (_disposed) return;
    if (!await _settingOn()) {
      _set(_Phase.off);
      return;
    }
    if (!await _leavePrivateNode()) return;
    await _stopNode();
    if (_session == null && !await _reopenPublic()) {
      _set(_Phase.walletClosed);
      return;
    }
    await _bringUp();
  });

  /// Stops the node for now; the wallet moves to a public node first. It
  /// starts again with [retry] (the panel's "Start private node") or the
  /// next time the wallet opens.
  Future<void> stop() => _serial(() async {
    if (_disposed) return;
    if (!await _leavePrivateNode()) return;
    await _stopNode();
    _set(_Phase.stopped, issue: BeamPrivateNodeIssue.stoppedByUser);
  });

  /// Moves the wallet off the private node, if it is on it. False when no
  /// node at all would take the wallet (the status says so).
  Future<bool> _leavePrivateNode() async {
    _ownNodeGrace?.cancel();
    _ownNodeGrace = null;
    _walletReadyTimer?.cancel();
    _walletReadyTimer = null;
    await _ownNodeSub?.cancel();
    _ownNodeSub = null;
    if (!_onPrivate) return true;
    _set(_status.phase, privateReceive: false);
    if (await _moveToPublic()) return true;
    await _stopNode();
    _set(_Phase.walletClosed);
    return false;
  }

  /// Stops the node and all timers. The session stays open and belongs to
  /// the caller; if the wallet is on the private node it loses its node.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_running[walletDir], this)) {
      _running.remove(walletDir);
      _notifyRegistry();
    }
    _timer?.cancel();
    _ownNodeGrace?.cancel();
    _walletReadyTimer?.cancel();
    await _ownNodeSub?.cancel();
    // An operation in flight (e.g. waiting for own_node) sees _disposed at
    // its next step; do not hold app shutdown for it.
    await _queue.timeout(const Duration(seconds: 5), onTimeout: () {});
    // The node gets its full grace (kBeamNodeStopGrace) to stop, but
    // closing the wallet does not wait for all of it: a node busy with its
    // setup step finishes stopping in the background (and is SIGKILLed only
    // after the grace).
    await _stopNode().timeout(const Duration(seconds: 5), onTimeout: () {});
    await _statusController.close();
    await _sessionController.close();
  }

  // ---------------------------------------------------------------------------
  // Bring-up

  Future<void> _bringUp() async {
    _set(_Phase.preparing, issue: null);
    // Not started yet, so nothing to clean up if this goes no further.
    final node = _nodeFactory();

    // 1. Room on disk, before anything else happens.
    _nodeDiskProbe =
        _diskProbe ??
        (node is BeamNodeProcess ? BeamNodeDisk.probe(node.nodeDir) : null);
    final disk = await _measureDisk();
    _lastDiskCheck = _now();
    if (disk != null && !disk.allowsStart) {
      final free = formatBeamDiskSize(disk.space.freeBytes);
      final needed = formatBeamDiskSize(disk.neededFreeBytes);
      _log('Not starting the private node: $free free, $needed needed');
      _set(
        _Phase.failed,
        issue: BeamPrivateNodeIssue.notEnoughDisk,
        disk: disk,
      );
      return;
    }
    if (disk != null) _set(_Phase.preparing, disk: disk);
    final password = await _password();

    // 2. The owner key. Stored at create/restore: no pause at all. Otherwise
    // the wallet pauses for as short as possible to read it.
    var ownerKey = await _readStoredOwnerKey();
    if (ownerKey != null) {
      _lastPause = Duration.zero;
      _log('Owner key read from secure storage; the wallet was not paused');
    } else {
      await _waitUntilIdle();
      if (_disposed) return;
      final pause = Stopwatch()..start();
      final current = _session;
      _replaceSession(null);
      await _closeQuietly(current);
      Object? exportError;
      try {
        ownerKey = await host.exportOwnerKey(
          walletDir: walletDir,
          password: password,
        );
      } catch (e) {
        exportError = e;
      }
      final reopened = await _reopenPublic(password: password);
      pause.stop();
      _lastPause = pause.elapsed;
      _log(
        'Wallet paused ${pause.elapsedMilliseconds} ms to read the owner '
        'key${reopened ? '' : ' and could not be reopened'}',
      );
      if (!reopened) {
        _set(_Phase.walletClosed);
        return;
      }
      if (ownerKey == null || ownerKey.isEmpty) {
        _log('Owner key export failed: ${_describe(exportError)}');
        _set(_Phase.failed, issue: BeamPrivateNodeIssue.keyExportFailed);
        return;
      }
    }

    // 3. Start the node. The key is in this frame only; once start()
    // returns the node has read it and its file is gone.
    try {
      await node.start(ownerKey: ownerKey, password: password);
    } on BeamNodeException catch (e) {
      _log('Private node did not start: $e');
      await _quietStop(node);
      _set(_Phase.failed, issue: _issueFor(e.kind));
      return;
    } on BeamHostException catch (e) {
      _log('Private node did not start: $e');
      await _quietStop(node);
      _set(
        _Phase.failed,
        issue: switch (e.kind) {
          BeamHostError.binaryMissing ||
          BeamHostError.binaryUntrusted ||
          BeamHostError.unsupportedPlatform ||
          BeamHostError.consensusMismatch => BeamPrivateNodeIssue.binaryProblem,
          _ => BeamPrivateNodeIssue.nodeStartFailed,
        },
      );
      return;
    } catch (e) {
      _log('Private node did not start: ${_describe(e)}');
      await _quietStop(node);
      _set(_Phase.failed, issue: BeamPrivateNodeIssue.nodeStartFailed);
      return;
    }
    ownerKey = null;
    if (_disposed) {
      await _quietStop(node);
      return;
    }

    _node = node;
    _nodeStartedAt = _now();
    _behindStrikes = 0;
    _nodeSub = node.progressStream.listen(_onNodeProgress);
    _timer?.cancel();
    _timer = Timer.periodic(checkInterval, (_) => _scheduleCheck());
    _set(_phaseFromNode(node.progress), issue: null);
    _scheduleCheck();
  }

  /// The stored owner key, or null (no provider, none stored, or it could
  /// not be read — then the paused export takes over).
  Future<String?> _readStoredOwnerKey() async {
    final provider = _storedOwnerKey;
    if (provider == null) return null;
    try {
      final key = await provider();
      return key == null || key.isEmpty ? null : key;
    } catch (e) {
      _log('Stored owner key could not be read: ${_describe(e)}');
      return null;
    }
  }

  /// The node's disk judged against [diskPolicy], or null when it cannot be
  /// measured (then nothing is refused on its account).
  Future<BeamNodeDiskCheck?> _measureDisk() async {
    final probe = _nodeDiskProbe;
    if (probe == null) return null;
    try {
      final space = await probe();
      return space == null ? null : diskPolicy.check(space);
    } catch (e) {
      _log('Could not measure free disk space: ${_describe(e)}');
      return null;
    }
  }

  /// While the node runs: stops it before the disk fills up. True when it
  /// was stopped.
  Future<bool> _stopIfDiskFull() async {
    final last = _lastDiskCheck;
    final now = _now();
    if (last != null && now.difference(last) < diskCheckInterval) return false;
    _lastDiskCheck = now;
    final disk = await _measureDisk();
    if (disk == null || _disposed || _node == null) return false;
    if (!diskPolicy.mustStop(disk.space)) {
      _set(_status.phase, disk: disk);
      return false;
    }
    _log(
      'Only ${formatBeamDiskSize(disk.space.freeBytes)} free; stopping the '
      'private node before the disk fills up',
    );
    await _failover(
      _Phase.failed,
      BeamPrivateNodeIssue.diskFull,
      stopNode: true,
      disk: disk,
    );
    return true;
  }

  /// Waits until no money flow is open ([whenIdle]). Returns true when it
  /// actually had to wait; the status says so meanwhile.
  Future<bool> _waitUntilIdle() async {
    final waiter = _whenIdle;
    if (waiter == null) return false;
    var idle = false;
    final done = Future<void>.sync(waiter)
        .catchError((Object e) {
          _log('Waiting for the wallet failed: ${_describe(e)}');
        })
        .whenComplete(() => idle = true);
    // A waiter that is idle already completes in a microtask, before this.
    await Future<void>.delayed(Duration.zero);
    if (idle) return false;
    _log('A payment is open; the node switch waits until it is finished');
    _set(_status.phase, waiting: true);
    await done;
    _set(_status.phase, waiting: false);
    return true;
  }

  static BeamPrivateNodeIssue _issueFor(BeamNodeError kind) => switch (kind) {
    BeamNodeError.ownerKeyRejected => BeamPrivateNodeIssue.keyRejected,
    BeamNodeError.nodeInUse => BeamPrivateNodeIssue.nodeInUse,
    _ => BeamPrivateNodeIssue.nodeStartFailed,
  };

  // ---------------------------------------------------------------------------
  // Node progress and checks

  void _onNodeProgress(BeamNodeProgress p) {
    if (_disposed) return;
    if (p.isEnded) {
      unawaited(_serial(() => _onNodeEnded(p)));
      return;
    }
    // Numbers update at once; phase decisions wait for the next check.
    switch (_status.phase) {
      case _Phase.downloading:
      case _Phase.catchingUp:
        _set(_phaseFromNode(p));
      case _Phase.active ||
          _Phase.fellBehind ||
          _Phase.cannotVerify ||
          _Phase.stuck:
        _set(_status.phase);
      default:
        break;
    }
    // A node catching up prints a line per block; check at most every few
    // seconds on its account (the timer covers the rest).
    if (p.txReplicationOn && !_onPrivate) {
      final now = _now();
      final last = _lastProgressCheck;
      if (last == null || now.difference(last) >= _progressCheckGap) {
        _lastProgressCheck = now;
        _scheduleCheck();
      }
    }
  }

  static const Duration _progressCheckGap = Duration(seconds: 2);
  DateTime? _lastProgressCheck;

  _Phase _phaseFromNode(BeamNodeProgress p) =>
      p.phase == BeamNodePhase.fastSyncDownloading ||
          p.phase == BeamNodePhase.starting
      ? _Phase.downloading
      : _Phase.catchingUp;

  void _scheduleCheck() {
    if (_disposed || _checkQueued) return;
    _checkQueued = true;
    unawaited(
      _serial(() async {
        _checkQueued = false;
        await _check();
      }),
    );
  }

  Future<void> _check() async {
    final node = _node;
    if (_disposed || node == null) return;
    final p = node.progress;
    if (p.isEnded) return _onNodeEnded(p);
    if (await _stopIfDiskFull()) return;
    switch (_status.phase) {
      case _Phase.active:
        return _checkActive(p);
      case _Phase.downloading ||
          _Phase.catchingUp ||
          _Phase.cannotVerify ||
          _Phase.stuck ||
          _Phase.fellBehind:
        return _checkReady(p);
      default:
        return;
    }
  }

  Future<void> _checkReady(BeamNodeProgress p) async {
    final waiting = _status.phase == _Phase.fellBehind
        ? _Phase.fellBehind
        : null;
    if (!p.txReplicationOn) {
      _set(waiting ?? _phaseFromNode(p), issue: null);
      return;
    }
    // Routine checks use the explorer client's short cache; the decision
    // to hand over is made on a height fetched just now.
    var network = await _freshExplorer(force: false);
    final tip = p.bestHeight;
    if (network != null && tip != null && p.finishingPercent == null) {
      if ((network - tip).abs() <= readyWithinBlocks) {
        network = await _freshExplorer(force: true);
        if (network != null && (network - tip).abs() <= readyWithinBlocks) {
          final since = _readySince ??= _now();
          final held = _now().difference(since) >= readyHoldFor;
          final allowed =
              _noSwitchBefore == null || !_now().isBefore(_noSwitchBefore!);
          if (held && allowed) {
            await _handover(tip, network);
            return;
          }
          _set(waiting ?? _Phase.catchingUp, issue: null, network: network);
          return;
        }
      }
    }
    _readySince = null;
    if (network == null) {
      _set(
        _Phase.cannotVerify,
        issue: BeamPrivateNodeIssue.explorerUnavailable,
      );
      return;
    }
    if (tip == null) {
      _set(waiting ?? _Phase.catchingUp, issue: null, network: network);
      return;
    }
    final behind = network - tip;
    if (behind < 0) {
      _set(
        _Phase.cannotVerify,
        issue: BeamPrivateNodeIssue.explorerBehind,
        network: network,
      );
      return;
    }
    if (_belowHardFork(tip, network)) {
      _set(
        _Phase.stuck,
        issue: BeamPrivateNodeIssue.belowHardFork,
        network: network,
      );
      return;
    }
    final lastMove = p.myTipAt ?? _nodeStartedAt;
    if (lastMove != null && _now().difference(lastMove) > stallAfter) {
      _set(
        _Phase.stuck,
        issue: BeamPrivateNodeIssue.notAdvancing,
        network: network,
      );
      return;
    }
    _set(waiting ?? _Phase.catchingUp, issue: null, network: network);
  }

  Future<void> _checkActive(BeamNodeProgress p) async {
    final network = await _freshExplorer(force: false);
    final tip = p.bestHeight;
    // No independent height is no evidence of a problem: stay.
    if (network == null || tip == null) return;
    final behind = network - tip;
    _set(_Phase.active, network: network);
    if (behind <= failoverBehindBlocks) {
      _behindStrikes = 0;
      return;
    }
    if (++_behindStrikes < 2) return;
    _behindStrikes = 0;
    _log(
      'Private node is $behind blocks behind the network; moving the wallet '
      'to a public node',
    );
    await _failover(
      _Phase.fellBehind,
      _belowHardFork(tip, network)
          ? BeamPrivateNodeIssue.belowHardFork
          : BeamPrivateNodeIssue.notAdvancing,
      network: network,
    );
  }

  /// A node that claims to be synced just below the HF6 height while the
  /// chain is past it follows the old rules (the 3928665 freeze). Only the
  /// day below the fork counts: a node far below it is simply behind.
  static bool _belowHardFork(int tip, int network) =>
      tip < beamMainnetHf6Height &&
      tip >= beamMainnetHf6Height - 1440 &&
      network >= beamMainnetHf6Height;

  /// The freshest independent height, or null when there is none.
  Future<int?> _freshExplorer({required bool force}) async {
    try {
      final s = await _explorer.status(forceRefresh: force);
      if (s.tipAgeAt(_now()) > maxExplorerTipAge) return null;
      return s.height;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Handover

  Future<void> _handover(int tip, int network) async {
    final node = _node;
    final port = node?.port;
    final current = _session;
    if (node == null || port == null || current == null) return;
    _set(_Phase.switching, issue: null, network: network);
    // Never under an open send, swap, claim or approval (R11). After a wait
    // the node and the network have moved on, so decide again.
    if (await _waitUntilIdle()) {
      if (_disposed || !identical(_node, node)) return;
      final p = node.progress;
      if (p.isEnded) return _onNodeEnded(p);
      return _checkReady(p);
    }
    if (_disposed || !identical(_session, current)) return;
    _log(
      'Private node at $tip, network at $network: moving the wallet to '
      '127.0.0.1:$port',
    );
    final pause = Stopwatch()..start();
    final own = BeamNodeEndpoint('127.0.0.1', port, isOwned: true);
    _replaceSession(null);
    BeamSession? next;
    try {
      next = await current.switchNode(own);
    } catch (e) {
      _log('Switching to the private node failed: ${_describe(e)}');
      await _closeQuietly(current);
    }
    if (next == null) {
      _lastPause = pause.elapsed;
      await _stopNode();
      _set(
        await _reopenPublic() ? _Phase.ownNodeUnconfirmed : _Phase.walletClosed,
        issue: BeamPrivateNodeIssue.switchFailed,
      );
      return;
    }
    _replaceSession(next);
    final confirmed = await _awaitOwnNode(next.transport);
    pause.stop();
    _lastPause = pause.elapsed;
    if (confirmed) {
      _log(
        'own_node == true ${pause.elapsedMilliseconds} ms after leaving the '
        'public node',
      );
      _watchOwnNode(next.transport);
      _set(_Phase.active, issue: null, network: network, privateReceive: true);
      _watchWalletServed();
      return;
    }
    _log(
      'own_node was not confirmed within ${ownNodeTimeout.inSeconds} s; '
      'moving the wallet back to a public node',
    );
    await _stopNode();
    await _failover(
      _Phase.ownNodeUnconfirmed,
      null,
      network: network,
      nodeAlreadyStopped: true,
    );
  }

  /// After a move to the node: if the wallet still cannot send after
  /// [walletReadyTimeout], back to a public node, and no new switch for
  /// [retryAfterNotServing].
  void _watchWalletServed() {
    final canSend = _walletCanSend;
    if (canSend == null) return;
    _walletReadyTimer?.cancel();
    _walletReadyTimer = Timer(walletReadyTimeout, () {
      _walletReadyTimer = null;
      if (_disposed || !_onPrivate || canSend()) return;
      unawaited(
        _serial(() async {
          if (_disposed || !_onPrivate || canSend()) return;
          _log(
            'The wallet could not send ${walletReadyTimeout.inSeconds} s '
            'after moving to the private node; back to a public node, next '
            'try in ${retryAfterNotServing.inMinutes} min',
          );
          _noSwitchBefore = _now().add(retryAfterNotServing);
          await _failover(
            _Phase.fellBehind,
            BeamPrivateNodeIssue.notServingWallet,
          );
        }),
      );
    });
  }

  /// Subscribes to `ev_connection_changed` on [transport] (only that event,
  /// so the wallet layer's other subscriptions are untouched) and waits for
  /// `own_node == true`.
  Future<bool> _awaitOwnNode(BeamTransport transport) async {
    final confirmed = Completer<bool>();
    final sub = transport.events.listen((e) {
      if (e.name == 'ev_connection_changed' &&
          e.data['own_node'] == true &&
          !confirmed.isCompleted) {
        confirmed.complete(true);
      }
    }, onError: (Object _) {});
    try {
      // The core answers with a snapshot of the current state straight
      // away (v6_1_api_handle.cpp:129), then sends changes.
      await transport.call('ev_subunsub', {
        'ev_connection_changed': true,
      }, const Duration(seconds: 15));
      return await confirmed.future.timeout(
        ownNodeTimeout,
        onTimeout: () => false,
      );
    } catch (e) {
      _log('Could not watch the node connection: ${_describe(e)}');
      return false;
    } finally {
      await sub.cancel();
    }
  }

  /// While active: private receive follows `own_node`; if it stays false
  /// for [ownNodeTimeout], the wallet goes back to a public node.
  void _watchOwnNode(BeamTransport transport) {
    unawaited(_ownNodeSub?.cancel());
    _ownNodeSub = transport.events.listen((e) {
      if (_disposed || e.name != 'ev_connection_changed') return;
      if (_status.phase != _Phase.active) return;
      if (e.data['own_node'] == true) {
        _ownNodeGrace?.cancel();
        _ownNodeGrace = null;
        _set(_Phase.active, privateReceive: true);
        return;
      }
      _set(_Phase.active, privateReceive: false);
      _ownNodeGrace ??= Timer(ownNodeTimeout, () {
        _ownNodeGrace = null;
        unawaited(
          _serial(() async {
            if (_status.phase != _Phase.active ||
                _status.privateReceiveAvailable) {
              return;
            }
            _log('own_node stayed false; moving to a public node');
            await _failover(
              _Phase.ownNodeUnconfirmed,
              BeamPrivateNodeIssue.ownNodeLost,
              stopNode: true,
            );
          }),
        );
      });
    }, onError: (Object _) {});
  }

  // ---------------------------------------------------------------------------
  // Failover

  Future<void> _onNodeEnded(BeamNodeProgress p) async {
    if (_node == null) return;
    final rejected = p.error == BeamNodeError.ownerKeyRejected;
    _log(
      'Private node ended (${p.error?.name ?? p.phase.name}'
      '${p.exitCode == null ? '' : ', exit ${p.exitCode}'})',
    );
    await _failover(
      rejected ? _Phase.failed : _Phase.stopped,
      rejected
          ? BeamPrivateNodeIssue.keyRejected
          : BeamPrivateNodeIssue.nodeExited,
      stopNode: true,
    );
  }

  /// Moves the wallet to a public node if it is on the private one, and
  /// settles in [phase]. With [stopNode] the node is stopped too.
  Future<void> _failover(
    _Phase phase,
    BeamPrivateNodeIssue? issue, {
    int? network,
    bool stopNode = false,
    bool nodeAlreadyStopped = false,
    BeamNodeDiskCheck? disk,
  }) async {
    _ownNodeGrace?.cancel();
    _ownNodeGrace = null;
    _walletReadyTimer?.cancel();
    _walletReadyTimer = null;
    _readySince = null;
    await _ownNodeSub?.cancel();
    _ownNodeSub = null;
    // Private receive is off from this moment, before anything slow.
    _set(_status.phase, privateReceive: false);
    if (stopNode && !nodeAlreadyStopped) await _stopNode();
    if (_onPrivate || _session == null) {
      if (!await _moveToPublic()) {
        _set(_Phase.walletClosed, issue: issue, disk: disk);
        return;
      }
    }
    _set(phase, issue: issue, network: network, disk: disk);
  }

  /// Points the wallet at a public node: the one it last used, then the
  /// list in order. Waits for an open money flow first ([whenIdle]).
  Future<bool> _moveToPublic() async {
    if (_session != null) await _waitUntilIdle();
    final current = _session;
    if (current == null) return _reopenPublic();
    final pause = Stopwatch()..start();
    final first = _publicCandidates().first;
    _replaceSession(null);
    try {
      final next = await current.switchNode(first);
      _lastPublic = first;
      _replaceSession(next);
      _lastPause = pause.elapsed;
      return true;
    } catch (e) {
      _log('Public node $first did not open: ${_describe(e)}');
      await _closeQuietly(current);
    }
    final ok = await _reopenPublic(skip: first);
    _lastPause = pause.elapsed;
    return ok;
  }

  List<BeamNodeEndpoint> _publicCandidates() => [
    _lastPublic,
    for (final n in _publicNodes)
      if (n != _lastPublic) n,
  ];

  /// Opens the wallet on the first public node that works.
  Future<bool> _reopenPublic({String? password, BeamNodeEndpoint? skip}) async {
    final pass = password ?? await _password();
    for (final node in _publicCandidates()) {
      if (node == skip) continue;
      try {
        final s = await host.openWallet(
          walletDir: walletDir,
          password: pass,
          node: node,
          requestBodies: _requestBodies(),
        );
        _lastPublic = node;
        _replaceSession(s);
        return true;
      } catch (e) {
        _log('Public node $node did not open: ${_describe(e)}');
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Helpers

  Future<void> _stopNode() async {
    final node = _node;
    _node = null;
    _timer?.cancel();
    _timer = null;
    await _nodeSub?.cancel();
    _nodeSub = null;
    if (node != null) await _quietStop(node);
  }

  static Future<void> _quietStop(BeamPrivateNode node) async {
    try {
      await node.stop();
    } catch (_) {
      // Stopping is best effort; the process registry stops it on exit.
    }
  }

  static Future<void> _closeQuietly(BeamSession? s) async {
    if (s == null) return;
    try {
      await s.close();
    } catch (_) {
      // A session that cannot close cleanly is still gone for us.
    }
  }

  Future<bool> _settingOn() async {
    final chosen = _enabledOverride;
    if (chosen != null) return chosen;
    try {
      return await setting.read();
    } catch (e) {
      _log('Could not read the private node setting: ${_describe(e)}');
      return false;
    }
  }

  void _replaceSession(BeamSession? s) {
    _session = s;
    if (!_sessionController.isClosed) _sessionController.add(s);
  }

  /// Sets the status. Numbers come from the node unless given.
  void _set(
    _Phase phase, {
    Object? issue = _keep,
    int? network,
    bool? privateReceive,
    BeamNodeDiskCheck? disk,
    bool? waiting,
  }) {
    final p = _node?.progress;
    final next = BeamPrivateNodeStatus(
      disk: disk ?? _status.disk,
      // "Waiting for the wallet" holds while the phase does, unless said.
      waitingForWallet:
          waiting ?? (phase == _status.phase && _status.waitingForWallet),
      phase: phase,
      issue: identical(issue, _keep)
          ? _status.issue
          : issue as BeamPrivateNodeIssue?,
      percent: phase == _Phase.downloading ? p?.percent : null,
      finishingPercent:
          phase == _Phase.catchingUp || phase == _Phase.downloading
          ? p?.finishingPercent
          : null,
      nodeHeight: p?.bestHeight ?? _status.nodeHeight,
      networkHeight: network ?? _status.networkHeight,
      onPrivateNode: _onPrivate,
      privateReceiveAvailable:
          (privateReceive ?? _status.privateReceiveAvailable) &&
          phase == _Phase.active &&
          _onPrivate,
      lastPause: _lastPause,
    );
    if (next == _status) return;
    final phaseChanged = next.phase != _status.phase;
    _status = next;
    if (phaseChanged) _log('Private node: $next');
    if (!_statusController.isClosed) _statusController.add(next);
  }

  /// Runs [op] after every earlier operation, so node events, checks and
  /// user actions never interleave. Never throws: an unexpected error is
  /// logged and the status keeps its last value.
  Future<void> _serial(Future<void> Function() op) {
    return _queue = _queue
        .then((_) => _disposed ? null : op())
        .catchError((Object e, StackTrace s) {
          _log('Private node coordinator error: ${_describe(e)}\n$s');
        });
  }

  /// Error text for logs. Host and node exceptions never carry a secret;
  /// anything else is cut short.
  static String _describe(Object? e) {
    final text = switch (e) {
      null => 'unknown error',
      BeamHostException(:final kind, :final message) =>
        '${kind.name}: $message',
      BeamNodeException(:final kind, :final message) =>
        '${kind.name}: $message',
      BeamRpcException(:final code, :final message) => 'rpc $code: $message',
      _ => e.toString(),
    };
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }
}

typedef _Phase = BeamPrivateNodePhase;

const Object _keep = Object();

void _noLog(String _) {}
