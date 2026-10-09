/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

/// Pipe answers recorded on mainnet on 2026-10-09 at height 4072898 (see
/// the `_comment` in each file and `live_pipe_test.dart`). `flutter test`
/// runs from the package root.
const pipeFixtureDir = 'test/beam/bridge/fixtures';

const pipeShaders = FileShaderSource('assets/beam/shaders');

/// The b2e receiver of every recorded `send`, and the amounts.
const recordedReceiver = '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a';
final recordedSendAmount = BigInt.from(100000000);
final recordedSendFee = BigInt.from(1000000);

/// The recorded `receive` builds: route id → (msgId, amount claimed).
const recordedReceives = {
  'usdt': (78, 91049000),
  'eth': (67, 500000),
  'beam': (226, 2000000),
};

Map<String, Object?> _load(String name) =>
    (jsonDecode(File('$pipeFixtureDir/$name').readAsStringSync()) as Map)
        .cast<String, Object?>();

final Map<String, String> _views = (_load('pipe_views.json')['views']! as Map)
    .cast<String, String>();

final Map<String, Map<String, Object?>> _builds = {
  for (final e in (_load('pipe_builds.json')['builds']! as Map).entries)
    e.key as String: (e.value as Map).cast<String, Object?>(),
};

/// The recorded output of [args] run with [shader].
String? recordedView(BridgeShader shader, String args) =>
    _views['${shader.name} $args'];

/// The recorded `invoke_contract` answer of the build [args].
Map<String, Object?>? recordedBuild(String args) {
  final b = _builds[args];
  if (b == null) return null;
  return {
    'output': b['output'],
    'txid': '0' * 32,
    'raw_data': base64.decode(b['raw_data_base64']! as String),
  };
}

List<int> recordedRawData(String args) =>
    base64.decode(_builds[args]!['raw_data_base64']! as String);

String recordedRawSha256(String args) =>
    _builds[args]!['raw_data_sha256']! as String;

Iterable<String> get recordedBuildArgs => _builds.keys;

/// Which pinned shader a request carried, by its length.
BridgeShader shaderOf(Map<String, Object?> params) =>
    switch ((params['contract']! as List).length) {
      kPipeAppShaderSize => BridgeShader.forward,
      kPipeReverseAppShaderSize => BridgeShader.reverse,
      final n => throw StateError('a $n-byte shader is not a pipe shader'),
    };

/// Answers `invoke_contract` like the recorded wallet, or from [overrides]
/// (keyed by the exact args), and keeps every request.
class PipeRouter {
  PipeRouter({this.overrides = const {}});

  final Map<String, Object? Function()> overrides;
  final seen = <Map<String, Object?>>[];

  List<String> get args => [for (final p in seen) p['args']! as String];

  Object? call(Map<String, Object?> params) {
    seen.add(params);
    final args = params['args']! as String;
    final o = overrides[args];
    if (o != null) return o();
    final view = recordedView(shaderOf(params), args);
    if (view != null) return {'output': view, 'txid': '0' * 32};
    final build = recordedBuild(args);
    if (build != null) return build;
    throw StateError('no recorded answer for ${shaderOf(params).name} $args');
  }
}

List<int> hexBytes(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

/// [v] as [n] little-endian bytes.
List<int> le(int v, int n) => [
  for (var i = 0; i < n; i++) (v >> (8 * i)) & 0xff,
];
