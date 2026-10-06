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
    final pubspec = File(
      'scripts/app_config/templates/pubspec.template.yaml',
    ).readAsStringSync();
    final block = pubspec.substring(
      pubspec.lastIndexOf('# %%ENABLE_BEAM%%'),
      pubspec.lastIndexOf('# %%END_ENABLE_BEAM%%'),
    );
    expect(block, contains('#    - assets/beam/icons/'));
  });

  test('an unverified asset takes its on-chain name, with no icon', () {
    final d = BeamAssetCatalog.display(
      777,
      _meta('N=Moon Rocket;SN=MOON;UN=MOON;NTHUN=m'),
    );
    expect(d.verified, isFalse);
    expect(d.name, 'Moon Rocket');
    expect(d.symbol, 'MOON');
    expect(d.icon, isNull);
    expect(d.color, isNull);
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
}
