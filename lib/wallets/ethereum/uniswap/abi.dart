/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A small Solidity ABI codec for the Uniswap calls: the types those calls
// use (uint/int of any width, address, bool, bytes, bytesN, arrays and
// tuples, nested), encoded and decoded exactly as `abi.encode` does.
// Written here rather than through web3dart's contract classes so every
// byte the swap sends is visible in one file and pinned by tests against
// Foundry's `cast abi-encode`.
//
// Values: uint/int → BigInt (or int), address → "0x…" string, bool →
// bool, bytes/bytesN → Uint8List, string → String, arrays and tuples →
// List.

import 'dart:convert';
import 'dart:typed_data';

import 'package:web3dart/web3dart.dart' show keccak256, keccakUtf8;

/// One ABI type.
sealed class AbiType {
  const AbiType();

  /// Parses "uint256", "(address,bool,bytes)[]", "((address,uint24),bytes)".
  factory AbiType.parse(String type) => _parse(type.replaceAll(' ', ''));

  bool get isDynamic;

  /// Bytes this type takes in the head of an enclosing tuple.
  int get headSize => isDynamic ? 32 : _staticSize;
  int get _staticSize => 32;

  Uint8List encode(Object? value);

  /// Decodes the value whose encoding starts at [offset] in [data].
  Object decode(Uint8List data, int offset);
}

class AbiUint extends AbiType {
  const AbiUint(this.bits);
  final int bits;

  @override
  bool get isDynamic => false;

  @override
  Uint8List encode(Object? value) {
    final v = _bigInt(value);
    if (v.isNegative || v.bitLength > bits) {
      throw ArgumentError('uint$bits out of range: $v');
    }
    return _word(v);
  }

  @override
  Object decode(Uint8List data, int offset) =>
      _readWord(data, offset) & ((BigInt.one << bits) - BigInt.one);
}

class AbiInt extends AbiType {
  const AbiInt(this.bits);
  final int bits;

  @override
  bool get isDynamic => false;

  @override
  Uint8List encode(Object? value) {
    final v = _bigInt(value);
    final limit = BigInt.one << (bits - 1);
    if (v >= limit || v < -limit) {
      throw ArgumentError('int$bits out of range: $v');
    }
    return _word(v.isNegative ? (BigInt.one << 256) + v : v);
  }

  @override
  Object decode(Uint8List data, int offset) {
    final raw = _readWord(data, offset) & ((BigInt.one << bits) - BigInt.one);
    return raw >= (BigInt.one << (bits - 1)) ? raw - (BigInt.one << bits) : raw;
  }
}

class AbiAddress extends AbiType {
  const AbiAddress();

  @override
  bool get isDynamic => false;

  @override
  Uint8List encode(Object? value) {
    final bytes = hexToBytes(value! as String);
    if (bytes.length != 20) throw ArgumentError('not an address: $value');
    return Uint8List(32)..setRange(12, 32, bytes);
  }

  @override
  Object decode(Uint8List data, int offset) =>
      bytesToHex(data.sublist(offset + 12, offset + 32));
}

class AbiBool extends AbiType {
  const AbiBool();

  @override
  bool get isDynamic => false;

  @override
  Uint8List encode(Object? value) =>
      _word((value! as bool) ? BigInt.one : BigInt.zero);

  @override
  Object decode(Uint8List data, int offset) =>
      _readWord(data, offset) != BigInt.zero;
}

/// bytes1 … bytes32.
class AbiFixedBytes extends AbiType {
  const AbiFixedBytes(this.length);
  final int length;

  @override
  bool get isDynamic => false;

  @override
  Uint8List encode(Object? value) {
    final b = value! as Uint8List;
    if (b.length != length) throw ArgumentError('bytes$length: ${b.length}');
    return Uint8List(32)..setRange(0, length, b);
  }

  @override
  Object decode(Uint8List data, int offset) =>
      Uint8List.fromList(data.sublist(offset, offset + length));
}

class AbiBytes extends AbiType {
  const AbiBytes();

  @override
  bool get isDynamic => true;

  @override
  Uint8List encode(Object? value) {
    final b = value! as Uint8List;
    final padded = (b.length + 31) ~/ 32 * 32;
    return Uint8List(32 + padded)
      ..setRange(0, 32, _word(BigInt.from(b.length)))
      ..setRange(32, 32 + b.length, b);
  }

  @override
  Object decode(Uint8List data, int offset) {
    final len = _readWord(data, offset).toInt();
    return Uint8List.fromList(data.sublist(offset + 32, offset + 32 + len));
  }
}

class AbiString extends AbiType {
  const AbiString();

  @override
  bool get isDynamic => true;

  @override
  Uint8List encode(Object? value) => const AbiBytes().encode(
    Uint8List.fromList(utf8.encode(value! as String)),
  );

  @override
  Object decode(Uint8List data, int offset) => utf8.decode(
    const AbiBytes().decode(data, offset) as Uint8List,
    allowMalformed: true,
  );
}

class AbiArray extends AbiType {
  const AbiArray(this.element);
  final AbiType element;

  @override
  bool get isDynamic => true;

  @override
  Uint8List encode(Object? value) {
    final list = value! as List;
    final body = AbiTuple(List.filled(list.length, element)).encode(list);
    return Uint8List.fromList([..._word(BigInt.from(list.length)), ...body]);
  }

  @override
  Object decode(Uint8List data, int offset) {
    final n = _readWord(data, offset).toInt();
    return AbiTuple(List.filled(n, element)).decode(data, offset + 32);
  }
}

class AbiTuple extends AbiType {
  const AbiTuple(this.components);
  final List<AbiType> components;

  @override
  bool get isDynamic => components.any((c) => c.isDynamic);

  @override
  int get _staticSize => components.fold(0, (sum, c) => sum + c.headSize);

  @override
  Uint8List encode(Object? value) {
    final values = value! as List;
    if (values.length != components.length) {
      throw ArgumentError(
        'tuple of ${components.length} given ${values.length} values',
      );
    }
    final headLength = components.fold(0, (s, c) => s + c.headSize);
    final head = BytesBuilder(copy: false);
    final tail = BytesBuilder(copy: false);
    for (var i = 0; i < components.length; i++) {
      final c = components[i];
      final encoded = c.encode(values[i]);
      if (c.isDynamic) {
        head.add(_word(BigInt.from(headLength + tail.length)));
        tail.add(encoded);
      } else {
        head.add(encoded);
      }
    }
    return Uint8List.fromList([...head.takeBytes(), ...tail.takeBytes()]);
  }

  @override
  List<Object> decode(Uint8List data, int offset) {
    final out = <Object>[];
    var head = offset;
    for (final c in components) {
      if (c.isDynamic) {
        final rel = _readWord(data, head).toInt();
        out.add(c.decode(data, offset + rel));
      } else {
        out.add(c.decode(data, head));
      }
      head += c.headSize;
    }
    return out;
  }
}

/// `abi.encode(values…)` for the comma-separated [types].
Uint8List abiEncode(String types, List<Object?> values) =>
    (AbiType.parse('($types)') as AbiTuple).encode(values);

/// `abi.decode(data, (types…))`.
List<Object> abiDecode(String types, Uint8List data) =>
    (AbiType.parse('($types)') as AbiTuple).decode(data, 0);

/// The 4-byte selector of a function signature ("transfer(address,uint256)").
Uint8List selector(String signature) =>
    Uint8List.fromList(keccakUtf8(signature).sublist(0, 4));

/// Calldata: selector + `abi.encode` of the arguments. The argument types
/// are read from [signature].
Uint8List encodeCall(String signature, List<Object?> args) {
  final open = signature.indexOf('(');
  final types = signature.substring(open + 1, signature.length - 1);
  return Uint8List.fromList([
    ...selector(signature),
    ...abiEncode(types, args),
  ]);
}

Uint8List keccak(Uint8List data) => keccak256(data);

// ------------------------------------------------------------------ hex

Uint8List hexToBytes(String hex) {
  var h = hex.startsWith('0x') || hex.startsWith('0X') ? hex.substring(2) : hex;
  if (h.length.isOdd) h = '0$h';
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(List<int> bytes, {bool prefix = true}) {
  final sb = StringBuffer(prefix ? '0x' : '');
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// A big-endian unsigned integer from bytes.
BigInt bytesToBigInt(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

/// 0x-prefixed lowercase address, or throws.
String normAddress(String address) {
  final b = hexToBytes(address);
  if (b.length != 20) throw ArgumentError('not an address: $address');
  return bytesToHex(b);
}

// --------------------------------------------------------------- private

BigInt _bigInt(Object? v) => switch (v) {
  final BigInt b => b,
  final int i => BigInt.from(i),
  final String s => BigInt.parse(s),
  _ => throw ArgumentError('not an integer: $v'),
};

Uint8List _word(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  for (var i = 31; i >= 0 && x > BigInt.zero; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

BigInt _readWord(Uint8List data, int offset) {
  if (offset + 32 > data.length) {
    throw const FormatException('ABI data too short');
  }
  return bytesToBigInt(data.sublist(offset, offset + 32));
}

AbiType _parse(String t) {
  if (t.endsWith('[]')) {
    return AbiArray(_parse(t.substring(0, t.length - 2)));
  }
  if (t.startsWith('(')) {
    // Split the top level of "(a,(b,c),d)".
    final inner = t.substring(1, t.length - 1);
    final parts = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < inner.length; i++) {
      final ch = inner[i];
      if (ch == '(') depth++;
      if (ch == ')') depth--;
      if (ch == ',' && depth == 0) {
        parts.add(inner.substring(start, i));
        start = i + 1;
      }
    }
    if (inner.isNotEmpty) parts.add(inner.substring(start));
    return AbiTuple([for (final p in parts) _parse(p)]);
  }
  if (t == 'address') return const AbiAddress();
  if (t == 'bool') return const AbiBool();
  if (t == 'bytes') return const AbiBytes();
  if (t == 'string') return const AbiString();
  if (t.startsWith('bytes')) return AbiFixedBytes(int.parse(t.substring(5)));
  if (t.startsWith('uint')) {
    return AbiUint(t.length == 4 ? 256 : int.parse(t.substring(4)));
  }
  if (t.startsWith('int')) {
    return AbiInt(t.length == 3 ? 256 : int.parse(t.substring(3)));
  }
  throw ArgumentError('unsupported ABI type: $t');
}
