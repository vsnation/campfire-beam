/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../explorer/beam_explorer_client.dart';
import 'beam_sync_state.dart';

/// Creates a periodic timer; replaceable in tests.
typedef BeamPeriodicTimerFactory = Timer Function(
  Duration period,
  void Function(Timer timer) onTick,
);

/// Turns wallet status updates plus periodic explorer checks into a stream
/// of [BeamSyncAssessment]s.
///
/// * Every wallet update is assessed at once.
/// * Every [pollInterval] the explorer is asked for the tip (it caches, so
///   this is cheap) and the state is assessed again, so a tip that silently
///   ages past ten minutes turns into "stalled" even when the core sends
///   nothing.
/// * While the app is in the background ([setForeground] `false`) the timer
///   is stopped and nothing goes to the network. Coming back refreshes at
///   once.
/// * The monitor tracks how the wallet height moves, so the rules can tell
///   "catching up" from "stalled" and estimate time left.
/// * [assessments] emits only when the verdict changes.
class BeamSyncMonitor {
  BeamSyncMonitor({
    required BeamNetworkTipSource explorer,
    required this._walletStatus,
    this._node = BeamNodeKind.publicNode,
    this.rules = const BeamSyncRules(),
    this.pollInterval = const Duration(seconds: 30),
    this.explorerReuse = const Duration(minutes: 3),
    this.speedWindow = const Duration(minutes: 2),
    DateTime Function()? now,
    BeamPeriodicTimerFactory? timerFactory,
  }) : _explorerSource = explorer,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.periodic {
    _current = assessBeamSync(
      wallet: null,
      explorer: null,
      now: _now(),
      node: _node,
      rules: rules,
    );
  }

  final BeamNetworkTipSource _explorerSource;
  final Stream<BeamWalletSyncInput> _walletStatus;
  final DateTime Function() _now;
  final BeamPeriodicTimerFactory _timerFactory;

  final BeamSyncRules rules;

  /// How often the explorer is checked and the state re-assessed.
  final Duration pollInterval;

  /// How long a good explorer answer is still used after later checks
  /// fail. After that the explorer counts as unavailable.
  final Duration explorerReuse;

  /// Window over which processing speed is measured for the ETA.
  final Duration speedWindow;

  final _controller = StreamController<BeamSyncAssessment>.broadcast();
  StreamSubscription<BeamWalletSyncInput>? _walletSub;
  Timer? _timer;
  Future<void>? _pollInFlight;

  BeamNodeKind _node;
  BeamWalletSyncInput? _wallet;
  BeamExplorerStatus? _explorer;
  bool _lastExplorerFailed = false;

  DateTime? _observingSince;
  DateTime? _heightLastAdvancedAt;
  int? _lastHeight;
  final _samples = <({DateTime at, int height})>[];

  late BeamSyncAssessment _current;
  bool _started = false;
  bool _foreground = true;
  bool _disposed = false;

  /// Verdicts as they change. Broadcast; read [current] for the latest.
  Stream<BeamSyncAssessment> get assessments => _controller.stream;

  /// The latest verdict.
  BeamSyncAssessment get current => _current;

  /// Whether the explorer timer is running.
  bool get isPolling => _timer?.isActive ?? false;

  /// The latest explorer answer, if any.
  BeamExplorerStatus? get lastExplorerStatus => _explorer;

  /// Starts listening to wallet updates and polling. Calling it again does
  /// nothing.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _walletSub = _walletStatus.listen(
      _onWallet,
      // A broken status stream must not take the verdict with it; the timer
      // keeps re-assessing, and an ageing tip turns into "stalled".
      onError: (Object _, StackTrace _) {},
    );
    if (_foreground) _startPolling();
  }

  /// The core was pointed at another node (a new session). History is reset
  /// so the new node gets its own grace period, and what the old session
  /// said about its node connection is forgotten: until the new core reports
  /// `node_connected`, the last chain state alone cannot make the wallet
  /// "synced" (it may be minutes old and the new node unreachable).
  void setNode(BeamNodeKind node) {
    if (_disposed) return;
    _node = node;
    _wallet = _wallet?.withoutConnection();
    _resetProgress();
    _emit();
  }

  /// App lifecycle. `false` stops polling; `true` resumes and refreshes.
  void setForeground(bool foreground) {
    if (_disposed || foreground == _foreground) return;
    _foreground = foreground;
    if (!_started) return;
    if (foreground) {
      _startPolling();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Checks the explorer now (e.g. behind a "Check again" button).
  Future<void> refresh() async {
    if (_disposed) return;
    await _poll(forceRefresh: true);
  }

  /// Stops the timer and the wallet subscription and closes [assessments].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _walletSub?.cancel();
    _walletSub = null;
    await _controller.close();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = _timerFactory(pollInterval, (_) => unawaited(_poll()));
    unawaited(_poll());
  }

  Future<void> _poll({bool forceRefresh = false}) {
    return _pollInFlight ??= _doPoll(forceRefresh).whenComplete(() {
      _pollInFlight = null;
    });
  }

  Future<void> _doPoll(bool forceRefresh) async {
    try {
      final status = await _explorerSource.status(forceRefresh: forceRefresh);
      if (_disposed) return;
      _explorer = status;
      _lastExplorerFailed = false;
    } catch (_) {
      if (_disposed) return;
      _lastExplorerFailed = true;
    }
    _emit();
  }

  void _onWallet(BeamWalletSyncInput input) {
    if (_disposed) return;
    final now = _now();
    _observingSince ??= now;
    final last = _lastHeight;
    final h = input.currentHeight;
    if (last != null && h < last) {
      // Rolled back or switched node: start measuring afresh.
      _resetProgress();
      _observingSince = now;
    } else if (last != null && h > last) {
      _heightLastAdvancedAt = now;
    }
    _lastHeight = h;
    if (h > 0) _addSample(now, h);
    _wallet = input;
    _emit();
  }

  void _resetProgress() {
    _observingSince = _wallet == null ? null : _now();
    _heightLastAdvancedAt = null;
    _lastHeight = null;
    _samples.clear();
  }

  void _addSample(DateTime at, int height) {
    _samples.add((at: at, height: height));
    final cutoff = at.subtract(speedWindow);
    while (_samples.length > 2 && _samples.first.at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  double? _speed() {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final seconds = last.at.difference(first.at).inMilliseconds / 1000;
    if (seconds < 10) return null;
    return (last.height - first.height) / seconds;
  }

  BeamExplorerStatus? _usableExplorer(DateTime now) {
    final e = _explorer;
    if (e == null) return null;
    if (!_lastExplorerFailed) return e;
    final age = now.difference(e.receivedAt);
    return (age.isNegative || age > explorerReuse) ? null : e;
  }

  void _emit() {
    if (_disposed) return;
    final now = _now();
    final since = _observingSince;
    final next = assessBeamSync(
      wallet: _wallet,
      explorer: _usableExplorer(now),
      now: now,
      node: _node,
      progress: since == null
          ? null
          : BeamSyncProgress(
              observingSince: since,
              heightLastAdvancedAt: _heightLastAdvancedAt,
              blocksPerSecond: _speed(),
            ),
      rules: rules,
    );
    if (next == _current) return;
    _current = next;
    _controller.add(next);
  }
}
