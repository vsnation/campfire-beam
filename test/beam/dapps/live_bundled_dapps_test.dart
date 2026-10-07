/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, read-only: each of the 9 bundled dApps, unmodified, in headless
// Chrome, against a real wallet on mainnet through the app's own dApp path
// (live_dapp_harness.dart). Nothing is signed: every approval is refused.
//
// Proves that the contract reads each dApp makes on its own when it opens
// (`invoke_contract` with its own app shader) reach the core and come back
// without an error, and prints every exchange for diagnosis.
//
// Opt-in. Needs Chrome, the fetched packages and a running TCP-mode
// wallet-api (any wallet; a fresh one with no funds is enough):
//
//   test/beam/dapps/tool/fetch_bundled_dapps.sh
//   python3 -I scripts/beam/live/wapi.py start <label> --port 10121 --tcp
//   BEAM_LIVE_DAPPS=1 BEAM_LIVE_LABEL=<label> CFB_DAPP_CHROME=<chrome> \
//     flutter test test/beam/dapps/live_bundled_dapps_test.dart
//
// CFB_DAPP_SHOTS=<folder> keeps a PNG of each dApp after it settled.
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 40))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

import 'live_dapp_harness.dart';

class _RecordAndRefuse implements DappConsentPolicy {
  final seen = <DappConsentRequest>[];

  @override
  Future<bool> approve(DappConsentRequest request) async {
    seen.add(request);
    return false;
  }
}

void main() {
  final enabled = Platform.environment['BEAM_LIVE_DAPPS'] == '1';
  final chrome = Platform.environment['CFB_DAPP_CHROME'];
  final label = Platform.environment['BEAM_LIVE_LABEL'] ?? 'w2views';
  final shots = Platform.environment['CFB_DAPP_SHOTS'];
  final only = Platform.environment['CFB_DAPP_ONLY'];

  TcpLineTransport? wallet;
  setUpAll(() async {
    if (enabled) wallet = await liveWalletTransport(label);
  });
  tearDownAll(() async => wallet?.close());

  for (final entry in dappBundledCatalogue) {
    if (only != null && !entry.fileName.contains(only)) continue;
    test(
      '${entry.name}: its own contract reads reach the core and succeed',
      () async {
        final policy = _RecordAndRefuse();
        final run = await LiveDappRun.open(
          entry,
          chrome: chrome!,
          wallet: wallet!,
          consent: DappConsentQueue(policy),
        );
        try {
          await run.waitFor(() => run.calls('invoke_contract').isNotEmpty);
          await run.settle(timeout: const Duration(minutes: 2));
          // Pages that poll (BeamX DAO, the NFT gallery) always have a
          // read in flight: judge the ones asked so far, once answered.
          final invokes = run.calls('invoke_contract');
          await run.waitFor(
            () => invokes.every((x) => x.response != null),
            timeout: const Duration(seconds: 90),
          );
          print('=== ${entry.name} (${entry.fileName})');
          for (final x in run.exchanges) {
            print('  ${x.summary()}');
          }
          for (final c in run.console.take(20)) {
            print('  console $c');
          }
          if (shots != null) {
            Directory(shots).createSync(recursive: true);
            File(p.join(shots, 'live_${entry.fileName}.png'))
                .writeAsBytesSync(await run.cdp.screenshot());
          }
          expect(
            invokes,
            isNotEmpty,
            reason: 'the dApp never read its contract',
          );
          for (final x in invokes) {
            expect(x.response, isNotNull, reason: 'unanswered: ${x.summary()}');
            final e = x.error;
            if (e != null && entry.fileName == 'bans.dapp') {
              // By design: the BANS dApp's own name list derives keys
              // with get_PkEx, which needs privilege; Campfire gives
              // privilege only to its own Names screen.
              expect('${e['data']}', contains('get_PkEx'), reason: x.summary());
              continue;
            }
            expect(e, isNull, reason: x.summary());
          }
          // Every other wallet call answered without an error the dApp
          // cannot live with: only IPFS (not built into the core) and the
          // DEX's empty process_invoke_data after each price preview.
          for (final x in run.exchanges) {
            if (x.response == null || x.error == null) continue;
            if (x.method == 'invoke_contract') continue;
            final why = x.summary();
            expect(
              x.method == 'ipfs_get' ||
                  (x.method == 'process_invoke_data' &&
                      '${x.error!['data']}'.contains('data is required')),
              isTrue,
              reason: why,
            );
          }
          expect(policy.seen, isEmpty, reason: 'nothing asks to sign on open');
        } finally {
          await run.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: !enabled
          ? 'set BEAM_LIVE_DAPPS=1 to run'
          : chrome == null
          ? 'set CFB_DAPP_CHROME to a Chrome executable'
          : false,
    );
  }
}
