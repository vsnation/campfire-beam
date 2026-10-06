/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Names home: my names with their status, the empty state, the renewal
// warning, money from a sold name, and what a stock core (no privilege 1)
// shows instead. The recorded user_view fixture IS the stock core's
// answer (the get_PkEx failure), so the recorded home shows that state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/names/beam_name_confirm_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_detail_view.dart';
import 'package:stackwallet/pages/beam/names/beam_name_register_view.dart';
import 'package:stackwallet/pages/beam/names/beam_names_home_view.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/widgets/beam/names/names_deps.dart';
import 'package:stackwallet/widgets/beam/names/names_format.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';

import 'names_ui_harness.dart';

final _clock = BansClock(
  tipHeight: tipHeight,
  tipTime: DateTime.fromMillisecondsSinceEpoch(
    tipTimestamp * 1000,
    isUtc: true,
  ),
);

/// Synthetic names of this wallet, one per status.
final Map<String, int> _mine = {
  'sunrise': tipHeight + 700 * blocksPerDay, // active
  'alice': tipHeight + 12 * blocksPerDay + 300, // expires in 12 days
  'coffee': tipHeight + 400 * blocksPerDay, // active, listed
  'moonwalk': tipHeight - 10 * blocksPerDay, // expired, in its 90 days
  'oldname': tipHeight - 200 * blocksPerDay, // expired for good
};

Map<String, Object?> _mixed() => {
  'my_key': 'my_key',
  'view_params': 'view_params',
  'view_domain': viewDomain(_mine, prices: {'coffee': 50000000000}),
  'view': userView(),
};

final _empty = answer('{"domains": []}');

void main() {
  late NamesUiFake fake;
  late BeamNamesDeps deps;

  Future<void> openHome(
    WidgetTester tester,
    Map<String, Object?> routes, {
    bool desktop = false,
    FakeGate? gate,
  }) async {
    fake = NamesUiFake(routes);
    deps = makeDeps(fake, desktop: desktop, gate: gate);
    await pumpNames(
      tester,
      BeamNamesHomeView(deps: deps),
      size: desktop ? desktopWindow : phone,
      pixelRatio: desktop ? 1 : 2,
    );
    await settle(tester);
  }

  testWidgets('my names: status in words, renewal first, one CTA', (
    tester,
  ) async {
    await openHome(tester, _mixed());
    expect(find.byKey(const Key('names-home-renew-warning')), findsOneWidget);
    expect(find.text('moonwalk has expired (and 1 more)'), findsOneWidget);
    expect(find.byType(PrimaryButton), findsOneWidget);
    expect(find.text('Get a name'), findsOneWidget);
    expectOnScreen(tester, const Key('names-home-cta'), phone);
    // Read-only: my key, then my names, then the inbox. Nothing built.
    expect(fake.actions, ['my_key', 'view_domain', 'view']);
    fake.expectOnlyBuilds();
    expect(fake.executed, isEmpty);
    await golden(tester, 'home_mobile_names');

    // A tall window builds the whole list, to check every line.
    tester.view.physicalSize = const Size(375, 1600) * 2;
    await tester.pump();
    String status(String n) => textOf(tester, Key('names-home-status-$n'));
    expect(
      status('sunrise'),
      'Active until ${NamesFormat.date(_clock.dateOf(_mine['sunrise']!))}',
    );
    expect(status('alice'), 'Expires in 12 days');
    expect(
      status('moonwalk'),
      'Expired · renew by '
      '${NamesFormat.date(_clock.dateOf(_mine['moonwalk']! + kBansHoldBlocks))}'
      ' to keep it',
    );
    expect(status('oldname'), 'Expired · anyone can register it now');
    expect(
      textOf(tester, const Key('names-home-sale-coffee')),
      'For sale at 500 BEAM',
    );
    // No block heights on the list.
    expect(find.textContaining('block'), findsNothing);
    // The most urgent first: on hold, then the soonest expiry.
    final order = [
      for (final n in ['moonwalk', 'alice', 'coffee', 'sunrise', 'oldname'])
        tester.getTopLeft(find.byKey(Key('names-home-name-$n'))).dy,
    ];
    expect(order, [...order]..sort());
    tester.view.physicalSize = phone * 2;
    await tester.pump();

    // The warning's action opens that name.
    await tester.tap(find.byKey(const Key('names-home-renew-action')));
    await settle(tester);
    expect(find.byType(BeamNameDetailView), findsOneWidget);
    expect(textOf(tester, const Key('names-detail-name')), 'moonwalk.beam');
  });

  testWidgets('recorded: view_domain by key on a stock core', (tester) async {
    await openHome(tester, {
      'my_key': 'my_key',
      'view_domain': 'view_domain_pk',
      'view': 'user_view', // the recorded get_PkEx failure
    });
    expect(find.byKey(const Key('names-home-name-beam')), findsOneWidget);
    expect(find.byKey(const Key('names-home-name-foundation')), findsOneWidget);
    expect(
      textOf(tester, const Key('names-home-status-amir')),
      'Expired · anyone can register it now',
    );
    // Claim-related parts only: the limitation, said plainly, below the
    // names (the screen's job comes first).
    await tester.scrollUntilVisible(
      find.byKey(const Key('names-home-check-sale')),
      200,
    );
    await tester.pump();
    expect(
      find.byKey(const Key('names-home-claim-unsupported')),
      findsOneWidget,
    );
    expect(
      find.text("This version can't see payments to your names yet"),
      findsOneWidget,
    );
    expect(find.textContaining('get_PkEx'), findsNothing);
    // Registering still works on this core.
    expect(
      tester
          .widget<PrimaryButton>(find.byKey(const Key('names-home-cta')))
          .enabled,
      isTrue,
    );
    await golden(tester, 'home_mobile_stock_core');
  });

  testWidgets('stock core: a sale payment can still be checked for', (
    tester,
  ) async {
    await openHome(tester, {
      'my_key': 'my_key',
      'view_domain': 'view_domain_pk',
      'view': 'user_view',
      'view_params': 'view_params',
      'receive': 'receive_raw', // recorded: "no funds"
    });
    await tester.scrollUntilVisible(
      find.byKey(const Key('names-home-check-sale')),
      200,
    );
    await tester.tap(find.byKey(const Key('names-home-check-sale')));
    await settle(tester);
    expect(fake.seenArgs.last, contains('action=receive'));
    expect(
      find.text('Nothing from a name sale is waiting for this wallet.'),
      findsOneWidget,
    );
    expect(fake.executed, isEmpty);
  });

  testWidgets('empty: what a name is, in one sentence', (tester) async {
    await openHome(tester, {
      'my_key': 'my_key',
      'view_domain': _empty,
      'view': userView(),
    });
    expect(find.byKey(const Key('names-home-empty')), findsOneWidget);
    expect(find.text("You don't have a name yet"), findsOneWidget);
    expect(
      find.text('Let people pay alice instead of a 67-character address.'),
      findsOneWidget,
    );
    expect(find.byType(BeamStickerImage), findsOneWidget);
    expectOnScreen(tester, const Key('names-home-cta'), phone);
    await golden(tester, 'home_mobile_empty');
  });

  testWidgets('a sold name: claim its money, decoded before signing', (
    tester,
  ) async {
    final gate = FakeGate(false);
    const sold = 50000000000; // 500 BEAM
    await openHome(tester, {
      ..._mixed(),
      'view': userView(saleProceeds: {0: sold}),
      'receive': built(claimRaw(0, sold)), // synthetic
    }, gate: gate);
    expect(
      find.text('You sold a name: 500 BEAM is waiting for you'),
      findsOneWidget,
    );
    await golden(tester, 'home_mobile_proceeds');

    await tester.tap(find.byKey(const Key('names-home-claim-0')));
    await settle(tester);
    expect(find.byType(BeamNameConfirmView), findsOneWidget);
    expect(fake.seenArgs.last, contains('aid=0'));
    expect(textOf(tester, const Key('names-confirm-receive-0')), '500 BEAM');
    expect(textOf(tester, const Key('names-confirm-fee')), '0.011 BEAM');
    expect(textOf(tester, const Key('names-confirm-total')), '499.989 BEAM');
    expect(find.text('Claim 500 BEAM'), findsOneWidget);
    await golden(tester, 'confirm_claim_mobile');

    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, isEmpty, reason: 'wrong PIN');

    gate.result = true;
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);
    expect(fake.executed, [claimRaw(0, sold)]);
    expect(find.byType(BeamNameConfirmView), findsNothing);
    expect(find.text('Claim sent'), findsOneWidget);
  });

  testWidgets('register from home: back with the name on its way', (
    tester,
  ) async {
    var registered = false;
    await openHome(tester, {
      'my_key': 'my_key',
      'view_params': 'view_params',
      'view_domain': (int n) => registered
          ? viewDomain({quotedName5: tipHeight + 366 * blocksPerDay})
          : _empty,
      'view': userView(),
      'view_name': 'view_name_free',
      'domain_register': 'register5',
    });
    await tester.tap(find.byKey(const Key('names-home-cta')));
    await settle(tester);
    expect(find.byType(BeamNameRegisterView), findsOneWidget);
    await typeName(tester, quotedName5);
    await tester.tap(find.byKey(const Key('names-register-cta')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('names-confirm-cta')));
    await settle(tester);

    expect(fake.executed, [bansRaw('register5')]);
    expect(find.byType(BeamNamesHomeView), findsOneWidget);
    expect(find.byType(BeamNameRegisterView), findsNothing);
    expect(find.text('$quotedName5 is on its way to you'), findsOneWidget);
    // The Beam girl celebrates, small and beside the message (a still when
    // the system asks for less motion, as in this test).
    expect(find.byType(BeamAnimatedStickerView), findsOneWidget);
    expect(
      find.byKey(const Key('names-home-pending-$quotedName5')),
      findsOneWidget,
    );
    expect(find.text('Registering… usually under 2 minutes'), findsOneWidget);
    await golden(tester, 'home_mobile_registered');

    // Once the chain shows it, the pending marker goes.
    registered = true;
    await tester.fling(find.byType(ListView), const Offset(0, 400), 1000);
    await settle(tester);
    expect(
      find.byKey(const Key('names-home-name-$quotedName5')),
      findsOneWidget,
    );
    expect(deps.pending.of(quotedName5), isNull);
  });

  testWidgets('desktop: two columns, as Spark Names had them', (tester) async {
    await openHome(tester, _mixed(), desktop: true);
    expect(find.text('Get a name'), findsWidgets);
    expect(find.text('My names'), findsOneWidget);
    expect(find.byKey(const Key('names-home-name-alice')), findsOneWidget);
    await golden(tester, 'home_desktop_names');
  });

  testWidgets('a wallet that is behind says so above the list', (tester) async {
    fake = NamesUiFake(_mixed());
    deps = makeDeps(fake, sync: catchingUp);
    await pumpNames(tester, BeamNamesHomeView(deps: deps));
    await settle(tester);
    expect(find.byKey(const Key('names-sync-banner')), findsOneWidget);
    expect(find.text('Catching up with the network'), findsOneWidget);
  });
}
