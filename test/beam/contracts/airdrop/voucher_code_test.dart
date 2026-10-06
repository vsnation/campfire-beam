/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/voucher_code.dart';

/// Replays fixed bytes, to drive the rejection sampler.
class _Bytes implements Random {
  _Bytes(this.bytes);

  final List<int> bytes;
  var _i = 0;

  @override
  int nextInt(int max) {
    expect(max, 256);
    return bytes[_i++ % bytes.length];
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  group('generate', () {
    test('16 symbols of the alphabet, grouped by 4', () {
      final rng = Random(7);
      for (var i = 0; i < 200; i++) {
        final c = AirdropVoucherCode.generate(rng);
        expect(
          c,
          matches(RegExp(r'^([A-HJ-NP-Z2-9]{4}-){3}[A-HJ-NP-Z2-9]{4}$')),
        );
        expect(AirdropVoucherCode.isWellFormed(c), isTrue);
      }
    });

    test('never contains I, O, 0 or 1', () {
      expect(AirdropVoucherCode.alphabet, hasLength(32));
      for (final ch in ['I', 'O', '0', '1']) {
        expect(AirdropVoucherCode.alphabet.contains(ch), isFalse);
      }
    });

    test('maps each byte to alphabet[byte % 32]', () {
      final c = AirdropVoucherCode.generate(
        _Bytes([0, 1, 31, 32, 33, 255, 224, 8]),
      );
      // 0→A 1→B 31→9 32→A 33→B 255→9 224→A 8→J, repeated.
      expect(c, 'AB9A-B9AJ-AB9A-B9AJ');
    });

    test('Random.secure codes do not repeat', () {
      final seen = <String>{};
      for (var i = 0; i < 2000; i++) {
        expect(seen.add(AirdropVoucherCode.generate()), isTrue);
      }
    });

    test('symbols are close to uniform', () {
      final counts = <String, int>{};
      final rng = Random(42);
      for (var i = 0; i < 2000; i++) {
        for (final ch in AirdropVoucherCode.normalise(
          AirdropVoucherCode.generate(rng),
        ).split('')) {
          counts[ch] = (counts[ch] ?? 0) + 1;
        }
      }
      expect(
        counts.keys.toSet(),
        AirdropVoucherCode.alphabet.split('').toSet(),
      );
      // 32,000 draws, 1,000 expected per symbol.
      for (final n in counts.values) {
        expect(n, inInclusiveRange(850, 1150));
      }
    });
  });

  group('normalise, exactly as the app shader does', () {
    test('upper-cases ASCII and drops everything else', () {
      expect(
        AirdropVoucherCode.normalise('abcd-efgh jklm_npqr'),
        'ABCDEFGHJKLMNPQR',
      );
      expect(AirdropVoucherCode.normalise('  a.b,c  '), 'ABC');
      expect(AirdropVoucherCode.normalise('---'), '');
    });

    test('keeps I, O, 0 and 1: the shader does not map look-alikes', () {
      expect(AirdropVoucherCode.normalise('io01'), 'IO01');
    });

    test('drops non-ASCII letters instead of upper-casing them', () {
      // LightWallet's JS turns 'ß' into 'SS' before stripping; the shader
      // drops both UTF-8 bytes, and so must the port.
      expect(AirdropVoucherCode.normalise('aßb'), 'AB');
      expect(AirdropVoucherCode.normalise('ÄÖÜ'), '');
    });

    test('keeps at most 64 symbols', () {
      expect(AirdropVoucherCode.normalise('a' * 100), 'A' * 64);
    });

    test('format regroups partial input', () {
      expect(AirdropVoucherCode.format('abcdef'), 'ABCD-EF');
      expect(
        AirdropVoucherCode.format('abcd-efgh-jklm-npqr'),
        'ABCD-EFGH-JKLM-NPQR',
      );
      expect(AirdropVoucherCode.format(''), '');
    });

    test('isWellFormed wants 16 alphabet symbols', () {
      expect(AirdropVoucherCode.isWellFormed('abcd-efgh-jklm-npqr'), isTrue);
      expect(AirdropVoucherCode.isWellFormed('abcd-efgh-jklm-npq'), isFalse);
      expect(AirdropVoucherCode.isWellFormed('abcd-efgh-jklm-npq0'), isFalse);
    });
  });

  group('hashHex', () {
    test('is SHA-256 of the normalised ASCII code', () {
      const want =
          '7cf629bb82226bfb6356859edb341b8f36a74d8997c4fe385dbef6dc85c5c4bb';
      expect(AirdropVoucherCode.hashHex('ABCDEFGHJKLMNPQR'), want);
      expect(AirdropVoucherCode.hashHex('abcd-efgh-jklm-npqr'), want);
      expect(AirdropVoucherCode.hashHex(' Abcd efgh\tJKLM-npqr '), want);
      expect(
        AirdropVoucherCode.hashHex('z-9'),
        '43f02fcda5eca7b6d0d9c9b1fe1b75dfb5fca6b667b8fc5be65efb1804ba93c6',
      );
    });

    test('refuses text with nothing to hash', () {
      expect(() => AirdropVoucherCode.hashHex('- -'), throwsArgumentError);
    });
  });
}
