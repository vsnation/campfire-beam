/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The history's details screen names a payment's asset like every other
// screen: a DEX liquidity token by its pair, never "Asset #59 — not verified
// by Campfire". Anything else Campfire does not vouch for keeps that line.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_lp_tokens.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_text.dart';

import '../asset_wallet/asset_test_support.dart' show recordedPools;

void main() {
  setUp(BeamLpTokens.clear);

  test('verified and unknown assets read as before', () {
    expect(BeamTxText.assetName(0), 'BEAM');
    expect(BeamTxText.assetName(174), 'FOMO');
    expect(BeamTxText.assetName(4), 'Gothic Crown (CROWN)');
    expect(BeamTxText.assetName(557), 'Asset #557 — not verified by Campfire');
  });

  test('an LP token is named by its pair once the DEX has named it', () {
    // Before any DEX read it is just an asset Campfire does not vouch for.
    expect(BeamTxText.assetName(175), 'Asset #175 — not verified by Campfire');
    BeamAssetMarket(recordedPools());
    expect(BeamTxText.assetName(175), 'BEAM/FOMO LP');
    expect(BeamTxText.assetName(110), 'bETH/bWBTC LP');
    // LP 59, BEAM / #3: from the DEX's list alone the side is "#3".
    expect(BeamTxText.assetName(59), 'BEAM/#3 LP');
  });

  test('an unverified side is named from the cached row, as in the asset '
      'list', () {
    BeamAssetMarket(recordedPools());
    final row = BeamAssetRegistry.build(
      59,
      pool: BeamLpTokens.of(59),
      metadataOf: (id) => id == 3
          ? BeamAssetMetadata.parse(
              'STD:SCH_VER=1;N=BeamBots Token;SN=BB;UN=BB;NTHUN=MiniB',
            )
          : null,
    );
    expect(row.name, 'BEAM/BB #3 LP');
    expect(BeamTxText.assetName(59, cached: row), 'BEAM/BB #3 LP');
    // Another asset's row is never used.
    expect(BeamTxText.assetName(175, cached: row), 'BEAM/FOMO LP');
  });

  test('a row cached as a pool share names it even before the DEX is read, '
      'in today\'s words', () {
    final old = BeamAssetContract(
      address: BeamAssetContract.addressFor(59),
      assetId: 59,
      name: 'BEAM / BB #3 pool share',
      symbol: 'LP',
      decimals: 8,
      verified: false,
      metadataKnown: true,
      poolAssetA: 0,
      poolAssetB: 3,
      poolKind: 2,
    );
    expect(BeamTxText.assetName(59, cached: old), 'BEAM/BB #3 LP');
  });
}
