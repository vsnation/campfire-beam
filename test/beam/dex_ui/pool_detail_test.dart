/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pool detail: the position (valued by BeamAssetPricer), adding liquidity
// with the second amount computed by the shader, withdrawing a share, and
// both confirmations, over the recorded predictions and raw_data vectors.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_confirm_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_pool_detail_view.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'dex_ui_harness.dart';

void main() {
  const g = BigInt.from;
  final beamFomo = recordedPool(0, 174, BeamPoolKind.high);

  String add({required bool predict}) => DexArgs.addLiquidity(
    aid1: 0,
    aid2: 174,
    kind: BeamPoolKind.high,
    amount1: g(10000000),
    predictOnly: predict,
  );

  String withdraw({required bool predict}) => DexArgs.withdraw(
    aid1: 0,
    aid2: 174,
    kind: BeamPoolKind.high,
    ctl: g(100000000),
    predictOnly: predict,
  );

  Map<String, Object? Function()> routes() => {
    DexArgs.poolsView(): () => recorded('pools_view'),
    add(predict: true): () => recorded('add_beam_side'),
    add(predict: false): () => built(rawVector('add_dependent')),
    withdraw(predict: true): () => recorded('withdraw_ctl'),
    withdraw(predict: false): () => built(rawVector('withdraw')),
  };

  Future<DexUiFake> openPool(
    WidgetTester tester, {
    FakeGate? gate,
    Map<int, BigInt>? balances,
  }) async {
    final fake = DexUiFake(routes());
    final deps = makeDeps(
      fake,
      gate: gate,
      balances: balances ?? {0: beam('12.5'), 174: beam('3'), 175: beam('1')},
      // A round fiat price, so the golden shows the format.
      fiat: roundUsd,
    );
    await pumpDex(tester, BeamDexPoolDetailView(deps: deps, pool: beamFomo));
    await tester.pump();
    await tester.pump();
    return fake;
  }

  testWidgets('position valued by the pricer; add one side, other computed', (
    tester,
  ) async {
    final gate = FakeGate(true);
    final fake = await openPool(tester, gate: gate);

    // 1 LP of 21,252.5781388: its share, and both sides valued in BEAM
    // through the deepest BEAM pool (this one): 0.29987143 BEAM plus
    // 2.43416758 FOMO at 0.12319… BEAM.
    expect(textOf(tester, const Key('dex-position-share')), '< 0.01%');
    expect(
      textOf(tester, const Key('dex-position-value')),
      '0.5997 BEAM · 1.19 USD',
    );
    expect(textOf(tester, const Key('dex-pool-price')), '1 BEAM = 8.1173 FOMO');
    // The pool's size: 6,373.04 BEAM and as much again in FOMO, at 2 USD.
    expect(textOf(tester, const Key('dex-pool-size')), '≈ 25,492.16 USD');

    await typeAmount(tester, const Key('dex-add-amount-1'), '0.1');
    // Only BEAM was given: the shader filled in FOMO (val2=0).
    expect(fake.seenArgs, contains(add(predict: true)));
    expect(add(predict: true), contains('val1=10000000,val2=0'));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('dex-add-amount-2')))
          .controller!
          .text,
      '0.81173706',
    );
    expect(textOf(tester, const Key('dex-add-share')), '< 0.01%');
    // Each side says what it is worth.
    expect(textOf(tester, const Key('dex-add-worth-1')), '≈ 0.20 USD');
    expect(textOf(tester, const Key('dex-add-worth-2')), '≈ 0.19 USD');
    expect(
      tester
          .widget<PrimaryButton>(find.byKey(const Key('dex-liquidity-cta')))
          .enabled,
      isTrue,
    );
    expectOnScreen(tester, const Key('dex-liquidity-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/pool_detail_mobile_add.png'),
    );

    await tester.tap(find.byKey(const Key('dex-liquidity-cta')));
    await tester.pumpAndSettle();
    expect(find.byType(BeamDexConfirmView), findsOneWidget);
    expect(fake.executed, isEmpty);

    final d = BeamInvokeData.decode(rawVector('add_dependent'));
    expect(
      textOf(tester, const Key('dex-confirm-pays-0')),
      '${DexFormat.exact(d.pays[0]!)} BEAM',
    );
    expect(
      textOf(tester, const Key('dex-confirm-pays-174')),
      '${DexFormat.exact(d.pays[174]!)} FOMO',
    );
    expect(
      textOf(tester, const Key('dex-confirm-pays-174')),
      '0.81173706 FOMO',
    );
    expect(
      textOf(tester, const Key('dex-confirm-receives-175')),
      '${DexFormat.exact(d.receives[175]!)} BEAM/FOMO LP',
    );
    expect(
      textOf(tester, const Key('dex-confirm-fee')),
      '${DexFormat.exact(d.fee)} BEAM',
    );
    expect(
      textOf(tester, const Key('dex-confirm-total')),
      '0.111 BEAM + 0.81173706 FOMO',
    );
    expectOnScreen(tester, const Key('dex-confirm-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/add_liquidity_confirm_mobile.png'),
    );

    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(gate.reasons, ['Authenticate to add liquidity']);
    expect(fake.executed.single, rawVector('add_dependent'));
  });

  testWidgets('withdraw a share: what comes back, then the confirmation', (
    tester,
  ) async {
    final gate = FakeGate(false);
    final fake = await openPool(tester, gate: gate);
    await tester.tap(find.byKey(const Key('dex-mode-withdraw')));
    await tester.pump();
    await tester.pump();
    expect(fake.seenArgs, contains(withdraw(predict: true)));
    expect(
      textOf(tester, const Key('dex-withdraw-back')),
      '0.29987143 BEAM + 2.43416758 FOMO',
    );
    // Both sides together: 0.59974286 BEAM at 2 USD.
    expect(textOf(tester, const Key('dex-withdraw-worth')), '≈ 1.19 USD');
    expect(find.text('Withdraw'), findsWidgets);
    expectOnScreen(tester, const Key('dex-liquidity-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/pool_detail_mobile_withdraw.png'),
    );

    await tester.tap(find.byKey(const Key('dex-liquidity-cta')));
    await tester.pumpAndSettle();
    final d = BeamInvokeData.decode(rawVector('withdraw'));
    expect(d.pays, {175: g(100000000)});
    expect(textOf(tester, const Key('dex-confirm-pays-175')), '1 BEAM/FOMO LP');
    expect(
      textOf(tester, const Key('dex-confirm-receives-0')),
      '${DexFormat.exact(d.receives[0]!)} BEAM',
    );
    expect(
      textOf(tester, const Key('dex-confirm-receives-174')),
      '2.43416758 FOMO',
    );
    expect(textOf(tester, const Key('dex-confirm-fee')), '0.011 BEAM');
    expect(
      textOf(tester, const Key('dex-confirm-total')),
      '0.011 BEAM + 1 BEAM/FOMO LP',
    );
    // Pool tokens are valued as their share of both sides.
    expect(
      textOf(tester, const Key('dex-confirm-pays-175-worth')),
      '≈ 1.19 USD',
    );
    expect(textOf(tester, const Key('dex-confirm-total-worth')), '≈ 1.22 USD');
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/withdraw_confirm_mobile.png'),
    );
    // Wrong PIN: nothing sent.
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(gate.reasons, ['Authenticate to withdraw']);
    expect(fake.executed, isEmpty);
  });

  testWidgets('an empty pool asks for both amounts and says why', (
    tester,
  ) async {
    final fake = DexUiFake(routes());
    final deps = makeDeps(fake, balances: {0: beam('12.5')});
    await pumpDex(
      tester,
      BeamDexPoolDetailView(
        deps: deps,
        pool: recordedPool(0, 1, BeamPoolKind.high),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('dex-pool-is-empty')), findsOneWidget);
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      "Enter both amounts. They set the pool's starting price.",
    );
  });
}
