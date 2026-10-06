/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Decodes the `raw_data` that `invoke_contract` returns with
/// `create_tx: false`, so a confirmation screen can show exactly what
/// `process_invoke_data` will sign: which contract and method, what leaves
/// the wallet, and the fee.
///
/// `raw_data` is `bvm2::ContractInvokeData` (`bvm/invoke_data.h:27-207`)
/// written by `toByteBuffer` with yas `binary | no_header | elittle |
/// compacted` (`utility/serialize.h:39`). Compacted integers
/// (`3rdparty/yas/detail/io/binary_streams.hpp:254-324`):
///
/// * unsigned: one byte `0x80 | v` when `v < 128`, otherwise a byte `n`
///   followed by `n` little-endian bytes;
/// * signed: one byte `0x40 | sign << 7 | |v|` when `|v| < 64`, otherwise
///   `sign << 7 | n` followed by `n` little-endian bytes of `|v|`.
///
/// Fixed-size byte arrays (`uintBig_t`, hashes, contract ids) are raw;
/// vectors, strings and maps carry a compacted length first. Points are
/// `X[32] || Y[1]`.
///
/// Generic BEAM code: it belongs with the shared contract helpers and is
/// kept in the BANS module only until those exist.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One contract call in a [BeamInvokeData].
@immutable
class BeamInvokeEntry {
  const BeamInvokeEntry({
    required this.flags,
    required this.method,
    required this.contractId,
    required this.args,
    required this.signatureKeyCount,
    required this.charge,
    required this.comment,
    required this.spend,
    this.deployData,
    this.advancedFee,
    this.minHeight,
    this.maxHeight,
  });

  static const flagAdvanced = 1;
  static const flagDependent = 2;
  static const flagMultisigned = 8;
  static const flagHasCommitment = 0x10;
  static const flagSaveAppInvoke = 0x20;
  static const flagSaveSpendMax = 0x40;

  final int flags;

  /// Contract method number. 0 deploys a contract ([deployData] is its
  /// bytecode and [contractId] is empty).
  final int method;

  /// 64 lower-case hex characters, or empty for a deployment.
  final String contractId;

  /// The method's argument bytes, exactly as the contract receives them.
  final Uint8List args;

  /// How many signatures the call carries (`m_vSig`).
  final int signatureKeyCount;

  /// BVM charge units the app shader declared.
  final int charge;

  /// Kernel comment, e.g. `BANS: registering domain`.
  final String comment;

  /// `ins − outs` per asset, fee excluded: positive leaves the wallet,
  /// negative arrives in it.
  final Map<int, BigInt> spend;

  final Uint8List? deployData;

  /// For an advanced kernel the fee is fixed inside it.
  final BigInt? advancedFee;
  final int? minHeight;
  final int? maxHeight;

  bool get isAdvanced => flags & flagAdvanced != 0;
  bool get isMultisigned => flags & flagMultisigned != 0;
}

/// A decoded `ContractInvokeData`.
@immutable
class BeamInvokeData {
  const BeamInvokeData(this.entries, {this.spendExtra = const {}});

  final List<BeamInvokeEntry> entries;

  /// Multisig only: extra funds outside the entries.
  final Map<int, BigInt> spendExtra;

  /// What the whole transaction moves, per asset, fee excluded
  /// (`get_FullSpend`, `invoke_data.cpp:324-331`).
  Map<int, BigInt> get fullSpend {
    final out = <int, BigInt>{...spendExtra};
    for (final e in entries) {
      e.spend.forEach((aid, v) => out[aid] = (out[aid] ?? BigInt.zero) + v);
    }
    out.removeWhere((_, v) => v == BigInt.zero);
    return Map.unmodifiable(out);
  }

  /// The fee the wallet core will attach, in groth (`get_FullFee`).
  BigInt get fee => BeamContractFee.forInvokeData(this);

  /// All kernel comments, in order, non-empty only.
  List<String> get comments => [
    for (final e in entries)
      if (e.comment.isNotEmpty) e.comment,
  ];

  /// Decodes [rawData]. Throws [FormatException] if the bytes are not a
  /// complete `ContractInvokeData` (trailing bytes included).
  static BeamInvokeData decode(List<int> rawData) {
    final r = _YasReader(rawData);
    final count = r.size();
    final entries = <BeamInvokeEntry>[];
    for (var i = 0; i < count; i++) {
      entries.add(_entry(r));
    }
    var spendExtra = const <int, BigInt>{};
    if (entries.any((e) => e.isMultisigned)) {
      r.byte(); // m_IsSender
      r.bytes(32); // m_hvKey
      final peers = r.size();
      r.bytes(33 * peers); // m_vPeers
      spendExtra = _fundsMap(r);
    }
    if (entries.isNotEmpty) {
      final f = entries.first.flags;
      if (f & BeamInvokeEntry.flagSaveAppInvoke != 0) {
        r.blob(); // m_App
        r.blob(); // m_Contract
        final n = r.size(); // m_Args
        for (var i = 0; i < n; i++) {
          r.blob();
          r.blob();
        }
        r.unsigned(); // m_Privilege
      }
      if (f & BeamInvokeEntry.flagSaveSpendMax != 0) _fundsMap(r);
    }
    if (!r.atEnd) {
      throw FormatException(
        'invoke data: ${r.remaining} unexpected trailing bytes',
      );
    }
    return BeamInvokeData(
      List.unmodifiable(entries),
      spendExtra: Map.unmodifiable(spendExtra),
    );
  }

  static BeamInvokeEntry _entry(_YasReader r) {
    const hasFlags = 0x80000000;
    final first = r.unsignedInt();
    var flags = 0;
    int method;
    if (first & hasFlags != 0) {
      flags = first & ~hasFlags;
      method = r.unsignedInt() & ~hasFlags;
    } else {
      method = first;
    }
    final args = r.blob();
    final nSig = r.size();
    r.bytes(32 * nSig);
    final charge = r.unsignedInt();
    final comment = utf8.decode(r.blob(), allowMalformed: true);
    final spend = _fundsMap(r);
    var cid = '';
    Uint8List? data;
    if (method != 0) {
      cid = _hex(r.bytes(32));
    } else {
      data = r.blob();
    }
    BigInt? fee;
    int? hMin;
    int? hMax;
    if (flags & BeamInvokeEntry.flagAdvanced != 0) {
      final min = r.unsigned();
      final max = min + r.unsigned();
      hMin = min.isValidInt ? min.toInt() : null;
      hMax = max.isValidInt ? max.toInt() : null;
      fee = r.unsigned();
      r.bytes(65); // m_Sig
      r.bytes(32); // m_hvSk
    }
    if (flags & BeamInvokeEntry.flagDependent != 0) {
      r.unsigned();
      r.bytes(32); // m_ParentCtx
    }
    if (flags & BeamInvokeEntry.flagHasCommitment != 0) r.bytes(33);
    if (flags & BeamInvokeEntry.flagMultisigned != 0) r.bytes(33);
    return BeamInvokeEntry(
      flags: flags,
      method: method,
      contractId: cid,
      args: args,
      signatureKeyCount: nSig,
      charge: charge,
      comment: comment,
      spend: Map.unmodifiable(spend),
      deployData: data,
      advancedFee: fee,
      minHeight: hMin,
      maxHeight: hMax,
    );
  }

  static Map<int, BigInt> _fundsMap(_YasReader r) {
    final n = r.size();
    final out = <int, BigInt>{};
    for (var i = 0; i < n; i++) {
      final aid = r.unsignedInt();
      out[aid] = r.signed();
    }
    return out;
  }
}

/// The wallet core's contract fee rules after HF3
/// (`core/block_crypt.cpp:1707-1759`, `bvm/invoke_data.cpp:233-256`).
///
/// Per non-advanced call: outputs (one per spent asset, plus one BEAM
/// change output when BEAM is not spent) at 18,000 groth, one kernel at
/// 10,000, argument bytes above 32 KiB at 50 each; that is raised to the
/// standard 100,000 minimum; then the BVM charge at 10 groth per unit, at
/// least 1,000,000. A typical call therefore costs 1,100,000 groth
/// (0.011 BEAM). An advanced call carries its own fee.
abstract final class BeamContractFee {
  static const output = 18000;
  static const kernel = 10000;
  static const defaultStd = 100000;
  static const chargeUnitPrice = 10;
  static const bvmMinimum = 1000000;
  static const extraSizeFree = 32768;
  static const extraBytePrice = 50;

  static BigInt forEntry(BeamInvokeEntry e) {
    if (e.isAdvanced) return e.advancedFee ?? BigInt.zero;
    final outputs = e.spend.length + (e.spend.containsKey(0) ? 0 : 1);
    var base = output * outputs + kernel;
    final size = e.args.length + (e.deployData?.length ?? 0);
    if (size > extraSizeFree) base += extraBytePrice * (size - extraSizeFree);
    if (base < defaultStd) base = defaultStd;
    final bvm = chargeUnitPrice * e.charge;
    return BigInt.from(base + (bvm > bvmMinimum ? bvm : bvmMinimum));
  }

  static BigInt forInvokeData(BeamInvokeData d) =>
      d.entries.fold(BigInt.zero, (sum, e) => sum + forEntry(e));
}

/// Little-endian reads of a contract's argument bytes.
class BeamArgsReader {
  BeamArgsReader(List<int> bytes) : _b = Uint8List.fromList(bytes);

  final Uint8List _b;
  int _pos = 0;

  int get remaining => _b.length - _pos;
  bool get atEnd => _pos == _b.length;

  Uint8List bytes(int n) {
    if (n < 0 || n > remaining) {
      throw const FormatException('contract args: truncated');
    }
    final out = Uint8List.sublistView(_b, _pos, _pos + n);
    _pos += n;
    return Uint8List.fromList(out);
  }

  int u8() => bytes(1)[0];
  int u32() => _le(bytes(4)).toInt();
  BigInt u64() => _le(bytes(8));

  /// A 33-byte public key as 66 hex characters.
  String pubKey() => _hex(bytes(33));
}

class _YasReader {
  _YasReader(List<int> bytes) : _b = Uint8List.fromList(bytes);

  final Uint8List _b;
  int _pos = 0;

  int get remaining => _b.length - _pos;
  bool get atEnd => _pos == _b.length;

  int byte() {
    if (_pos >= _b.length) throw const FormatException('invoke data: short');
    return _b[_pos++];
  }

  Uint8List bytes(int n) {
    if (n < 0 || n > remaining) {
      throw const FormatException('invoke data: truncated');
    }
    final out = Uint8List.fromList(Uint8List.sublistView(_b, _pos, _pos + n));
    _pos += n;
    return out;
  }

  BigInt unsigned() {
    final ns = byte();
    if (ns & 0x80 != 0) return BigInt.from(ns & 0x7f);
    if (ns > 8) throw FormatException('invoke data: integer of $ns bytes');
    return _le(bytes(ns));
  }

  BigInt signed() {
    final head = byte();
    final negative = head & 0x80 != 0;
    final oneByte = head & 0x40 != 0;
    final n = head & 0x3f;
    final BigInt v;
    if (oneByte) {
      v = BigInt.from(n);
    } else {
      if (n > 8) throw FormatException('invoke data: integer of $n bytes');
      v = _le(bytes(n));
    }
    return negative ? -v : v;
  }

  /// An unsigned value that must fit a 32-bit field.
  int unsignedInt() {
    final v = unsigned();
    if (v.bitLength > 32) {
      throw const FormatException('invoke data: 32-bit field out of range');
    }
    return v.toInt();
  }

  /// A collection length, bounded by the bytes left so a corrupt length
  /// cannot make the caller allocate or loop without end.
  int size() {
    final v = unsigned();
    if (v > BigInt.from(remaining)) {
      throw const FormatException('invoke data: length beyond the data');
    }
    return v.toInt();
  }

  Uint8List blob() => bytes(size());
}

BigInt _le(Uint8List b) {
  var v = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(b[i]);
  }
  return v;
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
