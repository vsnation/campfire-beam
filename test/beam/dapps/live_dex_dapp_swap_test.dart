/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds: the Beam DEX dApp, unmodified, swaps
// BEAM for FOMO through Campfire's approval flow.
//
// The dApp runs in headless Chrome and is driven through its own page
// (open the BEAM/FOMO pool, "trade", switch to buying FOMO, type the
// amount, press "trade"); everything it then sends goes through the app's
// own path (live_dapp_harness.dart) into Campfire's real approval
// presenter, which builds the sheet's model from the decoded request and
// live wallet lookups. Only the person is simulated: the sheet's answer is
// [BEAM_LIVE_DEX_DAPP] (`approve` or `reject`).
//
// * reject: the dApp gets -32021 and nothing reaches the core.
// * approve: exactly the approved data reaches the core once; the swap
//   completes on chain (tx id, kernel, height printed).
//
// Opt-in; spends at most 0.02 BEAM plus the decoded fee on `approve`:
//
//   python3 -I scripts/beam/live/wapi.py start funder2 --port 10110 --tcp
//   BEAM_LIVE_DEX_DAPP=reject CFB_DAPP_CHROME=<chrome> \
//     flutter test test/beam/dapps/live_dex_dapp_swap_test.dart
//
// Prints tx ids cut to 12 characters, heights and amounts only.
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 30))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_presenter.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_watched_consent_queue.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';

import 'live_dapp_harness.dart';

/// R9 and the task: the swap pays at most 0.02 BEAM (plus the fee).
final _maxPay = BigInt.from(2000000);

/// FOMO to buy: about 0.01 BEAM at the pool's price on 2026-10-07; the
/// test refuses anything that would cost more than [_maxPay].
final _buyFomo = Platform.environment['BEAM_LIVE_DEX_DAPP_FOMO'] ?? '376';

String _b(BigInt g) {
  final s = g.abs().toString().padLeft(9, '0');
  final w = s.substring(0, s.length - 8);
  return '${g.isNegative ? '-' : ''}$w.${s.substring(s.length - 8)}';
}

String _short(String s) => s.length <= 12 ? s : s.substring(0, 12);

const _openPool = '''
(() => {
  const t = Array.from(document.querySelectorAll('*')).find(
      e => e.children.length === 0 && e.textContent.trim() === '(id:175)');
  if (!t) return 'no FOMO pool card';
  let c = t;
  for (let i = 0; i < 10 && c; i++) {
    c = c.parentElement;
    const b = c && Array.from(c.querySelectorAll('button'))
        .find(b => b.innerText.trim() === 'trade');
    if (b) { b.scrollIntoView(); b.click(); return 'opened'; }
  }
  return 'no trade button';
})()''';

/// The direction switch: the dApp opens the form as "receive BEAM".
const _buyFomoSide = '''
(() => { document.querySelectorAll('button')[1].click();
  return document.body.innerText.includes('RECEIVE AMOUNT') ? 'ok' : 'no form'; })()''';

String _type(String amount) =>
    '''
(() => {
  const i = document.querySelectorAll('input')[0];
  const set = Object.getOwnPropertyDescriptor(
      HTMLInputElement.prototype, 'value').set;
  set.call(i, ${jsonEncode(amount)});
  i.dispatchEvent(new Event('input', {bubbles: true}));
  return 'typed';
})()''';

const _pressTrade = '''
(() => {
  const b = Array.from(document.querySelectorAll('button'))
      .filter(b => b.innerText.trim() === 'trade').pop();
  b.click();
  return 'pressed';
})()''';

void main() {
  final mode = Platform.environment['BEAM_LIVE_DEX_DAPP'];
  final chrome = Platform.environment['CFB_DAPP_CHROME'];
  final label = Platform.environment['BEAM_LIVE_LABEL'] ?? 'funder2';
  final record = Platform.environment['CFB_DAPP_RECORD'];

  test(
    'Beam DEX dApp: BEAM -> FOMO through the approval flow ($mode)',
    () async {
      final approve = mode == 'approve';
      final tcp = await liveWalletTransport(label);
      final spy = LiveSpyTransport(tcp);
      final link = LiveWalletLink(spy);
      final presenter = DappApprovalPresenter(link);
      final queue = DappWatchedConsentQueue(presenter);
      final shown = <DappApprovalModel>[];
      presenter.attach((model) async {
        shown.add(model);
        if (!approve) return false;
        // The person approves only what they would: a swap of at most
        // 0.02 BEAM by BEAM's verified DEX code, on a wallet that may send.
        return model.kind == DappApprovalKind.swap &&
            model.canApprove &&
            model.rebuild?.verified == true &&
            model.request.pays.single.amount <= _maxPay;
      });

      final before = await link.api.walletStatus();
      final txsBefore = (await link.api.txList()).length;
      print(
        '[evidence] height ${before.currentHeight}, in sync '
        '${before.isInSync}; before: '
        '${_b(before.totalsFor(0)?.available ?? BigInt.zero)} BEAM, '
        '${_b(before.totalsFor(174)?.available ?? BigInt.zero)} FOMO',
      );
      if (approve) {
        expect(
          before.isInSync,
          isTrue,
          reason: 'never trade on a stale wallet',
        );
      }

      final entry = dappBundledCatalogue.firstWhere(
        (e) => e.fileName == 'dex-app.dapp',
      );
      final run = await LiveDappRun.open(
        entry,
        chrome: chrome!,
        wallet: spy,
        consent: queue,
        height: 900,
      );
      try {
        await run.waitFor(() => run.calls('invoke_contract').length >= 2);
        await run.settle();
        expect(await run.cdp.evaluate(_openPool), 'opened');
        await run.settle(quiet: const Duration(seconds: 2));
        expect(await run.cdp.evaluate(_buyFomoSide), 'ok');
        await run.settle(quiet: const Duration(seconds: 2));
        await run.cdp.evaluate(_type(_buyFomo));
        await run.waitFor(
          () => run
              .calls('invoke_contract')
              .any((x) => '${x.request['params']}'.contains('bPredictOnly=1')),
        );
        await run.settle(quiet: const Duration(seconds: 2));
        final processBefore = spy.to('process_invoke_data').length;
        expect(await run.cdp.evaluate(_pressTrade), 'pressed');

        // The dApp builds the trade and asks; the sheet answers.
        await run.waitFor(
          () => run
              .calls('process_invoke_data')
              .any(
                (x) =>
                    x.response != null &&
                    x.request['params'] is Map &&
                    (x.request['params']! as Map).containsKey('data'),
              ),
          timeout: const Duration(minutes: 2),
        );
        final ask = run
            .calls('process_invoke_data')
            .lastWhere(
              (x) => (x.request['params']! as Map).containsKey('data'),
            );
        expect(shown, hasLength(1), reason: 'exactly one approval shown');
        final m = shown.single;
        final r = m.request;
        print(
          '[evidence] sheet: ${m.dappName} · ${m.summary} '
          'pays ${m.pays.map((l) => l.text).join(', ')}, receives '
          '${m.receives.map((l) => l.text).join(', ')}, network fee '
          '${m.fee.text} (decoded), CTA "${m.cta}"',
        );
        print(
          '[evidence] worst case: ${m.rebuild?.appCodeLabel} '
          '(${m.rebuild?.appCodeFingerprint}); pays at most '
          '${m.rebuild?.maxPays.map((l) => l.text).join(', ')}, gets at '
          'least ${m.rebuild?.minReceives.map((l) => l.text).join(', ')}; '
          'tick needed: ${m.needsAcknowledgement}',
        );
        expect(m.kind, DappApprovalKind.swap);
        expect(r.calls.single.contractId, kDexContractId);
        expect(r.fee >= BigInt.from(1100000), isTrue, reason: 'contract call');
        expect(r.pays.single.assetId, 0);
        expect(r.receives.single.assetId, 174);
        expect(r.rebuild!.appCode, DappAppCode.beamDex);
        expect(m.needsAcknowledgement, isFalse);
        expect(r.pays.single.amount <= _maxPay, isTrue, reason: 'R9');
        if (record != null) {
          File(record).writeAsStringSync(
            jsonEncode({
              'result': {
                'raw_data_base64': base64.encode(
                  ((ask.request['params']! as Map)['data']! as List)
                      .cast<int>(),
                ),
              },
            }),
          );
        }

        if (!approve) {
          expect(ask.error!['code'], -32021, reason: "BEAM's UserRejected");
          expect(
            spy.to('process_invoke_data').length,
            processBefore,
            reason: 'nothing reached the core',
          );
          expect((await link.api.txList()).length, txsBefore);
          print('[evidence] rejected: dApp got -32021, core got nothing');
          return;
        }

        // Approved: the core got exactly the approved bytes, once.
        final sent = spy.to('process_invoke_data');
        expect(sent.length, processBefore + 1);
        expect(
          (sent.last['data']! as List).cast<int>(),
          ((ask.request['params']! as Map)['data']! as List).cast<int>(),
        );
        final txId = (ask.result! as Map)['txid']! as String;
        print('[evidence] process_invoke_data -> tx ${_short(txId)}');

        final sw = Stopwatch()..start();
        late BeamTransaction tx;
        while (true) {
          tx = await link.api.txStatus(txId);
          if (tx.status == BeamTxStatus.completed ||
              tx.status == BeamTxStatus.failed ||
              tx.status == BeamTxStatus.canceled) {
            break;
          }
          if (sw.elapsed > const Duration(minutes: 20)) {
            fail('swap not completed after 20 min: ${tx.statusString}');
          }
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        print(
          '[evidence] tx ${_short(txId)} ${tx.statusString} at height '
          '${tx.height}, kernel ${_short(tx.kernel ?? '')}, after '
          '${sw.elapsed.inSeconds} s',
        );
        expect(tx.status, BeamTxStatus.completed);
        final after = await link.api.walletStatus();
        final dBeam =
            (after.totalsFor(0)?.available ?? BigInt.zero) -
            (before.totalsFor(0)?.available ?? BigInt.zero);
        final dFomo =
            (after.totalsFor(174)?.available ?? BigInt.zero) -
            (before.totalsFor(174)?.available ?? BigInt.zero);
        print('[evidence] after: BEAM ${_b(dBeam)}, FOMO +${_b(dFomo)}');
        expect(-dBeam <= r.rebuild!.maxPays[0]! + r.fee, isTrue);
      } finally {
        for (final x in run.exchanges.skip(2)) {
          print('  ${x.summary()}');
        }
        await run.close();
        await tcp.close();
      }
    },
    skip: mode == null
        ? 'set BEAM_LIVE_DEX_DAPP=reject or approve to run'
        : chrome == null
        ? 'set CFB_DAPP_CHROME to a Chrome executable'
        : false,
  );
}
