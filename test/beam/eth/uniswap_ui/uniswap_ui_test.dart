/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Uniswap screens on Campfire's theme, phone (375 × 667) and desktop
// (1280 × 800), over a fake service (uniswap_ui_fakes.dart): the form with
// a price, the reasons the button is off, the big-price-change tick box,
// the token picker with what trades with WBEAM (and a fake "USDT"), the
// exact-amount approval, the review and its PIN, the finished swap, no
// pool, and the pools list. Goldens are copied to
// docs/beam/screenshots/B-UNISWAP/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/eth/uniswap_ui/uniswap_ui_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_approve_view.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_deps.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_pools_view.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_swap_view.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_token_picker.dart';
import 'package:stackwallet/pages_desktop_specific/eth/uniswap/desktop_uniswap_view.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import '../../wiring_ui/wiring_harness.dart';
import 'uniswap_ui_fakes.dart';

Finder _k(String key) => find.byKey(Key(key));

String _text(WidgetTester tester, String key) {
  final w = tester.widget(_k(key));
  if (w is Text) return w.data ?? w.textSpan!.toPlainText();
  throw StateError('$key is ${w.runtimeType}');
}

/// Lets the fake service's futures finish and the screen redraw.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

Future<void> _type(WidgetTester tester, String amount) async {
  await tester.enterText(_k('uni-pay-amount'), amount);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 520));
  await _flush(tester);
}

/// [pumpWiring] with Material's icon font, which the screens use.
bool _icons = false;

Future<void> _pump(
  WidgetTester tester,
  Widget w, {
  required bool desktop,
}) async {
  await pumpWiring(tester, w, desktop: desktop);
  if (!_icons) {
    _icons = true;
    await loadMaterialIcons(tester);
    await tester.pump();
  }
}

Future<void> _golden(String name) =>
    expectLater(find.byKey(goldenKey), matchesGoldenFile('goldens/$name.png'));

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('phone: the empty form says what to do', (tester) async {
    final deps = fakeUniswapDeps(desktop: false);
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    expect(_text(tester, 'dex-cta-reason'), 'Enter how much ETH to swap.');
    expect(_text(tester, 'uni-pay-balance'), 'Balance 0.0042 ETH');
    await _golden('phone_uniswap_empty');
    await finish(tester);
  });

  testWidgets('phone: a price, the route, the least you receive', (
    tester,
  ) async {
    final deps = fakeUniswapDeps(desktop: false);
    await _pump(
      tester,
      UniswapSwapView(deps: deps, onPayWithOtherCoin: () {}),
      desktop: false,
    );
    await _flush(tester);
    expect(find.byKey(const Key('uni-pay-other-coin')), findsOneWidget);
    await _type(tester, '0.001');
    expect(_text(tester, 'uni-rate'), '1 ETH ≈ 322,127.46 WBEAM');
    expect(_text(tester, 'uni-route'), 'ETH → WBEAM');
    expect(_text(tester, 'uni-route-pools'), 'Uniswap v4 · 1%');
    expect(_text(tester, 'uni-impact'), '0.31%');
    expect(_text(tester, 'uni-minimum'), startsWith('At least 318.9'));
    expect(find.text('Swap 0.001 ETH'), findsOneWidget);
    expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
    await _golden('phone_uniswap_quote');
    await finish(tester);
  });

  testWidgets('phone: more ETH than the wallet has says so', (tester) async {
    final deps = fakeUniswapDeps(desktop: false);
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    await _type(tester, '1');
    expect(
      _text(tester, 'dex-cta-reason'),
      'Not enough ETH. You have 0.0042 ETH.',
    );
    await finish(tester);
  });

  testWidgets('phone: a 14% price change needs a tick first', (tester) async {
    final service = FakeUniswapService()..mode = FakeQuoteMode.bigImpact;
    final deps = fakeUniswapDeps(desktop: false, service: service);
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    await _type(tester, '0.003');
    expect(find.byKey(const Key('uni-impact-warning')), findsOneWidget);
    expect(
      _text(tester, 'dex-cta-reason'),
      'Tick the box to accept the price change.',
    );
    await tester.ensureVisible(_k('uni-impact-ack'));
    await _golden('phone_uniswap_big_impact');
    await tester.tap(_k('uni-impact-ack'));
    await _flush(tester);
    expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
    await finish(tester);
  });

  testWidgets('phone: no pool says what Campfire looked at', (tester) async {
    final service = FakeUniswapService()..mode = FakeQuoteMode.noPool;
    final deps = fakeUniswapDeps(desktop: false, service: service);
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    await _type(tester, '0.001');
    expect(find.byKey(const Key('uni-no-pool')), findsOneWidget);
    await _golden('phone_uniswap_no_pool');
    await finish(tester);
  });

  testWidgets('phone: the picker lists what trades with WBEAM, and warns '
      'about a copy of USDT', (tester) async {
    final deps = fakeUniswapDeps(desktop: false);
    UniToken? picked;
    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open'),
            onPressed: () async => picked = await showUniTokenPicker(
              context,
              deps: deps,
              title: 'You receive',
              selected: kWbeamToken,
              other: kWbeamToken,
            ),
            child: const Text('open'),
          ),
        ),
      ),
      desktop: false,
    );
    await tester.tap(_k('open'));
    await _flush(tester);
    expect(find.text('Trades with WBEAM on Uniswap'), findsOneWidget);
    expect(find.text('KAS'), findsOneWidget);
    expect(find.text('wXTM'), findsOneWidget);
    await _golden('phone_uniswap_picker');
    await tester.enterText(_k('uni-token-search'), fakeUsdt.address);
    await _flush(tester);
    expect(find.textContaining('Not the real USDT'), findsOneWidget);
    await tester.ensureVisible(_k('uni-token-${kas.address}'));
    await tester.pump();
    await tester.tap(_k('uni-token-${kas.address}'));
    await _flush(tester);
    expect(picked, kas);
    await finish(tester);
  });

  testWidgets('phone: WBEAM asks for an exact-amount permission first', (
    tester,
  ) async {
    final signer = FakeSigner();
    final gate = FakeUniGate();
    final deps = fakeUniswapDeps(desktop: false, signer: signer, gate: gate);
    var ok = false;
    await _pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open'),
            onPressed: () async => ok =
                await UniswapApproveView.show(
                  context,
                  deps: deps,
                  approval: UniApproval(
                    UniApprovalKind.approve,
                    kWbeamToken,
                    BigInt.from(1000) * beamUnit,
                    BigInt.zero,
                  ),
                ) ??
                false,
            child: const Text('open'),
          ),
        ),
      ),
      desktop: false,
    );
    await tester.tap(_k('open'));
    await _flush(tester);
    expect(find.text('Allow 1,000 WBEAM'), findsOneWidget);
    await _golden('phone_uniswap_approve');
    await tester.tap(_k('uni-approve-cta'));
    await _flush(tester);
    expect(gate.reasons, ['Authenticate to allow WBEAM']);
    expect(signer.sent.single.kind, UniTxKind.approve);
    expect(signer.sent.single.note, 'Uniswap: allow 1,000 WBEAM');
    expect(ok, isTrue);
    await finish(tester);
  });

  testWidgets('phone: review, PIN, and what arrived', (tester) async {
    final signer = FakeSigner();
    final gate = FakeUniGate();
    final deps = fakeUniswapDeps(desktop: false, signer: signer, gate: gate);
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    await _type(tester, '0.001');
    await tester.tap(_k('uni-swap-cta'));
    await _flush(tester);
    expect(find.text('Confirm swap'), findsOneWidget);
    expect(_text(tester, 'uni-review-pay'), '0.001 ETH');
    expect(_text(tester, 'uni-review-receive'), '322.12746 WBEAM');
    expect(_text(tester, 'uni-review-minimum'), startsWith('At least 318.'));
    expect(find.byKey(const Key('uni-review-permit')), findsNothing);
    await _golden('phone_uniswap_review');
    // Nothing is signed or sent before the PIN.
    expect(signer.sent, isEmpty);
    await tester.tap(_k('uni-review-cta'));
    await _flush(tester);
    expect(gate.reasons, ['Authenticate to swap']);
    expect(signer.sent.single.kind, UniTxKind.swap);
    expect(signer.sent.single.value, ethUnit ~/ BigInt.from(1000));
    expect(signer.sent.single.note, 'Uniswap: swap 0.001 ETH for WBEAM');
    expect(find.byKey(const Key('uni-review-done')), findsOneWidget);
    expect(
      find.text('Swap done: you received 3,221.27460965 WBEAM'),
      findsOneWidget,
    );
    await _golden('phone_uniswap_done');
    await finish(tester);
  });

  testWidgets('phone: a wrong PIN sends nothing', (tester) async {
    final signer = FakeSigner();
    final deps = fakeUniswapDeps(
      desktop: false,
      signer: signer,
      gate: FakeUniGate(answer: false),
    );
    await _pump(tester, UniswapSwapView(deps: deps), desktop: false);
    await _flush(tester);
    await _type(tester, '0.001');
    await tester.tap(_k('uni-swap-cta'));
    await _flush(tester);
    await tester.tap(_k('uni-review-cta'));
    await _flush(tester);
    expect(signer.sent, isEmpty);
    expect(find.text('Confirm swap'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('phone: every pool between ETH and WBEAM', (tester) async {
    final deps = fakeUniswapDeps(desktop: false);
    await _pump(
      tester,
      UniswapPoolsView(deps: deps, a: UniToken.eth, b: kWbeamToken),
      desktop: false,
    );
    await _flush(tester);
    expect(
      _text(tester, 'uni-pools-summary'),
      startsWith('2 of 2 pools can trade now'),
    );
    await _golden('phone_uniswap_pools');
    await finish(tester);
  });

  testWidgets('desktop: the form beside every pool', (tester) async {
    final deps = fakeUniswapDeps(desktop: true);
    await _pump(
      tester,
      DesktopUniswapView(deps: deps, onPayWithOtherCoin: () {}),
      desktop: true,
    );
    await _flush(tester);
    await _type(tester, '0.001');
    expect(_text(tester, 'uni-rate'), '1 ETH ≈ 322,127.46 WBEAM');
    expect(find.byKey(const Key('uni-pools-summary')), findsOneWidget);
    await _golden('desktop_uniswap');
    await finish(tester);
  });

  testWidgets('desktop: the review is a dialog', (tester) async {
    final deps = fakeUniswapDeps(desktop: true);
    await _pump(tester, DesktopUniswapView(deps: deps), desktop: true);
    await _flush(tester);
    await _type(tester, '0.001');
    await tester.tap(_k('uni-swap-cta'));
    await _flush(tester);
    expect(find.text('Confirm swap'), findsOneWidget);
    await _golden('desktop_uniswap_review');
    await finish(tester);
  });
}
