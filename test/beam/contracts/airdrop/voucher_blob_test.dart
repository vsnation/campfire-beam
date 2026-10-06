/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';

import 'airdrop_fixtures.dart';

void main() {
  const g = BigInt.from;
  final h1 = 'ab' * 32;
  final h2 = '01' * 32;

  group('creation fee, against the C++ statements', () {
    test('every vector from tool/fee_vectors.cpp matches', () {
      final json = jsonDecode(
        File('$airdropFixtureDir/fee_vectors.json').readAsStringSync(),
      ) as Map;
      final vectors = json['vectors']! as List;
      expect(vectors, hasLength(27));
      for (final v in vectors) {
        final pair = v as List;
        final total = BigInt.parse(pair[0] as String);
        expect(
          AirdropFee.creationFee(total),
          BigInt.parse(pair[1] as String),
          reason: 'total $total',
        );
      }
    });

    test('1% floored, never below 1 groth', () {
      expect(AirdropFee.creationFee(g(1)), g(1));
      expect(AirdropFee.creationFee(g(199)), g(1));
      expect(AirdropFee.creationFee(g(200000)), g(2000));
      expect(AirdropFee.creationFee(BigInt.zero), BigInt.zero);
    });

    test('maxTotal is where the uint64 product starts to wrap', () {
      final max = AirdropFee.maxTotal;
      expect(max * g(100) <= (BigInt.one << 64) - BigInt.one, isTrue);
      expect((max + BigInt.one) * g(100) >= BigInt.one << 64, isTrue);
      // The C++ wraps to a tiny "1%" just above it.
      expect(AirdropFee.creationFee(max + BigInt.one), g(1));
    });

    test('refuses a value outside 64 bits', () {
      expect(() => AirdropFee.creationFee(g(-1)), throwsArgumentError);
      expect(
        () => AirdropFee.creationFee(BigInt.one << 64),
        throwsArgumentError,
      );
    });
  });

  group('voucher blob', () {
    test('each entry is the 32-byte hash then the 8-byte LE value', () {
      final hex = AirdropVoucherBlob.encode([
        AirdropVoucherEntry(h1, g(100000)),
        AirdropVoucherEntry(h2, g(0x0102030405060708)),
      ]);
      expect(hex, '${h1}a086010000000000${h2}0807060504030201');
      expect(hex.length, 2 * 80);
    });

    test('decode reads back what encode wrote', () {
      final entries = [
        AirdropVoucherEntry(h1, g(1)),
        AirdropVoucherEntry(h2, AirdropFee.maxTotal - g(1)),
      ];
      expect(
        AirdropVoucherBlob.decode(AirdropVoucherBlob.bytes(entries)),
        entries,
      );
      // A full 64-bit value decodes too (the blob itself allows it).
      final max = (BigInt.one << 64) - BigInt.one;
      expect(
        AirdropVoucherBlob.decode([
          ...List.filled(32, 0xab),
          ...List.filled(8, 0xff),
        ]),
        [AirdropVoucherEntry(h1, max)],
      );
      expect(
        () => AirdropVoucherBlob.decode(List.filled(41, 0)),
        throwsFormatException,
      );
    });

    test('refuses an empty, an oversized or a repeating batch', () {
      expect(() => AirdropVoucherBlob.bytes([]), throwsArgumentError);
      final many = [
        for (var i = 0; i < 101; i++)
          AirdropVoucherEntry(i.toRadixString(16).padLeft(64, '0'), g(1)),
      ];
      expect(() => AirdropVoucherBlob.bytes(many), throwsArgumentError);
      expect(AirdropVoucherBlob.bytes(many.sublist(0, 100)), hasLength(4000));
      expect(
        () => AirdropVoucherBlob.bytes([
          AirdropVoucherEntry(h1, g(1)),
          AirdropVoucherEntry(h1, g(2)),
        ]),
        throwsArgumentError,
      );
    });

    test('refuses a total whose fee would overflow in the contract', () {
      final half = AirdropFee.maxTotal ~/ g(2) + g(1);
      expect(
        () => AirdropVoucherBlob.bytes([
          AirdropVoucherEntry(h1, half),
          AirdropVoucherEntry(h2, half),
        ]),
        throwsArgumentError,
      );
    });

    test('refuses a zero value and a malformed hash', () {
      expect(() => AirdropVoucherEntry(h1, BigInt.zero), throwsArgumentError);
      expect(() => AirdropVoucherEntry('AB' * 32, g(1)), throwsArgumentError);
      expect(() => AirdropVoucherEntry('ab' * 31, g(1)), throwsArgumentError);
    });
  });

  group('the recorded create_batch raw_data (mainnet, never sent)', () {
    test('decodes to one Airdrop CreateBatch of 2 x 0.001 BEAM', () {
      final d = BeamInvokeData.decode(airdropRaw('create_batch_2x0.001'));
      final e = d.entries.single;
      expect(e.contractId, kAirdropContractId);
      expect(e.method, AirdropMethod.createBatch);
      expect(e.charge, AirdropCharge.createBatch);
      expect(e.comment, AirdropKernelComment.createBatch);
      expect(e.signatureCount, 1);
      expect(e.args.length, 41 + 2 * 40);
      // PubKey33 (the synthetic key) | AssetID 0 | count 2 | 2 entries.
      expect(e.args.sublist(0, 33), [...List.filled(32, 0x5a), 0]);
      expect(e.args.sublist(33, 41), [0, 0, 0, 0, 2, 0, 0, 0]);
      final entries = AirdropVoucherBlob.decode(e.args.sublist(41));
      expect(entries.map((x) => x.value), [g(100000), g(100000)]);
      expect(d.spend, {0: g(202000)});
      expect(d.pays, {0: g(202000)});
      expect(d.fee, g(12100000));
      expect(d.fee, kAirdropCallFee);
    });
  });
}
