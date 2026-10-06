/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'bans_exceptions.dart';
import 'bans_models.dart';

/// Kernel fee of one BANS claim transaction (`receive_all`), measured on
/// mainnet (research/05 §fees).
final BigInt kBansClaimFeeGroth = BigInt.from(1100000);

/// `receive_all` claims at most this many entries per transaction
/// (`bans/app.cpp`, research/05).
const int kBansClaimsPerTransaction = 30;

/// Money waiting in the BANS vault for this wallet: payments sent to its
/// names, plus proceeds from names it sold. The wallet home shows it under
/// the spendable balance, never inside it, until it is claimed.
class BansPendingSummary {
  const BansPendingSummary({
    required this.visibility,
    required this.totalsByAsset,
    required this.entryCount,
    required this.names,
    required this.checkedAt,
  });

  /// Nothing to show yet, or the wallet cannot see its BANS inbox.
  BansPendingSummary.empty(this.visibility, this.checkedAt)
    : totalsByAsset = const {},
      entryCount = 0,
      names = const [];

  final BansInboxVisibility visibility;

  /// Asset id → total waiting, payments and sale proceeds together.
  final Map<int, BigInt> totalsByAsset;

  /// Vault entries to claim (each payment and each proceeds balance).
  final int entryCount;

  /// The user's names that received payments, sorted, without repeats.
  final List<String> names;

  final DateTime checkedAt;

  bool get isEmpty => entryCount == 0;

  /// What claiming everything now would cost and whether it is worth it.
  BansClaimAdvice advise({required BigInt beamAvailable}) {
    if (visibility != BansInboxVisibility.visible) {
      return BansClaimAdvice._(
        canClaim: false,
        transactions: 0,
        feeGroth: BigInt.zero,
        reason: BansClaimBlocker.needsCampfireCore,
      );
    }
    if (isEmpty) {
      return BansClaimAdvice._(
        canClaim: false,
        transactions: 0,
        feeGroth: BigInt.zero,
        reason: BansClaimBlocker.nothingToClaim,
      );
    }
    final transactions =
        (entryCount + kBansClaimsPerTransaction - 1) ~/
        kBansClaimsPerTransaction;
    final fee = kBansClaimFeeGroth * BigInt.from(transactions);
    final beamWaiting = totalsByAsset[0] ?? BigInt.zero;
    // A claim that releases BEAM pays its own fee from it (FundsUnlock is
    // negative in the funds map); a claim of tokens only needs the fee in
    // the wallet already.
    final needsBeam = beamAvailable + beamWaiting < fee;
    return BansClaimAdvice._(
      canClaim: !needsBeam,
      transactions: transactions,
      feeGroth: fee,
      reason: needsBeam ? BansClaimBlocker.needsBeamForFee : null,
      beamCostsMoreThanItReturns:
          totalsByAsset.length == 1 &&
          totalsByAsset.containsKey(0) &&
          beamWaiting <= fee,
    );
  }
}

enum BansInboxVisibility {
  /// The inbox was read.
  visible,

  /// The wallet core cannot run the BANS shader at the privilege the inbox
  /// needs (a stock wallet-api). Payments are safe in the vault; this build
  /// just cannot see or claim them.
  needsCampfireCore,
}

enum BansClaimBlocker { nothingToClaim, needsCampfireCore, needsBeamForFee }

/// The decision the claim button shows.
class BansClaimAdvice {
  BansClaimAdvice._({
    required this.canClaim,
    required this.transactions,
    required this.feeGroth,
    this.reason,
    this.beamCostsMoreThanItReturns = false,
  });

  final bool canClaim;

  /// Claim transactions needed (30 entries each).
  final int transactions;

  /// Total network fee for all of them, in groth.
  final BigInt feeGroth;

  /// Why [canClaim] is false.
  final BansClaimBlocker? reason;

  /// Only BEAM is waiting and the fee is at least as large: claiming now
  /// returns nothing or less than nothing. The UI says so before the user
  /// confirms; it does not forbid it.
  final bool beamCostsMoreThanItReturns;
}

/// Keeps [BansPendingSummary] current: on wallet open, on new blocks and on
/// transaction events, without ever running two inbox reads at once and
/// without reading more often than [minInterval] unless forced.
///
/// A failed read keeps the last good summary on screen (a stale "2.5 BEAM
/// waiting" beats a flicker to zero); only a core that cannot run the
/// inbox at all changes what is shown.
class BansInboxMonitor {
  BansInboxMonitor(
    this._read, {
    this.minInterval = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Reads the inbox, normally `BeamBansService.inbox`.
  final Future<BansInbox> Function() _read;
  final Duration minInterval;
  final DateTime Function() _now;

  final _summaries = StreamController<BansPendingSummary>.broadcast();
  BansPendingSummary? _latest;
  Future<void>? _inFlight;
  DateTime? _lastRead;
  Object? _lastError;
  bool _disposed = false;

  Stream<BansPendingSummary> get summaries => _summaries.stream;

  /// The newest summary, or null before the first successful check.
  BansPendingSummary? get latest => _latest;

  /// The error of the last failed read, cleared by the next success.
  Object? get lastError => _lastError;

  /// Re-reads the inbox. Concurrent calls share one read; calls within
  /// [minInterval] of the last read are skipped unless [force] (after a
  /// claim, or when the user pulls to refresh).
  Future<void> refresh({bool force = false}) {
    if (_disposed) return Future.value();
    final running = _inFlight;
    if (running != null) return running;
    final last = _lastRead;
    if (!force && last != null && _now().difference(last) < minInterval) {
      return Future.value();
    }
    final f = _readOnce().whenComplete(() => _inFlight = null);
    _inFlight = f;
    return f;
  }

  Future<void> _readOnce() async {
    _lastRead = _now();
    BansPendingSummary summary;
    try {
      summary = summarize(await _read(), _now());
      _lastError = null;
    } on BansClaimUnsupported catch (e) {
      _lastError = e;
      summary = BansPendingSummary.empty(
        BansInboxVisibility.needsCampfireCore,
        _now(),
      );
    } catch (e) {
      _lastError = e;
      return;
    }
    if (_disposed) return;
    _latest = summary;
    _summaries.add(summary);
  }

  /// Totals an inbox per asset.
  static BansPendingSummary summarize(BansInbox inbox, DateTime at) {
    final totals = <int, BigInt>{};
    void add(int aid, BigInt amount) =>
        totals[aid] = (totals[aid] ?? BigInt.zero) + amount;
    for (final p in inbox.payments) {
      add(p.assetId, p.amount);
    }
    for (final a in inbox.saleProceeds) {
      add(a.assetId, a.amount);
    }
    final names = {
      for (final p in inbox.payments)
        if (p.name != null && p.name!.isNotEmpty) p.name!,
    }.toList()..sort();
    return BansPendingSummary(
      visibility: BansInboxVisibility.visible,
      totalsByAsset: Map.unmodifiable(totals),
      entryCount: inbox.payments.length + inbox.saleProceeds.length,
      names: List.unmodifiable(names),
      checkedAt: at,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await _summaries.close();
  }
}
