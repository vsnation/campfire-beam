/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The confirmation on its own: the real mainnet swap kernel, prepared by a
// real BeamDexService, and what happens around the send.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dex/beam_dex_confirm_view.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_quotes.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/dex/dex_deps.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'dex_ui_harness.dart';

void main() {
  const g = BigInt.from;
  final real = realTradeBuild();

  Future<
    ({
      DexUiFake fake,
      FakeGate gate,
      BeamPreparedDexCall prepared,
      BeamDexDeps deps,
    })
  >
  open(WidgetTester tester, {bool? gateResult = true}) async {
    final fake = DexUiFake({
      DexArgs.poolsView(): () => recorded('pools_view'),
      real.args: () => built(real.raw),
    });
    final gate = FakeGate(gateResult);
    final deps = makeDeps(fake, gate: gate, balances: {0: beam('12.5')});
    final pool = recordedPool(0, 174, BeamPoolKind.high);
    // Prepared in the test's fake-async zone: a future completed in the
    // real zone (runAsync) would schedule the service's later calls there,
    // where the fake clock never runs them.
    final prepared = await fake.service.prepareSwap(
      BeamSwapQuote(
        pool: pool,
        payAsset: 0,
        receiveAsset: 174,
        pay: g(10000000),
        payRaw: g(9900990),
        receive: g(80368764),
        feePool: g(69307),
        feeDao: g(29703),
      ),
    );
    await pumpDex(tester, BeamDexConfirmView(deps: deps, prepared: prepared));
    await tester.pump();
    return (fake: fake, gate: gate, prepared: prepared, deps: deps);
  }

  bool ctaEnabled(WidgetTester tester) => tester
      .widget<PrimaryButton>(find.byKey(const Key('dex-confirm-cta')))
      .enabled;

  testWidgets('the wallet falls behind on this screen: button off', (
    tester,
  ) async {
    final o = await open(tester);
    expect(ctaEnabled(tester), isTrue);
    (o.deps.sync as ValueNotifier<BeamSyncAssessment>).value = catchingUp;
    await tester.pump();
    expect(ctaEnabled(tester), isFalse);
    expect(
      textOf(tester, const Key('dex-cta-reason')),
      'Paused until the wallet is up to date.',
    );
    expect(find.byKey(const Key('dex-sync-banner')), findsOneWidget);
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pump();
    expect(o.gate.reasons, isEmpty);
    expect(o.fake.executed, isEmpty);
  });

  testWidgets('a double tap asks for the PIN once and sends once', (
    tester,
  ) async {
    final o = await open(tester);
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(o.gate.reasons, hasLength(1));
    expect(o.fake.executed, hasLength(1));
    expect(o.prepared.isExecuted, isTrue);
  });

  testWidgets('a send that may or may not have gone out is never retried', (
    tester,
  ) async {
    final o = await open(tester);
    o.fake.transport.reply(
      'process_invoke_data',
      const BeamConnectionException('timed out'),
    );
    await tester.tap(find.byKey(const Key('dex-confirm-cta')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dex-send-unknown')), findsOneWidget);
    expect(find.byKey(const Key('dex-confirm-cta')), findsNothing);
    expect(find.text('Back'), findsOneWidget);
    expect(o.prepared.isExecuted, isTrue);
    expect(o.fake.transport.callsTo('process_invoke_data'), hasLength(1));
    // The service itself refuses a second send of the same prepared call.
    expect(
      () => o.deps.dex.execute(o.prepared),
      throwsA(
        isA<BeamDexException>().having(
          (e) => e.code,
          'code',
          BeamDexErrorCode.alreadyExecuted,
        ),
      ),
    );
    await settleImages(tester);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/swap_mobile_send_unknown.png'),
    );
  });
}
