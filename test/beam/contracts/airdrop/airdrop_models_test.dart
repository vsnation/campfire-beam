/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';

import 'airdrop_fixtures.dart';

void main() {
  const g = BigInt.from;

  test('view_stats (recorded)', () {
    final s = AirdropStats.fromOutput(
      ShaderOutput.decode(airdropOutput('view_stats')),
    );
    expect(s.totalBatches, g(13));
    expect(s.totalVouchers, g(69));
    expect(s.totalRedeemed, g(23));
    expect(s.availableVouchers, g(46));
    expect(s.totalFeesCollected, g(537520000));
    expect(s.feesAvailable, s.totalFeesCollected - s.totalFeesWithdrawn);
  });

  test('view (recorded, owner key synthetic)', () {
    final s = AirdropSettings.fromOutput(
      ShaderOutput.decode(airdropOutput('view')),
    );
    expect(s.version, 3);
    expect(s.paused, isFalse);
    expect(s.isOwner, isTrue);
    expect(s.ownerKey, fakeOwnerKey);
  });

  test('view_fees (recorded)', () {
    final f = AirdropFeePool.listFromOutput(
      ShaderOutput.decode(airdropOutput('view_fees')),
    );
    expect(f.map((x) => x.assetId), [0, 174]);
    expect(f.first.accumulated, g(34000000));
    expect(f.first.available, g(34000000));
    expect(f.last.accumulated, g(503520000));
  });

  test('check_voucher on an unknown code is an error the service maps', () {
    expect(
      () => ShaderOutput.decode(airdropOutput('check_voucher_not_found')),
      throwsA(
        isA<BeamShaderException>().having(
          (e) => e.message,
          'message',
          'Voucher not found',
        ),
      ),
    );
    expect(
      BeamAirdropService.codeFor('Voucher not found'),
      AirdropErrorCode.voucherNotFound,
    );
    expect(
      BeamAirdropService.codeFor('Voucher already redeemed'),
      AirdropErrorCode.alreadyRedeemed,
    );
    expect(
      BeamAirdropService.codeFor('Not contract owner'),
      AirdropErrorCode.notOwner,
    );
    expect(
      BeamAirdropService.codeFor('something new'),
      AirdropErrorCode.shaderError,
    );
  });

  test('check_voucher of a redeemed voucher', () {
    final out = ShaderOutput.decode(
      jsonEncode({
        'voucher': {
          'batch_id': 4,
          'asset_id': 174,
          'value': 1000000,
          'redeemed': 1,
          'redeemer': fakeKey,
          'redeemed_at': 4000123,
        },
      }),
    );
    final v = AirdropVoucherInfo.fromOutput(out, 'ab' * 32);
    expect(v.batchId, g(4));
    expect(v.assetId, 174);
    expect(v.value, g(1000000));
    expect(v.redeemed, isTrue);
    expect(v.redeemerKey, fakeKey);
    expect(v.redeemedAtHeight, g(4000123));
  });

  test('view_my_batches rows', () {
    final b = AirdropBatch.listFromOutput(
      ShaderOutput.decode(
        '{"batches": [{"id": 21,"asset_id": 174,"value_per_voucher": '
        '1000000,"total_count": 3,"redeemed_count": 2,"created_at": '
        '4000000}]}',
      ),
    );
    expect(b.single.id, g(21));
    expect(b.single.unclaimedCount, 1);
    expect(
      () => AirdropBatch.fromJson(
        ShaderOutput.decode(
          '{"id": 1,"asset_id": 0,"value_per_voucher": 1,"total_count": 1,'
          '"redeemed_count": 2,"created_at": 1}',
        ),
      ),
      throwsFormatException,
    );
  });

  test('view_batch_vouchers rows', () {
    final v = AirdropBatchVoucher.listFromOutput(
      ShaderOutput.decode(
        jsonEncode({
          'vouchers': [
            {'hash': 'cd' * 32, 'value': 7, 'redeemed': 0},
          ],
        }),
      ),
    );
    expect(v.single.hashHex, 'cd' * 32);
    expect(v.single.redeemed, isFalse);
    expect(
      () => AirdropBatchVoucher.fromJson({
        'hash': 'xyz',
        'value': BigInt.one,
        'redeemed': BigInt.zero,
      }),
      throwsFormatException,
    );
  });
}
