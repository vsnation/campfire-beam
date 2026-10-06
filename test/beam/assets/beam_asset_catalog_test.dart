/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';

BeamAssetMetadata _meta(String fields) =>
    BeamAssetMetadata.parse('STD:SCH_VER=1;$fields');

void main() {
  test('verified assets show Campfire\'s name, ticker, colour and icon', () {
    final d = BeamAssetCatalog.display(174, _meta('N=whatever;UN=X'));
    expect(d.verified, isTrue);
    expect(d.name, 'FOMO');
    expect(d.symbol, 'FOMO');
    expect(d.icon, 'assets/beam/icons/174.png');
    expect(d.impersonates, isNull);
  });

  test('every bundled icon the catalogue names exists', () {
    for (final a in BeamAssetCatalog.verified.values) {
      if (a.icon == null) continue;
      expect(File(a.icon!).existsSync(), isTrue, reason: a.icon);
    }
  });

  test('the icons folder is bundled under the BEAM flag', () {
    final pubspec = File('scripts/app_config/templates/pubspec.template.yaml')
        .readAsStringSync();
    final block = pubspec.substring(
      pubspec.lastIndexOf('# %%ENABLE_BEAM%%'),
      pubspec.lastIndexOf('# %%END_ENABLE_BEAM%%'),
    );
    expect(block, contains('#    - assets/beam/icons/'));
  });

  test('an unverified asset takes its on-chain name, with a generic icon', () {
    final d = BeamAssetCatalog.display(
      777,
      _meta('N=Moon Rocket;SN=MOON;UN=MOON;NTHUN=m'),
    );
    expect(d.verified, isFalse);
    expect(d.name, 'Moon Rocket');
    expect(d.symbol, 'MOON');
    // The desktop wallet's generic icon for its id, never one of its own.
    expect(d.icon, 'assets/beam/icons/generic/asset-${d.assetId % 20}.svg');
    expect(d.color, BeamAssetCatalog.genericColor(777));
    expect(d.idLabel, '#777');
    expect(d.impersonates, isNull);
  });

  test('an unverified copy of a verified ticker is flagged', () {
    expect(
      BeamAssetCatalog.display(999, _meta('N=Fomo Token;UN=FOMO')).impersonates,
      174,
    );
    expect(
      BeamAssetCatalog.display(998, _meta('N=b.e.a.m;UN=B')).impersonates,
      0,
    );
  });

  test('direction and invisible characters are stripped from names', () {
    // U+202E (right-to-left override) can make "MOOF" render as "FOOM".
    final d = BeamAssetCatalog.display(
      555,
      _meta('N=\u202EOMOF\u200B;UN=\u202EOMOF'),
    );
    expect(d.name, 'OMOF');
    expect(d.name.runes.every((r) => r >= 0x20 && r < 0x7f), isTrue);
  });

  test('long names are cut, empty metadata falls back to the id', () {
    final long = BeamAssetCatalog.display(
      556,
      _meta('N=${'A' * 80};UN=LONGTICKER1'),
    );
    expect(long.name.length, 32);
    expect(long.name.endsWith('…'), isTrue);
    expect(long.symbol.length, 8);
    final none = BeamAssetCatalog.display(557, null);
    expect(none.name, 'Asset #557');
    expect(none.symbol, '#557');
    expect(none.verified, isFalse);
  });

  group('generic icons, as in the BEAM desktop wallet', () {
    test('an asset without its own icon gets asset-<id % 20>', () {
      expect(
        BeamAssetCatalog.display(6, null).icon,
        'assets/beam/icons/generic/asset-6.svg',
      );
      expect(
        BeamAssetCatalog.display(1234, null).icon,
        'assets/beam/icons/generic/asset-14.svg',
      );
      expect(
        BeamAssetCatalog.display(20, null).icon,
        BeamAssetCatalog.display(40, null).icon,
      );
    });

    test('BEAM and verified assets keep their own icons', () {
      expect(
        BeamAssetCatalog.display(0, null).icon,
        'assets/beam/icons/beam.svg',
      );
      expect(
        BeamAssetCatalog.display(174, null).icon,
        'assets/beam/icons/174.png',
      );
    });

    test(
      'a look-alike gets its id\'s icon and colour, not the original\'s',
      () {
        final fake = BeamAssetCatalog.display(
          555,
          BeamAssetMetadata.parse(
            'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO;OPT_COLOR=#60A5FA',
          ),
        );
        expect(fake.verified, isFalse);
        expect(fake.impersonates, 174);
        expect(fake.icon, 'assets/beam/icons/generic/asset-15.svg');
        expect(fake.color, BeamAssetCatalog.genericColor(555));
        expect(fake.color, isNot(BeamAssetCatalog.verified[174]!.color));
      },
    );

    test('all 20 generic icons and the missing-asset icon are bundled', () {
      for (var i = 0; i < BeamAssetCatalog.genericIconCount; i++) {
        final path = BeamAssetCatalog.genericIcon(i);
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      expect(File(BeamAssetCatalog.missingIcon).existsSync(), isTrue);
      expect(File('assets/beam/icons/generic/NOTICE.txt').existsSync(), isTrue);
    });
  });
}
