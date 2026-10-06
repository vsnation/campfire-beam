/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A name's details and everything done to an owned name — renew, transfer,
// list, stop selling — plus buying a listed name (recorded: nephrite, the
// one name for sale on mainnet when the fixtures were taken).
//
// Renew, transfer and list kernels are synthetic (no recording exists: the
// owner deferred live name transactions). They are serialised by the same
// builder that reproduces the recorded register kernel byte for byte
// (names_register_test.dart), and the real BeamBansService decodes and
// checks them exactly as it would a core's.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/names/beam_name_confirm_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_detail_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_register_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_sell_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_transfer_view.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/widgets/beam/names/names_deps.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'names_ui_harness.dart';

final _tipTime = DateTime.fromMillisecondsSinceEpoch(
  tipTimestamp * 1000,
  isUtc: true,
);
final _clock = BansClock(tipHeight: tipHeight, tipTime: _tipTime);

/// Expires in 12 days.
const _aliceExpire = tipHeight + 12 * blocksPerDay + 300;

/// Active for over a year, listed at 500 BEAM.
const _coffeeExpire = tipHeight + 400 * blocksPerDay;
const _coffeePrice = 50000000000;

const _alice = BansDomain(
  name: 'alice',
  ownerKey: fakeMyKey,
  expireHeight: _aliceExpire,
);

final _coffee = BansDomain(
  name: 'coffee',
  ownerKey: fakeMyKey,
  expireHeight: _coffeeExpire,
  salePrice: BansAmount(0, BigInt.from(_coffeePrice)),
);

Map<String, Object?> _routes() => {
  'my_key': 'my_key',
  'view_params': 'view_params',
  'view_name:alice': viewName(fakeMyKey, _aliceExpire),
  'view_name:coffee': viewName(fakeMyKey, _coffeeExpire, price: _coffeePrice),
  'view_name:nephrite': 'view_name_listed',
  'domain_extend': built(extendRaw('alice', 1, price5)),
  'domain_set_owner': built(setOwnerRaw('alice', beamOwnerKey)),
  'domain_set_price:alice': built(setPriceRaw('alice', 0, 50000000000)),
  'domain_set_price:coffee': built(setPriceRaw('coffee', 0, 0)),
  'domain_buy': 'buy_listed',
};

bool _enabled(WidgetTester tester, Key key) =>
    tester.widget<PrimaryButton>(find.byKey(key)).enabled;

void main() {
  late NamesUiFake fake;
  late BeamNamesDeps deps;
  Object? popped;

  Future<void> launch(
    WidgetTester tester,
    Future<Object?> Function(BuildContext) open, {
    FakeGate? gate,
  }) async {
    fake = NamesUiFake(_routes());
    deps = makeDeps(fake, gate: gate);
    popped = null;
    await pumpNames(tester, Launcher(open: open, onResult: (r) => popped = r));
    await tester.tap(find.byKey(const Key('launch')));
    await settle(tester);
  }

  Future<void> openDetail(
    WidgetTester tester,
    BansDomain d, {
    FakeGate? gate,
  }) => launch(
    tester,
    (c) => BeamNameDetailView.show(c, deps: deps, domain: d, clock: _clock),
    gate: gate,
  );

  testWidgets('details: until when, renew as the one primary action', (
    tester,
  ) async {
    await openDetail(tester, _alice);
    expect(textOf(tester, const Key('names-detail-name')), 'alice.beam');
    expect(
      textOf(tester, const Key('names-detail-status')),
      'Expires in 12 days',
    );
    expect(
      textOf(tester, const Key('names-detail-expiry')),
      '≈ ${NamesFormat.date(_clock.dateOf(_aliceExpire))}',
    );
    // Heights only on tap.
    expect(find.textContaining('block '), findsNothing);
    await tester.tap(find.byKey(const Key('names-detail-expiry')));
    await tester.pump();
    expect(find.text(NamesFormat.block(_aliceExpire)), findsOneWidget);
    await tester.tap(find.byKey(const Key('names-detail-expiry')));
    await tester.pump();

    expect(find.byType(PrimaryButton), findsOneWidget);
    expect(find.text('Renew alice for 1 year'), findsOneWidget);
    expect(textOf(tester, const Key('names-detail-renew-usd')), '\$10');
    expect(find.text('≈ 1,162 BEAM today'), findsOneWidget);
    expectOnScreen(tester, const Key('names-detail-cta'), phone);
    await golden(tester, 'detail_mobile');
  });

  testWidgets('renew: confirm shows the decoded kernel, PIN decides', (
    tester,
  ) async {
    final gate = FakeGate(false);
    await openDetail(tester, _alice, gate: gate);
    await tester.tap(find.byKey(const Key('names-detail-cta')));
    await settle(tester);

    expect(find.byType(BeamNameConfirmView), findsOneWidget);
    expect(fake.actions, contains('domain_extend'));
    final decoded = BeamInvokeData.decode(extendRaw('alice', 1, price5));
    expect(
      textOf(tester, const Key('names-confirm-pay-0')),
      '${NamesFormat.exact(decoded.pays[0]!)} BEAM',
    );
    expect(
      textOf(tester, const Key('names-confirm-fee')),
      '${NamesFormat.exact(decoded.fee)} BEAM',
    );
    expect(
      textOf(tester, const Key('names-confirm-total')),
      '${NamesFormat.exact(decoded.pays[0]! + decoded.fee)} BEAM',
    );
    // An active name renews from its current expiry.
    const renewed = _aliceExpire + kBansBlocksPerPeriod;
    expect(
      textOf(tester, const Key('names-confirm-expiry')),
      '≈ ${NamesFormat.date(_clock.dateOf(renewed))}',
    );
    expect(find.text('Pay & renew alice'), findsOneWidget);
    expectOnScreen(tester, const Key('names-confirm-cta'), phone);
    await golden(tester, 'confirm_renew_mobile');

    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(gate.reasons, ['Authenticate to renew alice']);
    expect(fake.executed, isEmpty);

    gate.result = true;
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, [extendRaw('alice', 1, price5)]);
    expect((popped! as BeamNameSent).action, BansAction.extend);
    final p = deps.pending.of('alice')!;
    expect(p.kind, BansPendingKind.renew);
    expect(p.expireAtLeast, renewed);
  });

  testWidgets('transfer: key checked, fingerprint shown, tick + PIN', (
    tester,
  ) async {
    await launch(
      tester,
      (c) => BeamNameTransferView.show(
        c,
        deps: deps,
        domain: _alice,
        clock: _clock,
      ),
    );
    expect(_enabled(tester, const Key('names-transfer-cta')), isFalse);

    await tester.enterText(
      find.byKey(const Key('names-transfer-key')),
      'not a key',
    );
    await settle(tester);
    expect(
      textOf(tester, const Key('names-transfer-key-error')),
      startsWith('That is not a name key.'),
    );

    await tester.enterText(
      find.byKey(const Key('names-transfer-key')),
      fakeMyKey,
    );
    await settle(tester);
    expect(
      textOf(tester, const Key('names-transfer-key-error')),
      startsWith("That is this wallet's own key."),
    );
    expect(_enabled(tester, const Key('names-transfer-cta')), isFalse);

    await tester.enterText(
      find.byKey(const Key('names-transfer-key')),
      beamOwnerKey,
    );
    await settle(tester);
    expect(
      textOf(tester, const Key('names-transfer-fingerprint')),
      '72e3…51ef',
    );
    expect(find.text("This can't be undone"), findsOneWidget);
    expect(_enabled(tester, const Key('names-transfer-cta')), isTrue);
    expectOnScreen(tester, const Key('names-transfer-cta'), phone);
    await golden(tester, 'transfer_mobile');

    await tester.tap(find.byKey(const Key('names-transfer-cta')));
    await settle(tester);
    expect(find.byType(BeamNameConfirmView), findsOneWidget);
    expect(fake.seenArgs.last, contains('pkOwner=$beamOwnerKey'));
    expect(textOf(tester, const Key('names-confirm-fingerprint')), '72e3…51ef');
    expect(textOf(tester, const Key('names-confirm-fee')), '0.011 BEAM');
    expect(textOf(tester, const Key('names-confirm-total')), '0.011 BEAM');
    // Not until the box is ticked.
    expect(_enabled(tester, const Key('names-confirm-cta')), isFalse);
    expect(
      textOf(tester, const Key('names-cta-reason')),
      'Tick the box once the key matches.',
    );
    await golden(tester, 'confirm_transfer_mobile');

    expectOnScreen(tester, const Key('names-confirm-ack'), phone);
    expectOnScreen(tester, const Key('names-confirm-cta'), phone);
    await tester.tap(find.byKey(const Key('names-confirm-ack')));
    await tester.pump();
    expect(_enabled(tester, const Key('names-confirm-cta')), isTrue);
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, [setOwnerRaw('alice', beamOwnerKey)]);
    expect((popped! as BeamNameSent).action, BansAction.setOwner);
  });

  testWidgets('sell: price and asset, then the listing to confirm', (
    tester,
  ) async {
    final gate = FakeGate(false);
    fake = NamesUiFake(_routes());
    deps = makeDeps(fake, gate: gate);
    await pumpNames(
      tester,
      Launcher(
        open: (c) =>
            BeamNameSellView.show(c, deps: deps, domain: _alice, clock: _clock),
      ),
    );
    await tester.tap(find.byKey(const Key('launch')));
    await settle(tester);
    expect(_enabled(tester, const Key('names-sell-cta')), isFalse);
    expect(find.textContaining('Anyone can buy alice instantly'), findsOne);

    await tester.enterText(find.byKey(const Key('names-sell-amount')), '500');
    await tester.pump();
    expect(find.text('List alice for 500 BEAM'), findsOneWidget);
    expectOnScreen(tester, const Key('names-sell-cta'), phone);
    await golden(tester, 'sell_mobile');

    await tester.tap(find.byKey(const Key('names-sell-cta')));
    await settle(tester);
    expect(fake.seenArgs.last, contains('aid=0,amount=50000000000'));
    expect(textOf(tester, const Key('names-confirm-price')), '500 BEAM');
    expect(textOf(tester, const Key('names-confirm-total')), '0.011 BEAM');
    expect(find.text('List alice for sale'), findsOneWidget);
    await golden(tester, 'confirm_list_mobile');
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, isEmpty, reason: 'wrong PIN');
  });

  testWidgets('a listed name: Stop selling builds a zero price', (
    tester,
  ) async {
    await openDetail(tester, _coffee);
    expect(textOf(tester, const Key('names-detail-price')), '500 BEAM');
    await tester.ensureVisible(find.byKey(const Key('names-detail-sell')));
    await tester.tap(find.text('Stop selling coffee'));
    await settle(tester);
    expect(fake.seenArgs.last, contains('aid=0,amount=0'));
    expect(textOf(tester, const Key('names-confirm-price')), 'Not for sale');
    expect(find.text('Stop selling coffee'), findsWidgets);
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, [setPriceRaw('coffee', 0, 0)]);
    expect(deps.pending.of('coffee')!.kind, BansPendingKind.unlist);
  });

  testWidgets(
    'buy a listed name (recorded): seller\'s price, fee, and that it is '
    'not renewed',
    (tester) async {
      final gate = FakeGate(false);
      await launch(
        tester,
        (c) => BeamNameRegisterView.show(c, deps: deps),
        gate: gate,
      );
      await typeName(tester, 'nephrite');
      expect(
        textOf(tester, const Key('names-register-status')),
        'nephrite is for sale: 100,000 BEAM',
      );
      expect(find.textContaining('It does not renew it.'), findsOneWidget);
      expect(find.text('Buy nephrite for 100,000 BEAM'), findsOneWidget);

      await tester.tap(find.byKey(const Key('names-register-cta')));
      await settle(tester);
      final decoded = BeamInvokeData.decode(bansRaw('buy_listed'));
      expect(decoded.pays, {0: BigInt.from(10000000000000)});
      expect(textOf(tester, const Key('names-confirm-pay-0')), '100,000 BEAM');
      expect(textOf(tester, const Key('names-confirm-fee')), '0.011 BEAM');
      expect(
        textOf(tester, const Key('names-confirm-total')),
        '${NamesFormat.exact(decoded.pays[0]! + decoded.fee)} BEAM',
      );
      expect(
        textOf(tester, const Key('names-confirm-total')),
        '100,000.011 BEAM',
      );
      expect(
        textOf(tester, const Key('names-confirm-expiry')),
        '≈ ${NamesFormat.date(_clock.dateOf(4524205))}',
      );
      expect(
        textOf(tester, const Key('names-confirm-note')),
        startsWith('Buying does not renew the name'),
      );
      expect(
        tester
            .widget<PrimaryButton>(find.byKey(const Key('names-confirm-cta')))
            .label,
        'Buy nephrite',
      );
      expectOnScreen(tester, const Key('names-confirm-cta'), phone);
      await golden(tester, 'confirm_buy_mobile');

      await tester.tap(find.byKey(const Key('names-confirm-cta')));
      await settle(tester);
      expect(fake.executed, isEmpty);
      expect(gate.reasons, ['Authenticate to buy nephrite']);
    },
  );
}
