/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Real wallet-api answers recorded on 2026-10-06 at height 4068103 from a
// throwaway, zero-balance wallet running the pinned BANS shader against
// eu-node01.mainnet.beam.mw (invoke_contract with create_tx=false only;
// nothing was broadcast). The throwaway wallet's own BANS key is replaced
// by the synthetic [fakeMyKey] everywhere, including inside raw_data. Other
// keys are public chain data that the explorer serves to anyone.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:stackwallet/wallets/beam/contracts/bans/bans_shader.dart';

const fakeMyKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';

/// The `beam` name's owner (the BEAM foundation's key).
const beamOwnerKey =
    '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';

const vaultCid =
    'a3385e50cf33afc9f769ee1d82d56b73046d680d343977f36d9a303d7bcdc4da';
const daoVaultCid =
    '0066b12078623df132b691001b25d7eb94b207b42c018020c9e58152e21ecd25';

/// The unregistered names the recorded register quotes were built for.
const quotedName5 = 'cfbac2de77099';
const quotedName4 = 'cf70';

Map<String, Object?> bansEnvelope(String name) =>
    (jsonDecode(
              File(
                'test/beam/contracts/bans/fixtures/$name.json',
              ).readAsStringSync(),
            )
            as Map)
        .cast<String, Object?>();

Map<String, Object?> bansResult(String name) =>
    (bansEnvelope(name)['result']! as Map).cast<String, Object?>();

String bansOutput(String name) => bansResult(name)['output']! as String;

List<int> bansRaw(String name) => [
  for (final b in bansResult(name)['raw_data']! as List) b as int,
];

/// The pinned shader as committed in the repo.
BansShaderLoader repoShader() => BansShaderLoader(
  () async => Uint8List.fromList(
    File('assets/beam/shaders/bans_app.wasm').readAsBytesSync(),
  ),
);
