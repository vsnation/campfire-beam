/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';

AirdropSavedBatch _batch({int n = 2, int assetId = 0}) {
  final rng = Random(3);
  return AirdropSavedBatch(
    localId: 'batch_1',
    contractId: kAirdropContractId,
    assetId: assetId,
    createdAt: DateTime.utc(2026, 10, 6, 12),
    codes: [
      for (var i = 0; i < n; i++)
        () {
          final c = AirdropVoucherCode.generate(rng);
          return AirdropSavedCode(
            code: c,
            hashHex: AirdropVoucherCode.hashHex(c),
            value: BigInt.from(100000 * (i + 1)),
          );
        }(),
    ],
  );
}

void main() {
  test('a saved batch survives a JSON round trip exactly', () {
    final b = _batch().copyWith(
      txId: 'ab' * 16,
      txStatus: AirdropBatchTxStatus.broadcast,
    );
    final back = AirdropSavedBatch.fromJson(
      (jsonDecode(jsonEncode(b.toJson())) as Map).cast<String, Object?>(),
    );
    expect(back.toJson(), b.toJson());
    expect(back.total, BigInt.from(300000));
    // Amounts are strings: JSON numbers lose precision above 2^53.
    expect(
      (b.toJson()['codes']! as List).first,
      containsPair('value', '100000'),
    );
  });

  test('a code whose hash does not match is refused, not trusted', () {
    final json = _batch().toJson();
    final codes = (json['codes']! as List).cast<Map<String, Object?>>();
    codes.first['hash'] = '00' * 32;
    expect(() => AirdropSavedBatch.fromJson(json), throwsFormatException);
  });

  test('an unreadable status reads as unconfirmed, never as settled', () {
    final json = _batch().toJson()..['txStatus'] = 'garbage';
    expect(
      AirdropSavedBatch.fromJson(json).txStatus,
      AirdropBatchTxStatus.unconfirmed,
    );
  });

  test('toString never prints a code', () {
    final b = _batch();
    expect(b.toString(), isNot(contains(b.codes.first.code)));
    expect(b.codes.first.toString(), isNot(contains(b.codes.first.code)));
  });

  group('CSV export', () {
    test('LightWallet columns, one row per code', () {
      final b = _batch();
      final csv = AirdropCsv.export(
        b,
        formatValue: (v) => (v.toDouble() / 1e8).toString(),
        assetLabel: 'BEAM',
      );
      final rows = csv.split('\r\n')..removeLast();
      expect(rows.first, 'Number,Code,Value,Asset,Status');
      expect(rows, hasLength(3));
      expect(rows[1], '1,${b.codes[0].code},0.001,BEAM,unknown');
      expect(rows[2], '2,${b.codes[1].code},0.002,BEAM,unknown');
    });

    test('defuses formulas and quotes separators from asset metadata', () {
      expect(AirdropCsv.cell('=HYPERLINK("x")'), '"\'=HYPERLINK(""x"")"');
      expect(AirdropCsv.cell('+1'), "'+1");
      expect(AirdropCsv.cell('-1'), "'-1");
      expect(AirdropCsv.cell('@SUM(A1)'), "'@SUM(A1)");
      expect(AirdropCsv.cell('a,b'), '"a,b"');
      expect(AirdropCsv.cell('line\nbreak'), '"line\nbreak"');
      expect(AirdropCsv.cell('FOMO'), 'FOMO');
      final csv = AirdropCsv.export(
        _batch(n: 1, assetId: 174),
        formatValue: (v) => '$v',
        assetLabel: '=cmd|"/c calc"!A1',
      );
      expect(csv, contains(',"\'=cmd|""/c calc""!A1",'));
    });
  });
}
