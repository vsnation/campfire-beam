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
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
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

  group('copycats however they are spelt (M-3)', () {
    int? copies(String fields) =>
        BeamAssetCatalog.display(999, _meta(fields)).impersonates;

    test('look-alike letters of other scripts, accents and overlays', () {
      expect(
        copies('N=F\u041E\u041C\u041E;UN=F\u041E\u041C\u041E'),
        174,
        reason: 'Cyrillic О and М',
      );
      expect(
        copies('N=\u0392\u0395\u0391\u039C;UN=X'),
        0,
        reason: 'Greek capitals',
      );
      expect(
        copies('N=Pepe;UN=\uFF26\uFF2F\uFF2D\uFF2F'),
        174,
        reason: 'fullwidth',
      );
      expect(
        copies('N=\u{1D405}\u{1D40E}\u{1D40C}\u{1D40E};UN=X'),
        174,
        reason: 'mathematical bold',
      );
      expect(copies('N=F\u00D6M\u00D6;UN=X'), 174, reason: 'accents');
      expect(
        copies('N=F\u0336O\u0336M\u0336O;UN=X'),
        174,
        reason: 'combining overlays',
      );
      expect(copies('N=\u13DFhad;UN=X'), 187, reason: 'Cherokee C');
      expect(copies('N=Pepe;UN=F.O.M.O'), 174, reason: 'punctuation');
    });

    test('digits and letters that stand for each other', () {
      expect(copies('N=Pepe;UN=F0MO'), 174);
      expect(copies('N=Pepe;UN=F0M0'), 174);
      expect(copies('N=G1GA;UN=X'), 186);
      expect(copies('N=Pepe;UN=TlCO'), 9, reason: 'lower-case L for I');
      expect(copies('N=Pepe;UN=FORNO'), 174, reason: 'rn for m');
    });

    test('near misses: an extra, missing or swapped letter, a filler word', () {
      expect(copies('N=Pepe;UN=wFOMO'), 174);
      expect(copies('N=Pepe;UN=FOMO2'), 174);
      expect(copies('N=FOOMO;UN=X'), 174);
      expect(copies('N=FMOO;UN=X'), 174);
      expect(copies('N=Gothic Crwn;UN=X'), 4);
      expect(copies('N=Official FOMO Token;UN=X'), 174);
      expect(copies('N=Giga Inu;UN=X'), 186);
      // The longest match wins: BEAMX2 copies BeamX, not BEAM.
      expect(copies('N=Pepe;UN=BEAMX2'), 7);
    });

    test('a borrowed "#174" is caught and never shown', () {
      final d = BeamAssetCatalog.display(999, _meta('N=Pepe #174;UN=PEPE'));
      expect(d.impersonates, 174);
      expect(d.name, 'Pepe');
      expect(
        BeamAssetCatalog.display(
          999,
          _meta('N=Pepe \uFF03\uFF11\uFF17\uFF14;UN=P#7'),
        ),
        isA<BeamAssetDisplay>()
            .having((d) => d.impersonates, 'impersonates', 174)
            .having((d) => d.name.contains('\uFF03'), 'fullwidth #', isFalse)
            .having((d) => d.symbol, 'symbol', 'P'),
      );
      // A number that is not a verified asset's is still not shown.
      final other = BeamAssetCatalog.display(
        998,
        _meta('N=Moon #12345;UN=MOON'),
      );
      expect(other.name, 'Moon');
      expect(other.impersonates, isNull);
    });

    test('different words are not copies (recorded mainnet names)', () {
      for (final f in [
        'N=Beatcoin;UN=Beat',
        'N=Bean;UN=BEAN',
        'N=Moon Rocket;UN=MOON',
        'N=BeamBots Token;UN=BB',
        'N=Pepe Coin;UN=PEPE',
        'N=Kekz Token;UN=Kek',
        'N=Litecoin',
        'N=Celtic Circle Coin;UN=Celtic Coin',
        'N=Native Dollar;UN=Native Dollar',
        'N=Amm Liquidity Token 0-174-2;UN=AMML',
        'N=Scorpia;UN=Scorpia',
        'N=Dogenero;UN=doggy',
        'N=CANDY;UN=CANDY',
        'N=Tether;UN=USD Tether',
      ]) {
        expect(copies(f), isNull, reason: f);
      }
    });

    test('a cached row is cleaned and checked again on refresh', () {
      // As an older version cached it: the borrowed "#174" kept, the
      // Cyrillic copy not flagged.
      final old = BeamAssetContract(
        address: BeamAssetContract.addressFor(999),
        assetId: 999,
        name: 'F\u041E\u041C\u041E #174',
        symbol: 'F\u041E\u041C\u041E',
        decimals: 8,
        verified: false,
        metadataKnown: true,
        iconAsset: BeamAssetCatalog.genericIcon(999),
        color: BeamAssetCatalog.genericColor(999),
      );
      final fresh = BeamAssetRegistry.refreshLook(old);
      expect(fresh.impersonates, 174);
      expect(fresh.name, 'F\u041E\u041C\u041E');
      // Placeholders stay as they are.
      final unnamed = BeamAssetRegistry.refreshLook(
        BeamAssetRegistry.build(557),
      );
      expect(unnamed.name, 'Asset #557');
      expect(unnamed.symbol, '#557');
      expect(unnamed.impersonates, isNull);
    });
  });

  group('names are text, not layout (M-3, L-13)', () {
    test('invisible, direction and layout characters are dropped', () {
      final d = BeamAssetCatalog.display(
        555,
        _meta(
          'N=A\u061CB\u2028C\u2060D\u00ADE\u034FF\u3164G\u{E0041}H'
          '\u2800I\uFE0FJ;UN=X',
        ),
      );
      expect(d.name, 'ABCDEFGHIJ');
    });

    test('combining marks are capped per character', () {
      final d = BeamAssetCatalog.display(
        556,
        _meta('N=Z${'\u0301' * 30}a;UN=X'),
      );
      expect(d.name, 'Z\u0301\u0301a');
    });

    test('a cut never splits a character', () {
      final d = BeamAssetCatalog.display(557, _meta('N=${'🚀' * 40};UN=X'));
      expect(d.name, '${'🚀' * 31}…');
    });

    test('runs of spaces read as one', () {
      final d = BeamAssetCatalog.display(
        558,
        _meta('N=Moon\u00A0\u2003  Rocket;UN=X'),
      );
      expect(d.name, 'Moon Rocket');
    });
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

    test('no unverified asset or pool share wears verified RFC\'s icon '
        '(L-12)', () {
      final rfc = BeamAssetCatalog.display(6, null).icon;
      expect(rfc, 'assets/beam/icons/generic/asset-6.svg');
      for (final id in [26, 46, 206, 1006]) {
        expect(
          BeamAssetCatalog.display(id, null).icon,
          isNot(rfc),
          reason: '#$id',
        );
        expect(BeamAssetCatalog.unverifiedIcon(id), isNot(rfc), reason: '#$id');
      }
      // Ids that do not collide keep the desktop wallet's icon.
      expect(
        BeamAssetCatalog.unverifiedIcon(555),
        BeamAssetCatalog.genericIcon(555),
      );
    });

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
