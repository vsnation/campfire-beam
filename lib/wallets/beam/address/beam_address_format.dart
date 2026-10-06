/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

import '../models/beam_address.dart';

/// Synchronous, pure-Dart format check for BEAM addresses. It needs no
/// wallet, core or network, so UI validators can call it on every keystroke.
///
/// It mirrors the core's parser (`ParseParameters` and `GetAddressTypeImpl`,
/// `wallet/core/common.cpp`, and the `PeerAddr` check in
/// `V6Api::onHandleValidateAddress`):
///
/// * the text is decoded as hex if every character is a hex digit, otherwise
///   as base58 (`wallet/core/base58.cpp` alphabet);
/// * a buffer longer than 33 bytes whose first byte has the 0x80 flag is a
///   token: flags, optional 16-byte tx id, then (parameter id, bytes) pairs in
///   the core's compacted little-endian serialization;
/// * anything else is a plain SBBS `WalletID` of at most 40 bytes: an 8-byte
///   channel below 1024 and a 32-byte key that is a valid secp256k1 x.
///
/// It is stricter than the core where the core accepts forms no BEAM wallet
/// writes, because those forms let other coins' addresses through:
///
/// * a plain `WalletID` must be hex (`to_string(WalletID)`), never base58. A
///   25-byte base58check address (Bitcoin, Firo) would otherwise pass about
///   half the time, whenever its last 32 bytes happen to be a curve x;
/// * that hex must be at least [minRegularLength] characters, which rules out
///   a 40-hex Ethereum address typed without its `0x`;
/// * a token must be consumed exactly, with no trailing bytes. Base58 has no
///   checksum, so this is the best typo check available offline.
///
/// It is weaker in one way: the parameters that decide the type are checked
/// for their exact serialized size (`core/serialization_adapters.h`), but the
/// vouchers' and public generator's curve points are not verified. The
/// authoritative check is `validate_address` on an open wallet, which runs
/// before anything is sent.
abstract final class BeamAddressFormat {
  /// Longest text accepted. The core caps an offline address at 30 vouchers
  /// (`local_private_key_keeper.cpp`), about 9,400 base58 characters.
  static const int maxLength = 12000;

  /// Shortest hex SBBS address accepted. The encoder strips leading zero
  /// nibbles, and the channel (0 to 1023) comes from the key, so real
  /// addresses are 64 to 67 characters. Fewer than 60 needs channel 0 and
  /// four leading zero nibbles in the key, about one address in 10^9.
  static const int minRegularLength = 60;

  /// True if [address] is a well-formed BEAM address of any type.
  static bool isValid(String address) => typeOf(address) != null;

  /// The type of a well-formed BEAM address, or null if [address] is not one.
  /// Never returns [BeamAddressType.unknown].
  static BeamAddressType? typeOf(String address) {
    if (address.isEmpty || address.length > maxLength) {
      return null;
    }
    final isHex = _isHex(address);
    final Uint8List? buffer = isHex
        ? _decodeHex(address)
        : _decodeBase58(address);
    if (buffer == null || buffer.length < 2) {
      return null;
    }
    if (buffer.length > 33 && (buffer[0] & _tokenFlag) != 0) {
      return _tokenType(buffer);
    }
    return isHex &&
            address.length >= minRegularLength &&
            _isValidWalletId(buffer)
        ? BeamAddressType.regular
        : null;
  }

  // TxToken::TokenFlag.
  static const int _tokenFlag = 0x80;

  // TxParameterID values (wallet/core/common.h).
  static const int _pTransactionType = 0;
  static const int _pPeerAddr = 7; // PeerID
  static const int _pIsPermanentPeerId = 8;
  static const int _pPeerEndpoint = 21; // PeerWalletIdentity
  static const int _pPublicAddressGen = 123;
  static const int _pShieldedVoucherList = 124;
  static const int _pVoucher = 125;

  // TxType values.
  static const int _txSimple = 0;
  static const int _txPushTransaction = 7;

  // sizeof(WalletID): uintBig_t<8> channel + 32-byte PeerID.
  static const int _walletIdSize = 40;
  static const int _peerIdSize = 32;
  static const int _txIdSize = 16;
  // Ticket (flags + 4 x 32) + shared secret (32) + signature (1 + 2 x 32).
  static const int _voucherSize = 226;
  // Flags + 6 x 32 (two packed public key generators).
  static const int _publicGenSize = 193;
  // proto::Bbs::s_MaxWalletChannels.
  static const int _maxWalletChannels = 1024;

  static BeamAddressType? _tokenType(Uint8List buffer) {
    final Map<int, Uint8List> params;
    try {
      params = _readTokenParams(buffer);
    } on FormatException {
      return null;
    }

    final peerAddr = params[_pPeerAddr];
    if (peerAddr != null && !_isValidWalletId(peerAddr, serialized: true)) {
      return null;
    }
    final endpoint = params[_pPeerEndpoint];
    final voucher = params[_pVoucher];
    final publicGen = params[_pPublicAddressGen];
    final permanent = params[_pIsPermanentPeerId];
    final vouchers = params[_pShieldedVoucherList];
    final voucherCount = vouchers == null ? 0 : _voucherCount(vouchers);
    // TxToken::IsValid: every public parameter present must deserialize.
    if ((endpoint != null && endpoint.length != _peerIdSize) ||
        (voucher != null && voucher.length != _voucherSize) ||
        (publicGen != null && publicGen.length != _publicGenSize) ||
        (permanent != null && permanent.length != 1) ||
        voucherCount < 0) {
      return null;
    }

    final txTypeBytes = params[_pTransactionType];
    if (txTypeBytes != null) {
      // An enum is serialized as its size (1) and then its value.
      if (txTypeBytes.length != 2 || txTypeBytes[0] != 1) {
        return null;
      }
      final txType = txTypeBytes[1];
      if (txType == _txSimple) {
        return peerAddr != null ? BeamAddressType.regularNew : null;
      }
      // Atomic swap offers and every other type are not payment addresses.
      if (txType != _txPushTransaction) {
        return null;
      }
    }

    if (voucher != null && endpoint != null) {
      return BeamAddressType.maxPrivacy;
    }
    if (voucherCount > 0 && endpoint != null && peerAddr != null) {
      return BeamAddressType.offline;
    }
    if (publicGen != null) {
      return BeamAddressType.publicOffline;
    }
    if (peerAddr != null) {
      return BeamAddressType.regularNew;
    }
    return null;
  }

  /// Reads `TxToken` (flags, optional tx id, packed parameters). Throws
  /// [FormatException] unless the whole buffer is consumed.
  static Map<int, Uint8List> _readTokenParams(Uint8List buffer) {
    final reader = _Reader(buffer)..byte(); // flags, checked by the caller
    final hasTxId = reader.byte();
    if (hasTxId > 1) {
      throw const FormatException('bad optional flag');
    }
    if (hasTxId == 1) {
      reader.take(_txIdSize);
    }
    final count = reader.compactUint();
    // Each parameter takes at least 3 bytes: enum size, id, length.
    if (count > reader.remaining ~/ 3) {
      throw const FormatException('bad parameter count');
    }
    final params = <int, Uint8List>{};
    for (var i = 0; i < count; i++) {
      if (reader.byte() != 1) {
        throw const FormatException('bad parameter id size');
      }
      final id = reader.byte();
      params[id] = reader.take(reader.compactUint());
    }
    if (reader.remaining != 0) {
      throw const FormatException('trailing bytes');
    }
    return params;
  }

  /// The number of vouchers in a serialized `ShieldedVoucherList` (a count,
  /// then that many fixed-size vouchers), or -1 if it is malformed.
  static int _voucherCount(Uint8List list) {
    try {
      final reader = _Reader(list);
      final count = reader.compactUint();
      return reader.remaining == count * _voucherSize ? count : -1;
    } on FormatException {
      return -1;
    }
  }

  /// `WalletID::FromBuf` + `WalletID::IsValid`. A text address is
  /// right-aligned into 40 bytes (leading zeros are stripped when encoding);
  /// inside a token it is always exactly 40 bytes.
  static bool _isValidWalletId(Uint8List bytes, {bool serialized = false}) {
    if (serialized ? bytes.length != _walletIdSize : bytes.length > 40) {
      return false;
    }
    final id = Uint8List(_walletIdSize)
      ..setRange(_walletIdSize - bytes.length, _walletIdSize, bytes);
    // The channel is big-endian; below 1024 only its last two bytes are set.
    for (var i = 0; i < 6; i++) {
      if (id[i] != 0) {
        return false;
      }
    }
    final channel = (id[6] << 8) | id[7];
    return channel < _maxWalletChannels &&
        _isSecp256k1X(id.sublist(_walletIdSize - _peerIdSize));
  }

  static final BigInt _fieldPrime = BigInt.parse(
    'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
    radix: 16,
  );
  static final BigInt _legendreExponent = (_fieldPrime - BigInt.one) >> 1;
  static final BigInt _three = BigInt.from(3);
  static final BigInt _seven = BigInt.from(7);

  /// `PeerID::ExportNnz`: [x] is below the field prime and x^3 + 7 is a
  /// square mod p, so a curve point with that x exists.
  static bool _isSecp256k1X(Uint8List x) {
    var value = BigInt.zero;
    for (final b in x) {
      value = (value << 8) | BigInt.from(b);
    }
    if (value >= _fieldPrime) {
      return false;
    }
    final rhs = (value.modPow(_three, _fieldPrime) + _seven) % _fieldPrime;
    return rhs == BigInt.zero ||
        rhs.modPow(_legendreExponent, _fieldPrime) == BigInt.one;
  }

  static bool _isHex(String s) {
    for (final c in s.codeUnits) {
      final isHex =
          (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x41 && c <= 0x46) || // A-F
          (c >= 0x61 && c <= 0x66); // a-f
      if (!isHex) {
        return false;
      }
    }
    return true;
  }

  /// Hex to bytes; an odd length gets a leading zero nibble, like `from_hex`.
  static Uint8List _decodeHex(String s) {
    final padded = s.length.isOdd ? '0$s' : s;
    final out = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(padded.substring(2 * i, 2 * i + 2), radix: 16);
    }
    return out;
  }

  static const String _base58Alphabet =
      '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

  static final List<int> _base58Index = () {
    final index = List<int>.filled(128, -1);
    for (var i = 0; i < _base58Alphabet.length; i++) {
      index[_base58Alphabet.codeUnitAt(i)] = i;
    }
    return index;
  }();

  /// Base58 to bytes, each leading '1' becoming a leading zero byte, like
  /// `DecodeBase58`. Returns null for any character outside the alphabet.
  ///
  /// Digits are folded in five at a time (58^5 < 2^30) into little-endian
  /// 32-bit limbs, so the largest offline address decodes in a few
  /// milliseconds.
  static Uint8List? _decodeBase58(String s) {
    final digits = Uint8List(s.length);
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final d = c < 128 ? _base58Index[c] : -1;
      if (d < 0) {
        return null;
      }
      digits[i] = d;
    }
    var zeros = 0;
    while (zeros < digits.length && digits[zeros] == 0) {
      zeros++;
    }

    final limbs = <int>[];
    var i = zeros;
    while (i < digits.length) {
      var chunk = 0;
      var factor = 1;
      for (var k = 0; k < 5 && i < digits.length; k++, i++) {
        chunk = chunk * 58 + digits[i];
        factor *= 58;
      }
      var carry = chunk;
      for (var j = 0; j < limbs.length; j++) {
        final v = limbs[j] * factor + carry;
        limbs[j] = v & 0xffffffff;
        carry = v >> 32;
      }
      while (carry > 0) {
        limbs.add(carry & 0xffffffff);
        carry >>= 32;
      }
    }

    final body = <int>[];
    for (var j = limbs.length - 1; j >= 0; j--) {
      final limb = limbs[j];
      for (var shift = 24; shift >= 0; shift -= 8) {
        final b = (limb >> shift) & 0xff;
        if (body.isNotEmpty || b != 0) {
          body.add(b);
        }
      }
    }
    return Uint8List(zeros + body.length)
      ..setRange(zeros, zeros + body.length, body);
  }
}

/// Bounds-checked reader for the core's compacted little-endian format.
class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  int get remaining => _bytes.length - _pos;

  int byte() {
    if (_pos >= _bytes.length) {
      throw const FormatException('unexpected end');
    }
    return _bytes[_pos++];
  }

  Uint8List take(int n) {
    if (n < 0 || n > remaining) {
      throw const FormatException('unexpected end');
    }
    final out = Uint8List.sublistView(_bytes, _pos, _pos + n);
    _pos += n;
    return out;
  }

  /// yas `compacted` unsigned integer: one byte with the top bit set holds a
  /// value below 128; otherwise that byte is the count (at most 8) of
  /// little-endian bytes that follow. Values of 2^48 and above are rejected:
  /// no buffer here is that long.
  int compactUint() {
    final head = byte();
    if ((head & 0x80) != 0) {
      return head & 0x7f;
    }
    if (head > 8) {
      throw const FormatException('bad compact size');
    }
    var value = 0;
    for (var i = 0; i < head; i++) {
      final b = byte();
      if (i >= 6 && b != 0) {
        throw const FormatException('compact value too large');
      }
      value |= b << (8 * i);
    }
    return value;
  }
}
