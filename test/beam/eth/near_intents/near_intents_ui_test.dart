/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The NEAR Intents screens on Campfire's theme, phone (375 × 667) and
// desktop (1280 × 800), over a fake 1Click client that answers with real
// 1Click data (fixtures/): the form with a price and what it buys in
// WBEAM, the coin picker with BTC, ZEC and LTC first, the signed deposit
// address with its QR, a refusal in 1Click's own words, and the finished
// swap offering to buy WBEAM. Goldens: docs/beam/screenshots/B-NEAR-INTENTS/.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/eth/near_intents/near_intents_ui_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/eth/near_intents/near_intents_deposit_view.dart';
import 'package:stackwallet/pages/eth/near_intents/near_intents_view.dart';
import 'package:stackwallet/wallets/ethereum/near_intents/near_intents_store.dart';
import 'package:stackwallet/wallets/ethereum/near_intents/one_click_client.dart';

import '../../wiring_ui/wiring_harness.dart';
import '../uniswap_ui/uniswap_ui_fakes.dart';

Map<String, dynamic> _fixture(String name) => (jsonDecode(
  File('test/beam/eth/near_intents/fixtures/$name').readAsStringSync(),
) as Map).cast<String, dynamic>();

const _zec = OneClickToken(
  assetId: 'nep141:zec.omft.near',
  symbol: 'ZEC',
  blockchain: 'zec',
  decimals: 8,
  priceUsd: 1210.4,
);

class FakeOneClick extends OneClickClient {
  FakeOneClick() : super(clientFactory: () => throw StateError('no network'));

  OneClickState state = OneClickState.pendingDeposit;
  String? refuse;
  final List<bool> quotes = [];

  @override
  Future<List<OneClickToken>> tokens() async => const [
    OneClickToken(
      assetId: 'a',
      symbol: 'AAVE',
      blockchain: 'eth',
      decimals: 18,
      contractAddress: '0x1',
      priceUsd: 140,
    ),
    OneClickToken(
      assetId: 'nep141:btc.omft.near',
      symbol: 'BTC',
      blockchain: 'btc',
      decimals: 8,
      priceUsd: 82852,
    ),
    _zec,
    OneClickToken(
      assetId: 'nep141:ltc.omft.near',
      symbol: 'LTC',
      blockchain: 'ltc',
      decimals: 8,
      priceUsd: 112.3,
    ),
    OneClickToken(
      assetId: 'u',
      symbol: 'USDT',
      blockchain: 'tron',
      decimals: 6,
      contractAddress: 'TR7',
      priceUsd: 1,
    ),
    OneClickToken(
      assetId: 'k',
      symbol: 'KAIA',
      blockchain: 'kaia',
      decimals: 18,
      priceUsd: 0.12,
    ),
  ];

  @override
  Future<OneClickQuote> quote({
    required OneClickToken origin,
    required BigInt amountIn,
    required String recipient,
    required String refundTo,
    required bool dry,
    int slippageBips = 100,
    Duration depositWindow = const Duration(hours: 1),
    DateTime? now,
    String destinationAsset = kOneClickEthOnEthereum,
  }) async {
    quotes.add(dry);
    if (refuse != null) throw OneClickError(refuse!);
    // The real signed ZEC quote (0.1 ZEC → 0.0488 ETH).
    final q = OneClickQuote(_fixture('quote_zec.json'));
    expect(verifyOneClickQuote(q.raw), isTrue);
    return q;
  }

  @override
  Future<OneClickStatus> status(String depositAddress, {String? memo}) async =>
      OneClickStatus(state, {
        'status': state.wire,
        'swapDetails': {
          if (state == OneClickState.success) 'amountOut': '48771184169646411',
        },
      });
}

Finder _k(String key) => find.byKey(Key(key));

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

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

NearIntentsDeps _deps({
  required bool desktop,
  FakeOneClick? client,
  NearIntentsStore? store,
  void Function(BigInt)? onBuy,
}) => NearIntentsDeps(
  uniswap: fakeUniswapDeps(desktop: desktop),
  client: client ?? FakeOneClick(),
  store: store ?? MemoryNearIntentsStore(),
  walletId: 'w1',
  onBuyWbeam: onBuy == null ? null : (_, eth) => onBuy(eth),
);

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('phone: 0.1 ZEC prices in ETH and in WBEAM, and asks for a '
      'refund address first', (tester) async {
    final client = FakeOneClick();
    final deps = _deps(desktop: false, client: client);
    await _pump(
      tester,
      NearIntentsView(deps: deps, initial: _zec),
      desktop: false,
    );
    await _flush(tester);
    await tester.enterText(_k('ni-amount'), '0.1');
    await _flush(tester);
    expect(
      tester.widget<Text>(_k('dex-cta-reason')).data,
      'Add your Zcash address for a refund.',
    );
    await tester.enterText(
      _k('ni-refund'),
      't1Hsc1LR8yKnbbe3twRp88p6vFfC5t7DLbs',
    );
    await tester.pump(const Duration(milliseconds: 650));
    await _flush(tester);
    expect(client.quotes, [true]); // a price only, no address yet
    expect(find.text('≈ 0.04877 ETH'), findsOneWidget);
    expect(
      find.textContaining('Then buy WBEAM with it: about'),
      findsOneWidget,
    );
    expect(find.text('Get a ZEC deposit address'), findsOneWidget);
    await _golden('phone_near_intents_quote');
    await finish(tester);
  });

  testWidgets('phone: the coin picker starts with BTC, ZEC and LTC', (
    tester,
  ) async {
    final deps = _deps(desktop: false);
    await _pump(tester, NearIntentsView(deps: deps), desktop: false);
    await _flush(tester);
    await tester.tap(_k('ni-coin'));
    await _flush(tester);
    final order = [
      for (final e in find.byType(InkWell).evaluate())
        if ((e.widget.key as ValueKey<String>?)?.value.startsWith('ni-coin-') ??
            false)
          (e.widget.key! as ValueKey<String>).value.substring(8),
    ];
    expect(order.take(4), [
      'nep141:btc.omft.near',
      'nep141:zec.omft.near',
      'nep141:ltc.omft.near',
      'u',
    ]);
    await _golden('phone_near_intents_coins');
    await finish(tester);
  });

  testWidgets('phone: the signed deposit address, its QR and the network '
      'warning', (tester) async {
    final deps = _deps(desktop: false);
    final swap = NearIntentsSwap(
      walletId: 'w1',
      quote: OneClickQuote(_fixture('quote_zec.json')),
      origin: _zec,
      createdAt: DateTime.utc(2026, 10, 9, 15),
    );
    await _pump(
      tester,
      NearIntentsDepositView(
        deps: deps,
        swap: swap,
        pollEvery: const Duration(hours: 1),
      ),
      desktop: false,
    );
    await _flush(tester);
    expect(find.text('t1RCMXfRc2EvLc6yoPbddg5YVJb2L5SWdxp'), findsOneWidget);
    expect(find.text('Signed by NEAR Intents'), findsOneWidget);
    expect(find.byKey(const Key('ni-qr')), findsOneWidget);
    expect(
      find.textContaining('Send exactly 0.1 ZEC on Zcash'),
      findsOneWidget,
    );
    await _golden('phone_near_intents_deposit');
    await finish(tester);
  });

  testWidgets('phone: once the ETH is here, one tap buys WBEAM with it', (
    tester,
  ) async {
    final client = FakeOneClick()..state = OneClickState.success;
    BigInt? bought;
    final deps = _deps(
      desktop: false,
      client: client,
      onBuy: (e) => bought = e,
    );
    final swap = NearIntentsSwap(
      walletId: 'w1',
      quote: OneClickQuote(_fixture('quote_zec.json')),
      origin: _zec,
      createdAt: DateTime.utc(2026, 10, 9, 15),
    );
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          key: const Key('open'),
          onPressed: () =>
              NearIntentsDepositView.show(context, deps: deps, swap: swap),
          child: const Text('open'),
        ),
      ),
      desktop: false,
    );
    await tester.tap(_k('open'));
    await _flush(tester);
    expect(find.text('0.04877 ETH arrived in this wallet'), findsOneWidget);
    expect(find.text('Buy WBEAM with 0.04877 ETH'), findsOneWidget);
    await _golden('phone_near_intents_done');
    await tester.tap(_k('ni-deposit-cta'));
    await _flush(tester);
    expect(bought, BigInt.parse('48771184169646411'));
    await finish(tester);
  });

  testWidgets("phone: a refusal is shown in NEAR Intents' own words", (
    tester,
  ) async {
    final client = FakeOneClick()
      ..refuse = 'Amount is too low for bridge, try at least 0.0002';
    final deps = _deps(desktop: false, client: client);
    await _pump(
      tester,
      NearIntentsView(deps: deps, initial: _zec),
      desktop: false,
    );
    await _flush(tester);
    await tester.enterText(_k('ni-amount'), '0.00001');
    await tester.enterText(
      _k('ni-refund'),
      't1Hsc1LR8yKnbbe3twRp88p6vFfC5t7DLbs',
    );
    await tester.pump(const Duration(milliseconds: 650));
    await _flush(tester);
    expect(find.byKey(const Key('ni-refused')), findsOneWidget);
    expect(find.textContaining('Amount is too low'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('desktop: the form as a dialog page', (tester) async {
    final deps = _deps(desktop: true);
    await _pump(
      tester,
      NearIntentsView(deps: deps, initial: _zec),
      desktop: true,
    );
    await _flush(tester);
    await tester.enterText(_k('ni-amount'), '0.1');
    await tester.enterText(
      _k('ni-refund'),
      't1Hsc1LR8yKnbbe3twRp88p6vFfC5t7DLbs',
    );
    await tester.pump(const Duration(milliseconds: 650));
    await _flush(tester);
    await _golden('desktop_near_intents_quote');
    await finish(tester);
  });
}
