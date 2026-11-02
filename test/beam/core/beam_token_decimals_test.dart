/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Each token in its own decimals: its metadata's NTH_RATIO ("1 unit =
// NTH_RATIO smallest units", BEAM's Asset Descriptor v1.0; 10^8 when
// missing). A user's CANDY (#31, NTH_RATIO=10) read 1,203.7557598 where a
// wallet reading NTH_RATIO shows 12,037,557,598. The web wallet reads them
// the same way (pwa/test/unit/decimals.test.mjs).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/widgets/beam/airdrop/beam_units.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_format.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_dashboard_assets.dart';

final _candy = BeamAssetMetadata.parse(
  'STD:SCH_VER=1;N=CANDY;SN=EAT;UN=CANDY;NTHUN=BITE;NTH_RATIO=10;'
  'OPT_SHORT_DESC=Cannot be split into fractions;',
);
final _doggy = BeamAssetMetadata.parse(
  'STD:SCH_VER=1;N=Dogenero;UN=doggy;SN=XDG;NTHUN=pupper;'
  'NTH_RATIO=1000000000000;OPT_SHORT_DESC=Woof',
);

void main() {
  test('displays carry the decimals: pinned, read, or unknown', () {
    expect(BeamAssetCatalog.display(0, null).decimals, 8);
    expect(BeamAssetCatalog.display(4, null).decimals, 3, reason: 'CROWN');
    expect(BeamAssetCatalog.display(174, _candy).decimals, 8, reason: 'FOMO');
    expect(BeamAssetCatalog.display(31, _candy).decimals, 1);
    expect(BeamAssetCatalog.display(161, _doggy).decimals, 12);
    expect(BeamAssetCatalog.display(7031, null).decimals, isNull);
  });

  test('Send reads and writes an amount in the asset\'s decimals', () {
    final candy = BeamAssetCatalog.display(31, _candy);
    expect(
      BeamSendFormat.parse('12037557598.5', places: 1),
      BigInt.parse('120375575985'),
    );
    expect(BeamSendFormat.parse('1.25', places: 1), isNull);
    expect(BeamSendFormat.parse('150', places: 0), BigInt.from(150));
    expect(
      BeamSendFormat.parse('1', places: null),
      isNull,
      reason: 'not read yet',
    );
    expect(BeamSendFormat.parse('1.5'), BigInt.from(150000000), reason: 'BEAM');
    expect(
      BeamSendFormat.amount(BigInt.parse('120375575985'), candy),
      '12,037,557,598.5 CANDY #31',
    );
    expect(
      BeamSendFormat.editable(BigInt.parse('120375575985'), places: 1),
      '12037557598.5',
    );
    expect(BeamSendFormat.editable(BigInt.one, places: null), '');
  });

  test('the 8-decimal figure for other wallets, only where it differs', () {
    final candy = BeamAssetCatalog.display(31, _candy);
    final doggy = BeamAssetCatalog.display(161, _doggy);
    expect(
      BeamSendFormat.atEight(BigInt.parse('120375575980'), candy),
      '1,203.7557598 CANDY #31',
    );
    // "5 doggy" here is 50,000 doggy in BEAM's official wallet and explorer.
    expect(
      BeamSendFormat.atEight(BigInt.parse('5000000000000'), doggy),
      '50,000 doggy #161',
    );
    expect(
      BeamSendFormat.atEight(BigInt.one, BeamAssetCatalog.display(0, null)),
      isNull,
    );
    expect(
      BeamSendFormat.atEight(BigInt.one, BeamAssetCatalog.display(7031, null)),
      isNull,
    );
  });

  test('two different core reads make an asset\'s decimals unknown', () {
    BeamAssetCatalog.rememberDecimals(7077, 1);
    BeamAssetCatalog.rememberDecimals(7077, 1);
    expect(BeamAssetCatalog.decimalsOf(7077, null), 1);
    BeamAssetCatalog.rememberDecimals(7077, 6);
    expect(BeamAssetCatalog.decimalsOf(7077, null), isNull);
    expect(BeamAssetCatalog.decimalsOf(4, null), 3, reason: 'pinned');
  });

  test('home list amounts and the DEX\'s too-many-decimals message', () {
    expect(
      BeamDashboardModel.shortAmount(BigInt.parse('120375575985'), places: 1),
      '12,037,557,598.5',
    );
    expect(
      BeamDashboardModel.shortAmount(BigInt.from(1234500), places: 3),
      '1,234.5',
    );
    expect(BeamDashboardModel.shortAmount(BigInt.from(150), places: 0), '150');
    expect(
      BeamDashboardModel.shortAmount(BigInt.from(56812972897)),
      '568.1297',
    );
    expect(DexFormat.parse('1.2345', places: 3).error, contains('3'));
    expect(
      DexFormat.parse('1.123456789').error,
      DexFormat.parse('1.123456789', places: 8).error,
    );
  });

  test('airdrop, mint and burn fields, the DEX and name prices', () {
    expect(BeamUnits.parse('2.5', places: 1), BigInt.from(25));
    expect(BeamUnits.parse('2.55', places: 1), isNull);
    expect(BeamUnits.parse('3', places: 0), BigInt.from(3));
    expect(BeamUnits.parse('3', places: null), isNull);
    expect(BeamUnits.plain(BigInt.from(25), places: 1), '2.5');
    expect(BeamUnits.plain(BigInt.from(25), places: null), '');
    expect(
      BeamUnits.format(BigInt.parse('99980001'), places: 12),
      '0.000099980001',
    );
    expect(
      BeamUnits.problem('1', places: null, symbol: 'X #9'),
      contains('X #9'),
    );
    expect(
      DexFormat.parse('0.000099980001', places: 12).value,
      BigInt.parse('99980001'),
    );
    expect(DexFormat.parse('1.25', places: 1).error, isNotNull);
    expect(DexFormat.parse('1', places: null).error, isNotNull);
    expect(
      DexFormat.exact(BigInt.parse('120375575985'), places: 1),
      '12,037,557,598.5',
    );
    expect(DexFormat.compact(BigInt.from(150), places: 0), '150');
    expect(DexFormat.plain(BigInt.one, places: null), '');
    expect(NamesFormat.parse('7.5', places: 1), BigInt.from(75));
    expect(NamesFormat.readable(BigInt.from(1234567), places: 3), '1,234.57');
    expect(NamesFormat.exact(BigInt.from(1234567), places: 3), '1,234.567');
    expect(NamesFormat.readable(BigInt.from(150), places: 0), '150');
  });
}
