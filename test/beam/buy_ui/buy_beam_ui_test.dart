/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Buy BEAM screens on Campfire's theme, phone (375 × 667) and desktop
// (1280 × 800, the form and the buy in a dialog over the window, the
// chooser beside the side menu), over a fake buybeam.my
// (../buy/buybeam_fakes.dart): the chooser; the form empty, pricing,
// priced, under the smallest buy, unreachable; a buy waiting for its
// payment, buying, sent by buybeam.my, arrived in the wallet, sent back,
// expired, held for a look; the list of buys. Goldens: docs/beam/screenshots/B-BUYBEAM/.
//
//   CFB_HOST_WORKDIR=/private/tmp/cfb-h-ui scripts/beam/host_test.sh \
//       --no-analyze --update-goldens --copy-goldens test/beam/buy_ui

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_deps.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_order_view.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_orders_view.dart';
import 'package:stackwallet/pages/beam/buy/buy_beam_view.dart';
import 'package:stackwallet/pages/beam/buy/buy_chooser_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_scaffold.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_controller.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_order.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_store.dart';
import 'package:stackwallet/widgets/custom_buttons/app_bar_icon_button.dart';

import '../buy/buybeam_fakes.dart';
import '../wiring_ui/wiring_harness.dart';

Finder _k(String key) => find.byKey(Key(key));

String _text(WidgetTester tester, String key) {
  final w = tester.widget(_k(key));
  if (w is Text) return w.data ?? w.textSpan!.toPlainText();
  throw StateError('$key is ${w.runtimeType}');
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

bool _icons = false;

Future<void> _golden(String name) =>
    expectLater(find.byKey(goldenKey), matchesGoldenFile('goldens/$name.png'));

const _deposit = 'bc1qfake0deposit0address0000000000000000000';

class _Rig {
  _Rig({this.desktop = false, this.tor = false}) {
    controller = BuyBeamController(
      client: BuyBeamClient(clientFactory: server.client),
      store: store,
      autoPoll: false,
    );
  }

  final bool desktop;
  final bool tor;
  final FakeBuyBeamServer server = FakeBuyBeamServer();
  final MemoryBuyBeamStore store = MemoryBuyBeamStore();
  late final BuyBeamController controller;
  int wbeamTaps = 0;
  String? openedTx;

  /// The wallet has buybeam.my's BEAM transaction.
  bool arrived = false;
  bool supportOpened = false;

  BuyBeamDeps get deps => BuyBeamDeps(
    controller: controller,
    walletId: 'w1',
    walletName: 'Everyday BEAM',
    newBeamAddress: () async => kFakeBeamAddress,
    refundAddressFor: (a) async =>
        a.blockchain == 'eth' ? kFakeEthRefund : null,
    receivedInWallet: (tx) async => arrived && tx == 'beamtx0fake',
    onWantWbeam: (_, _) => wbeamTaps++,
    onOpenTransaction: (_, tx) async => openedTx = tx,
    onOpenSupport: () => supportOpened = true,
    torOn: () => tor,
    isDesktop: desktop,
  );

  /// A buy kept on this device, which buybeam.my says is [state].
  Future<void> stored(String state, {String? txId, DateTime? deadline}) async {
    server
      ..depositAddress = _deposit
      ..state = state
      ..txId = txId;
    await store.save(
      BuyBeamOrder(
        depositAddress: _deposit,
        assetId: kBtcId,
        symbol: 'BTC',
        chain: 'btc',
        decimals: 8,
        sendAmount: '0.0123',
        sendAmountRaw: BigInt.from(1230000),
        beamAddress: kFakeBeamAddress,
        beamWalletId: 'w1',
        refundAddress: kFakeBtcRefund,
        createdAt: DateTime.utc(2026, 10, 9, 12),
        beamEstimate: 111326.36,
        deadline: deadline,
        etaSeconds: 810,
        lastState: BuyBeamState.parse(state),
        beamTxId: txId,
        terminal: BuyBeamState.parse(state).isFinal,
      ),
    );
  }
}

/// Pumps a "wallet" screen with one button that opens [open], and taps it:
/// the screen opens as the app opens it (a page, or a dialog on desktop).
Future<void> _open(
  WidgetTester tester,
  _Rig rig,
  Future<void> Function(BuildContext context) open,
) async {
  await pumpWiring(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('open'),
            onPressed: () => unawaited(open(context)),
            child: const Text('Everyday BEAM'),
          ),
        ),
      ),
    ),
    desktop: rig.desktop,
  );
  if (!_icons) {
    _icons = true;
    await loadMaterialIcons(tester);
    await tester.pump();
  }
  await tester.tap(_k('open'));
  await _flush(tester);
}

Future<void> _openForm(WidgetTester tester, _Rig rig) =>
    _open(tester, rig, (c) => BuyBeamView.show(c, rig.deps));

Future<void> _openOrder(WidgetTester tester, _Rig rig) =>
    _open(tester, rig, (c) => BuyBeamOrderView.show(c, rig.deps, _deposit));

Future<void> _type(WidgetTester tester, String key, String text) async {
  await tester.enterText(_k(key), text);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await _flush(tester);
}

/// The primary button is entirely on the screen.
void _ctaOnScreen(WidgetTester tester, String key, Size screen) {
  final r = tester.getRect(_k(key));
  expect(r.bottom, lessThanOrEqualTo(screen.height), reason: key);
  expect(r.top, greaterThanOrEqualTo(0), reason: key);
}

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  for (final desktop in [false, true]) {
    final on = desktop ? 'desktop' : 'phone';
    final screen = desktop ? desktopWindow : phone;

    testWidgets('$on: the chooser, BEAM or WBEAM, each a tap', (tester) async {
      var beam = 0;
      var wbeam = 0;
      final deps = BuyChooserDeps(
        hasBeamWallet: true,
        hasEthWallet: false,
        onBeam: (_, _) => beam++,
        onWbeam: (_, _) => wbeam++,
        isDesktop: desktop,
      );
      await pumpWiring(
        tester,
        desktop
            ? BeamSidebarScaffold(
                title: 'Buy BEAM',
                showWallet: false,
                body: BuyChooserView(deps: deps, embedded: true),
              )
            : BuyChooserView(deps: deps),
        desktop: desktop,
      );
      if (!_icons) {
        _icons = true;
        await loadMaterialIcons(tester);
      }
      await _flush(tester);
      expect(find.text('What do you want to buy?'), findsOneWidget);
      expect(find.text('Buy BEAM'), findsWidgets);
      // No Ethereum wallet: the card still works, and says what it does.
      expect(find.text('Create an Ethereum wallet first'), findsOneWidget);
      await _golden('${on}_buy_chooser');
      await tester.tap(_k('buy-choose-beam'));
      await tester.tap(_k('buy-choose-wbeam'));
      expect((beam, wbeam), (1, 1));
      await finish(tester);
    });

    testWidgets('$on: the form, before anything is typed', (tester) async {
      final rig = _Rig(desktop: desktop);
      await _openForm(tester, rig);
      expect(find.text('Get a BTC deposit address'), findsOneWidget);
      expect(_text(tester, 'dex-cta-reason'), 'Enter how much BTC you pay.');
      expect(
        _text(tester, 'buy-minimum-hint'),
        'Smallest buy right now: about \$1,000',
      );
      expect(_text(tester, 'buy-arrives-in'), 'Arrives in Everyday BEAM');
      expect(
        find.text(
          "Your Bitcoin address, for a refund if the buy can't go through",
        ),
        findsOneWidget,
      );
      expect(
        _text(tester, 'buy-footer'),
        'buybeam.my buys the BEAM and sends it to your wallet.',
      );
      _ctaOnScreen(tester, 'buy-cta', screen);
      await _golden('${on}_buy_empty');
      await finish(tester);
    });

    testWidgets('$on: pricing, then priced', (tester) async {
      final rig = _Rig(desktop: desktop);
      await _openForm(tester, rig);
      final hold = rig.server.holdQuotes = Completer<void>();
      await tester.enterText(_k('buy-amount'), '0.0123');
      await tester.enterText(_k('buy-refund'), kFakeBtcRefund);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 50));
      expect(_k('buy-estimate-loading'), findsOneWidget);
      expect(
        _text(tester, 'dex-cta-reason'),
        'Getting a price from buybeam.my…',
      );
      expect(_text(tester, 'buy-worth'), '≈ \$1,012');
      await _golden('${on}_buy_quoting');
      hold.complete();
      rig.server.holdQuotes = null;
      await _flush(tester);
      expect(_text(tester, 'buy-estimate'), '≈ 111,360.01 BEAM');
      expect(_text(tester, 'buy-eta'), 'Usually done in about 14 minutes');
      expect(find.byKey(const Key('dex-cta-reason')), findsNothing);
      _ctaOnScreen(tester, 'buy-cta', screen);
      await _golden('${on}_buy_quoted');
      await finish(tester);
    });

    testWidgets('$on: under the smallest buy, the amount that is not, '
        'one tap away', (tester) async {
      final rig = _Rig(desktop: desktop);
      await _openForm(tester, rig);
      await tester.enterText(_k('buy-refund'), kFakeBtcRefund);
      await _type(tester, 'buy-amount', '0.001');
      expect(find.text('Buy at least 0.0123 BTC (\$1,000)'), findsOneWidget);
      expect(find.text('Use 0.0123 BTC'), findsOneWidget);
      _ctaOnScreen(tester, 'buy-cta', screen);
      await _golden('${on}_buy_below_minimum');
      await tester.ensureVisible(find.text('Use 0.0123 BTC'));
      await tester.tap(find.text('Use 0.0123 BTC'));
      await tester.pump(const Duration(milliseconds: 450));
      await _flush(tester);
      expect(
        tester.widget<TextField>(_k('buy-amount')).controller!.text,
        '0.0123',
      );
      expect(find.textContaining('Buy at least'), findsNothing);
      expect(_k('buy-estimate'), findsOneWidget);
      await finish(tester);
    });

    testWidgets("$on: buybeam.my can't be reached (a proxy's page), Tor on", (
      tester,
    ) async {
      final rig = _Rig(desktop: desktop, tor: true);
      rig.server.queue('/quote', FakeAnswer.html(403));
      await _openForm(tester, rig);
      await tester.enterText(_k('buy-refund'), kFakeBtcRefund);
      await _type(tester, 'buy-amount', '0.0123');
      expect(find.text("Couldn't reach buybeam.my"), findsOneWidget);
      expect(
        find.text(
          'Nothing was sent. If Tor is on, a new connection usually helps.',
        ),
        findsOneWidget,
      );
      _ctaOnScreen(tester, 'buy-cta', screen);
      await _golden('${on}_buy_blocked');
      // "Try again" asks again; this time it answers.
      await tester.ensureVisible(find.text('Try again'));
      await tester.tap(find.text('Try again'));
      await _flush(tester);
      expect(_k('buy-estimate'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('$on: a buy waiting for its payment', (tester) async {
      final rig = _Rig(desktop: desktop);
      await rig.stored(
        'awaiting_deposit',
        deadline: DateTime(2030, 10, 10, 14, 30),
      );
      await _openOrder(tester, rig);
      expect(find.text('Send 0.0123 BTC'), findsOneWidget);
      expect(
        _text(tester, 'buy-network-warning'),
        'Send only BTC on the Bitcoin network to this address.',
      );
      expect(find.text(_deposit), findsOneWidget);
      expect(_text(tester, 'buy-exact-amount'), '0.0123 BTC');
      expect(_k('buy-qr'), findsOneWidget);
      expect(
        _text(tester, 'buy-deadline'),
        'This address works until 14:30 on 10 Oct.',
      );
      expect(find.text('Copy address'), findsOneWidget);
      _ctaOnScreen(tester, 'buy-order-cta', screen);
      await _golden('${on}_buy_deposit_awaiting');
      await finish(tester);
    });

    for (final (state, name) in [
      ('buying', 'buying'),
      ('delivered', 'delivered'),
      ('delivered', 'arrived'),
      ('refunded', 'refunded'),
      ('expired', 'expired'),
      ('attention', 'attention'),
    ]) {
      testWidgets('$on: a buy that is $name', (tester) async {
        final rig = _Rig(desktop: desktop)..arrived = name == 'arrived';
        await rig.stored(
          state,
          txId: state == 'delivered' ? 'beamtx0fake' : null,
        );
        await _openOrder(tester, rig);
        final cta = switch (name) {
          'arrived' => 'See it in your wallet',
          'expired' => 'Start a new buy',
          'attention' => 'Contact buybeam.my support',
          _ => 'Back to your wallet',
        };
        const title = 'Buy BEAM';
        expect(find.text(title), findsWidgets);
        expect(
          tester
              .widget<Text>(
                find.descendant(
                  of: _k('buy-order-cta'),
                  matching: find.byType(Text),
                ),
              )
              .data,
          cta,
        );
        switch (name) {
          case 'buying':
            expect(find.text('Payment received'), findsOneWidget);
            expect(find.text('Buying your BEAM'), findsOneWidget);
            expect(_k('buy-keep-open'), findsOneWidget);
          case 'delivered':
            // Sent is not arrived: said until the wallet has it.
            expect(find.text('buybeam.my sent your BEAM'), findsOneWidget);
            expect(find.text('Your BEAM has arrived'), findsNothing);
            expect(find.text('Arriving in your wallet'), findsOneWidget);
            expect(find.byKey(const Key('buy-step-done')), findsNWidgets(3));
            expect(find.text('You paid'), findsOneWidget);
          case 'arrived':
            expect(_k('buy-arrived'), findsOneWidget);
            expect(find.byKey(const Key('buy-step-done')), findsNWidgets(4));
            expect(find.text('You got'), findsOneWidget);
            expect(_k('buy-keep-open'), findsNothing);
          case 'refunded':
            expect(
              find.text('Your payment was sent back to bc1qfa…0000'),
              findsOneWidget,
            );
          case 'expired':
            expect(
              find.text('No payment arrived in time. Nothing was taken.'),
              findsOneWidget,
            );
          case 'attention':
            expect(
              find.text('buybeam.my is checking this order'),
              findsOneWidget,
            );
            expect(_k('buy-copy-order'), findsOneWidget);
        }
        _ctaOnScreen(tester, 'buy-order-cta', screen);
        await _golden('${on}_buy_deposit_$name');
        await finish(tester);
      });
    }

    testWidgets('$on: your buys', (tester) async {
      final rig = _Rig(desktop: desktop);
      await rig.stored('buying');
      await rig.store.save(
        BuyBeamOrder(
          depositAddress: 'TFakeUsdtDepositAddress0000000000',
          assetId: kUsdtTronId,
          symbol: 'USDT',
          chain: 'tron',
          decimals: 6,
          sendAmount: '1050',
          sendAmountRaw: BigInt.from(1050000000),
          beamAddress: kFakeBeamAddress,
          beamWalletId: 'w1',
          refundAddress: 'TFakeRefund',
          createdAt: DateTime.utc(2026, 10, 8, 9),
          beamEstimate: 115290.4,
          lastState: BuyBeamState.delivered,
          beamTxId: 'beamtx1',
          terminal: true,
        ),
      );
      await _open(tester, rig, (c) => BuyBeamOrdersView.show(c, rig.deps));
      expect(find.text('Your buys'), findsWidgets);
      expect(find.text('Buying your BEAM'), findsOneWidget);
      expect(find.text('BEAM sent to your wallet'), findsOneWidget);
      await _golden('${on}_buy_orders');
      await finish(tester);
    });
  }

  testWidgets('phone: the button gets the address, the deposit screen takes '
      "the form's place, and Back goes to the wallet", (tester) async {
    final rig = _Rig();
    await _openForm(tester, rig);
    await tester.enterText(_k('buy-refund'), kFakeBtcRefund);
    await _type(tester, 'buy-amount', '0.0123');
    await tester.tap(_k('buy-cta'));
    await _flush(tester);
    expect(find.text('Send 0.0123 BTC'), findsOneWidget);
    expect(rig.store.writes, hasLength(1));
    final body = rig.server.requests
        .singleWhere((r) => r.method == 'POST')
        .body;
    expect(body, contains(kFakeBeamAddress));
    expect(body, contains(kFakeBtcRefund));
    // Copy, with its own word for it.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    await tester.tap(_k('buy-order-cta'));
    await tester.pump();
    expect(copied, _deposit);
    expect(find.text('Address copied'), findsOneWidget);
    await tester.tap(_k('buy-copy-amount'));
    await tester.pump();
    expect(copied, '0.0123');
    // Back: the wallet, not the form.
    await tester.tap(find.byType(AppBarBackButton));
    await _flush(tester);
    expect(_k('open'), findsOneWidget);
    expect(find.text('Buy BEAM'), findsNothing);
    // The form again shows the buy, one tap away.
    await tester.tap(_k('open'));
    await _flush(tester);
    expect(find.text('Your buys (1 in progress)'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('phone: Ethereum coins get the Ethereum wallet as refund '
      'address; an amount buybeam.my cannot read exactly is caught first', (
    tester,
  ) async {
    final rig = _Rig();
    await _openForm(tester, rig);
    await tester.tap(_k('buy-coin'));
    await _flush(tester);
    final order = [
      for (final e in find.byType(InkWell).evaluate())
        if ((e.widget.key as ValueKey<String>?)?.value.startsWith(
              'buy-coin-',
            ) ??
            false)
          (e.widget.key! as ValueKey<String>).value.substring(9),
    ];
    expect(order.take(3), [kBtcId, kEthId, kUsdtTronId]);
    await tester.tap(_k('buy-coin-$kEthId'));
    await _flush(tester);
    expect(
      tester.widget<TextField>(_k('buy-refund')).controller!.text,
      kFakeEthRefund,
    );
    await _type(tester, 'buy-amount', '9.51234567');
    expect(
      find.text("buybeam.my can't take exactly 9.51234567 ETH"),
      findsOneWidget,
    );
    expect(rig.server.count('/quote'), 0);
    await tester.ensureVisible(find.text('Use 9.5123457 ETH'));
    await tester.tap(find.text('Use 9.5123457 ETH'));
    await tester.pump(const Duration(milliseconds: 450));
    await _flush(tester);
    expect(rig.server.count('/quote'), 1);
    expect(_k('buy-estimate'), findsOneWidget);
    // A refund address that is not an Ethereum one is said at once.
    await _type(tester, 'buy-refund', '0x123');
    expect(_k('buy-refund-error'), findsOneWidget);
    expect(
      _text(tester, 'dex-cta-reason'),
      'Ethereum addresses start with 0x and have 42 characters.',
    );
    await finish(tester);
  });

  testWidgets('phone: "Want WBEAM on Ethereum instead?" is one link', (
    tester,
  ) async {
    final rig = _Rig();
    await _openForm(tester, rig);
    await tester.ensureVisible(_k('buy-want-wbeam'));
    await tester.tap(_k('buy-want-wbeam'));
    await tester.pump();
    expect(rig.wbeamTaps, 1);
    await finish(tester);
  });

  testWidgets('phone: arrived — "See it in your wallet" opens the BEAM '
      'transaction', (tester) async {
    final rig = _Rig()..arrived = true;
    await rig.stored('delivered', txId: 'beamtx0fake');
    await _openOrder(tester, rig);
    await tester.tap(_k('buy-order-cta'));
    await tester.pump();
    expect(rig.openedTx, 'beamtx0fake');
    await finish(tester);
  });

  testWidgets('phone: expired — "Start a new buy" opens the form in its '
      'place', (tester) async {
    final rig = _Rig();
    await rig.stored('expired');
    await _openOrder(tester, rig);
    await tester.tap(_k('buy-order-cta'));
    await _flush(tester);
    expect(find.text('Buy BEAM'), findsOneWidget);
    await tester.tap(find.byType(AppBarBackButton));
    await _flush(tester);
    expect(_k('open'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('phone: the chooser takes a ref for each card', (tester) async {
    WidgetRef? got;
    final deps = BuyChooserDeps(
      hasBeamWallet: false,
      hasEthWallet: true,
      onBeam: (_, ref) => got = ref,
      onWbeam: (_, _) {},
    );
    await pumpWiring(tester, BuyChooserView(deps: deps), desktop: false);
    await _flush(tester);
    expect(find.text('Create a BEAM wallet first'), findsOneWidget);
    await tester.tap(_k('buy-choose-beam'));
    expect(got, isNotNull);
    await finish(tester);
  });
}
