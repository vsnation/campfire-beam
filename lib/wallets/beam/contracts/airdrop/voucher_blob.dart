/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'airdrop_constants.dart';

final _u64Max = (BigInt.one << 64) - BigInt.one;
final _u64Modulus = BigInt.one << 64;
final _hash = RegExp(r'^[0-9a-f]{64}$');

/// The 1% creation fee, computed exactly as the app shader and the
/// contract do (`On_user_create_batch` and `Method_2`):
///
/// ```cpp
/// Amount fee = (totalValue * FEE_BPS) / BPS_TOTAL;   // uint64_t
/// if (fee == 0 && totalValue > 0) fee = 1;
/// ```
///
/// The shader computes it to declare the funds it locks and the contract
/// computes it again to lock them; if the wallet's figure differed,
/// `FundsLock` would not balance and the transaction would fail.
abstract final class AirdropFee {
  /// The largest total whose `total * 100` still fits in 64 bits. Above it
  /// the C++ product wraps and the "1%" becomes a meaningless small number;
  /// [AirdropVoucherBlob.encode] refuses such totals.
  static final maxTotal = _u64Max ~/ BigInt.from(kAirdropFeeBps);

  /// The creation fee for vouchers worth [total] in all, in the same asset.
  /// Replicates the `uint64_t` arithmetic bit for bit, wrap-around
  /// included, so it also reproduces what the shader does with a total
  /// above [maxTotal].
  static BigInt creationFee(BigInt total) {
    if (total.isNegative || total > _u64Max) {
      throw ArgumentError.value(total, 'total', 'not a 64-bit amount');
    }
    final product = (total * BigInt.from(kAirdropFeeBps)) % _u64Modulus;
    var fee = product ~/ BigInt.from(kAirdropBpsTotal);
    if (fee == BigInt.zero && total > BigInt.zero) fee = BigInt.one;
    return fee;
  }
}

/// One voucher as `create_batch` sends it: the hash of its code and its
/// value in the asset's smallest unit (`Airdrop::VoucherEntry`).
@immutable
class AirdropVoucherEntry {
  AirdropVoucherEntry(this.hashHex, this.value) {
    if (!_hash.hasMatch(hashHex)) {
      throw ArgumentError.value(hashHex, 'hashHex', '64 lowercase hex chars');
    }
    if (value <= BigInt.zero || value > _u64Max) {
      throw ArgumentError.value(value, 'value', 'must be 1..2^64-1');
    }
  }

  final String hashHex;
  final BigInt value;

  @override
  bool operator ==(Object other) =>
      other is AirdropVoucherEntry &&
      other.hashHex == hashHex &&
      other.value == value;

  @override
  int get hashCode => Object.hash(hashHex, value);

  @override
  String toString() => 'AirdropVoucherEntry($hashHex, $value)';
}

/// The `vouchers=` argument of `create_batch`: every entry as its 32-byte
/// SHA-256 followed by its 8-byte little-endian value (40 bytes), all
/// concatenated into one hex string. The shader reads exactly
/// `count * 40` bytes of it (`DocGetBlob`).
abstract final class AirdropVoucherBlob {
  static const entryBytes = 40;

  /// The bytes of [entries], validated: 1 to 100 entries, no repeated
  /// hash (the contract halts on one), and a total the fee can be computed
  /// for without the C++ product overflowing.
  static Uint8List bytes(List<AirdropVoucherEntry> entries) {
    _check(entries);
    final out = Uint8List(entries.length * entryBytes);
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final o = i * entryBytes;
      for (var j = 0; j < 32; j++) {
        out[o + j] = int.parse(
          e.hashHex.substring(2 * j, 2 * j + 2),
          radix: 16,
        );
      }
      var v = e.value;
      for (var j = 0; j < 8; j++) {
        out[o + 32 + j] = (v & BigInt.from(0xff)).toInt();
        v >>= 8;
      }
    }
    return out;
  }

  /// [bytes] as lowercase hex, the form the `vouchers=` argument takes.
  static String encode(List<AirdropVoucherEntry> entries) {
    final b = bytes(entries);
    final out = StringBuffer();
    for (final x in b) {
      out.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }

  /// Reads entries back from [bytes] (a multiple of 40).
  static List<AirdropVoucherEntry> decode(List<int> bytes) {
    if (bytes.length % entryBytes != 0) {
      throw FormatException('voucher blob of ${bytes.length} bytes');
    }
    final out = <AirdropVoucherEntry>[];
    for (var o = 0; o < bytes.length; o += entryBytes) {
      final hash = StringBuffer();
      for (var j = 0; j < 32; j++) {
        hash.write(bytes[o + j].toRadixString(16).padLeft(2, '0'));
      }
      var v = BigInt.zero;
      for (var j = 7; j >= 0; j--) {
        v = (v << 8) | BigInt.from(bytes[o + 32 + j]);
      }
      out.add(AirdropVoucherEntry(hash.toString(), v));
    }
    return out;
  }

  /// The sum of [entries]' values.
  static BigInt total(List<AirdropVoucherEntry> entries) =>
      entries.fold(BigInt.zero, (s, e) => s + e.value);

  static void _check(List<AirdropVoucherEntry> entries) {
    if (entries.isEmpty || entries.length > kAirdropMaxVouchersPerBatch) {
      throw ArgumentError.value(
        entries.length,
        'entries',
        'a batch holds 1 to $kAirdropMaxVouchersPerBatch vouchers',
      );
    }
    final seen = <String>{};
    for (final e in entries) {
      if (!seen.add(e.hashHex)) {
        throw ArgumentError.value(e.hashHex, 'entries', 'repeated voucher');
      }
    }
    final sum = total(entries);
    if (sum > AirdropFee.maxTotal) {
      throw ArgumentError.value(
        sum,
        'entries',
        'total above ${AirdropFee.maxTotal}, where the contract fee '
            'overflows',
      );
    }
  }
}
