/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Recorded answers from mainnet (2026-10-06, height 4068189, the pinned
// Airdrop shader, invoke_contract with create_tx: false only; nothing was
// broadcast), and a fake app shader that answers the way the real one does.
//
// Sanitized: this wallet's contract key is the synthetic [fakeKey] inside
// create_batch_2x0.001.json, and the contract owner's key in view.json is
// the synthetic [fakeOwnerKey]. view_stats and view_fees are contract-wide
// public totals. view_my_batches is not recorded (it would link the
// recording wallet to its batches); the fake builds its own.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';

import 'invoke_data_writer.dart';

const airdropFixtureDir = 'test/beam/contracts/airdrop/fixtures';

const fakeKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';
const fakeOwnerKey =
    '5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b00';

Map<String, Object?> airdropResult(String name) =>
    ((jsonDecode(File('$airdropFixtureDir/$name.json').readAsStringSync())
                as Map)['result']!
            as Map)
        .cast<String, Object?>();

String airdropOutput(String name) => airdropResult(name)['output']! as String;

List<int> airdropRaw(String name) => [
  for (final b in airdropResult(name)['raw_data']! as List) b as int,
];

/// SHA-256("bvm.m.key\0" || cid || 00): the key preimage hash the Airdrop
/// shader's `MyAccountID{cid, 0}` produces, as in the recorded raw_data.
List<int> airdropSigHash([String cid = kAirdropContractId]) =>
    crypto.sha256.convert([
      ...'bvm.m.key'.codeUnits,
      0,
      ...InvokeDataWriter.hexBytes(cid),
      0,
    ]).bytes;

class FakeVoucher {
  FakeVoucher(this.batchId, this.assetId, this.value, {this.redeemed = false});

  final BigInt batchId;
  final int assetId;
  final BigInt value;
  bool redeemed;
}

/// Answers `invoke_contract` like the pinned Airdrop app shader, from an
/// in-memory contract state, so the service runs end to end.
class FakeAirdropShader {
  FakeAirdropShader({this.myKey = fakeKey, this.cid = kAirdropContractId});

  final String myKey;
  final String cid;

  /// Vouchers by code hash.
  final vouchers = <String, FakeVoucher>{};

  /// Batches of this wallet: id → asset.
  final myBatches = <BigInt, int>{};

  /// Every `args` seen.
  final seen = <String>[];

  /// Applied to each built entry before it is serialized: lets a test
  /// return a transaction that differs from the request.
  FakeInvokeEntry Function(FakeInvokeEntry e)? tamper;

  /// Added to a view's answer, to test that views refuse raw_data.
  bool viewsReturnRawData = false;

  Map<String, Object?> call(Map<String, Object?> params) {
    if (params['create_tx'] != false) {
      throw StateError('create_tx must be false');
    }
    final contract = params['contract'];
    if (contract is! List || contract.isEmpty) throw StateError('no shader');
    final args = params['args']! as String;
    seen.add(args);
    final a = parseArgs(args);
    if (a['cid'] != cid) return _out({'error': 'Contract not found'});
    switch ((a['role'], a['action'])) {
      case ('user', 'get_my_key'):
        return _out({'pk': myKey});
      case ('user', 'check_voucher'):
        final v = vouchers[a['hash']];
        if (v == null) return _out({'error': 'Voucher not found'});
        return _out({
          'voucher': {
            'batch_id': v.batchId.toInt(),
            'asset_id': v.assetId,
            'value': v.value.toInt(),
            'redeemed': v.redeemed ? 1 : 0,
            if (v.redeemed) 'redeemer': fakeOwnerKey,
            if (v.redeemed) 'redeemed_at': 4000000,
          },
        });
      case ('user', 'view_my_batches'):
        return _out({
          'batches': [
            for (final b in myBatches.entries)
              {
                'id': b.key.toInt(),
                'asset_id': b.value,
                'value_per_voucher': _ofBatch(b.key).first.value.toInt(),
                'total_count': _ofBatch(b.key).length,
                'redeemed_count': _ofBatch(b.key)
                    .where((v) => v.redeemed)
                    .length,
                'created_at': 4000000,
              },
          ],
        });
      case ('user', 'view_batch_vouchers'):
        final id = BigInt.parse(a['batch_id']!);
        if (!myBatches.containsKey(id)) {
          return _out({'error': 'Batch not found'});
        }
        return _out({
          'vouchers': [
            for (final e in vouchers.entries)
              if (e.value.batchId == id)
                {
                  'hash': e.key,
                  'value': e.value.value.toInt(),
                  'redeemed': e.value.redeemed ? 1 : 0,
                  if (e.value.redeemed) 'redeemer': fakeOwnerKey,
                  if (e.value.redeemed) 'redeemed_at': 4000000,
                },
          ],
        });
      case ('manager', 'view'):
        return {'output': airdropOutput('view')};
      case ('manager', 'view_stats'):
        return {'output': airdropOutput('view_stats')};
      case ('manager', 'view_fees'):
        return {'output': airdropOutput('view_fees')};
      case ('user', 'create_batch'):
        final aid = int.parse(a['asset_id']!);
        final count = int.parse(a['count']!);
        final blob = InvokeDataWriter.hexBytes(a['vouchers']!);
        final entries = AirdropVoucherBlob.decode(blob.sublist(0, 40 * count));
        final total = AirdropVoucherBlob.total(entries);
        return _built(
          AirdropMethod.createBatch,
          [
            ...InvokeDataWriter.hexBytes(myKey),
            ...InvokeDataWriter.le(BigInt.from(aid), 4),
            ...InvokeDataWriter.le(BigInt.from(count), 4),
            ...blob.sublist(0, 40 * count),
          ],
          {aid: total + AirdropFee.creationFee(total)},
          AirdropKernelComment.createBatch,
          AirdropCharge.createBatch,
        );
      case ('user', 'redeem'):
        final code = a['code']!;
        final hash = AirdropVoucherCode.hashHex(code);
        final v = vouchers[hash];
        if (v == null) return _out({'error': 'Voucher not found'});
        if (v.redeemed) return _out({'error': 'Voucher already redeemed'});
        return _built(
          AirdropMethod.redeem,
          [
            ...InvokeDataWriter.hexBytes(myKey),
            ...InvokeDataWriter.le(BigInt.from(code.length), 4),
            ...ascii.encode(code),
          ],
          {v.assetId: -v.value},
          AirdropKernelComment.redeem,
          AirdropCharge.redeem,
        );
      case ('user', 'cancel_batch'):
        final id = BigInt.parse(a['batch_id']!);
        final aid = myBatches[id];
        if (aid == null) return _out({'error': 'Batch not found'});
        final open = [
          for (final e in vouchers.entries)
            if (e.value.batchId == id && !e.value.redeemed) e,
        ];
        if (open.isEmpty) return _out({'error': 'No unclaimed vouchers'});
        return _built(
          AirdropMethod.cancelBatch,
          [
            ...InvokeDataWriter.hexBytes(myKey),
            ...InvokeDataWriter.le(id, 8),
            ...InvokeDataWriter.le(BigInt.from(open.length), 4),
            for (final e in open) ...InvokeDataWriter.hexBytes(e.key),
          ],
          {aid: -open.fold(BigInt.zero, (s, e) => s + e.value.value)},
          AirdropKernelComment.cancelBatch,
          AirdropCharge.cancelBatch,
        );
      case ('manager', 'withdraw_fees'):
        final aid = int.parse(a['asset_id']!);
        final amount = BigInt.parse(a['amount']!);
        return _built(
          AirdropMethod.withdrawFees,
          [
            ...InvokeDataWriter.hexBytes(fakeOwnerKey),
            ...InvokeDataWriter.le(BigInt.from(aid), 4),
            ...InvokeDataWriter.le(amount, 8),
          ],
          {aid: -amount},
          AirdropKernelComment.withdrawFees,
          AirdropCharge.withdrawFees,
        );
    }
    return _out({'error': 'invalid action'});
  }

  /// Adds the vouchers of a confirmed batch to the fake contract.
  void addBatch(BigInt id, int assetId, Map<String, BigInt> hashToValue) {
    myBatches[id] = assetId;
    for (final e in hashToValue.entries) {
      vouchers[e.key] = FakeVoucher(id, assetId, e.value);
    }
  }

  List<FakeVoucher> _ofBatch(BigInt id) => [
    for (final v in vouchers.values)
      if (v.batchId == id) v,
  ];

  Map<String, Object?> _out(Map<String, Object?> json) => {
    'output': jsonEncode(json),
    if (viewsReturnRawData) 'raw_data': [1, 2, 3],
  };

  Map<String, Object?> _built(
    int method,
    List<int> args,
    Map<int, BigInt> funds,
    String comment,
    int charge,
  ) {
    var e = FakeInvokeEntry(
      method: method,
      cid: cid,
      args: args,
      funds: funds,
      comment: comment,
      charge: charge,
      sigs: [airdropSigHash(cid)],
    );
    final t = tamper;
    if (t != null) e = t(e);
    return {
      'output': '{}',
      'raw_data': InvokeDataWriter.write([e]),
      'txid': '00000000000000000000000000000000',
    };
  }
}
