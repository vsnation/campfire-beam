/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Which assets are DEX liquidity (LP) tokens, how they are named, and the
// real mainnet facts the naming and valuing rest on (explorer /assets rows
// for every LP token of the recorded pools: fixtures/explorer_lp_assets.json).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_text.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_lp_tokens.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';

import '../asset_wallet/asset_test_support.dart' show recordedPools;

/// The explorer's /assets rows for the recorded pools' LP tokens.
List<({int aid, String owner, String ownerType, BigInt supply, String meta})>
_explorerRows() {
  final json = jsonDecode(
    File('test/beam/assets/fixtures/explorer_lp_assets.json')
        .readAsStringSync(),
  ) as Map;
  return [
    for (final r in json['rows']! as List)
      (
        aid: ((r as List)[0] as Map)['value']! as int,
        owner: (r[1] as Map)['value']! as String,
        ownerType: (r[1] as Map)['type']! as String,
        supply: BigInt.from((r[3] as Map)['value']! as int),
        meta: r[5] as String,
      ),
  ];
}

BeamAssetMetadata _meta(String fields) =>
    BeamAssetMetadata.parse('STD:SCH_VER=1;$fields');

void main() {
  final pools = recordedPools();

  setUp(BeamLpTokens.clear);

  group('mainnet facts (explorer, 2026-10-07)', () {
    test('every LP token is owned by the DEX contract and its metadata is '
        'the contract\'s own "Amm Liquidity Token <aid1>-<aid2>-<kind>"', () {
      final rows = {for (final r in _explorerRows()) r.aid: r};
      expect(rows.length, pools.length);
      for (final p in pools) {
        final r = rows[p.lpToken]!;
        expect(r.ownerType, 'cid', reason: 'LP ${p.lpToken}');
        expect(r.owner, kDexContractId, reason: 'LP ${p.lpToken}');
        expect(
          r.meta,
          'STD:SCH_VER=1;N=Amm Liquidity Token '
          '${p.aid1}-${p.aid2}-${p.kind.wire};SN=AmmL;UN=AMML;NTHUN=GROTH',
        );
      }
    });

    test('an LP token has 8 decimals like every asset: its supply is the '
        'pool\'s ctl in the same smallest units', () {
      final rows = {for (final r in _explorerRows()) r.aid: r};
      final moved = <int>[];
      for (final p in pools) {
        if (rows[p.lpToken]!.supply != p.ctl) moved.add(p.lpToken);
      }
      // A day apart (pools_view at height 4068104, the explorer at
      // 4069624): only two pools took or lost liquidity in between.
      expect(moved, [199, 201]);
      // BEAM/FOMO: 21,252.57813880 LP in both.
      expect(rows[175]!.supply, BigInt.parse('2125257813880'));
      expect(
        pools.singleWhere((p) => p.lpToken == 175).ctl,
        BigInt.parse('2125257813880'),
      );
      expect(BeamAssetInfo.decimalsFor(175), 8);
    });
  });

  group('recognised from the DEX only', () {
    test('a pools_view row makes an asset an LP token; its name does not', () {
      // Before the DEX is read, 175 is just an asset with that metadata.
      final lpMeta = BeamAssetMetadata.parse(
        'STD:SCH_VER=1;N=Amm Liquidity Token 0-174-2;SN=AmmL;UN=AMML;'
        'NTHUN=GROTH',
      );
      expect(BeamAssetCatalog.display(175, lpMeta).isPoolShare, isFalse);
      BeamAssetMarket(pools);
      expect(BeamLpTokens.of(175), isNotNull);
      final d = BeamAssetCatalog.display(175, lpMeta);
      expect(d.isPoolShare, isTrue);
      expect(d.name, 'BEAM/FOMO LP');
      // Anyone can mint "Amm Liquidity Token 0-174-2" from their own key:
      // an asset the DEX does not list stays what it is.
      final fake = BeamAssetCatalog.display(999, lpMeta);
      expect(fake.isPoolShare, isFalse);
      expect(fake.verified, isFalse);
      expect(fake.name, 'Amm Liquidity Token 0-174-2');
      expect(fake.label, 'AMML #999');
    });

    test('malformed pools are ignored', () {
      BeamLpTokens.learn(
        const BeamLpPool(lpToken: 174, aid1: 0, aid2: 174, kind: 2),
      );
      BeamLpTokens.learn(
        const BeamLpPool(lpToken: 900, aid1: 7, aid2: 7, kind: 2),
      );
      BeamLpTokens.learn(
        const BeamLpPool(lpToken: 0, aid1: 0, aid2: 7, kind: 2),
      );
      expect(BeamLpTokens.all, isEmpty);
    });

    test('a verified asset is never named as an LP token', () {
      BeamLpTokens.learn(
        const BeamLpPool(lpToken: 174, aid1: 0, aid2: 7, kind: 2),
      );
      expect(BeamAssetCatalog.display(174, null).name, 'FOMO');
    });
  });

  group('named after the pair, as the DEX names it', () {
    setUp(() => BeamAssetMarket(pools));

    String nameOf(int lp) => BeamAssetCatalog.display(lp, null).name;

    test('verified pairs, the bridge assets included', () {
      expect(nameOf(175), 'BEAM/FOMO LP');
      expect(nameOf(50), 'BEAM/BEAMX LP');
      expect(nameOf(60), 'BEAM/NPH LP');
      expect(nameOf(77), 'BEAM/bETH LP');
      expect(nameOf(58), 'BEAM/bUSDT LP');
      expect(nameOf(95), 'BEAM/bWBTC LP');
      expect(nameOf(105), 'BEAM/bDAI LP');
      expect(nameOf(110), 'bETH/bWBTC LP');
      expect(nameOf(73), 'bUSDT/NPH LP');
      expect(nameOf(106), 'bDAI/NPH LP');
      final d = BeamAssetCatalog.display(175, null);
      expect(d.verified, isTrue);
      expect(d.symbol, d.name);
      expect(d.label, 'BEAM/FOMO LP');
      expect(
        d.pool,
        const BeamLpPool(lpToken: 175, aid1: 0, aid2: 174, kind: 2),
      );
    });

    test('pools of one pair are told apart by their fee tier', () {
      // BEAM/BEAMX exists as kinds 0, 1 and 2 (LP 57, 56, 50).
      final rows = [
        for (final lp in [57, 56, 50]) BeamAssetRegistry.build(lp),
      ];
      expect(rows.map((r) => r.name).toSet(), {'BEAM/BEAMX LP'});
      expect(
        [for (final r in rows) BeamAssetText.poolSubtitle(r)],
        [
          'Pool share · 0.05% fee',
          'Pool share · 0.3% fee',
          'Pool share · 1% fee',
        ],
      );
    });

    test('an unverified side keeps its number, named from its metadata '
        'when known', () {
      // LP 59: BEAM / #3 (BeamBots, BB).
      final bare = BeamAssetCatalog.display(59, null);
      expect(bare.name, 'BEAM/#3 LP');
      expect(bare.verified, isFalse);
      expect(bare.label, 'BEAM/#3 LP #59');
      final named = BeamAssetCatalog.display(
        59,
        null,
        metadataOf: (id) => id == 3 ? _meta('N=BeamBots Token;UN=BB') : null,
      );
      expect(named.name, 'BEAM/BB #3 LP');
      // A copycat side can never read like the real pair.
      final copy = BeamAssetCatalog.display(
        59,
        null,
        metadataOf: (id) => id == 3 ? _meta('N=FOMO;UN=FOMO') : null,
      );
      expect(copy.name, 'BEAM/FOMO #3 LP');
    });

    test('an LP token traded in a pool is bracketed', () {
      // LP 67 is BEAM / LP 60, and LP 60 is BEAM/NPH.
      expect(nameOf(67), 'BEAM/(BEAM/NPH LP) LP');
      expect(BeamAssetCatalog.display(67, null).verified, isTrue);
      // LP 119 is BEAMX / LP 50 (BEAM/BEAMX).
      expect(nameOf(119), 'BEAMX/(BEAM/BEAMX LP) LP');
      expect(BeamAssetRegistry.sideLabel(60, null), '(BEAM/NPH LP)');
    });
  });

  group('cached rows', () {
    test('a row cached as "BEAM / FOMO pool share" reads "BEAM/FOMO LP"', () {
      final old = BeamAssetContract(
        address: BeamAssetContract.addressFor(175),
        assetId: 175,
        name: 'BEAM / FOMO pool share',
        symbol: 'LP',
        decimals: 8,
        verified: false,
        metadataKnown: true,
        iconAsset: BeamAssetCatalog.unverifiedIcon(175),
        color: BeamAssetCatalog.genericColor(175),
        poolAssetA: 0,
        poolAssetB: 174,
        poolKind: 2,
      );
      final fresh = BeamAssetRegistry.refreshLook(old);
      expect(fresh.name, 'BEAM/FOMO LP');
      expect(fresh.symbol, 'BEAM/FOMO LP');
      expect(fresh.verified, isTrue);
      expect(fresh.isPoolShare, isTrue);
      // An unverified side keeps the name it was cached with.
      final pepe = BeamAssetRegistry.refreshLook(
        old.copyWith(name: 'BEAM / PEPE #777 pool share', poolAssetB: 777),
      );
      expect(pepe.name, 'BEAM/PEPE #777 LP');
      expect(pepe.verified, isFalse);
    });

    test('cached LP rows teach which assets are LP tokens', () {
      BeamAssetRegistry.learnPools([
        BeamAssetRegistry.build(
          189,
          pool: const BeamLpPool(lpToken: 189, aid1: 0, aid2: 186, kind: 2),
        ),
      ]);
      expect(BeamAssetCatalog.display(189, null).name, 'BEAM/GIGA LP');
    });

    test('the list shows "LP" after the amount; its name says the pair', () {
      BeamAssetMarket(pools);
      final row = BeamAssetRegistry.build(188);
      final amount = Amount(
        rawValue: BigInt.from(272825000000),
        fractionDigits: 8,
      );
      expect(
        BeamAssetText.roundedShort(amount, row, locale: 'en_US'),
        '2,728.25 LP',
      );
      expect(
        BeamAssetText.rounded(amount, row, locale: 'en_US'),
        '2,728.25 BEAM/CHAD LP',
      );
      expect(
        BeamAssetText.poolLine(row),
        'Your share of the BEAM/CHAD pool (1% fee)',
      );
    });
  });
}
