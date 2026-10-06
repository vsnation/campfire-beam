/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

/// Reads a contract method's packed argument struct
/// (`BeamInvokeEntry.args`): `#pragma pack(1)` C++ fields, little-endian,
/// exactly as the contract receives them.
///
/// Every read is bounds-checked and throws [FormatException] past the end.
class BeamArgsReader {
  BeamArgsReader(List<int> bytes) : _b = Uint8List.fromList(bytes);

  final Uint8List _b;
  int _pos = 0;

  int get remaining => _b.length - _pos;
  bool get atEnd => _pos == _b.length;

  /// The next [n] bytes, as a copy.
  Uint8List bytes(int n) {
    if (n < 0 || n > remaining) {
      throw const FormatException('contract args: truncated');
    }
    final out = Uint8List.sublistView(_b, _pos, _pos + n);
    _pos += n;
    return Uint8List.fromList(out);
  }

  int u8() => bytes(1)[0];
  int u32() => _fromLe(bytes(4)).toInt();
  BigInt u64() => _fromLe(bytes(8));

  /// A 33-byte public key (`X[32] || Y[1]`) as 66 lowercase hex characters.
  String pubKey() => [
    for (final b in bytes(33)) b.toRadixString(16).padLeft(2, '0'),
  ].join();

  static BigInt _fromLe(Uint8List b) {
    var v = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(b[i]);
    }
    return v;
  }
}

/// Writes packed little-endian contract arguments, the inverse of
/// [BeamArgsReader]. Services use it to build the bytes they expect a
/// decoded call to carry.
abstract final class BeamArgsWriter {
  /// [value] (an `int` or a `BigInt`) as [byteCount] little-endian bytes.
  ///
  /// Throws [ArgumentError] when [value] is negative or does not fit in
  /// [byteCount] bytes: nothing is silently truncated, so a value out of
  /// range can never match the truncated bytes of a different one.
  static Uint8List le(Object value, int byteCount) {
    if (byteCount < 1) {
      throw ArgumentError.value(byteCount, 'byteCount', 'must be positive');
    }
    final BigInt v;
    if (value is BigInt) {
      v = value;
    } else if (value is int) {
      v = BigInt.from(value);
    } else {
      throw ArgumentError.value(value, 'value', 'an int or a BigInt');
    }
    if (v.isNegative || v.bitLength > 8 * byteCount) {
      throw ArgumentError.value(
        value,
        'value',
        'does not fit in $byteCount unsigned bytes',
      );
    }
    final out = Uint8List(byteCount);
    var rest = v;
    final mask = BigInt.from(0xff);
    for (var i = 0; i < byteCount; i++) {
      out[i] = (rest & mask).toInt();
      rest >>= 8;
    }
    return out;
  }
}
