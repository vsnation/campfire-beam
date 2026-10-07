/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_confirm_view.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_create_pool_view.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/widgets/beam/dex/dex_deps.dart';
import 'package:stackwallet/widgets/beam/dex/dex_format.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'dex_ui_harness.dart';

void main() {
  final createArgs = DexArgs.createPool(
    aidA: 174,
    aidB: 9,
    kind: BeamPoolKind.high,
  );

  Future<DexUiFake> openCreate(
    WidgetTester tester, {
    int aidA = 174,
    int aidB = 9,
    Map<int, BigInt>? balances,
    FakeGate? gate,
    BeamDexFiat? fiat,
  }) async {
    final fake = DexUiFake({
      DexArgs.poolsView(): () => recorded('pools_view'),
      createArgs: () => built(rawVector('create_pool')),
    });
    final deps = makeDeps(
      fake,
      gate: gate,
      balances: balances ?? {0: beam('12.5'), 174: beam('3')},
      fiat: fiat,
    );
    await pumpDex(
      tester,
      BeamDexCreatePoolView(deps: deps, aidA: aidA, aidB: aidB),
    );
    await tester.pump();
    await tester.pump();
    return fake;
  }

  bool ctaEnabled(WidgetTester tester, String key) =>
      tester.widget<PrimaryButton>(find.byKey(Key(key))).enabled;

  testWidgets('the deposit is stated first; confirm needs the tick', (
    tester,
  ) async {
    final gate = FakeGate(true);
    final fake = await openCreate(tester, gate: gate);
    expect(find.byKey(const Key('dex-create-deposit-note')), findsOneWidget);
    expect(
      find.text('Creating a pool locks a 10 BEAM deposit'),
      findsOneWidget,
    );
    expect(ctaEnabled(tester, 'dex-create-cta'), isTrue);
    expectOnScreen(tester, const Key('dex-create-cta'), phone);
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/create_pool_mobile.png'),
    );

    await tester.tap(find.byKey(const Key('dex-create-cta')));
    await tester.pumpAndSettle();
    expect(fake.seenArgs.last, createArgs);
    expect(find.byType(BeamDexConfirmView), findsOneWidget);

    final d = BeamInvokeData.decode(rawVector('create_pool'));
    expect(d.pays, {0: kDexPoolCreateDeposit});
    expect(d.fee, kDexPoolCreateFee);
    expect(
      textOf(tester, const Key('dex-create-warning')),
      'Creating a pool locks a 10 BEAM deposit, returned only when the '
      'pool is empty and destroyed.',
    );
    expect(textOf(tester, const Key('dex-confirm-pays-0')), '10 BEAM');
    expect(
      textOf(tester, const Key('dex-confirm-fee')),
      '${DexFormat.exact(d.fee)} BEAM',
    );
    expect(textOf(tester, const Key('dex-confirm-fee')), '0.01471 BEAM');
    expect(textOf(tester, const Key('dex-confirm-total')), '10.01471 BEAM');
    // Pools are named in pool order: the smaller asset id first.
    expect(find.text('Create the TICO/FOMO pool'), findsOneWidget);

    // The button stays off until the deposit is acknowledged.
    expect(ctaEnabled(tester, 'dex-confirm-cta'), isFalse);
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Tick the box above to continue.',
    );
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/create_pool_confirm_mobile.png'),
    );
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(gate.reasons, isEmpty);

    await tester.tap(find.byKey(const Key('dex-create-ack')));
    await tester.pump();
    expect(ctaEnabled(tester, 'dex-confirm-cta'), isTrue);
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(gate.reasons, ['Authenticate to create the pool']);
    expect(fake.executed.single, rawVector('create_pool'));
  });

  testWidgets('a pool that exists: say so and offer it', (tester) async {
    final fake = await openCreate(tester, aidA: 0, aidB: 174);
    expect(find.byKey(const Key('dex-create-exists')), findsOneWidget);
    expect(ctaEnabled(tester, 'dex-create-cta'), isFalse);
    expect(find.text('Open the pool'), findsOneWidget);
    expect(fake.seenArgs, [DexArgs.poolsView()]);
  });

  testWidgets('not enough BEAM for the deposit and fee', (tester) async {
    await openCreate(tester, balances: {0: beam('5')});
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Not enough BEAM. A new pool needs 10 BEAM for the deposit plus about '
      '0.01471 BEAM network fee. You have 5 BEAM.',
    );
  });

  testWidgets('the deposit says what it is worth', (tester) async {
    await openCreate(tester, fiat: realUsd);
    expect(
      find.text('Creating a pool locks a 10 BEAM deposit (≈ 0.08 USD)'),
      findsOneWidget,
    );
  });

  testWidgets('no fiat price: the deposit in BEAM only, no "(No price)"', (
    tester,
  ) async {
    await openCreate(
      tester,
      fiat: const BeamDexFiat(perBeam: null, currency: 'USD'),
    );
    expect(
      find.text('Creating a pool locks a 10 BEAM deposit'),
      findsOneWidget,
    );
  });
}
