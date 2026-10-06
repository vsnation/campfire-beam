/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Hand-built `raw_data` for dApp tests: what a malicious dApp can send to
// `process_invoke_data` without running any shader. Serialized as the core
// does (yas, little-endian, compacted integers), field order as
// BeamInvokeData.decode reads it.

import 'dart:convert';

const flagDependent = 0x02;
const flagSaveAppInvoke = 0x20;
const flagSaveSpendMax = 0x40;

/// A compacted unsigned integer.
List<int> yu(int v) {
  if (v < 128) return [0x80 | v];
  final b = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [b.length, ...b];
}

/// A compacted signed integer.
List<int> ys(int v) {
  final a = v.abs();
  final sign = v < 0 ? 0x80 : 0;
  if (a < 64) return [sign | 0x40 | a];
  final b = <int>[];
  for (var x = a; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [sign | b.length, ...b];
}

List<int> yBuf(List<int> bytes) => [...yu(bytes.length), ...bytes];

List<int> yStr(String s) => yBuf(utf8.encode(s));

List<int> hexBytes(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

/// A distinct, made-up 32-byte contract id: `cid(0xa1)` = "a1a1…a1".
String cid(int fill) => fill.toRadixString(16).padLeft(2, '0') * 32;

/// One `ContractInvokeEntry`. [spend]: positive = the wallet pays (locks
/// into the contract), negative = it receives. [sigs]: `m_vSig` key
/// hashes, hex. A null [contractId] with method 0 deploys a contract.
List<int> invokeEntry({
  required String? contractId,
  int method = 2,
  int flags = 0,
  Map<int, int> spend = const {},
  List<String> sigs = const [],
  String comment = '',
  int charge = 0,
  List<int> args = const [1, 2, 3, 4],
  int parentHeight = 4068100,
}) => [
  if (flags != 0) ...[...yu(0x80000000 | flags), ...yu(method)] else
    ...yu(method),
  ...yBuf(args),
  ...yu(sigs.length),
  for (final k in sigs) ...hexBytes(k),
  ...yu(charge),
  ...yStr(comment),
  ...yu(spend.length),
  for (final e in spend.entries) ...[...yu(e.key), ...ys(e.value)],
  if (contractId == null)
    ...yBuf(const [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])
  else
    ...hexBytes(contractId),
  if (flags & flagDependent != 0) ...[
    ...yu(parentHeight),
    ...List.filled(32, 0x5c), // a parent context hash the dApp made up
  ],
];

/// A whole `ContractInvokeData`. When the first entry carries
/// [flagSaveAppInvoke], [appShader], [appArgs] and [privilege] follow; with
/// [flagSaveSpendMax], [spendMax].
List<int> invokeData(
  List<List<int>> entries, {
  int firstFlags = 0,
  List<int> appShader = const [0, 0x61, 0x73, 0x6d],
  Map<String, String> appArgs = const {'action': 'steal'},
  int privilege = 0,
  Map<int, int> spendMax = const {0: 100000000000},
}) => [
  ...yu(entries.length),
  for (final e in entries) ...e,
  if (firstFlags & flagSaveAppInvoke != 0) ...[
    ...yBuf(appShader),
    ...yBuf(const []),
    ...yu(appArgs.length),
    for (final a in appArgs.entries) ...[...yStr(a.key), ...yStr(a.value)],
    ...yu(privilege),
  ],
  if (firstFlags & flagSaveSpendMax != 0) ...[
    ...yu(spendMax.length),
    for (final e in spendMax.entries) ...[...yu(e.key), ...ys(e.value)],
  ],
];
