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

/// Sanitized wallet-api responses recorded from a real wallet
/// (`scripts/beam/live/sanitize_fixtures.py`). `flutter test` runs with the
/// package root as the working directory.
Map<String, Object?> fixtureEnvelope(String name) =>
    (jsonDecode(File('test/beam/fixtures/$name.json').readAsStringSync())
            as Map)
        .cast<String, Object?>();

Object? fixtureResult(String name) => fixtureEnvelope(name)['result'];

Map<String, Object?> fixtureMap(String name) =>
    (fixtureResult(name)! as Map).cast<String, Object?>();

List<Map<String, Object?>> fixtureList(String name) => [
  for (final e in fixtureResult(name)! as List)
    (e as Map).cast<String, Object?>(),
];
