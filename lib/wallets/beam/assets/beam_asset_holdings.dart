/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../../../models/balance.dart';
import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../utilities/amount/amount.dart';
import '../contracts/dex/beam_pool.dart';
import '../models/beam_asset_info.dart';
import '../price/beam_asset_pricer.dart';
import '../wallet/beam_balance_mapper.dart';
import 'beam_asset_registry.dart';

/// What the DEX says right now: prices and which assets are pool shares.
class BeamAssetMarket {
  BeamAssetMarket(List<BeamPool> pools, {DateTime? readAt})
    : pools = List.unmodifiable(pools),
      pricer = BeamAssetPricer(pools),
      readAt = readAt ?? DateTime.now(),
      poolsByLpToken = Map.unmodifiable({for (final p in pools) p.lpToken: p});

  final List<BeamPool> pools;
  final BeamAssetPricer pricer;
  final DateTime readAt;

  /// LP token asset id → its pool.
  final Map<int, BeamPool> poolsByLpToken;
}

/// One asset as a wallet holds it.
@immutable
class BeamAssetHolding {
  const BeamAssetHolding({
    required this.contract,
    required this.totals,
    required this.hidden,
    required this.priced,
    this.valueGroth,
    this.saleValue = false,
  });

  final BeamAssetContract contract;
  final BeamCachedAssetTotals totals;

  /// The user hid it from the list.
  final bool hidden;

  /// The DEX prices it. False while prices are unknown too.
  final bool priced;

  /// What [totals] is worth in groth (estimate), when [priced].
  final BigInt? valueGroth;

  /// [valueGroth] is what its pool would pay for it (an unverified asset,
  /// `BeamAssetPricer.isSaleValue`), not a verified asset's spot price.
  final bool saleValue;

  int get assetId => contract.assetId;

  /// Campfire's balance for this asset, mapped exactly like BEAM's
  /// (`BeamBalanceMapper.balance`): spendable = available, pending =
  /// receiving + maturing, nothing blocked.
  Balance get balance => beamAssetBalance(totals);
}

/// [totals] as Campfire's [Balance] (8 decimals).
Balance beamAssetBalance(BeamCachedAssetTotals totals) {
  Amount a(BigInt v) =>
      Amount(rawValue: v, fractionDigits: BeamAssetInfo.beamDecimals);
  return Balance(
    total: a(totals.total),
    spendable: a(totals.available),
    blockedTotal: a(BigInt.zero),
    pendingSpendable: a(totals.receiving + totals.maturing),
  );
}

/// The visible holdings, valued.
@immutable
class BeamAssetPortfolio {
  const BeamAssetPortfolio({
    required this.valueGroth,
    required this.unpriced,
    required this.marketKnown,
  });

  /// Sum of the priced, visible holdings, in groth.
  final BigInt valueGroth;

  /// Visible holdings the DEX does not price (left out of [valueGroth]).
  final int unpriced;

  /// False while DEX prices have not been read: [valueGroth] is then 0 and
  /// means nothing.
  final bool marketKnown;
}

abstract final class BeamAssetHoldings {
  /// Every Confidential Asset in [totals] the wallet has or is moving,
  /// BEAM (asset 0) excluded: it is the wallet itself.
  ///
  /// [contracts] are the cached rows (an asset without one is shown from
  /// the catalogue until it is cached). Verified assets and pool shares
  /// come first, by estimated value, highest first; then other priced
  /// assets by value, so no asset anyone can mint and price tops the list;
  /// then unpriced holdings, verified first, then by id.
  static List<BeamAssetHolding> build({
    required Map<int, BeamCachedAssetTotals> totals,
    required Map<int, BeamAssetContract> contracts,
    required Set<int> hidden,
    BeamAssetMarket? market,
  }) {
    final out = <BeamAssetHolding>[];
    for (final t in totals.values) {
      if (t.assetId <= 0) continue;
      if (t.total == BigInt.zero && t.sending == BigInt.zero) continue;
      var contract = contracts[t.assetId];
      final pool = market?.poolsByLpToken[t.assetId];
      if (contract == null || (pool != null && !contract.isPoolShare)) {
        contract = pool != null
            ? BeamAssetRegistry.build(
                t.assetId,
                pool: pool,
                pairLabel:
                    '${BeamAssetRegistry.sideLabel(pool.aid1, null)} / '
                    '${BeamAssetRegistry.sideLabel(pool.aid2, null)}',
              )
            : BeamAssetRegistry.build(t.assetId);
      }
      final value = market?.pricer.valueInGroth(t.assetId, t.total);
      out.add(
        BeamAssetHolding(
          contract: contract,
          totals: t,
          hidden: hidden.contains(t.assetId),
          priced: value != null,
          valueGroth: value,
          saleValue:
              value != null && (market?.pricer.isSaleValue(t.assetId) ?? false),
        ),
      );
    }
    out.sort(_order);
    return List.unmodifiable(out);
  }

  /// 0: a priced verified asset or pool share, 1: another priced asset,
  /// 2: unpriced.
  static int _rank(BeamAssetHolding h) => h.valueGroth == null
      ? 2
      : (h.contract.verified || h.contract.isPoolShare ? 0 : 1);

  static int _order(BeamAssetHolding a, BeamAssetHolding b) {
    final rank = _rank(a).compareTo(_rank(b));
    if (rank != 0) return rank;
    final av = a.valueGroth, bv = b.valueGroth;
    if (av != null && bv != null && av != bv) return bv.compareTo(av);
    if (av != null && bv == null) return -1;
    if (av == null && bv != null) return 1;
    if (a.contract.verified != b.contract.verified) {
      return a.contract.verified ? -1 : 1;
    }
    return a.assetId.compareTo(b.assetId);
  }

  /// The value of the holdings not hidden.
  static BeamAssetPortfolio portfolio(
    List<BeamAssetHolding> holdings, {
    required bool marketKnown,
  }) {
    var value = BigInt.zero;
    var unpriced = 0;
    for (final h in holdings) {
      if (h.hidden) continue;
      final v = h.valueGroth;
      if (v == null) {
        unpriced++;
      } else {
        value += v;
      }
    }
    return BeamAssetPortfolio(
      valueGroth: value,
      unpriced: marketKnown ? unpriced : 0,
      marketKnown: marketKnown,
    );
  }
}
