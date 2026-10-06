/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A test-only writer for `raw_data`: one plain `bvm2::ContractInvokeEntry`
// serialized the way the core does (yas binary | no_header | elittle |
// compacted, field order of bvm/invoke_data.h). Fake wallet-apis use it to
// answer `invoke_contract` like an app shader would. live_*_test.dart
// re-encodes real raw_data with it and requires identical bytes.

import 'dart:convert';

class FakeInvokeEntry {
  const FakeInvokeEntry({
    required this.method,
    required this.cid,
    required this.args,
    required this.funds,
    required this.comment,
    this.charge = 0,
    this.sigs = const [],
  });

  final int method;

  /// 64 hex.
  final String cid;
  final List<int> args;

  /// Positive = locked from the wallet, negative = unlocked to it.
  final Map<int, BigInt> funds;
  final String comment;
  final int charge;

  /// 32-byte key-preimage hashes, one per signing key.
  final List<List<int>> sigs;
}

abstract final class InvokeDataWriter {
  static List<int> write(List<FakeInvokeEntry> entries) {
    final out = <int>[];
    _u(out, BigInt.from(entries.length));
    for (final e in entries) {
      _u(out, BigInt.from(e.method)); // no flags
      _u(out, BigInt.from(e.args.length));
      out.addAll(e.args);
      _u(out, BigInt.from(e.sigs.length));
      for (final s in e.sigs) {
        if (s.length != 32) throw ArgumentError('sig hash of ${s.length}');
        out.addAll(s);
      }
      _u(out, BigInt.from(e.charge));
      final c = utf8.encode(e.comment);
      _u(out, BigInt.from(c.length));
      out.addAll(c);
      final funds = e.funds.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      _u(out, BigInt.from(funds.length));
      for (final f in funds) {
        _u(out, BigInt.from(f.key));
        _i(out, f.value);
      }
      out.addAll(hexBytes(e.cid));
    }
    return out;
  }

  static List<int> hexBytes(String h) => [
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];

  static List<int> le(BigInt v, int n) {
    var x = v;
    final out = <int>[];
    for (var i = 0; i < n; i++) {
      out.add((x & BigInt.from(0xff)).toInt());
      x >>= 8;
    }
    return out;
  }

  /// Compacted unsigned: `0x80 | v` below 128, else a byte count and the
  /// minimal little-endian bytes.
  static void _u(List<int> out, BigInt v) {
    if (v < BigInt.from(128)) {
      out.add(0x80 | v.toInt());
      return;
    }
    final n = (v.bitLength + 7) ~/ 8;
    out
      ..add(n)
      ..addAll(le(v, n));
  }

  /// Compacted signed: `0x40 | sign << 7 | |v|` below 64, else
  /// `sign << 7 | n` and the minimal little-endian magnitude.
  static void _i(List<int> out, BigInt v) {
    final neg = v.isNegative;
    final m = v.abs();
    if (m < BigInt.from(64)) {
      out.add((neg ? 0x80 : 0) | 0x40 | m.toInt());
      return;
    }
    final n = (m.bitLength + 7) ~/ 8;
    out
      ..add((neg ? 0x80 : 0) | n)
      ..addAll(le(m, n));
  }
}

/// Splits wallet-api `args` the way the core's parser does for the values
/// the services send (no quoting except a final quoted `metadata`).
Map<String, String> parseArgs(String args) {
  final out = <String, String>{};
  final q = args.indexOf('"');
  final plain = q < 0 ? args : args.substring(0, args.lastIndexOf(',', q));
  for (final kv in plain.split(',')) {
    final i = kv.indexOf('=');
    out.putIfAbsent(kv.substring(0, i), () => kv.substring(i + 1));
  }
  if (q >= 0) {
    final key = args.substring(args.lastIndexOf(',', q) + 1, q - 1);
    out.putIfAbsent(key, () => args.substring(q + 1, args.length - 1));
  }
  return out;
}
