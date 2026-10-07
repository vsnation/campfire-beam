/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../utilities/logger.dart';
import '../../../wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import '../../../wallets/beam/node/beam_private_node_coordinator.dart';
import '../../../wallets/beam/price/beam_asset_pricer.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_sync_tracker.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import 'beam_home_source.dart';
import 'beam_home_text.dart';
import 'beam_scan_state.dart';

/// The live half of the BEAM wallet home: sync verdict, restore scan,
/// private node, core problems, money waiting for the user's names, and
/// asset prices.
///
/// Nothing here is awaited on the build path (R11). Every value starts from
/// what the wallet already knows (its getters, the inbox monitor's last
/// summary) and is replaced as fresher values arrive; a failed read keeps
/// the last good value.
///
/// The BANS inbox is re-read when the home opens, when the core comes up,
/// on every new block and whenever the transaction history changes. The
/// monitor shares concurrent reads and throttles repeats, so these
/// triggers never overlap in the core.
class BeamHomeController extends ChangeNotifier {
  BeamHomeController(
    this.source, {
    this.pollInterval = const Duration(seconds: 2),
    void Function(String message)? log,
  }) : _log = log ?? ((m) => Logging.instance.i(m));

  final BeamHomeSource source;

  /// How often the getters without an event (private node, scan progress)
  /// are re-read. Reading them is free; nothing is fetched.
  final Duration pollInterval;

  final void Function(String message) _log;

  late BeamSyncAssessment _assessment = source.syncAssessment;
  late bool _canSpend = source.canSpend;
  late bool _scanning = source.isScanningForCoins;
  late BeamScanProgress? _scan = source.scanProgress;
  late BeamPrivateNodeStatus? _node = source.privateNodeStatus;
  late BeamWalletException? _problem = source.coreProblem;
  late BansPendingSummary? _names = source.bansInbox.latest;
  BeamAssetPricer? _pricer;
  int _maxBlocksBehind = 0;
  bool _wasOpen = false;
  Set<int> _heldAssets = const {};
  Future<void>? _pricing;
  DateTime? _pricedAt;
  BansInboxVisibility? _loggedVisibility;

  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _poll;
  bool _started = false;
  bool _disposed = false;

  BeamSyncAssessment get assessment => _assessment;
  bool get canSpend => _canSpend;

  /// A restore scan the user is waiting for ([beamScanRunning]): false once
  /// the wallet is up to date with the scan done, even while it keeps
  /// asking for block bodies until a private node takes over.
  bool get isScanningForCoins =>
      beamScanRunning(pending: _scanning, scan: _scan, canSpend: _canSpend);
  BeamScanProgress? get scanProgress => _scan;
  BeamPrivateNodeStatus? get privateNodeStatus => _node;
  BeamWalletException? get coreProblem => _problem;

  /// The newest summary of money waiting for the user's names, or null
  /// before the first successful read.
  BansPendingSummary? get namePayments => _names;

  /// The DEX pricer, once read; null until then (and while unreadable).
  BeamAssetPricer? get pricer => _pricer;

  /// The banner for the current state, or null when all is well.
  BeamBannerContent? get banner => BeamHomeText.syncBanner(
    assessment: _assessment,
    scanning: isScanningForCoins,
    scan: _scan,
    problem: _problem,
    maxBlocksBehind: _maxBlocksBehind,
  );

  /// Why Send is off, or null when sending is allowed.
  String? get sendPausedReason => _canSpend && _problem == null
      ? null
      : BeamHomeText.sendPaused(assessment: _assessment, problem: _problem) ??
            'Sending is paused for a moment.';

  /// Starts listening. Safe to call more than once.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _observeBlocks(_assessment);
    _subs
      ..add(source.syncAssessments.listen(_onAssessment))
      ..add(source.bansInbox.summaries.listen(_onNames))
      ..add(source.walletEvents.listen((_) => _pull()))
      ..add(source.transactionsChanged.listen((_) => _refreshNames()));
    _poll = Timer.periodic(pollInterval, (_) => _pull());
    _logVisibility(_names);
    _wasOpen = source.isOpen;
    if (_wasOpen) {
      _refreshNames();
      _refreshPricer();
    }
  }

  /// The assets the wallet holds (from Campfire's cache). Prices are only
  /// fetched when there is something other than BEAM to value.
  void setHeldAssets(Set<int> assetIds) {
    final next = {...assetIds}..remove(0);
    if (setEquals(next, _heldAssets)) return;
    _heldAssets = next;
    _refreshPricer();
  }

  /// Re-reads the inbox now, skipping the throttle (after a claim).
  Future<void> refreshNamesNow() =>
      source.isOpen ? source.bansInbox.refresh(force: true) : Future.value();

  void _onAssessment(BeamSyncAssessment a) {
    final previousHeight = _assessment.walletHeight;
    _assessment = a;
    _observeBlocks(a);
    _canSpend = source.canSpend;
    final h = a.walletHeight;
    if (h != null && previousHeight != null && h > previousHeight) {
      // A new block: payments to the user's names arrive in blocks.
      _refreshNames();
      _refreshPricer();
    }
    _pull(force: true);
  }

  void _observeBlocks(BeamSyncAssessment a) {
    final behind = switch (a) {
      BeamSyncCatchingUp(:final blocksBehind) => blocksBehind,
      _ => null,
    };
    if (a is BeamSynced) {
      _maxBlocksBehind = 0;
    } else if (behind != null && behind > _maxBlocksBehind) {
      _maxBlocksBehind = behind;
    }
  }

  void _onNames(BansPendingSummary s) {
    _names = s;
    _logVisibility(s);
    _notify();
  }

  void _logVisibility(BansPendingSummary? s) {
    final v = s?.visibility;
    if (v == null || v == _loggedVisibility) return;
    _loggedVisibility = v;
    if (v == BansInboxVisibility.needsCampfireCore) {
      // Not shown on the home on purpose: the money is safe and the user
      // can do nothing about it here. Logged so it is not invisible.
      _log(
        'BEAM home: this wallet core cannot read payments sent to BANS '
        'names (it lacks the Campfire core privilege); the name payments '
        'line stays hidden',
      );
    }
  }

  /// Re-reads the getters that have no event of their own.
  void _pull({bool force = false}) {
    if (_disposed) return;
    final open = source.isOpen;
    if (open && !_wasOpen) {
      // The core just came up: anything read before it failed or was
      // skipped, so read again now.
      unawaited(refreshNamesNow());
      _refreshPricer();
    }
    _wasOpen = open;

    final canSpend = source.canSpend;
    final scanning = source.isScanningForCoins;
    final scan = source.scanProgress;
    final node = source.privateNodeStatus;
    final problem = source.coreProblem;
    final changed =
        canSpend != _canSpend ||
        scanning != _scanning ||
        scan != _scan ||
        node != _node ||
        !identical(problem, _problem);
    _canSpend = canSpend;
    _scanning = scanning;
    _scan = scan;
    _node = node;
    _problem = problem;
    if (changed || force) _notify();
  }

  void _refreshNames() {
    if (_disposed || !source.isOpen) return;
    unawaited(source.bansInbox.refresh());
  }

  void _refreshPricer() {
    if (_disposed ||
        _heldAssets.isEmpty ||
        !source.isOpen ||
        _pricing != null) {
      return;
    }
    final at = _pricedAt;
    if (_pricer != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 2)) {
      return;
    }
    _pricing = () async {
      try {
        final p = await source.pricer();
        if (_disposed) return;
        _pricer = p;
        _pricedAt = DateTime.now();
        _notify();
      } catch (e) {
        // Keep the last good prices; the line says "Plus N assets" until
        // a read works.
        _log('BEAM home: asset prices unavailable for now: $e');
      } finally {
        _pricing = null;
      }
    }();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    super.dispose();
  }
}
