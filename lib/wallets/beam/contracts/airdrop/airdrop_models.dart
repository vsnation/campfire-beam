/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../common/shader_output.dart';

final _key = RegExp(r'^[0-9a-f]{64}0[01]$');
final _hash = RegExp(r'^[0-9a-f]{64}$');

/// A 33-byte BVM public key as the shader prints it (66 hex, last byte
/// 00 or 01).
String _pubKey(Map<String, Object?> json, String key) {
  final v = ShaderOutput.string(json, key);
  if (!_key.hasMatch(v)) throw FormatException('$key: not a public key');
  return v;
}

String _hashOf(Map<String, Object?> json, String key) {
  final v = ShaderOutput.string(json, key);
  if (!_hash.hasMatch(v)) throw FormatException('$key: not a hash');
  return v;
}

bool _flag(Map<String, Object?> json, String key) {
  final v = ShaderOutput.uint32(json, key);
  if (v > 1) throw FormatException('$key: expected 0 or 1');
  return v == 1;
}

/// A voucher as `check_voucher` prints it.
@immutable
class AirdropVoucherInfo {
  const AirdropVoucherInfo({
    required this.hashHex,
    required this.batchId,
    required this.assetId,
    required this.value,
    required this.redeemed,
    this.redeemerKey,
    this.redeemedAtHeight,
  });

  /// `{"voucher": {...}}` for the voucher whose code hashes to [hashHex].
  factory AirdropVoucherInfo.fromOutput(
    Map<String, Object?> out,
    String hashHex,
  ) {
    final v = ShaderOutput.map(out['voucher'], 'voucher');
    final redeemed = _flag(v, 'redeemed');
    return AirdropVoucherInfo(
      hashHex: hashHex,
      batchId: ShaderOutput.amount(v, 'batch_id'),
      assetId: ShaderOutput.uint32(v, 'asset_id'),
      value: ShaderOutput.amount(v, 'value'),
      redeemed: redeemed,
      redeemerKey: redeemed ? _pubKey(v, 'redeemer') : null,
      redeemedAtHeight: redeemed ? ShaderOutput.amount(v, 'redeemed_at') : null,
    );
  }

  final String hashHex;
  final BigInt batchId;
  final int assetId;

  /// In the asset's smallest unit.
  final BigInt value;
  final bool redeemed;

  /// The key that redeemed it. Public on chain.
  final String? redeemerKey;
  final BigInt? redeemedAtHeight;
}

/// One of this wallet's batches (`view_my_batches`). A batch disappears
/// from the contract once every voucher is redeemed or cancelled.
@immutable
class AirdropBatch {
  const AirdropBatch({
    required this.id,
    required this.assetId,
    required this.valuePerVoucher,
    required this.totalCount,
    required this.redeemedCount,
    required this.createdAtHeight,
  });

  factory AirdropBatch.fromJson(Map<String, Object?> json) {
    final total = ShaderOutput.uint32(json, 'total_count');
    final redeemed = ShaderOutput.uint32(json, 'redeemed_count');
    if (redeemed > total) {
      throw const FormatException('batch: more redeemed than issued');
    }
    return AirdropBatch(
      id: ShaderOutput.amount(json, 'id'),
      assetId: ShaderOutput.uint32(json, 'asset_id'),
      valuePerVoucher: ShaderOutput.amount(json, 'value_per_voucher'),
      totalCount: total,
      redeemedCount: redeemed,
      createdAtHeight: ShaderOutput.amount(json, 'created_at'),
    );
  }

  /// `{"batches": [...]}`.
  static List<AirdropBatch> listFromOutput(Map<String, Object?> out) =>
      List.unmodifiable([
        for (final row in ShaderOutput.list(out['batches'], 'batches'))
          AirdropBatch.fromJson(ShaderOutput.map(row, 'batches[]')),
      ]);

  final BigInt id;
  final int assetId;

  /// The first voucher's value. Vouchers in a batch may differ; the exact
  /// figures are in `view_batch_vouchers`.
  final BigInt valuePerVoucher;

  /// Vouchers still on record: a partial cancel lowers it.
  final int totalCount;
  final int redeemedCount;
  final BigInt createdAtHeight;

  int get unclaimedCount => totalCount - redeemedCount;
}

/// One voucher of one of this wallet's batches (`view_batch_vouchers`).
@immutable
class AirdropBatchVoucher {
  const AirdropBatchVoucher({
    required this.hashHex,
    required this.value,
    required this.redeemed,
    this.redeemerKey,
    this.redeemedAtHeight,
  });

  factory AirdropBatchVoucher.fromJson(Map<String, Object?> json) {
    final redeemed = _flag(json, 'redeemed');
    return AirdropBatchVoucher(
      hashHex: _hashOf(json, 'hash'),
      value: ShaderOutput.amount(json, 'value'),
      redeemed: redeemed,
      redeemerKey: redeemed ? _pubKey(json, 'redeemer') : null,
      redeemedAtHeight: redeemed
          ? ShaderOutput.amount(json, 'redeemed_at')
          : null,
    );
  }

  /// `{"vouchers": [...]}`.
  static List<AirdropBatchVoucher> listFromOutput(Map<String, Object?> out) =>
      List.unmodifiable([
        for (final row in ShaderOutput.list(out['vouchers'], 'vouchers'))
          AirdropBatchVoucher.fromJson(ShaderOutput.map(row, 'vouchers[]')),
      ]);

  final String hashHex;
  final BigInt value;
  final bool redeemed;
  final String? redeemerKey;
  final BigInt? redeemedAtHeight;
}

/// Contract totals (`view_stats`).
///
/// [totalValueLocked] and the fee totals add up raw units of **every**
/// asset (BEAM groth plus each token's units), so they are not an amount
/// of anything and must not be displayed as one.
@immutable
class AirdropStats {
  const AirdropStats({
    required this.totalBatches,
    required this.totalVouchers,
    required this.totalRedeemed,
    required this.availableVouchers,
    required this.totalValueLocked,
    required this.totalFeesCollected,
    required this.totalFeesWithdrawn,
    required this.feesAvailable,
  });

  factory AirdropStats.fromOutput(Map<String, Object?> out) {
    final s = ShaderOutput.map(out['stats'], 'stats');
    return AirdropStats(
      totalBatches: ShaderOutput.amount(s, 'total_batches'),
      totalVouchers: ShaderOutput.amount(s, 'total_vouchers'),
      totalRedeemed: ShaderOutput.amount(s, 'total_redeemed'),
      availableVouchers: ShaderOutput.amount(s, 'available_vouchers'),
      totalValueLocked: ShaderOutput.amount(s, 'total_value_locked'),
      totalFeesCollected: ShaderOutput.amount(s, 'total_fees_collected'),
      totalFeesWithdrawn: ShaderOutput.amount(s, 'total_fees_withdrawn'),
      feesAvailable: ShaderOutput.amount(s, 'fees_available'),
    );
  }

  final BigInt totalBatches;
  final BigInt totalVouchers;
  final BigInt totalRedeemed;
  final BigInt availableVouchers;
  final BigInt totalValueLocked;
  final BigInt totalFeesCollected;
  final BigInt totalFeesWithdrawn;
  final BigInt feesAvailable;
}

/// Contract settings (`view`), including whether this wallet owns it.
@immutable
class AirdropSettings {
  const AirdropSettings({
    required this.version,
    required this.ownerKey,
    required this.paused,
    required this.isOwner,
  });

  factory AirdropSettings.fromOutput(Map<String, Object?> out) {
    final s = ShaderOutput.map(out['settings'], 'settings');
    return AirdropSettings(
      version: ShaderOutput.uint32(s, 'version'),
      ownerKey: _pubKey(s, 'owner'),
      paused: _flag(s, 'paused'),
      isOwner: _flag(s, 'is_owner'),
    );
  }

  final int version;

  /// The owner's key. Public on chain.
  final String ownerKey;

  /// A paused contract refuses new batches; claims and cancels still work.
  final bool paused;

  /// This wallet derives [ownerKey] (`DeriveOwnerPk`).
  final bool isOwner;
}

/// Creation fees collected in one asset (`view_fees`).
@immutable
class AirdropFeePool {
  const AirdropFeePool({
    required this.assetId,
    required this.accumulated,
    required this.withdrawn,
    required this.available,
  });

  factory AirdropFeePool.fromJson(Map<String, Object?> json) => AirdropFeePool(
    assetId: ShaderOutput.uint32(json, 'asset_id'),
    accumulated: ShaderOutput.amount(json, 'accumulated'),
    withdrawn: ShaderOutput.amount(json, 'withdrawn'),
    available: ShaderOutput.amount(json, 'available'),
  );

  /// `{"fees": [...]}`.
  static List<AirdropFeePool> listFromOutput(Map<String, Object?> out) =>
      List.unmodifiable([
        for (final row in ShaderOutput.list(out['fees'], 'fees'))
          AirdropFeePool.fromJson(ShaderOutput.map(row, 'fees[]')),
      ]);

  final int assetId;
  final BigInt accumulated;
  final BigInt withdrawn;
  final BigInt available;
}
