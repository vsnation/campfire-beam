/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the shared decoder gained when BANS moved onto it: advanced entries
// on request (BANS claims), signing-key hashes, stored app shader and
// privilege, comments; and the shared little-endian args reader/writer.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/contract_args.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';

import '../dex/dex_fixtures.dart';

List<int> u(int v) {
  if (v < 128) return [0x80 | v];
  final b = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [b.length, ...b];
}

List<int> s(int v) {
  final a = v.abs();
  final sign = v < 0 ? 0x80 : 0;
  if (a < 64) return [sign | 0x40 | a];
  final b = <int>[];
  for (var x = a; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [sign | b.length, ...b];
}

List<int> bigU(BigInt v) {
  if (v < BigInt.from(128)) return [0x80 | v.toInt()];
  final b = <int>[];
  for (var x = v; x > BigInt.zero; x >>= 8) {
    b.add((x & BigInt.from(0xff)).toInt());
  }
  return [b.length, ...b];
}

/// One entry with [flags]; the advanced part and commitment are written
/// when the flags say so.
List<int> entry(
  int flags, {
  BigInt? hMin,
  BigInt? dh,
  int fee = 1100000,
  List<List<int>> sigs = const [],
}) => [
  ...u(0x80000000 | flags),
  ...u(3),
  ...u(1),
  7,
  ...u(sigs.length),
  for (final k in sigs) ...k,
  ...u(0),
  ...u(1),
  0x63,
  ...u(1),
  ...u(0),
  ...s(-5000),
  ...List.filled(32, 0xa3),
  if (flags & 0x01 != 0) ...[
    ...bigU(hMin ?? BigInt.from(4068103)),
    ...bigU(dh ?? BigInt.from(15)),
    ...u(fee),
    ...List.filled(65, 1),
    ...List.filled(32, 2),
  ],
  if (flags & 0x10 != 0) ...List.filled(33, 3),
  if (flags & 0x08 != 0) ...List.filled(33, 4),
];

void main() {
  group('advanced entries', () {
    final advCommit = [...u(1), ...entry(0x11, fee: 1234567)];

    test('refused by default, read when the caller allows them', () {
      expect(() => BeamInvokeData.decode(advCommit), throwsFormatException);
      final d = BeamInvokeData.decode(advCommit, allowAdvanced: true);
      final e = d.entries.single;
      expect(e.isAdvanced, isTrue);
      expect(e.isMultisigned, isFalse);
      expect(e.advancedFee, BigInt.from(1234567));
      // The fee fixed in the kernel, not the formula's 0.011 BEAM.
      expect(d.fee, BigInt.from(1234567));
      expect(e.minHeight, BigInt.from(4068103));
      expect(e.maxHeight, BigInt.from(4068118));
      expect(d.receives, {0: BigInt.from(5000)});
      expect(d.pays, isEmpty);
    });

    test('an advanced entry without a stored commitment', () {
      final d = BeamInvokeData.decode([
        ...u(1),
        ...entry(0x01),
      ], allowAdvanced: true);
      expect(d.entries.single.advancedFee, BigInt.from(1100000));
    });

    test('max height adds in 64 bits, as the core does', () {
      final max = (BigInt.one << 64) - BigInt.one;
      final d = BeamInvokeData.decode([
        ...u(1),
        ...entry(0x01, hMin: max, dh: BigInt.two),
      ], allowAdvanced: true);
      expect(d.entries.single.minHeight, max);
      expect(d.entries.single.maxHeight, BigInt.one);
    });

    test('multisig is refused even when advanced entries are allowed', () {
      // The trailing multisig section (peers, key) is not even present: the
      // decoder must stop at the flag.
      for (final allow in [false, true]) {
        expect(
          () => BeamInvokeData.decode([
            ...u(1),
            ...entry(0x09),
          ], allowAdvanced: allow),
          throwsFormatException,
          reason: 'allowAdvanced: $allow',
        );
      }
    });

    test('a commitment without an advanced kernel is refused', () {
      expect(
        () => BeamInvokeData.decode([
          ...u(1),
          ...entry(0x10),
        ], allowAdvanced: true),
        throwsFormatException,
      );
    });

    test('truncated at every length, with advanced entries allowed', () {
      for (var n = 0; n < advCommit.length; n++) {
        expect(
          () => BeamInvokeData.decode(
            advCommit.sublist(0, n),
            allowAdvanced: true,
          ),
          throwsFormatException,
          reason: 'length $n',
        );
      }
      expect(
        () => BeamInvokeData.decode([...advCommit, 0], allowAdvanced: true),
        throwsFormatException,
      );
    });
  });

  group('signing keys, stored app invoke, comments', () {
    test('m_vSig hashes are exposed in order', () {
      final k1 = List.filled(32, 0x11);
      final k2 = [for (var i = 0; i < 32; i++) i];
      final d = BeamInvokeData.decode([
        ...u(1),
        ...entry(0, sigs: [k1, k2]),
      ]);
      final e = d.entries.single;
      expect(e.signatureCount, 2);
      expect(e.signatureKeyHashes, [
        '11' * 32,
        [for (var i = 0; i < 32; i++) i.toRadixString(16).padLeft(2, '0')]
            .join(),
      ]);
    });

    test('a dependent call keeps its app shader, args and privilege', () {
      final d = BeamInvokeData.decode(rawDataVector('add_dependent'));
      expect(d.entries.single.signatureKeyHashes, hasLength(1));
      expect(d.entries.single.signatureKeyHashes.single, hasLength(64));
      expect(d.appShader, isNotNull);
      expect(d.contractShader, isNotNull);
      expect(d.appPrivilege, isNotNull);
      expect(d.appArgs!['action'], 'pool_add_liquidity');
      expect(() => d.appShader![0] = 1, throwsUnsupportedError);
    });

    test('a plain call stores none of that', () {
      final d = BeamInvokeData.decode(rawDataVector('trade_plain'));
      expect(d.entries.single.signatureKeyHashes, isEmpty);
      expect(d.appShader, isNull);
      expect(d.contractShader, isNull);
      expect(d.appPrivilege, isNull);
      expect(d.comments, ['Amm trade']);
    });

    test('comments skip empty ones', () {
      final empty = [
        ...u(7),
        ...u(0),
        ...u(0),
        ...u(0),
        ...u(0),
        ...u(0),
        ...List.filled(32, 1),
      ];
      // count 2: one with comment "c", one with none.
      final d = BeamInvokeData.decode([...u(2), ...entry(0), ...empty]);
      expect(d.entries, hasLength(2));
      expect(d.comments, ['c']);
    });
  });

  group('BeamArgsWriter / BeamArgsReader', () {
    test('round trip of the packed fields services check', () {
      final bytes = [
        ...BeamArgsWriter.le(174, 4),
        ...BeamArgsWriter.le(BigInt.parse('18446744073709551615'), 8),
        ...BeamArgsWriter.le(0, 1),
        ...List.filled(33, 0xab),
      ];
      final r = BeamArgsReader(bytes);
      expect(r.u32(), 174);
      expect(r.u64(), BigInt.parse('18446744073709551615'));
      expect(r.u8(), 0);
      expect(r.pubKey(), 'ab' * 33);
      expect(r.atEnd, isTrue);
      expect(() => r.u8(), throwsFormatException);
    });

    test('little-endian, same bytes the services built before', () {
      expect(BeamArgsWriter.le(0x01020304, 4), [4, 3, 2, 1]);
      expect(
        BeamArgsWriter.le(BigInt.from(0x0102), 8),
        [2, 1, 0, 0, 0, 0, 0, 0],
      );
      expect(BeamArgsWriter.le(0, 4), [0, 0, 0, 0]);
    });

    test('nothing is silently truncated', () {
      expect(() => BeamArgsWriter.le(1 << 32, 4), throwsArgumentError);
      expect(() => BeamArgsWriter.le(-1, 4), throwsArgumentError);
      expect(
        () => BeamArgsWriter.le(BigInt.one << 64, 8),
        throwsArgumentError,
      );
      expect(() => BeamArgsWriter.le(1.5, 4), throwsArgumentError);
      expect(() => BeamArgsWriter.le(1, 0), throwsArgumentError);
      expect(BeamArgsWriter.le((1 << 32) - 1, 4), [255, 255, 255, 255]);
    });

    test('reads are bounds-checked and return copies', () {
      final src = Uint8List.fromList([1, 2, 3, 4]);
      final r = BeamArgsReader(src);
      final b = r.bytes(2);
      b[0] = 9;
      src[1] = 9;
      expect(BeamArgsReader(const [1, 2, 3, 4]).bytes(2), [1, 2]);
      expect(r.bytes(2), [3, 4]);
      expect(() => r.bytes(1), throwsFormatException);
      expect(
        () => BeamArgsReader(const [1, 2, 3]).u32(),
        throwsFormatException,
      );
    });
  });
}
