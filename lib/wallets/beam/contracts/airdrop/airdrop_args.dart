/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'airdrop_constants.dart';
import 'voucher_blob.dart';

/// `args` strings for the pinned Airdrop app shader. Pure functions; every
/// input is validated so nothing the shader would misread is sent.
///
/// Roles and actions are the ones the pinned shader exports (its `Method_1`
/// dispatch): `view`, `view_stats`, `view_fees` and `withdraw_fees` are
/// `role=manager`; everything else is `role=user`. A wrong role is answered
/// with `invalid action`.
///
/// Numbers are canonical decimals: the core reads them with
/// `strtoull(.., 0)` (a leading zero would mean octal) and blobs as hex.
/// The core's parser keeps the **first** occurrence of a key, so every
/// value is checked here to contain no `,`, `=`, space or quote.
abstract final class AirdropArgs {
  static final _maxU64 = (BigInt.one << 64) - BigInt.one;
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _code = RegExp(r'^[A-Z0-9]{1,64}$');

  /// `create_batch`: lock [vouchers] (their values plus the 1% fee) of
  /// [assetId]. The creator key is derived by the shader from this
  /// wallet's master key and the contract id; it must match
  /// [getMyKey]'s.
  static String createBatch({
    required int assetId,
    required List<AirdropVoucherEntry> vouchers,
    String cid = kAirdropContractId,
  }) => _join('user', 'create_batch', cid, {
    'asset_id': _assetId(assetId),
    'count': '${vouchers.length}',
    'vouchers': AirdropVoucherBlob.encode(vouchers),
  });

  /// `redeem`: claim a voucher with its **normalised code** (the preimage).
  /// Never the hash: the contract hashes the preimage itself, which is what
  /// stops anyone reading contract state from redeeming.
  static String redeem({
    required String normalisedCode,
    String cid = kAirdropContractId,
  }) {
    if (!_code.hasMatch(normalisedCode)) {
      throw ArgumentError.value(
        '<${normalisedCode.length} chars>',
        'normalisedCode',
        '1 to 64 of A-Z and 0-9 (normalise it first)',
      );
    }
    return _join('user', 'redeem', cid, {'code': normalisedCode});
  }

  /// `check_voucher`: a voucher's state by the hash of its code.
  /// `{"voucher": {batch_id, asset_id, value, redeemed, redeemer?,
  /// redeemed_at?}}`, or the error `Voucher not found`.
  static String checkVoucher({
    required String hashHex,
    String cid = kAirdropContractId,
  }) => _join('user', 'check_voucher', cid, {'hash': _hash(hashHex)});

  /// `view_my_batches`: batches this wallet created that still exist.
  /// `{"batches": [{id, asset_id, value_per_voucher, total_count,
  /// redeemed_count, created_at}]}`.
  static String viewMyBatches({String cid = kAirdropContractId}) =>
      _join('user', 'view_my_batches', cid, const {});

  /// `view_batch_vouchers`: every voucher of one of this wallet's batches.
  /// `{"vouchers": [{hash, value, redeemed, redeemer?, redeemed_at?}]}`.
  static String viewBatchVouchers({
    required BigInt batchId,
    String cid = kAirdropContractId,
  }) => _join('user', 'view_batch_vouchers', cid, {
    'batch_id': _u64(batchId, 'batchId'),
  });

  /// `cancel_batch`: take back every unclaimed voucher of [batchId]. The
  /// shader lists the unclaimed hashes from chain state itself.
  static String cancelBatch({
    required BigInt batchId,
    String cid = kAirdropContractId,
  }) => _join('user', 'cancel_batch', cid, {
    'batch_id': _u64(batchId, 'batchId'),
  });

  /// `get_my_key`: this wallet's key for the contract, `{"pk": hex}`.
  static String getMyKey({String cid = kAirdropContractId}) =>
      _join('user', 'get_my_key', cid, const {});

  /// `view` (manager): settings, totals and `is_owner`.
  static String view({String cid = kAirdropContractId}) =>
      _join('manager', 'view', cid, const {});

  /// `view_stats` (manager role, but anyone may call it): contract totals.
  static String viewStats({String cid = kAirdropContractId}) =>
      _join('manager', 'view_stats', cid, const {});

  /// `view_fees` (manager): per-asset creation fees collected.
  static String viewFees({String cid = kAirdropContractId}) =>
      _join('manager', 'view_fees', cid, const {});

  /// `withdraw_fees` (manager, owner only): withdraw collected fees.
  static String withdrawFees({
    required int assetId,
    required BigInt amount,
    String cid = kAirdropContractId,
  }) {
    if (amount <= BigInt.zero) {
      throw ArgumentError.value(amount, 'amount', 'must be positive');
    }
    return _join('manager', 'withdraw_fees', cid, {
      'asset_id': _assetId(assetId),
      'amount': _u64(amount, 'amount'),
    });
  }

  // ---------------------------------------------------------------- helpers

  static String _join(
    String role,
    String action,
    String cid,
    Map<String, String> p,
  ) {
    checkContractId(cid);
    return [
      'role=$role',
      'action=$action',
      'cid=$cid',
      for (final e in p.entries) '${e.key}=${e.value}',
    ].join(',');
  }

  /// Refuses anything but 64 lowercase hex characters, and the dead
  /// contracts in [kAirdropDeadContractIds].
  static void checkContractId(String cid) {
    if (!_hex64.hasMatch(cid)) {
      throw ArgumentError.value(cid, 'cid', '64 lowercase hex chars');
    }
    if (kAirdropDeadContractIds.contains(cid)) {
      throw ArgumentError.value(
        cid,
        'cid',
        'the dead v3 Airdrop contract; its ABI does not match the shader',
      );
    }
  }

  static String _hash(String h) {
    if (!_hex64.hasMatch(h)) {
      throw ArgumentError.value(h, 'hashHex', '64 lowercase hex chars');
    }
    return h;
  }

  static String _assetId(int id) {
    if (id < 0 || id > 0xffffffff) {
      throw ArgumentError.value(id, 'assetId', 'asset ids are 0..2^32-1');
    }
    return '$id';
  }

  static String _u64(BigInt v, String name) {
    if (v.isNegative || v > _maxU64) {
      throw ArgumentError.value(v, name, 'not a 64-bit unsigned number');
    }
    return v.toString();
  }
}
