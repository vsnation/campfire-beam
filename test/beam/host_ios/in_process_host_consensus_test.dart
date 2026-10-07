/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The in-process core's consensus check runs once per process, so it has a
// test file (and process) of its own.

import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';

import 'in_process_host_test.dart' show FakeCore;

void main() {
  test('a core whose rules lack HF6 is refused before anything runs', () async {
    final tmp = await Directory.systemTemp.createTemp('beam_inproc_rules_');
    addTearDown(() => tmp.delete(recursive: true));
    final old = FakeCore(rules: 'network=mainnet\n\t0-ed91a717313c6eb0\n');
    final h = InProcessHost(rootDir: p.join(tmp.path, 'beam'), library: old);
    final dir = p.join(tmp.path, 'beam', 'wallets', 'w');
    await expectLater(
      h.initWallet(
        walletDir: dir,
        password: 'right-password',
        words: bip39.generateMnemonic().split(' '),
      ),
      throwsA(
        isA<BeamHostException>().having(
          (e) => e.kind,
          'kind',
          BeamHostError.consensusMismatch,
        ),
      ),
    );
    await expectLater(
      h.openWallet(
        walletDir: dir,
        password: 'right-password',
        node: const BeamNodeEndpoint('127.0.0.1', 8100),
      ),
      throwsA(isA<BeamHostException>()),
    );
    expect(old.initCalls, 0);
    expect(old.runs, isEmpty);
  });
}
