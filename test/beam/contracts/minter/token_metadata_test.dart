/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/token_metadata.dart';

Matcher _bad(TokenMetadataField f) =>
    throwsA(isA<TokenMetadataException>().having((e) => e.field, 'field', f));

void main() {
  test('encodes the standard schema in a fixed order', () {
    final m = BeamTokenMetadata(
      name: 'Campfire Coin',
      shortName: 'CFC',
      unitName: 'CFC',
      decimals: 6,
      shortDescription: 'A test token = fun, maybe.',
      color: '#25C2A0',
      siteUrl: 'https://example.org/cfc?x=1',
    );
    expect(
      m.encode(),
      'STD:SCH_VER=1;N=Campfire Coin;SN=CFC;UN=CFC;NTHUN=groth;'
      'NTH_RATIO=1000000;OPT_SHORT_DESC=A test token = fun, maybe.;'
      'OPT_COLOR=#25C2A0;OPT_SITE_URL=https://example.org/cfc?x=1',
    );
    expect(m.nthRatio, BigInt.from(1000000));
    expect(m.supplyOf(BigInt.from(21)), BigInt.from(21000000));
  });

  test('the recorded mainnet build used exactly this text', () {
    final m = BeamTokenMetadata(
      name: 'Campfire build check',
      shortName: 'CFBC',
      unitName: 'CFBC',
      shortDescription: 'Built and decoded by a test, never sent.',
    );
    expect(
      m.encode(),
      'STD:SCH_VER=1;N=Campfire build check;SN=CFBC;UN=CFBC;NTHUN=groth;'
      'NTH_RATIO=100000000;OPT_SHORT_DESC=Built and decoded by a test, '
      'never sent.',
    );
  });

  group('refuses what the core would not read as standard', () {
    test('short name over 6 (LightWallet allowed 16)', () {
      expect(
        () => BeamTokenMetadata(name: 'A', shortName: 'SEVENCH', unitName: 'A'),
        _bad(TokenMetadataField.shortName),
      );
      BeamTokenMetadata(name: 'A', shortName: 'SIXCHR', unitName: 'A');
    });

    test('characters outside letters, digits, space and . , - _', () {
      for (final bad in [
        'Bad;Name',
        'Bad=Name',
        'Bad"Name',
        'Ünïcode',
        'a/b',
      ]) {
        expect(
          () => BeamTokenMetadata(name: bad, shortName: 'B', unitName: 'B'),
          _bad(TokenMetadataField.name),
          reason: bad,
        );
      }
      BeamTokenMetadata(
        name: 'Ok name, v1.0 - _',
        shortName: 'B',
        unitName: 'B',
      );
    });

    test('empty or padded required fields', () {
      expect(
        () => BeamTokenMetadata(name: '', shortName: 'B', unitName: 'B'),
        _bad(TokenMetadataField.name),
      );
      expect(
        () => BeamTokenMetadata(name: 'A', shortName: ' B', unitName: 'B'),
        _bad(TokenMetadataField.shortName),
      );
      expect(
        () => BeamTokenMetadata(
          name: 'A',
          shortName: 'B',
          unitName: 'B',
          nthUnitName: '',
        ),
        _bad(TokenMetadataField.nthUnitName),
      );
      expect(
        () => BeamTokenMetadata(name: 'A' * 65, shortName: 'B', unitName: 'B'),
        _bad(TokenMetadataField.name),
      );
      expect(
        () =>
            BeamTokenMetadata(name: 'A', shortName: 'B', unitName: 'NINECHARS'),
        _bad(TokenMetadataField.unitName),
      );
    });

    test('descriptions: ; " \\ and line breaks, and the byte limits', () {
      for (final bad in ['a;b', 'say "hi"', r'back\slash', 'two\nlines', '']) {
        expect(
          () => BeamTokenMetadata(
            name: 'A',
            shortName: 'B',
            unitName: 'B',
            shortDescription: bad,
          ),
          _bad(TokenMetadataField.shortDescription),
          reason: bad,
        );
      }
      BeamTokenMetadata(
        name: 'A',
        shortName: 'B',
        unitName: 'B',
        shortDescription: 'x' * 128,
        longDescription: 'y' * 1024,
      );
      expect(
        () => BeamTokenMetadata(
          name: 'A',
          shortName: 'B',
          unitName: 'B',
          shortDescription: 'x' * 129,
        ),
        _bad(TokenMetadataField.shortDescription),
      );
      // Bytes, not characters: 'é' is two UTF-8 bytes.
      expect(
        () => BeamTokenMetadata(
          name: 'A',
          shortName: 'B',
          unitName: 'B',
          longDescription: 'é' * 513,
        ),
        _bad(TokenMetadataField.longDescription),
      );
    });

    test('colour and links', () {
      for (final c in ['#25c2a0', '#ABC']) {
        BeamTokenMetadata(name: 'A', shortName: 'B', unitName: 'B', color: c);
      }
      for (final c in ['25c2a0', '#25c2a', '#ggg', 'red']) {
        expect(
          () => BeamTokenMetadata(
            name: 'A',
            shortName: 'B',
            unitName: 'B',
            color: c,
          ),
          _bad(TokenMetadataField.color),
          reason: c,
        );
      }
      for (final u in [
        'ftp://x',
        'https://a b',
        'https://a;b',
        'javascript:alert(1)',
      ]) {
        expect(
          () => BeamTokenMetadata(
            name: 'A',
            shortName: 'B',
            unitName: 'B',
            logoUrl: u,
          ),
          _bad(TokenMetadataField.logoUrl),
          reason: u,
        );
      }
    });

    test('decimals 0 to 8', () {
      expect(
        BeamTokenMetadata(
          name: 'A',
          shortName: 'B',
          unitName: 'B',
          decimals: 0,
        ).encode(),
        contains(';NTH_RATIO=1'),
      );
      expect(
        () => BeamTokenMetadata(
          name: 'A',
          shortName: 'B',
          unitName: 'B',
          decimals: 9,
        ),
        _bad(TokenMetadataField.decimals),
      );
    });
  });

  group('reading chain metadata (untrusted)', () {
    const cto =
        'STD:SCH_VER=1;N=CTO;UN=CTO;SN=CTO;NTHUN=groth;NTH_RATIO=100000000;'
        'OPT_SHORT_DESC=CTO';

    test('splits like the core', () {
      final f = BeamTokenMetadata.parseFields(cto)!;
      expect(f['N'], 'CTO');
      expect(f['NTH_RATIO'], '100000000');
      expect(BeamTokenMetadata.parseFields('STD:A=b=c;;novalue')!, {
        'A': 'b=c',
      });
      expect(BeamTokenMetadata.parseFields('not standard'), isNull);
    });

    test('decimals only from an exact power of ten', () {
      expect(BeamTokenMetadata.decimalsOf(cto), 8);
      expect(BeamTokenMetadata.decimalsOf('STD:NTH_RATIO=1'), 0);
      expect(BeamTokenMetadata.decimalsOf('STD:NTH_RATIO=1000'), 3);
      for (final r in ['0', '25', '010', '1e8', '']) {
        expect(BeamTokenMetadata.decimalsOf('STD:NTH_RATIO=$r'), isNull);
      }
      expect(BeamTokenMetadata.decimalsOf('STD:N=X'), isNull);
    });
  });
}
