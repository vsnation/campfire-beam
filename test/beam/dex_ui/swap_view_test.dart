/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Swap screen and its confirmation, driving a real BeamDexService over
// the recorded mainnet answers: pools_view, the 0.1 BEAM → FOMO prediction
// and the real kernel wallet-api built for it.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_confirm_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_swap_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/dex/desktop_beam_dex_view.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/dex/dex_deps.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';
import 'package:stackwallet/widgets/desktop/desktop_dialog.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'dex_ui_harness.dart';

String predict(int pay, int receive, String amount) => DexArgs.trade(
  payAsset: pay,
  receiveAsset: receive,
  kind: BeamPoolKind.high,
  payAmount: beam(amount),
  predictOnly: true,
);

/// The recorded 0.1 BEAM → FOMO prediction with `buy` replaced, to stand
/// for a pool that moved between the quote and the build.
Map<String, Object?> predictionBuying(int buy) => {
  'output': jsonEncode({
    'res': {
      'buy': buy,
      'pay': 10000000,
      'pay_raw': 9900990,
      'fee_pool': 69307,
      'fee_dao': 29703,
    },
  }),
  'txid': '00000000000000000000000000000000',
};

void main() {
  final real = realTradeBuild();
  final decoded = BeamInvokeData.decode(real.raw);

  Map<String, Object? Function()> routes() => {
    DexArgs.poolsView(): () => recorded('pools_view'),
    predict(0, 174, '0.1'): () => recorded('trade_pay_beam_get_fomo'),
    real.args: () => built(real.raw),
  };

  final wallet = {0: beam('12.5'), 174: beam('3')};

  Future<DexUiFake> openSwap(
    WidgetTester tester, {
    Map<int, BigInt>? balances,
    FakeGate? gate,
    Map<String, Object? Function()>? extra,
    int pay = 0,
    int receive = 174,
    bool desktop = false,
    BeamSyncAssessment sync = synced,
    BeamDexFiat? fiat,
    Map<int, BigInt> change = const {},
    void Function(BuildContext context, int assetId)? onSplitCoins,
  }) async {
    final fake = DexUiFake({...routes(), ...?extra});
    final deps = makeDeps(
      fake,
      balances: balances ?? wallet,
      gate: gate,
      desktop: desktop,
      sync: sync,
      fiat: fiat,
      change: change,
      onSplitCoins: onSplitCoins,
    );
    await pumpDex(
      tester,
      desktop
          ? DesktopBeamDexView(
              deps: deps,
              initialPayAsset: pay,
              initialReceiveAsset: receive,
            )
          : BeamDexSwapView(
              deps: deps,
              initialPayAsset: pay,
              initialReceiveAsset: receive,
            ),
      size: desktop ? desktopWindow : phone,
      pixelRatio: desktop ? 1 : 2,
    );
    await tester.pump();
    await tester.pump();
    return fake;
  }

  // A phone set to a region that writes 0,5 has no "." key on its decimal
  // pad: the "," it types must become the "." the DEX reads.
  testWidgets('the decimal key of a comma region types the DEX\'s "."', (
    tester,
  ) async {
    final fake = await openSwap(tester);
    final field = find.byKey(const Key('dex-pay-amount'));
    await tester.showKeyboard(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '0',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '0,',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await tester.pump();
    // The keyboard appends to what the field shows now.
    final shown = tester.widget<TextField>(field).controller!.text;
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${shown}1',
        selection: TextSelection.collapsed(offset: shown.length + 1),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '0.1');
    expect(find.text('Use a dot for decimals, like 0.5'), findsNothing);
    expect(fake.seenArgs.last, predict(0, 174, '0.1'));
  });

  testWidgets('live quote after the debounce, in plain words', (tester) async {
    final fake = await openSwap(tester, fiat: roundUsd);
    expect(fake.seenArgs, [DexArgs.poolsView()]);

    // Typing quickly asks for one price, for the final amount only.
    await tester.enterText(find.byKey(const Key('dex-pay-amount')), '0.2');
    await tester.pump(const Duration(milliseconds: 200));
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(fake.seenArgs, [DexArgs.poolsView(), predict(0, 174, '0.1')]);
    // aid1 = received (FOMO), aid2 = paid (BEAM): the settled direction.
    expect(fake.seenArgs.last, contains('aid1=174,aid2=0'));

    final field = tester.widget<TextField>(
      find.byKey(const Key('dex-receive-amount')),
    );
    expect(field.controller!.text, '0.80368764');
    expect(textOf(tester, const Key('dex-rate')), '1 BEAM ≈ 8.0368 FOMO');
    expect(textOf(tester, const Key('dex-pool-fee')), '0.0009901 BEAM');
    expect(textOf(tester, const Key('dex-network-fee')), '≈ 0.011 BEAM');
    expect(textOf(tester, const Key('dex-impact')), '< 0.01%');
    expect(textOf(tester, const Key('dex-protection-value')), '1%');
    expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
    final cta = tester.widget<PrimaryButton>(
      find.byKey(const Key('dex-swap-cta')),
    );
    expect(cta.enabled, isTrue);

    // What each side is worth (2 USD per BEAM here): FOMO by the pool
    // price the dashboard uses, the fee in fiat too.
    expect(textOf(tester, const Key('dex-pay-worth')), '≈ 0.20 USD');
    expect(textOf(tester, const Key('dex-receive-worth')), '≈ 0.19 USD');
    expect(textOf(tester, const Key('dex-network-fee-worth')), '≈ 0.02 USD');
    // 11% of the swap: no fee warning.
    expect(find.byKey(const Key('dex-fee-warning')), findsNothing);

    // USER_PSYCHOLOGY §1.3: the primary CTA is on a 375 px phone screen
    // without scrolling, and names the outcome.
    expectOnScreen(tester, const Key('dex-swap-cta'), phone);
    expect(find.text('Swap 0.1 BEAM'), findsOneWidget);

    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_quote.png'),
    );
  });

  testWidgets(
    'confirm shows the decoded kernel; execute only after the PIN gate',
    (tester) async {
      final gate = FakeGate(false);
      final fake = await openSwap(tester, gate: gate, fiat: roundUsd);
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      await tester.tap(find.byKey(const Key('dex-swap-cta')));
      await tester.pumpAndSettle();

      // Built with create_tx false; nothing sent yet.
      expect(fake.seenArgs.last, real.args);
      expect(
        fake.transport.callsTo('invoke_contract').last.params['create_tx'],
        isFalse,
      );
      expect(fake.executed, isEmpty);
      expect(find.byType(BeamDexConfirmView), findsOneWidget);

      // Every number equals the decoded transaction bytes.
      expect(decoded.pays, {0: BigInt.from(10000000)});
      expect(decoded.receives, {174: BigInt.from(80368764)});
      expect(decoded.fee, BigInt.from(1100000));
      String amount(BigInt v, String sym) => '${DexFormat.exact(v)} $sym';
      expect(
        textOf(tester, const Key('dex-confirm-pays-0')),
        amount(decoded.pays[0]!, 'BEAM'),
      );
      expect(textOf(tester, const Key('dex-confirm-pays-0')), '0.1 BEAM');
      expect(
        textOf(tester, const Key('dex-confirm-receives-174')),
        amount(decoded.receives[174]!, 'FOMO'),
      );
      expect(
        textOf(tester, const Key('dex-confirm-receives-174')),
        '0.80368764 FOMO',
      );
      expect(
        textOf(tester, const Key('dex-confirm-fee')),
        amount(decoded.fee, 'BEAM'),
      );
      expect(textOf(tester, const Key('dex-confirm-fee')), '0.011 BEAM');
      expect(
        textOf(tester, const Key('dex-confirm-total')),
        amount(decoded.pays[0]! + decoded.fee, 'BEAM'),
      );
      expect(textOf(tester, const Key('dex-confirm-total')), '0.111 BEAM');
      expect(
        textOf(tester, const Key('dex-confirm-destination')),
        'BEAM DEX contract 729fe0…ef9cbf',
      );
      // Every amount says what it is worth.
      expect(
        textOf(tester, const Key('dex-confirm-pays-0-worth')),
        '≈ 0.20 USD',
      );
      expect(
        textOf(tester, const Key('dex-confirm-receives-174-worth')),
        '≈ 0.19 USD',
      );
      expect(textOf(tester, const Key('dex-confirm-fee-worth')), '≈ 0.02 USD');
      expect(
        textOf(tester, const Key('dex-confirm-total-worth')),
        '≈ 0.22 USD',
      );
      // The button names the outcome.
      expect(
        tester
            .widget<PrimaryButton>(find.byKey(const Key('dex-confirm-cta')))
            .label,
        'Swap 0.1 BEAM',
      );
      expect(decoded.entries.single.contractId, kDexContractId);
      expectOnScreen(tester, const Key('dex-confirm-cta'), phone);
      // No character on the confirmation: nothing distracts from the money.
      expect(find.byType(BeamStickerImage), findsNothing);
      expect(find.byType(BeamAnimatedStickerView), findsNothing);

      await settleImages(tester);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/swap_mobile_confirm.png'),
      );

      // Wrong PIN: nothing is sent.
      await tester.tap(find.byKey(const Key('dex-confirm-cta')));
      await tester.pumpAndSettle();
      expect(gate.reasons, ['Authenticate to swap']);
      expect(fake.executed, isEmpty);
      expect(fake.transport.callsTo('process_invoke_data'), isEmpty);
      expect(find.byKey(const Key('dex-gate-message')), findsOneWidget);
      expect(find.text('Wrong PIN. Nothing was sent.'), findsOneWidget);

      // Backed out of the PIN screen: still nothing.
      gate.result = null;
      await tester.tap(find.byKey(const Key('dex-confirm-cta')));
      await tester.pumpAndSettle();
      expect(fake.executed, isEmpty);

      // Right PIN: the exact built bytes are sent, once.
      gate.result = true;
      await tester.tap(find.byKey(const Key('dex-confirm-cta')));
      await tester.pumpAndSettle();
      expect(fake.executed, hasLength(1));
      expect(fake.executed.single, real.raw);
      expect(textOf(tester, const Key('dex-success-txid')), fake.txId);
      // Said once, under the sticker; not again in the title.
      expect(find.text('Swap sent'), findsOneWidget);
      expect(find.byKey(const Key('dex-swap-done-sticker')), findsOneWidget);

      await settleImages(tester);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/swap_mobile_sent.png'),
      );

      // Done returns to the swap form, cleared.
      await tester.tap(find.byKey(const Key('dex-confirm-done')));
      await tester.pumpAndSettle();
      expect(find.byType(BeamDexConfirmView), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('dex-pay-amount')))
            .controller!
            .text,
        '',
      );
      expect(fake.executed, hasLength(1));
    },
  );

  testWidgets('not synced: plain banner, button off with the reason', (
    tester,
  ) async {
    final fake = await openSwap(tester, sync: catchingUp);
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(find.byKey(const Key('dex-sync-banner')), findsOneWidget);
    expect(find.text('Catching up with the network'), findsOneWidget);
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Swaps are paused until the wallet is up to date.',
    );
    await tester.tap(find.byKey(const Key('dex-swap-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexConfirmView), findsNothing);
    expect(fake.seenArgs, isNot(contains(real.args)));
    expectOnScreen(tester, const Key('dex-swap-cta'), phone);

    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_not_synced.png'),
    );
  });

  testWidgets('not enough of the paid asset', (tester) async {
    await openSwap(tester, balances: {0: beam('0.05')});
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Not enough BEAM. You have 0.05 BEAM.',
    );
    expectOnScreen(tester, const Key('dex-swap-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_insufficient.png'),
    );
  });

  // B-UTXO-1: the money is there, only tied up in a payment that has not
  // finished. Say when it is back, and offer the fix for next time.
  testWidgets('money in an unfinished payment: back in a minute, and a '
      'split offered for next time', (tester) async {
    final opened = <int>[];
    await openSwap(
      tester,
      balances: {0: beam('0.05')},
      change: {0: beam('0.8')},
      onSplitCoins: (_, assetId) => opened.add(assetId),
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      "0.8 BEAM is in a payment that hasn't finished yet; it's back in "
      'about a minute.',
    );
    expectOnScreen(tester, const Key('dex-swap-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_waiting.png'),
    );
    await tester.tap(find.byKey(const Key('dex-cta-reason-action')));
    await tester.pump();
    expect(opened, [0]);
  });

  testWidgets('the network fee counts: 0.1 BEAM held cannot swap 0.1', (
    tester,
  ) async {
    await openSwap(tester, balances: {0: beam('0.1')});
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Not enough BEAM. You need 0.111 BEAM, including the 0.011 BEAM '
      'network fee.',
    );
    // Max leaves the fee in the wallet.
    await tester.tap(find.byKey(const Key('dex-max')));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('dex-pay-amount')))
          .controller!
          .text,
      '0.089',
    );
  });

  testWidgets('BEAM received pays the fee: FOMO → BEAM with no BEAM', (
    tester,
  ) async {
    // The contract unlocks more BEAM than the call costs, so the core
    // selects no BEAM coins at all (project rules, gasless contract calls).
    await openSwap(
      tester,
      pay: 174,
      receive: 0,
      balances: {174: beam('3')},
      extra: {
        predict(174, 0, '0.1'): () => recorded('trade_pay_fomo_get_beam'),
      },
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
    expect(
      tester
          .widget<PrimaryButton>(find.byKey(const Key('dex-swap-cta')))
          .enabled,
      isTrue,
    );
  });

  testWidgets('token-only wallet: a swap that brings back less BEAM than the '
      'fee needs BEAM', (tester) async {
    await openSwap(
      tester,
      pay: 174,
      receive: 0,
      balances: {174: beam('3')},
      extra: {
        predict(174, 0, '0.1'): () => {
          'output': jsonEncode({
            'res': {
              'buy': 1000000,
              'pay': 9999996,
              'pay_raw': 9900986,
              'fee_pool': 69307,
              'fee_dao': 29703,
            },
          }),
          'txid': '00000000000000000000000000000000',
        },
      },
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'You need 0.011 BEAM for the network fee. You have 0 BEAM.',
    );
  });

  testWidgets('no pool for the pair: say so, offer BEAM first or a pool', (
    tester,
  ) async {
    final fake = await openSwap(
      tester,
      pay: 174,
      receive: 9,
      extra: {
        predict(174, 0, '0.1'): () => recorded('trade_pay_fomo_get_beam'),
      },
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(find.byKey(const Key('dex-no-pool')), findsOneWidget);
    expect(find.text('No pool trades FOMO for TICO yet'), findsOneWidget);
    expect(find.text('Swap FOMO for BEAM'), findsOneWidget);
    expect(find.text('Create a pool'), findsOneWidget);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_no_pool.png'),
    );

    // One tap to the route that exists.
    await tester.tap(find.text('Swap FOMO for BEAM'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.pump();
    expect(fake.seenArgs.last, predict(174, 0, '0.1'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('dex-receive-amount')))
          .controller!
          .text,
      '0.01219726',
    );
  });

  testWidgets('quote failed: not the user\'s fault, one-tap retry', (
    tester,
  ) async {
    var fail = true;
    final fake = await openSwap(
      tester,
      extra: {
        predict(0, 174, '0.1'): () => fail
            ? throw const BeamRpcException(-32603, 'Internal JSON-RPC error.')
            : recorded('trade_pay_beam_get_fomo'),
      },
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(find.byKey(const Key('dex-quote-failed')), findsOneWidget);
    expect(find.text("Couldn't get a price"), findsOneWidget);
    expect(find.textContaining('not something you did'), findsOneWidget);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_quote_failed.png'),
    );

    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('dex-quote-failed')), findsNothing);
    expect(textOf(tester, const Key('dex-rate')), '1 BEAM ≈ 8.0368 FOMO');
    expect(
      fake.seenArgs.where((a) => a == predict(0, 174, '0.1')),
      hasLength(2),
    );
  });

  testWidgets('price protection: a build that moved too far is not offered', (
    tester,
  ) async {
    // Quoted 0.813 FOMO; the build delivers 0.80368764 (1.15% less).
    final fake = await openSwap(
      tester,
      extra: {predict(0, 174, '0.1'): () => predictionBuying(81300000)},
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    await tester.tap(find.byKey(const Key('dex-swap-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexConfirmView), findsNothing);
    expect(find.byKey(const Key('dex-price-moved')), findsOneWidget);
    expect(find.text('The price moved 1.14% since your quote'), findsOneWidget);
    expect(fake.executed, isEmpty);
  });

  testWidgets('price protection: a small move is shown on the confirmation', (
    tester,
  ) async {
    await openSwap(
      tester,
      extra: {predict(0, 174, '0.1'): () => predictionBuying(80500000)},
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    await tester.tap(find.byKey(const Key('dex-swap-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexConfirmView), findsOneWidget);
    expect(find.text('The price moved 0.16% since your quote'), findsOneWidget);
    // The confirmation still shows the decoded amount, not the quote.
    expect(
      textOf(tester, const Key('dex-confirm-receives-174')),
      '0.80368764 FOMO',
    );
  });

  testWidgets('a stricter protection refuses what 1% accepts', (tester) async {
    await openSwap(
      tester,
      extra: {predict(0, 174, '0.1'): () => predictionBuying(80500000)},
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    await tester.tap(find.byKey(const Key('dex-protection')));
    await tester.pumpAndSettle();
    expect(find.textContaining('slippage tolerance'), findsOneWidget);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_protection.png'),
    );
    await tester.tap(find.byKey(const Key('dex-protection-1000')));
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('dex-protection-value')), '0.1%');
    await tester.tap(find.byKey(const Key('dex-swap-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexConfirmView), findsNothing);
    expect(find.byKey(const Key('dex-price-moved')), findsOneWidget);
  });

  testWidgets('desktop: swap beside the pools; confirm in a dialog', (
    tester,
  ) async {
    final gate = FakeGate(true);
    final fake = await openSwap(
      tester,
      desktop: true,
      gate: gate,
      fiat: roundUsd,
    );
    await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
    expect(find.text('All pools · 75'), findsOneWidget);
    expectOnScreen(tester, const Key('dex-swap-cta'), desktopWindow);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/dex_desktop.png'),
    );

    await tester.tap(find.byKey(const Key('dex-swap-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopDialog), findsOneWidget);
    expect(textOf(tester, const Key('dex-confirm-total')), '0.111 BEAM');
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_desktop_confirm.png'),
    );
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(gate.reasons, hasLength(1));
    expect(fake.executed.single, real.raw);
  });

  group('the network fee on a small swap (DMG test #25)', () {
    /// A prediction for [pay] groth of BEAM in the 1% BEAM/FOMO pool, with
    /// the pool's own fee split, as the AMM shader answers.
    Map<String, Object?> prediction(int pay, int payRaw, int buy) {
      final fee = BeamPoolKind.high.tradeFee(BigInt.from(payRaw));
      expect(BigInt.from(payRaw) + fee.pool + fee.dao, BigInt.from(pay));
      return {
        'output': jsonEncode({
          'res': {
            'buy': buy,
            'pay': pay,
            'pay_raw': payRaw,
            'fee_pool': fee.pool.toInt(),
            'fee_dao': fee.dao.toInt(),
          },
        }),
        'txid': '00000000000000000000000000000000',
      };
    }

    testWidgets('0.02 BEAM: "more than half", with the numbers', (
      tester,
    ) async {
      // The owner's live swap: 0.02 BEAM for 0.1607 FOMO, 0.011 BEAM fee.
      await openSwap(
        tester,
        fiat: realUsd,
        extra: {
          predict(0, 174, '0.02'): () => prediction(2000000, 1980198, 16073951),
        },
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.02');
      expect(
        find.text('The network fee is more than half of what you swap'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Every swap costs 0.011 BEAM in network fees, whatever the amount. '
          'Here that is 55% of the 0.02 BEAM you swap. A larger swap pays '
          'the same fee.',
        ),
        findsOneWidget,
      );
      // At 0.0086 USD per BEAM, nothing here reaches a cent, and nothing
      // says "0.00".
      expect(textOf(tester, const Key('dex-pay-worth')), 'under 0.01 USD');
      expect(textOf(tester, const Key('dex-receive-worth')), 'under 0.01 USD');
      expect(
        textOf(tester, const Key('dex-network-fee-worth')),
        'under 0.01 USD',
      );
      expect(find.textContaining('0.00 USD'), findsNothing);
      // A warning, not a block: the user may still swap.
      final cta = tester.widget<PrimaryButton>(
        find.byKey(const Key('dex-swap-cta')),
      );
      expect(cta.enabled, isTrue);
      expect(cta.label, 'Swap 0.02 BEAM');
      expectOnScreen(tester, const Key('dex-swap-cta'), phone);
      // The whole warning is in view above the button, without scrolling.
      expectOnScreen(tester, const Key('dex-fee-warning'), phone);
      expect(
        tester.getRect(find.byKey(const Key('dex-fee-warning'))).bottom,
        lessThan(tester.getRect(find.byKey(const Key('dex-swap-cta'))).top),
      );
      await settleImages(tester);
      await expectLater(
        find.byKey(goldenKey),
        matchesGoldenFile('goldens/swap_mobile_fee_warning.png'),
      );
    });

    testWidgets('0.005 BEAM: the fee is more than the swap', (tester) async {
      await openSwap(
        tester,
        extra: {
          predict(0, 174, '0.005'): () => prediction(500000, 495049, 4018493),
        },
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.005');
      expect(
        find.text('The network fee is more than what you swap'),
        findsOneWidget,
      );
      expect(find.textContaining('Here that is 220% of'), findsOneWidget);
    });

    testWidgets('0.04 BEAM: a quarter or more says the share', (tester) async {
      await openSwap(
        tester,
        extra: {
          predict(0, 174, '0.04'): () => prediction(4000000, 3960396, 32147802),
        },
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.04');
      expect(
        find.text('The network fee is 27.5% of what you swap'),
        findsOneWidget,
      );
    });

    testWidgets('FOMO paid: valued through its pool', (tester) async {
      // 0.1 FOMO is worth about 0.0122 BEAM: 0.011 BEAM is 89% of it.
      await openSwap(
        tester,
        pay: 174,
        receive: 0,
        extra: {
          predict(174, 0, '0.1'): () => recorded('trade_pay_fomo_get_beam'),
        },
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      expect(
        find.text('The network fee is more than half of what you swap'),
        findsOneWidget,
      );
      expect(
        find.textContaining('of what you swap (worth about 0.01231'),
        findsOneWidget,
      );
    });
  });

  group('the button names the outcome (DMG test #26)', () {
    testWidgets('"Swap" until an amount is typed, then "Swap 0.1 FOMO"', (
      tester,
    ) async {
      await openSwap(
        tester,
        pay: 174,
        receive: 0,
        extra: {
          predict(174, 0, '0.1'): () => recorded('trade_pay_fomo_get_beam'),
        },
      );
      String label() => tester
          .widget<PrimaryButton>(find.byKey(const Key('dex-swap-cta')))
          .label!;
      expect(label(), 'Swap');
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      expect(label(), 'Swap 0.1 FOMO');
    });
  });

  group('what amounts are worth', () {
    testWidgets('no fiat price yet: BEAM says so, FOMO in BEAM', (
      tester,
    ) async {
      await openSwap(
        tester,
        fiat: const BeamDexFiat(perBeam: null, currency: 'USD'),
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      expect(textOf(tester, const Key('dex-pay-worth')), 'No USD price');
      expect(textOf(tester, const Key('dex-receive-worth')), '≈ 0.099 BEAM');
      expect(
        textOf(tester, const Key('dex-network-fee-worth')),
        'No USD price',
      );
      expect(find.textContaining('0.00 USD'), findsNothing);
    });

    testWidgets('price lookups off: nothing under BEAM, FOMO in BEAM', (
      tester,
    ) async {
      await openSwap(tester);
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      expect(find.byKey(const Key('dex-pay-worth')), findsNothing);
      expect(textOf(tester, const Key('dex-receive-worth')), '≈ 0.099 BEAM');
      expect(find.byKey(const Key('dex-network-fee-worth')), findsNothing);
    });

    testWidgets('an asset no pool prices: "No price", never a number', (
      tester,
    ) async {
      // #26 trades only in a pool holding 1 groth of BEAM: far below the
      // 1,000 BEAM an unverified asset needs before it is priced.
      await openSwap(
        tester,
        receive: 26,
        fiat: roundUsd,
        extra: {predict(0, 26, '0.1'): () => predictionBuying(3)},
      );
      await typeAmount(tester, const Key('dex-pay-amount'), '0.1');
      expect(textOf(tester, const Key('dex-pay-worth')), '≈ 0.20 USD');
      expect(textOf(tester, const Key('dex-receive-worth')), 'No price');
    });
  });
}
