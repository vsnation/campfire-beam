/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';

void main() {
  const g = BigInt.from;
  const cid = kAirdropContractId;

  test('the live CID, not the dead v3 one', () {
    expect(cid, startsWith('8737e0d3'));
    expect(kAirdropDeadContractIds.single, startsWith('00c0dc81'));
    expect(kAirdropGasSupported, isFalse);
  });

  test('user actions', () {
    expect(
      AirdropArgs.viewMyBatches(),
      'role=user,action=view_my_batches,cid=$cid',
    );
    expect(AirdropArgs.getMyKey(), 'role=user,action=get_my_key,cid=$cid');
    expect(
      AirdropArgs.checkVoucher(hashHex: 'ab' * 32),
      'role=user,action=check_voucher,cid=$cid,hash=${'ab' * 32}',
    );
    expect(
      AirdropArgs.cancelBatch(batchId: g(5)),
      'role=user,action=cancel_batch,cid=$cid,batch_id=5',
    );
    expect(
      AirdropArgs.viewBatchVouchers(batchId: g(12)),
      'role=user,action=view_batch_vouchers,cid=$cid,batch_id=12',
    );
  });

  test('view, view_stats, view_fees and withdraw_fees are role=manager', () {
    expect(AirdropArgs.view(), 'role=manager,action=view,cid=$cid');
    expect(AirdropArgs.viewStats(), 'role=manager,action=view_stats,cid=$cid');
    expect(AirdropArgs.viewFees(), 'role=manager,action=view_fees,cid=$cid');
    expect(
      AirdropArgs.withdrawFees(assetId: 174, amount: g(500)),
      'role=manager,action=withdraw_fees,cid=$cid,asset_id=174,amount=500',
    );
    expect(
      () => AirdropArgs.withdrawFees(assetId: 0, amount: BigInt.zero),
      throwsArgumentError,
    );
  });

  test('create_batch carries the count and one hex blob', () {
    final a = AirdropArgs.createBatch(
      assetId: 0,
      vouchers: [
        AirdropVoucherEntry('11' * 32, g(100000)),
        AirdropVoucherEntry('22' * 32, g(100000)),
      ],
    );
    expect(
      a,
      'role=user,action=create_batch,cid=$cid,asset_id=0,count=2,'
      'vouchers=${'11' * 32}a086010000000000${'22' * 32}a086010000000000',
    );
  });

  test('redeem sends the normalised code, never a hash', () {
    final code = AirdropVoucherCode.normalise('abcd-efgh-jklm-npqr');
    expect(
      AirdropArgs.redeem(normalisedCode: code),
      'role=user,action=redeem,cid=$cid,code=ABCDEFGHJKLMNPQR',
    );
    // Dashes, lower case and anything else would be misread or mangled.
    for (final bad in ['ABCD-EFGH', 'abcd', '', 'A' * 65, 'ÄB', 'A,B=C']) {
      expect(
        () => AirdropArgs.redeem(normalisedCode: bad),
        throwsArgumentError,
        reason: bad,
      );
    }
  });

  test('refuses the dead CID and malformed ids', () {
    for (final dead in kAirdropDeadContractIds) {
      expect(() => AirdropArgs.viewStats(cid: dead), throwsArgumentError);
    }
    expect(() => AirdropArgs.viewStats(cid: 'AB' * 32), throwsArgumentError);
    expect(
      () => AirdropArgs.checkVoucher(hashHex: 'ab' * 31),
      throwsArgumentError,
    );
    expect(() => AirdropArgs.cancelBatch(batchId: g(-1)), throwsArgumentError);
    expect(
      () => AirdropArgs.cancelBatch(batchId: BigInt.one << 64),
      throwsArgumentError,
    );
    expect(
      () => AirdropArgs.createBatch(
        assetId: -1,
        vouchers: [AirdropVoucherEntry('11' * 32, g(1))],
      ),
      throwsArgumentError,
    );
  });

  test('the shader pin is the bundled file', () async {
    final bytes = await airdropAppShader(
      const FileShaderSource('assets/beam/shaders'),
    ).load();
    expect(bytes, hasLength(kAirdropAppShaderSize));
    expect(PinnedShader.digestOf(bytes), kAirdropAppShaderSha256);
  });

  test('fees derive from the declared charges', () {
    expect(kAirdropCallFee, g(12100000));
    expect(kAirdropCancelFee, g(18100000));
  });
}
