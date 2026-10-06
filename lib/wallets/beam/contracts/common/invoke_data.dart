/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The fee the wallet core charges for a contract call, per entry.
///
/// Mirrors `ContractInvokeEntry::get_FeeMin` (`bvm/invoke_data.cpp:233-256`)
/// with the post-HF3 `Transaction::FeeSettings` (`core/block_crypt.cpp:
/// 1706-1759`); mainnet is far past HF3. `process_invoke_data` pays exactly
/// this (`wallet/core/contract_transaction.cpp:737`), and wallet-api's own
/// confirmation info reports the same sum (`v6_api_parse.cpp:939`).
abstract final class BeamContractFee {
  static const _output = 18000;
  static const _kernel = 10000;
  static const _defaultStd = 100000;
  static const _chargeUnitPrice = 10;
  static const _bvmMinimum = 1000000;
  static const _extraSizeFree = 32768;
  static const _extraBytePrice = 50;

  /// 0.011 BEAM: the fee of any call whose charge is at most 100,000 units
  /// and whose args fit in 32 KB. Everything the AMM does except
  /// `pool_create` (see `kDexPoolCreateCharge`).
  static final minimum = BigInt.from(_defaultStd + _bvmMinimum);

  /// The fee for one entry: [argsBytes] + [dataBytes] of payload, funds
  /// moving in [spendAssets], and a declared BVM [charge].
  static BigInt forEntry({
    required int argsBytes,
    required int dataBytes,
    required Iterable<int> spendAssets,
    required int charge,
  }) {
    final assets = spendAssets.toSet();
    // The core assumes there is always a BEAM output (direct or change).
    final outputs = assets.length + (assets.contains(0) ? 0 : 1);
    var std = _output * outputs + _kernel;
    final extra = argsBytes + dataBytes;
    if (extra > _extraSizeFree) {
      std += _extraBytePrice * (extra - _extraSizeFree);
    }
    if (std < _defaultStd) std = _defaultStd;
    var bvm = _chargeUnitPrice * charge;
    if (bvm < _bvmMinimum) bvm = _bvmMinimum;
    return BigInt.from(std) + BigInt.from(bvm);
  }
}

/// One contract call inside `raw_data` (`bvm2::ContractInvokeEntry`).
@immutable
class BeamInvokeEntry {
  const BeamInvokeEntry({
    required this.flags,
    required this.method,
    required this.contractId,
    required this.args,
    required this.dataLength,
    required this.signatureCount,
    required this.charge,
    required this.comment,
    required this.spend,
    this.parentHeight,
  });

  final int flags;

  /// The contract method, e.g. 7 for an AMM trade. 0 deploys a contract.
  final int method;

  /// Lowercase hex, or null for a deployment (method 0).
  final String? contractId;

  /// The method's packed argument struct.
  final Uint8List args;

  /// Contract bytecode length (deployments only).
  final int dataLength;
  final int signatureCount;

  /// Declared BVM charge units; drives the fee above 100,000.
  final int charge;

  /// The shader's description, e.g. `Amm trade`.
  final String comment;

  /// Funds this entry moves, per asset id: positive = the wallet pays
  /// (locked into the contract), negative = the wallet receives. Never
  /// includes the fee. Kept exactly as serialized (the core never writes a
  /// zero, and the fee counts entries), so use [BeamInvokeData.spend] for
  /// display.
  final Map<int, BigInt> spend;

  /// Set for a dependent (HFT) call: the height of the context it builds on.
  final BigInt? parentHeight;

  bool get isDependent => flags & BeamInvokeData.flagDependent != 0;

  BigInt get fee => BeamContractFee.forEntry(
    argsBytes: args.length,
    dataBytes: dataLength,
    spendAssets: spend.keys,
    charge: charge,
  );
}

/// A decoded `invoke_contract` `raw_data` (`bvm2::ContractInvokeData`,
/// `bvm/invoke_data.h`), serialized by the core with yas `binary |
/// no_header | elittle | compacted`.
///
/// This is what `process_invoke_data` will execute, so a confirmation
/// screen shows [pays], [receives] and [fee] from here rather than from an
/// earlier quote. The same three numbers are what wallet-api derives for its
/// own confirmation (`v6_api_parse.cpp:900-951`).
///
/// Only plain and dependent single-signer calls are decoded. Advanced,
/// multisigned and commitment-carrying entries, unknown flags and trailing
/// bytes all raise [FormatException]: a screen must not summarise what it
/// cannot fully read.
@immutable
class BeamInvokeData {
  const BeamInvokeData({
    required this.entries,
    this.appArgs,
    this.spendMax,
  });

  static const flagAdvanced = 0x01;
  static const flagDependent = 0x02;
  static const flagMultisigned = 0x08;
  static const flagHasCommitment = 0x10;
  static const flagSaveAppInvoke = 0x20;
  static const flagSaveSpendMax = 0x40;
  static const _knownFlags =
      flagAdvanced |
      flagDependent |
      flagMultisigned |
      flagHasCommitment |
      flagSaveAppInvoke |
      flagSaveSpendMax;
  static const _unsupported =
      flagAdvanced | flagMultisigned | flagHasCommitment;

  final List<BeamInvokeEntry> entries;

  /// The app-shader args the core stored to rebuild a dependent call
  /// (`AppInvokeData.m_Args`), when present.
  final Map<String, String>? appArgs;

  /// An explicit spend ceiling the app set, when present.
  final Map<int, BigInt>? spendMax;

  /// Net funds over all entries (`get_FullSpend`): positive = paid,
  /// negative = received. Zero entries are dropped.
  Map<int, BigInt> get spend {
    final total = <int, BigInt>{};
    for (final e in entries) {
      for (final s in e.spend.entries) {
        total[s.key] = (total[s.key] ?? BigInt.zero) + s.value;
      }
    }
    total.removeWhere((_, v) => v == BigInt.zero);
    return Map.unmodifiable(total);
  }

  /// What the wallet pays, per asset, excluding the fee.
  Map<int, BigInt> get pays => Map.unmodifiable({
    for (final s in spend.entries)
      if (s.value > BigInt.zero) s.key: s.value,
  });

  /// What the wallet receives, per asset.
  Map<int, BigInt> get receives => Map.unmodifiable({
    for (final s in spend.entries)
      if (s.value < BigInt.zero) s.key: -s.value,
  });

  /// The network fee in BEAM groth (`get_FullFee`).
  BigInt get fee =>
      entries.fold(BigInt.zero, (sum, e) => sum + e.fee);

  static BeamInvokeData decode(List<int> rawData) {
    final r = _YasReader(rawData);
    final count = r.seqSize(minElementBytes: 4);
    final entries = <BeamInvokeEntry>[];
    for (var i = 0; i < count; i++) {
      entries.add(_entry(r));
    }

    Map<String, String>? appArgs;
    Map<int, BigInt>? spendMax;
    if (entries.isNotEmpty) {
      final flags = entries.first.flags;
      if (flags & flagSaveAppInvoke != 0) {
        r.byteBuffer(); // app shader body
        r.byteBuffer(); // contract shader body
        final n = r.seqSize(minElementBytes: 2);
        appArgs = {};
        for (var i = 0; i < n; i++) {
          final k = r.string();
          appArgs[k] = r.string();
        }
        r.u32(); // privilege
      }
      if (flags & flagSaveSpendMax != 0) spendMax = r.fundsMap();
    }
    if (!r.atEnd) {
      throw FormatException(
        'raw_data: ${r.remaining} unread bytes after the invoke data',
      );
    }
    return BeamInvokeData(
      entries: List.unmodifiable(entries),
      appArgs: appArgs == null ? null : Map.unmodifiable(appArgs),
      spendMax: spendMax,
    );
  }

  static BeamInvokeEntry _entry(_YasReader r) {
    const hasFlags = 0x80000000;
    final first = r.u32();
    var flags = 0;
    var method = first;
    if (first & hasFlags != 0) {
      flags = first & ~hasFlags;
      method = r.u32() & ~hasFlags;
    }
    if (flags & ~_knownFlags != 0) {
      throw FormatException('raw_data: unknown entry flags 0x'
          '${flags.toRadixString(16)}');
    }
    if (flags & _unsupported != 0) {
      throw FormatException('raw_data: unsupported entry flags 0x'
          '${flags.toRadixString(16)} (advanced, multisig or commitment)');
    }
    final args = r.byteBuffer();
    final sigs = r.seqSize(minElementBytes: 32);
    r.skip(32 * sigs);
    final charge = r.u32();
    final comment = r.string();
    final spend = r.fundsMap();
    String? cid;
    var dataLength = 0;
    if (method != 0) {
      cid = _hex(r.take(32));
    } else {
      dataLength = r.byteBuffer().length;
    }
    BigInt? parentHeight;
    if (flags & flagDependent != 0) {
      parentHeight = r.u64();
      r.skip(32); // parent context hash
    }
    return BeamInvokeEntry(
      flags: flags,
      method: method,
      contractId: cid,
      args: args,
      dataLength: dataLength,
      signatureCount: sigs,
      charge: charge,
      comment: comment,
      spend: spend,
      parentHeight: parentHeight,
    );
  }

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

/// Reads yas binary archives with BEAM's options (little-endian,
/// compacted integers): `3rdparty/yas/detail/io/binary_streams.hpp`.
class _YasReader {
  _YasReader(List<int> bytes) : _b = Uint8List.fromList(bytes);

  final Uint8List _b;
  int _pos = 0;

  bool get atEnd => _pos == _b.length;
  int get remaining => _b.length - _pos;

  int _byte() {
    if (_pos >= _b.length) throw const FormatException('raw_data: truncated');
    return _b[_pos++];
  }

  Uint8List take(int n) {
    if (n < 0 || n > remaining) {
      throw const FormatException('raw_data: truncated');
    }
    final out = Uint8List.sublistView(_b, _pos, _pos + n);
    _pos += n;
    return out;
  }

  void skip(int n) => take(n);

  BigInt _le(int n) {
    var v = BigInt.zero;
    final bytes = take(n);
    for (var i = n - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(bytes[i]);
    }
    return v;
  }

  /// A compacted unsigned integer of at most [maxBytes] bytes: one byte
  /// `0x80 | v` when v < 128, else a length byte (top bit clear) and that
  /// many little-endian bytes.
  BigInt _unsigned(int maxBytes) {
    final h = _byte();
    if (h & 0x80 != 0) return BigInt.from(h & 0x7f);
    if (h > maxBytes) {
      throw FormatException('raw_data: integer of $h bytes, max $maxBytes');
    }
    return _le(h);
  }

  int u32() => _unsigned(4).toInt();

  BigInt u64() => _unsigned(8);

  /// A compacted signed 64-bit integer: bit 7 of the header is the sign,
  /// bit 6 set means the magnitude (< 64) is in the low six bits, else the
  /// low six bits are the byte count of the little-endian magnitude.
  BigInt i64() {
    final h = _byte();
    final negative = h & 0x80 != 0;
    final BigInt magnitude;
    if (h & 0x40 != 0) {
      magnitude = BigInt.from(h & 0x3f);
    } else {
      final n = h & 0x3f;
      if (n > 8) throw FormatException('raw_data: integer of $n bytes');
      magnitude = _le(n);
      if (magnitude.bitLength > 63) {
        throw const FormatException('raw_data: signed integer overflow');
      }
    }
    return negative ? -magnitude : magnitude;
  }

  /// A container length, bounded by what is left to read.
  int seqSize({required int minElementBytes}) {
    final n = u64();
    if (n > BigInt.from(remaining ~/ minElementBytes)) {
      throw const FormatException('raw_data: container longer than data');
    }
    return n.toInt();
  }

  Uint8List byteBuffer() => take(seqSize(minElementBytes: 1));

  String string() => utf8.decode(byteBuffer(), allowMalformed: true);

  /// `std::map<Asset::ID, AmountSigned>`.
  Map<int, BigInt> fundsMap() {
    final n = seqSize(minElementBytes: 2);
    final m = <int, BigInt>{};
    for (var i = 0; i < n; i++) {
      final aid = u32();
      final v = i64();
      if (m.containsKey(aid)) {
        throw const FormatException('raw_data: duplicate asset in funds');
      }
      m[aid] = v;
    }
    return Map.unmodifiable(m);
  }
}
