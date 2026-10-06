/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Get a name: live validation, availability from recorded view_name
// answers, the quote, and the confirmation built from the real register
// kernel wallet-api produced on mainnet (never sent).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/names/beam_name_confirm_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_register_view.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/widgets/beam/names/names_deps.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'names_ui_harness.dart';

Map<String, Object?> _routes() => {
  'my_key': 'my_key',
  'view_params': 'view_params',
  'view_domain': 'view_domain_pk',
  'view_name:beam': 'view_name_beam',
  'view_name:nephrite': 'view_name_listed',
  'view_name:upperfixture': 'view_name_upper',
  'view_name:beamer': 'view_name_hold',
  // Synthetic: expired 200 days ago, past its 90 days of grace.
  'view_name:lapsed': viewName(beamOwnerKey, tipHeight - 200 * blocksPerDay),
  'view_name': 'view_name_free',
  'domain_register': 'register5',
  'domain_buy': 'buy_listed',
};

bool _ctaEnabled(WidgetTester tester) => tester
    .widget<PrimaryButton>(find.byKey(const Key('names-register-cta')))
    .enabled;

void main() {
  late NamesUiFake fake;
  late BeamNamesDeps deps;
  Object? popped;

  Future<void> open(
    WidgetTester tester, {
    Map<String, Object?>? routes,
    FakeGate? gate,
    Map<int, BigInt>? balances,
    bool desktop = false,
    VoidCallback? onAddFunds,
  }) async {
    fake = NamesUiFake({..._routes(), ...?routes});
    deps = makeDeps(
      fake,
      gate: gate,
      balances: balances,
      desktop: desktop,
      onAddFunds: onAddFunds,
    );
    popped = null;
    await pumpNames(
      tester,
      Launcher(
        open: (c) => BeamNameRegisterView.show(c, deps: deps),
        onResult: (r) => popped = r,
      ),
      size: desktop ? desktopWindow : phone,
      pixelRatio: desktop ? 1 : 2,
    );
    await tester.tap(find.byKey(const Key('launch')));
    await settle(tester);
  }

  test('the test serialiser reproduces the recorded register kernel', () {
    // Proof that the synthetic renew/transfer/list kernels used elsewhere
    // are serialised exactly as the core does it.
    expect(registerRaw(quotedName5, 1, price5), bansRaw('register5'));
  });

  testWidgets('invalid names are explained before anything is asked', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Get a name'), findsWidgets);
    expect(
      textOf(tester, const Key('names-register-tiers')),
      contains(
        '\$10 a year for 5 or more characters, \$120 for 4 and '
        '\$320 for 3',
      ),
    );

    await typeName(tester, 'ab');
    expect(
      textOf(tester, const Key('names-register-hint')),
      'Names need at least 3 characters.',
    );
    await typeName(tester, 'my name!');
    expect(
      textOf(tester, const Key('names-register-hint')),
      'Use only lowercase letters, numbers, - _ and ~.',
    );
    expect(_ctaEnabled(tester), isFalse);
    // No lookup for a name the contract would refuse anyway.
    expect(fake.actions, isNot(contains('view_name')));
    expectOnScreen(tester, const Key('names-register-cta'), phone);
    await golden(tester, 'register_mobile_invalid');
  });

  testWidgets('capitals become lowercase; .beam is accepted', (tester) async {
    await open(tester);
    await typeName(tester, 'Beam');
    final field = tester.widget<TextField>(
      find.byKey(const Key('names-register-field')),
    );
    expect(field.controller!.text, 'beam');
    expect(fake.seenArgs.last, contains('action=view_name'));
    expect(fake.seenArgs.last, contains('name=beam'));

    await typeName(tester, 'beam.beam');
    expect(fake.seenArgs.last, endsWith('name=beam'));
    expect(fake.actions.where((a) => a == 'view_name'), hasLength(2));
  });

  testWidgets('a taken name (recorded: beam) says until when', (tester) async {
    await open(tester);
    await typeName(tester, 'beam');
    expect(textOf(tester, const Key('names-register-status')), 'beam is taken');
    expect(find.textContaining('Registered until'), findsOneWidget);
    expect(find.textContaining('anyone can get it after'), findsOneWidget);
    expect(_ctaEnabled(tester), isFalse);
    expect(
      textOf(tester, const Key('names-cta-reason')),
      'beam is taken. Try another name above.',
    );
    await golden(tester, 'register_mobile_taken');
  });

  testWidgets('on hold (recorded: beamer) and available again', (tester) async {
    await open(tester);
    await typeName(tester, 'beamer');
    expect(
      textOf(tester, const Key('names-register-status')),
      'beamer is taken',
    );
    expect(
      find.textContaining('its owner can still renew it until'),
      findsOneWidget,
    );
    expect(_ctaEnabled(tester), isFalse);

    await typeName(tester, 'lapsed');
    expect(
      textOf(tester, const Key('names-register-status')),
      'lapsed is available',
    );
    expect(find.textContaining('let it expire'), findsOneWidget);
    expect(find.text('Get lapsed for 1 year'), findsOneWidget);
    expect(_ctaEnabled(tester), isTrue);
  });

  testWidgets('the shader refusing a name reads as plain words', (
    tester,
  ) async {
    // Recorded: view_name_upper is the shader's "name is invalid".
    await open(tester);
    await typeName(tester, 'upperfixture');
    expect(
      find.byKey(const Key('names-register-lookup-error')),
      findsOneWidget,
    );
    expect(
      find.text('Names use only a-z, 0-9, - _ and ~, in lowercase.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'available → quote → confirm shows the decoded kernel; the PIN gate '
    'decides whether anything is sent',
    (tester) async {
      final gate = FakeGate(false);
      await open(tester, gate: gate);
      await typeName(tester, quotedName5);

      expect(
        textOf(tester, const Key('names-register-status')),
        '$quotedName5 is available',
      );
      expect(textOf(tester, const Key('names-register-usd')), '\$10');
      // 10 USD / 0.00860 (5 decimals, truncated) → between 1,161.44 and
      // 1,162.79 BEAM; the midpoint rounds to 1,162.
      expect(textOf(tester, const Key('names-register-beam')), '≈ 1,162 BEAM');
      expect(
        textOf(tester, const Key('names-register-price-note')),
        contains(
          "set by BEAM's name service in dollars and paid in BEAM "
          "at today's rate (1 BEAM ≈ \$0.00860)",
        ),
      );
      expect(find.text('Get $quotedName5 for 1 year'), findsOneWidget);
      expectOnScreen(tester, const Key('names-register-cta'), phone);
      await golden(tester, 'register_mobile_available');

      await tester.tap(find.byKey(const Key('names-register-cta')));
      await settle(tester);
      expect(find.byType(BeamNameConfirmView), findsOneWidget);
      expect(fake.actions.where((a) => a == 'domain_register'), hasLength(1));
      expect(fake.executed, isEmpty);

      // Every number equals the recorded kernel's decoded bytes.
      final decoded = BeamInvokeData.decode(bansRaw('register5'));
      expect(decoded.pays, {0: BigInt.from(price5)});
      expect(decoded.fee, BigInt.from(1100000));
      final pay = '${NamesFormat.exact(decoded.pays[0]!)} BEAM';
      final fee = '${NamesFormat.exact(decoded.fee)} BEAM';
      final total = '${NamesFormat.exact(decoded.pays[0]! + decoded.fee)} BEAM';
      expect(textOf(tester, const Key('names-confirm-pay-0')), pay);
      expect(pay, '1,162.13166091 BEAM');
      expect(textOf(tester, const Key('names-confirm-fee')), fee);
      expect(fee, '0.011 BEAM');
      expect(textOf(tester, const Key('names-confirm-total')), total);
      expect(total, '1,162.14266091 BEAM');
      expect(
        textOf(tester, const Key('names-confirm-name')),
        '$quotedName5.beam',
      );
      expect(
        textOf(tester, const Key('names-confirm-expiry')),
        startsWith('≈'),
      );
      expect(find.text('Pay & register $quotedName5'), findsOneWidget);
      expectOnScreen(tester, const Key('names-confirm-cta'), phone);
      await golden(tester, 'confirm_register_mobile');

      // Wrong PIN: nothing is rebuilt, nothing is sent.
      await tester.tap(find.byKey(const Key('names-confirm-cta')));
      await settle(tester);
      expect(gate.reasons, ['Authenticate to register $quotedName5']);
      expect(fake.executed, isEmpty);
      expect(fake.actions.where((a) => a == 'domain_register'), hasLength(1));
      expect(find.text("That PIN didn't match. Nothing was sent."), findsOne);

      // Backed out of the PIN: still nothing.
      gate.result = null;
      await tester.tap(find.byKey(const Key('names-confirm-cta')));
      await settle(tester);
      expect(fake.executed, isEmpty);

      // The right PIN: rebuilt once more from the chain, then sent once,
      // exactly the recorded transaction.
      gate.result = true;
      await tester.tap(find.byKey(const Key('names-confirm-cta')));
      await settle(tester);
      expect(fake.actions.where((a) => a == 'domain_register'), hasLength(2));
      expect(fake.executed, [bansRaw('register5')]);
      expect(fake.transport.callsTo('process_invoke_data'), hasLength(1));

      // Back on the caller with what was sent, and the name pending.
      expect(find.byType(BeamNameRegisterView), findsNothing);
      final sent = popped! as BeamNameSent;
      expect(sent.txId, fake.txId);
      expect(sent.action, BansAction.register);
      expect(deps.pending.of(quotedName5)!.kind, BansPendingKind.register);
    },
  );

  testWidgets('the price moved between quote and signing: new total first', (
    tester,
  ) async {
    // The second build (after the PIN) comes back 1% dearer, as when the
    // oracle median updates in between.
    const dearer = price5 + price5 ~/ 100;
    await open(
      tester,
      routes: {
        'domain_register': (int n) =>
            n == 1 ? 'register5' : built(registerRaw(quotedName5, 1, dearer)),
      },
    );
    await typeName(tester, quotedName5);
    await tester.tap(find.byKey(const Key('names-register-cta')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);

    expect(fake.executed, isEmpty, reason: 'nothing signed at the old price');
    expect(
      find.text('The BEAM price moved; here is the new total.'),
      findsOneWidget,
    );
    final newTotal = BigInt.from(dearer) + BigInt.from(1100000);
    expect(
      textOf(tester, const Key('names-confirm-total')),
      '${NamesFormat.exact(newTotal)} BEAM',
    );
    await golden(tester, 'confirm_register_price_moved');

    // Confirming again (PIN again) sends the transaction built at the new
    // price — the third build agrees with the second.
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, [registerRaw(quotedName5, 1, dearer)]);
  });

  testWidgets('not enough BEAM: the button becomes Add BEAM', (tester) async {
    var added = 0;
    await open(tester, balances: {0: beam('12.5')}, onAddFunds: () => added++);
    await typeName(tester, quotedName5);
    expect(find.text('Add BEAM'), findsOneWidget);
    expect(
      textOf(tester, const Key('names-cta-reason')),
      'You have 12.5 BEAM; $quotedName5 costs about 1,161 BEAM for 1 year.',
    );
    await tester.tap(find.byKey(const Key('names-register-cta')));
    await tester.pump();
    expect(added, 1);
    expect(fake.actions, isNot(contains('domain_register')));
  });

  testWidgets('a wallet that is behind cannot register', (tester) async {
    fake = NamesUiFake(_routes());
    deps = makeDeps(fake, sync: catchingUp);
    await pumpNames(
      tester,
      Launcher(open: (c) => BeamNameRegisterView.show(c, deps: deps)),
    );
    await tester.tap(find.byKey(const Key('launch')));
    await settle(tester);
    await typeName(tester, quotedName5);
    expect(find.byKey(const Key('names-sync-banner')), findsOneWidget);
    expect(_ctaEnabled(tester), isFalse);
    expect(
      textOf(tester, const Key('names-cta-reason')),
      'Registering is paused until your wallet is up to date.',
    );
  });

  testWidgets('desktop: the confirmation in a dialog', (tester) async {
    await open(tester, desktop: true);
    await typeName(tester, quotedName5);
    await tester.tap(find.byKey(const Key('names-register-cta')));
    await settle(tester);
    expect(find.byType(BeamNameConfirmView), findsOneWidget);
    expect(
      textOf(tester, const Key('names-confirm-total')),
      '1,162.14266091 BEAM',
    );
    await golden(tester, 'confirm_register_desktop');
    expect(fake.executed, isEmpty);
  });
}
