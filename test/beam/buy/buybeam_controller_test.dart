/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The buy controller over the fake buybeam.my and a fake clock: a price
// asked once typing pauses, only the latest answer kept; an order kept on
// this device before it is returned; a dropped POST sent again as it was,
// which brings back the same order; open buys looked at as often as
// buybeam.my says, less often while it cannot be reached, never again
// once ended; and the open ones picked up again on start.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_controller.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_order.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_store.dart';

import 'buybeam_fakes.dart';

class _Rig {
  _Rig({bool autoPoll = true, BuyBeamStore? store})
    : store = store ?? MemoryBuyBeamStore() {
    controller = BuyBeamController(
      client: BuyBeamClient(clientFactory: server.client),
      store: this.store,
      clock: clock,
      autoPoll: autoPoll,
    );
  }

  final FakeBuyBeamServer server = FakeBuyBeamServer();
  final FakeBuyBeamClock clock = FakeBuyBeamClock();
  final BuyBeamStore store;
  late final BuyBeamController controller;
  int addressesMade = 0;

  Future<String> newAddress() async {
    addressesMade++;
    return addressesMade == 1 ? kFakeBeamAddress : kFakeBeamAddress2;
  }

  BuyBeamAsset get btc => BuyBeamAsset.fromJson(
    kFakeAssets.firstWhere((a) => a['asset_id'] == kBtcId),
  )!;

  BuyBeamQuoteRequest request(String amount) => BuyBeamQuoteRequest(
    asset: btc,
    amount: BuyBeamAmount.parse(amount, decimals: 8).amount!,
    refundAddress: kFakeBtcRefund,
  );

  Future<BuyBeamOrder> place([String amount = '0.0123']) =>
      controller.placeOrder(
        asset: btc,
        amount: BuyBeamAmount.parse(amount, decimals: 8).amount!,
        refundAddress: kFakeBtcRefund,
        beamWalletId: 'w1',
        newBeamAddress: newAddress,
      );
}

BuyBeamOrder _stored(String deposit, {BuyBeamState? state, DateTime? at}) =>
    BuyBeamOrder(
      depositAddress: deposit,
      assetId: kBtcId,
      symbol: 'BTC',
      chain: 'btc',
      decimals: 8,
      sendAmount: '0.0123',
      sendAmountRaw: BigInt.from(1230000),
      beamAddress: kFakeBeamAddress,
      beamWalletId: 'w1',
      refundAddress: kFakeBtcRefund,
      createdAt: at ?? DateTime.utc(2026, 10, 9, 11),
      lastState: state,
      terminal: state?.isFinal ?? false,
    );

void main() {
  group('quotes', () {
    test('asked once typing pauses for 400 ms', () async {
      final r = _Rig();
      final c = r.controller;
      c.requestQuote(r.request('0.01'));
      await r.clock.advance(const Duration(milliseconds: 200));
      c.requestQuote(r.request('0.012'));
      await r.clock.advance(const Duration(milliseconds: 200));
      c.requestQuote(r.request('0.0123'));
      expect(c.quoting, isTrue);
      await r.clock.advance(const Duration(milliseconds: 399));
      expect(r.server.count('/quote'), 0);
      await r.clock.advance(const Duration(milliseconds: 1));
      expect(r.server.count('/quote'), 1);
      expect(r.server.requests.single.url.queryParameters['amount'], '0.0123');
      expect(c.quoting, isFalse);
      expect(c.quote, isNotNull);
      expect(c.quoteError, isNull);
    });

    test('a slow answer to an older question is dropped', () async {
      final r = _Rig();
      final c = r.controller;
      final hold = r.server.holdQuotes = Completer<void>();
      c.requestQuote(r.request('0.0123'));
      await r.clock.advance(const Duration(milliseconds: 400));
      expect(r.server.count('/quote'), 1); // waiting for its answer
      r.server.holdQuotes = null;
      c.requestQuote(r.request('0.02'));
      await r.clock.advance(const Duration(milliseconds: 400));
      expect(r.server.count('/quote'), 2);
      final latest = c.quote;
      expect(latest, isNotNull);
      hold.complete();
      await drain();
      expect(identical(c.quote, latest), isTrue);
      expect(c.quoteRequest, r.request('0.02'));
      expect(c.quoting, isFalse);
    });

    test('clearing drops a price on its way', () async {
      final r = _Rig();
      final c = r.controller;
      c.requestQuote(r.request('0.0123'));
      c.requestQuote(null);
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.server.count('/quote'), 0);
      expect(c.quote, isNull);
      expect(c.quoting, isFalse);
    });

    test('the smallest-buy hint: buybeam.my\'s observed figure, else the '
        'one a refused price stated, else its own floor', () async {
      final r = _Rig();
      r.server.queue(
        '/limits',
        envelope({
          'our_minimum_usd': 5.0,
          'upstream_observed_minimum_usd': null,
        }),
      );
      await r.controller.refreshLimits();
      expect(r.controller.minimumHintUsd, 5);
      r.controller.requestQuote(r.request('0.0001'));
      await r.clock.advance(const Duration(milliseconds: 400));
      expect(r.controller.minimumHintUsd, 1000);
      await r.controller.refreshLimits(); // the default: 1,000 observed
      expect(r.controller.minimumHintUsd, 1000);
    });

    test('under the smallest buy: the error, with its figure', () async {
      final r = _Rig();
      r.controller.requestQuote(r.request('0.0001'));
      await r.clock.advance(const Duration(milliseconds: 400));
      final e = r.controller.quoteError!;
      expect(e.code, BuyBeamErrorCode.amountBelowUpstreamMinimum);
      expect(e.minimumUsd, 1000);
      // "Try again" asks at once.
      r.controller.requote();
      await r.clock.advance(Duration.zero);
      expect(r.server.count('/quote'), 2);
    });
  });

  group('orders', () {
    test('the buy is on disk before placeOrder returns', () async {
      final store = MemoryBuyBeamStore();
      final r = _Rig(store: store);
      final o = await r.place();
      expect(store.writes, hasLength(1));
      expect(store.writes.single.depositAddress, o.depositAddress);
      expect(o.beamAddress, kFakeBeamAddress);
      expect(o.sendAmount, '0.0123');
      expect(o.lastState, BuyBeamState.awaitingDeposit);
      expect(r.controller.orders(beamWalletId: 'w1').single, same(o));
      expect(r.controller.orders(beamWalletId: 'other'), isEmpty);
    });

    test('a POST that got no answer is sent again as it was: the same '
        'order comes back', () async {
      final r = _Rig();
      r.server
        ..queue('/order', http.ClientException('circuit closed'))
        ..queue('/order', FakeAnswer.html(403));
      final o = await r.place();
      final posts = r.server.requests.where((q) => q.method == 'POST');
      expect(posts, hasLength(3));
      expect(posts.map((p) => p.body).toSet(), hasLength(1));
      expect(r.addressesMade, 1);
      expect(o.depositAddress, r.server.depositAddress);
    });

    test('still no answer: the error, and "Try again" reuses the BEAM '
        'address so buybeam.my returns the same order', () async {
      final r = _Rig();
      r.server.offline = true;
      await expectLater(
        r.place(),
        throwsA(
          isA<BuyBeamError>().having(
            (e) => e.code,
            'code',
            BuyBeamErrorCode.network,
          ),
        ),
      );
      expect(r.server.count('/order'), 3);
      r.server.offline = false;
      r.server.queue('/order', orderJson(created: false));
      final o = await r.place();
      expect(r.addressesMade, 1);
      expect(o.beamAddress, kFakeBeamAddress);
      final bodies = r.server.requests
          .where((q) => q.method == 'POST')
          .map((q) => q.body)
          .toSet();
      expect(bodies, hasLength(1));
    });

    test('an answer for another order is not kept or shown', () async {
      final store = MemoryBuyBeamStore();
      final r = _Rig(store: store);
      r.server.queue('/order', orderJson(beamWallet: kFakeBeamAddress2));
      await expectLater(r.place(), throwsA(isA<BuyBeamError>()));
      expect(store.writes, isEmpty);
      expect(r.controller.orders(), isEmpty);
      expect(r.server.count('/order'), 1); // not "unreachable": no retry
    });
  });

  group('following a buy', () {
    test('looked at every poll_after_seconds until it ends', () async {
      final r = _Rig();
      final o = await r.place();
      final path = '/order/${o.depositAddress}';
      expect(r.server.count(path), 0);
      await r.clock.advance(const Duration(seconds: 14));
      expect(r.server.count(path), 0);
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.server.count(path), 1);
      // buybeam.my asks for 5 s now.
      r.server.queue(
        path,
        statusJson('buying', deposit: o.depositAddress, pollAfter: 5),
      );
      await r.clock.advance(const Duration(seconds: 15));
      expect(r.server.count(path), 2);
      expect(
        r.controller.order(o.depositAddress)!.lastState,
        BuyBeamState.buying,
      );
      await r.clock.advance(const Duration(seconds: 5));
      expect(r.server.count(path), 3);
      r.server
        ..state = 'delivered'
        ..txId = 'beamtx1';
      await r.clock.advance(const Duration(seconds: 15));
      expect(r.server.count(path), 4);
      final done = r.controller.order(o.depositAddress)!;
      expect(done.lastState, BuyBeamState.delivered);
      expect(done.terminal, isTrue);
      expect(done.beamTxId, 'beamtx1');
      expect(r.controller.dueAt(o.depositAddress), isNull);
      await r.clock.advance(const Duration(hours: 1));
      expect(r.server.count(path), 4); // never again
      expect(r.clock.pending, 0);
    });

    test('an unknown state keeps it followed', () async {
      final r = _Rig();
      final o = await r.place();
      r.server.state = 'settling_in_v2';
      await r.clock.advance(const Duration(seconds: 15));
      expect(
        r.controller.order(o.depositAddress)!.lastState,
        BuyBeamState.inProgress,
      );
      expect(r.controller.order(o.depositAddress)!.isOpen, isTrue);
      await r.clock.advance(const Duration(seconds: 15));
      expect(r.server.count('/order/${o.depositAddress}'), 2);
    });

    test('no answer: looked at less often, retry_after honoured', () async {
      final r = _Rig();
      final o = await r.place();
      final path = '/order/${o.depositAddress}';
      r.server.offline = true;
      await r.clock.advance(const Duration(seconds: 15));
      expect(
        r.controller.pollError(o.depositAddress)!.code,
        BuyBeamErrorCode.network,
      );
      // 30 s, then 60 s, then 120 s…
      final t0 = r.clock.now();
      expect(
        r.controller.dueAt(o.depositAddress),
        t0.add(const Duration(seconds: 30)),
      );
      await r.clock.advance(const Duration(seconds: 30));
      expect(
        r.controller.dueAt(o.depositAddress),
        r.clock.now().add(const Duration(seconds: 60)),
      );
      r.server.offline = false;
      r.server.queue(
        path,
        FakeAnswer.json(
          errorJson('upstream_unavailable', retryAfter: 600),
          status: 503,
        ),
      );
      await r.clock.advance(const Duration(seconds: 60));
      expect(
        r.controller.dueAt(o.depositAddress),
        r.clock.now().add(const Duration(seconds: 600)),
      );
      final before = r.server.requests.length;
      await r.clock.advance(const Duration(seconds: 599));
      expect(r.server.requests.length, before);
      await r.clock.advance(const Duration(seconds: 1));
      expect(r.server.requests.length, before + 1);
      // Answered again: back to every 15 s, and no error shown.
      expect(r.controller.pollError(o.depositAddress), isNull);
      expect(
        r.controller.dueAt(o.depositAddress),
        r.clock.now().add(const Duration(seconds: 15)),
      );
    });

    test('the open buys kept on this device are followed on start; ended '
        'ones are not', () async {
      final store = MemoryBuyBeamStore();
      await store.save(_stored('open1', state: BuyBeamState.buying));
      await store.save(_stored('done1', state: BuyBeamState.delivered));
      final r = _Rig(store: store);
      r.server.depositAddress = 'open1';
      r.server.state = 'sending';
      await r.controller.resumeAll();
      await r.clock.advance(Duration.zero);
      expect(r.server.count('/order/open1'), 1);
      expect(r.server.count('/order/done1'), 0);
      expect(r.controller.order('open1')!.lastState, BuyBeamState.sending);
      expect(store.writes.last.lastState, BuyBeamState.sending);
      expect(r.controller.orders(), hasLength(2));
      // Starting twice follows them once.
      await r.controller.resumeAll();
      await r.clock.advance(Duration.zero);
      expect(r.server.count('/order/open1'), 1);
    });

    test('nothing is polled while paused; resume catches up', () async {
      final r = _Rig();
      final o = await r.place();
      r.controller.pause();
      await r.clock.advance(const Duration(minutes: 5));
      expect(r.server.count('/order/${o.depositAddress}'), 0);
      r.controller.resume();
      await r.clock.advance(Duration.zero);
      expect(r.server.count('/order/${o.depositAddress}'), 1);
    });

    test('autoPoll off: nothing happens until pollDue', () async {
      final r = _Rig(autoPoll: false);
      final o = await r.place();
      await r.clock.advance(const Duration(minutes: 5));
      expect(r.server.count('/order/${o.depositAddress}'), 0);
      expect(r.clock.pending, 0);
      await r.controller.pollDue();
      expect(r.server.count('/order/${o.depositAddress}'), 1);
    });

    test('the state is written only when it changes', () async {
      final store = MemoryBuyBeamStore();
      final r = _Rig(store: store, autoPoll: false);
      final o = await r.place();
      await r.controller.poll(o.depositAddress);
      await r.controller.poll(o.depositAddress);
      expect(store.writes, hasLength(1)); // awaiting both times
      r.server.state = 'deposit_detected';
      await r.controller.poll(o.depositAddress);
      expect(store.writes, hasLength(2));
      expect(store.writes.last.lastState, BuyBeamState.depositDetected);
    });
  });
}
