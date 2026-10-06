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

/// Public DEX responses recorded from mainnet on 2026-10-06 at height
/// 4068104 (`invoke_contract`, `create_tx: false`, views and
/// `bPredictOnly=1` only). `creator` flags, which identify the recording
/// wallet's pools, were removed. `flutter test` runs from the package root.
const dexFixtureDir = 'test/beam/contracts/dex/fixtures';

const dexCid =
    '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';

Map<String, Object?> dexEnvelope(String name) =>
    (jsonDecode(File('$dexFixtureDir/$name.json').readAsStringSync()) as Map)
        .cast<String, Object?>();

/// The recorded shader `output` text of [name].
String dexOutput(String name) =>
    ((dexEnvelope(name)['result']! as Map)['output']! as String);

/// A yas-serialized `raw_data` test vector (see `tool/`).
List<int> rawDataVector(String name) {
  final json =
      jsonDecode(
            File('$dexFixtureDir/raw_data_vectors.json').readAsStringSync(),
          )
          as Map;
  final hex = (json['vectors']! as Map)[name]! as String;
  return [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
