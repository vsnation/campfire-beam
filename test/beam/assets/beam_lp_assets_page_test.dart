/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Reported: LP pairs were parsed incorrectly on the Assets page.
//
// The fixture wallet holds four DEX liquidity (LP) tokens: 50 (BEAM/BEAMX),
// 175 (BEAM/FOMO), 188 (BEAM/CHAD) and 189 (BEAM/GIGA). Their pools are the
// recorded mainnet `pools_view` (2026-10-06). These tests use only what the
// Assets page, the dashboard and the desktop sidebar's asset list are built
// from, so they read the same against the code before the fix:
//
// * the dashboard and the desktop sidebar titled them "LP #175", "LP #188";
// * the asset list called them "BEAM / FOMO pool share", and anything that
//   named an asset by its metadata said "Amm Liquidity Token 0-174-2";
// * an LP token with an unverified side was valued as if the pool's whole
//   reserve of that asset were sold into the pool (a quarter too low), and
//   one whose pool trades another LP token had no value at all.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/price/beam_asset_pricer.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_dashboard_assets.dart';

import '../asset_wallet/asset_test_support.dart' show recordedPools;

final _one = BigInt.from(100000000);

BeamCachedAssetTotals _totals(int id, BigInt available) =>
    BeamCachedAssetTotals(
      assetId: id,
      available: available,
      receiving: BigInt.zero,
      sending: BigInt.zero,
      maturing: BigInt.zero,
      change: BigInt.zero,
    );

/// The pool whose LP token is [lp].
BeamPool _poolOf(List<BeamPool> pools, int lp) =>
    pools.firstWhere((p) => p.lpToken == lp);

/// [lpAmount] of [pool]'s LP token at spot:
/// (lpAmount / ctl) × (tok1·price1 + tok2·price2), each price in groth per
/// smallest unit from the asset's deepest BEAM pool (BEAM is 1). Exact
/// rationals, rounded down once at the end.
BigInt _spotFormula(List<BeamPool> pools, BeamPool pool, BigInt lpAmount) {
  (BigInt, BigInt) price(int aid) {
    if (aid == 0) return (BigInt.one, BigInt.one);
    final deepest = pools
        .where((p) => p.aid1 == 0 && p.aid2 == aid && !p.isEmpty)
        .reduce((a, b) => a.tok1 >= b.tok1 ? a : b);
    return (deepest.tok1, deepest.tok2);
  }

  final (n1, d1) = price(pool.aid1);
  final (n2, d2) = price(pool.aid2);
  // tok1·n1/d1 + tok2·n2/d2, times lpAmount / ctl.
  final num = (pool.tok1 * n1 * d2 + pool.tok2 * n2 * d1) * lpAmount;
  final den = d1 * d2 * pool.ctl;
  return num ~/ den;
}

void main() {
  final pools = recordedPools();
  final market = BeamAssetMarket(pools, readAt: DateTime(2026, 10, 6, 12));
  final held = {
    for (final (id, units) in [
      (174, 568.1297),
      (175, 0.46659234),
      (188, 2728.25),
      (189, 2728.25),
      (50, 12.5),
    ])
      id: _totals(id, BigInt.from((units * 100000000).round())),
  };

  group('names', () {
    final holdings = BeamAssetHoldings.build(
      totals: held,
      contracts: const {},
      hidden: const {},
      market: market,
    );
    String nameOf(int id) =>
        holdings.firstWhere((h) => h.assetId == id).contract.name;

    test('the asset list names each LP token after its pair', () {
      expect(nameOf(175), 'BEAM/FOMO LP');
      expect(nameOf(188), 'BEAM/CHAD LP');
      expect(nameOf(189), 'BEAM/GIGA LP');
      expect(nameOf(50), 'BEAM/BEAMX LP');
    });

    test('the dashboard and the desktop asset list title it the same, not '
        '"LP #175"', () {
      final model = BeamDashboardModel.build(
        beamSpendable: BigInt.from(1200) * _one,
        holdings: holdings,
        market: market,
        formatBeam: (Amount a) => '${a.decimal} BEAM',
        fiat: (_) => null,
        now: DateTime(2026, 10, 6, 12),
        maxRows: 10,
      );
      final rows = {for (final r in model.rows) r.assetId: r};
      final shown = [for (final r in model.rows) '${r.title}: ${r.amount}'];
      expect(rows[188]?.title, 'BEAM/CHAD LP', reason: '$shown');
      expect(rows[189]?.title, 'BEAM/GIGA LP', reason: '$shown');
      expect(rows[50]?.title, 'BEAM/BEAMX LP', reason: '$shown');
      // Worth 0.28 BEAM, and listed: an LP token of two verified assets is
      // as listed as they are.
      expect(rows[175]?.title, 'BEAM/FOMO LP', reason: '$shown');
      expect(rows[175]!.amount, '0.46659234 LP');
      for (final r in model.rows) {
        expect(r.title, isNot(startsWith('LP ')), reason: 'asset ${r.assetId}');
      }
    });

    test('a screen naming an asset from its metadata names the pool, not '
        '"Amm Liquidity Token 0-174-2"', () {
      // The real on-chain metadata of asset 175 (explorer /assets).
      final meta = BeamAssetMetadata.parse(
        'STD:SCH_VER=1;N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;'
        'NTHUN=GROTH',
      );
      final d = BeamAssetCatalog.display(175, meta);
      expect(d.name, 'BEAM/FOMO LP');
      expect(d.symbol, 'BEAM/FOMO LP');
    });
  });

  group('values', () {
    final pricer = BeamAssetPricer(pools);

    test('an LP token of two verified assets is worth (lp / ctl) × '
        '(tok1·price1 + tok2·price2), for every such pool on mainnet', () {
      const verified = BeamAssetCatalog.verified;
      var checked = 0;
      for (final pool in pools) {
        if (pool.isEmpty) continue;
        if (!verified.containsKey(pool.aid1) ||
            !verified.containsKey(pool.aid2)) {
          continue;
        }
        // One whole LP token, or the whole supply if smaller.
        final amount = pool.ctl < _one ? pool.ctl : _one;
        final expected = _spotFormula(pools, pool, amount);
        final got = pricer.valueInGroth(pool.lpToken, amount);
        expect(got, isNotNull, reason: 'LP ${pool.lpToken}');
        expect(got, expected, reason: 'LP ${pool.lpToken}');
        checked++;
      }
      expect(checked, greaterThanOrEqualTo(20));
    });

    test('BEAM/FOMO: 0.46659234 LP is worth 0.27983543 BEAM', () {
      final pool = _poolOf(pools, 175);
      final lp = BigInt.from(46659234);
      // 0.46659234 / 21,252.578 of 6,373.04 BEAM and 51,732.34 FOMO:
      // 0.13991771 BEAM + 1.13576394 FOMO at 0.1231926 BEAM.
      final v = pricer.valueInGroth(175, lp)!;
      expect(v, BigInt.from(27983543));
      expect(v, _spotFormula(pools, pool, lp));
    });

    test('an unverified side is not valued as if the whole pool were sold '
        'into itself', () {
      // LP 59: BEAM/#3 (BeamBots, unverified), 2,089 BEAM deep. One LP
      // token is 1/20,935 of the pool: 0.0998 BEAM and 10.09 #3, which the
      // pool would buy for ~0.0998 BEAM. The old value counted the #3 side
      // at half the BEAM side.
      final pool = _poolOf(pools, 59);
      final spot = _spotFormula(pools, pool, _one);
      final v = pricer.valueInGroth(59, _one)!;
      expect(v <= spot, isTrue, reason: '$v vs spot $spot');
      expect(
        v * BigInt.from(1000) >= spot * BigInt.from(999),
        isTrue,
        reason: '$v vs spot $spot',
      );
      expect(pricer.isSaleValue(59), isTrue);
      expect(pricer.isSaleValue(175), isFalse);
    });

    test('an LP token whose pool trades another LP token is valued through '
        'it', () {
      // LP 119: BEAMX / LP 50 (BEAM/BEAMX), 0.3% pool.
      final pool = _poolOf(pools, 119);
      expect((pool.aid1, pool.aid2), (7, 50));
      final v = pricer.valueInGroth(119, _one);
      expect(v, isNotNull);
      // Its BEAMX side alone, at spot, is a lower bound.
      final beamx = _poolOf(pools, 50);
      final beamxSide = pool.tok1 * _one ~/ pool.ctl * beamx.tok1 ~/ beamx.tok2;
      expect(v! > beamxSide, isTrue);
    });
  });
}
