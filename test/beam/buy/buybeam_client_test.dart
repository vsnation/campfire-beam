/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The buybeam.my client over a fake http.Client: every error code it
// documents, a proxy's HTML page and a dead connection (never "the order
// failed"), sandbox as a query parameter only, an order answer refused
// for every way it can differ from the question, and amounts typed as
// decimals carried exactly for 6, 8 and 18 decimals.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';

import 'buybeam_fakes.dart';

BuyBeamAmount _amount(String text, int decimals) =>
    BuyBeamAmount.parse(text, decimals: decimals).amount!;

BuyBeamClient _client(FakeBuyBeamServer s, {bool sandbox = false}) =>
    BuyBeamClient(clientFactory: s.client, sandbox: sandbox);

Future<BuyBeamError> _error(Future<Object?> f) async {
  try {
    await f;
  } on BuyBeamError catch (e) {
    return e;
  }
  fail('expected a BuyBeamError');
}

Future<BuyBeamOrderAnswer> _order(
  BuyBeamClient c, {
  String amount = '0.0123',
  String beam = kFakeBeamAddress,
}) => c.order(
  assetId: kBtcId,
  amount: _amount(amount, 8),
  beamAddress: beam,
  refundAddress: kFakeBtcRefund,
);

void main() {
  group('errors', () {
    const documented = [
      'amount_below_upstream_minimum',
      'amount_below_our_minimum',
      'bad_amount',
      'amount_too_small',
      'unknown_asset',
      'asset_unavailable',
      'no_liquidity',
      'refund_address_required',
      'beam_wallet_required',
      'beam_wallet_too_short',
      'beam_wallet_too_long',
      'beam_wallet_invalid',
      'asset_id_required',
      'bad_body',
      'order_not_found',
      'price_unavailable',
      'upstream_absent',
      'upstream_unavailable',
      'quote_failed',
      'no_deposit_address',
    ];

    test('every documented code is its own typed error', () async {
      for (final code in documented) {
        final s = FakeBuyBeamServer()
          ..queue('/quote', FakeAnswer.json(errorJson(code), status: 400));
        final e = await _error(
          _client(s).quote(
            assetId: kBtcId,
            amount: _amount('0.0123', 8),
            refundAddress: kFakeBtcRefund,
          ),
        );
        expect(e.code.wire, code);
        expect(e.code, isNot(BuyBeamErrorCode.unknown), reason: code);
        expect(e.rawCode, code);
        expect(e.httpStatus, 400);
      }
      expect(documented.toSet().length, documented.length);
    });

    test('an unknown code is "unknown" and keeps the code it had', () async {
      final s = FakeBuyBeamServer()
        ..queue('/limits', FakeAnswer.json(errorJson('new_in_v1_9')));
      final e = await _error(_client(s).limits());
      expect(e.code, BuyBeamErrorCode.unknown);
      expect(e.rawCode, 'new_in_v1_9');
    });

    test('the smallest buy comes from the error, not Campfire', () async {
      final s = FakeBuyBeamServer()
        ..queue(
          '/quote',
          FakeAnswer.json(
            errorJson('amount_below_upstream_minimum', minimumUsd: 1234.5),
            status: 400,
          ),
        );
      final e = await _error(
        _client(s).quote(
          assetId: kBtcId,
          amount: _amount('0.0001', 8),
          refundAddress: kFakeBtcRefund,
        ),
      );
      expect(e.code, BuyBeamErrorCode.amountBelowUpstreamMinimum);
      expect(e.code.belowMinimum, isTrue);
      expect(e.minimumUsd, 1234.5);
    });

    test('retry_after: from the error, the envelope or the header', () async {
      final s = FakeBuyBeamServer()
        ..queue(
          '/limits',
          FakeAnswer.json(
            errorJson('price_unavailable', retryAfter: 30),
            status: 503,
          ),
        )
        ..queue(
          '/limits',
          FakeAnswer.json({
            ...errorJson('upstream_absent'),
            'retry_after': 12,
          }, status: 503),
        )
        ..queue(
          '/limits',
          FakeAnswer(
            503,
            jsonEncode(errorJson('quote_failed')),
            headers: {'retry-after': '7'},
          ),
        );
      final c = _client(s);
      expect(
        (await _error(c.limits())).retryAfter,
        const Duration(seconds: 30),
      );
      expect(
        (await _error(c.limits())).retryAfter,
        const Duration(seconds: 12),
      );
      expect((await _error(c.limits())).retryAfter, const Duration(seconds: 7));
    });

    test("a proxy's HTML 403 is 'blocked', not an order failure", () async {
      final s = FakeBuyBeamServer()..queue('/order', FakeAnswer.html(403));
      final e = await _error(_order(_client(s)));
      expect(e.code, BuyBeamErrorCode.blocked);
      expect(e.code.unreachable, isTrue);
      expect(e.httpStatus, 403);
    });

    test("a proxy's plain-text 502 is 'blocked' too", () async {
      final s = FakeBuyBeamServer()
        ..queue('/quote', FakeAnswer(502, 'error code: 502'));
      final e = await _error(
        _client(s).quote(
          assetId: kBtcId,
          amount: _amount('0.0123', 8),
          refundAddress: kFakeBtcRefund,
        ),
      );
      expect(e.code, BuyBeamErrorCode.blocked);
      expect(e.httpStatus, 502);
    });

    test('no connection is "network"', () async {
      final s = FakeBuyBeamServer()..offline = true;
      final e = await _error(_client(s).assets());
      expect(e.code, BuyBeamErrorCode.network);
      expect(e.code.unreachable, isTrue);
    });

    test('an answer that never comes is "network"', () async {
      final c = BuyBeamClient(
        clientFactory: () =>
            MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 50),
      );
      final e = await _error(c.limits());
      expect(e.code, BuyBeamErrorCode.network);
    });

    test('JSON without "ok" is an unexpected answer', () async {
      final s = FakeBuyBeamServer()
        ..queue('/limits', FakeAnswer.json({'hello': 1}));
      final e = await _error(_client(s).limits());
      expect(e.code, BuyBeamErrorCode.unexpectedAnswer);
    });
  });

  group('requests', () {
    test(
      'sandbox: a query parameter on every call, never in the body',
      () async {
        final s = FakeBuyBeamServer()..depositAddress = 'sbx_1_fake';
        final c = _client(s, sandbox: true);
        await c.assets();
        await c.limits();
        await c.quote(
          assetId: kBtcId,
          amount: _amount('0.0123', 8),
          refundAddress: kFakeBtcRefund,
        );
        await c.order(
          assetId: kBtcId,
          amount: _amount('0.0123', 8),
          beamAddress: kFakeBeamAddress,
          refundAddress: kFakeBtcRefund,
        );
        await c.status('sbx_1_fake');
        expect(s.requests, hasLength(5));
        for (final r in s.requests) {
          expect(r.url.queryParameters['sandbox'], 'true', reason: '${r.url}');
        }
        final post = s.requests.singleWhere((r) => r.method == 'POST');
        final body = (jsonDecode(post.body) as Map).cast<String, Object?>();
        expect(body.containsKey('sandbox'), isFalse);
        expect(body.keys.toSet(), {
          'asset_id',
          'amount',
          'beam_wallet',
          'refund_address',
        });
      },
    );

    test('without sandbox no call carries it', () async {
      final s = FakeBuyBeamServer();
      final c = _client(s);
      await c.assets();
      await _order(c);
      for (final r in s.requests) {
        expect(r.url.queryParameters.containsKey('sandbox'), isFalse);
      }
    });

    test('Campfire is the user agent, JSON is asked for, the BEAM address '
        'only travels in the body', () async {
      final s = FakeBuyBeamServer();
      await _order(_client(s));
      final r = s.requests.single;
      expect(r.headers['user-agent'], 'Campfire');
      expect(r.headers['accept'], 'application/json');
      expect(r.headers['content-type'], startsWith('application/json'));
      expect(r.url.toString(), isNot(contains(kFakeBeamAddress)));
      expect(r.url.path, '/api/v1/buy/order');
    });

    test('the coins are read, unreadable entries skipped', () async {
      final s = FakeBuyBeamServer()
        ..queue(
          '/assets',
          envelope({
            'assets': [
              kFakeAssets.first,
              {'asset_id': 'x'},
              'junk',
            ],
          }),
        );
      final list = await _client(s).assets();
      expect(list.single.symbol, 'AAVE');
      expect(list.single.isNative, isFalse);
    });

    test('BTC, ETH and USDT on Tron come first in the picker', () {
      final sorted = sortBuyBeamAssets([
        for (final j in kFakeAssets) BuyBeamAsset.fromJson(j)!,
      ]);
      expect(sorted.map((a) => '${a.symbol}/${a.blockchain}').toList(), [
        'BTC/btc',
        'ETH/eth',
        'USDT/tron',
        'LTC/ltc',
        'ZEC/zec',
        'KAIA/kaia',
        'AAVE/eth',
      ]);
      expect(sorted.first.chainName, 'Bitcoin');
      expect(sorted[5].chainName, 'KAIA');
    });

    test('the smallest-buy hint prefers the observed figure', () async {
      final s = FakeBuyBeamServer();
      expect((await _client(s).limits()).hintUsd, 1000);
      s.queue(
        '/limits',
        envelope({
          'our_minimum_usd': 5.0,
          'upstream_observed_minimum_usd': null,
        }),
      );
      expect((await _client(s).limits()).hintUsd, 5);
    });
  });

  group('quote', () {
    test("buybeam.my's estimate is taken as it is", () async {
      final s = FakeBuyBeamServer()
        ..queue('/quote', quoteJson(beam: 192460.19775695));
      final q = await _client(s).quote(
        assetId: kBtcId,
        amount: _amount('0.0123', 8),
        refundAddress: kFakeBtcRefund,
      );
      expect(q.beamEstimate, 192460.19775695);
      expect(q.beamGroth, BigInt.parse('19246019775695'));
      expect(q.etaSeconds, 810);
      final query = s.requests.single.url.queryParameters;
      expect(query['amount'], '0.0123');
      expect(query['refund_address'], kFakeBtcRefund);
    });

    test('a quote for another amount or coin is refused', () async {
      for (final a in [quoteJson(raw: '1230001'), quoteJson(assetId: kEthId)]) {
        final s = FakeBuyBeamServer()..queue('/quote', a);
        final e = await _error(
          _client(s).quote(
            assetId: kBtcId,
            amount: _amount('0.0123', 8),
            refundAddress: kFakeBtcRefund,
          ),
        );
        expect(e.code, BuyBeamErrorCode.unexpectedAnswer);
      }
    });
  });

  group('order', () {
    test('the order asked for is accepted, as is the same one again', () async {
      final s = FakeBuyBeamServer()
        ..queue('/order', orderJson())
        ..queue('/order', orderJson(created: false));
      final c = _client(s);
      final a = await _order(c);
      expect(a.depositAddress, 'bc1qfake0deposit0address0000000000000000000');
      expect(a.created, isTrue);
      expect(a.payable, isTrue);
      final again = await _order(c);
      expect(again.created, isFalse);
      expect(again.depositAddress, a.depositAddress);
    });

    for (final (what, answer) in [
      ('another coin', orderJson(assetId: kEthId)),
      ('another BEAM address', orderJson(beamWallet: kFakeBeamAddress2)),
      ('another amount', orderJson(raw: '1230001')),
      ('no raw amount', orderJson(raw: null)),
      ('not payable', orderJson(payable: false)),
      ('no deposit address', orderJson(deposit: '')),
      ('a blank deposit address', orderJson(deposit: '   ')),
    ]) {
      test('refused: $what', () async {
        final s = FakeBuyBeamServer()..queue('/order', answer);
        final e = await _error(_order(_client(s)));
        expect(e.code, BuyBeamErrorCode.unexpectedAnswer);
      });
    }

    test('sandbox: not payable, no raw figure, the same number', () async {
      final s = FakeBuyBeamServer()
        ..queue(
          '/order',
          orderJson(deposit: 'sbx_1_x', raw: null, payable: false),
        )
        ..queue(
          '/order',
          orderJson(
            deposit: 'sbx_1_x',
            raw: null,
            payable: false,
            sendAmount: 0.0124,
          ),
        );
      final c = _client(s, sandbox: true);
      expect((await _order(c)).depositAddress, 'sbx_1_x');
      expect((await _error(_order(c))).code, BuyBeamErrorCode.unexpectedAnswer);
    });

    test('a blocked POST is not an order failure', () async {
      final s = FakeBuyBeamServer()
        ..queue('/order', FakeAnswer.html(403))
        ..queue('/order', http.ClientException('reset'));
      final c = _client(s);
      expect((await _error(_order(c))).code, BuyBeamErrorCode.blocked);
      expect((await _error(_order(c))).code, BuyBeamErrorCode.network);
    });
  });

  group('status', () {
    test('every state; an unknown one is "in progress"', () async {
      for (final (wire, state, terminal) in [
        ('awaiting_deposit', BuyBeamState.awaitingDeposit, false),
        ('deposit_detected', BuyBeamState.depositDetected, false),
        ('swapping', BuyBeamState.swapping, false),
        ('buying', BuyBeamState.buying, false),
        ('processing', BuyBeamState.processing, false),
        ('sending', BuyBeamState.sending, false),
        ('attention', BuyBeamState.attention, false),
        ('delivered', BuyBeamState.delivered, true),
        ('refunded', BuyBeamState.refunded, true),
        ('expired', BuyBeamState.expired, true),
        ('failed', BuyBeamState.failed, true),
        ('settling_in_v2', BuyBeamState.inProgress, false),
      ]) {
        final s = FakeBuyBeamServer()..state = wire;
        final st = await _client(s).status(s.depositAddress);
        expect(st.state, state, reason: wire);
        expect(st.rawState, wire);
        expect(st.terminal, terminal, reason: wire);
      }
    });

    test('a new state marked terminal is still followed', () async {
      final s = FakeBuyBeamServer()
        ..queue(
          '/order/${Uri.encodeComponent('bc1qx')}',
          statusJson('archived', deposit: 'bc1qx', terminal: true),
        );
      final st = await _client(s).status('bc1qx');
      expect(st.state, BuyBeamState.inProgress);
      expect(st.terminal, isFalse);
    });

    test('poll_after, the delivery transaction, the echo', () async {
      final s = FakeBuyBeamServer()
        ..state = 'delivered'
        ..txId = 'sbx_delivery_txid';
      final st = await _client(s).status(s.depositAddress);
      expect(st.pollAfter, const Duration(seconds: 15));
      expect(st.beamTxId, 'sbx_delivery_txid');
      s.queue('/order/other', statusJson('delivered', deposit: 'someone_else'));
      expect(
        (await _error(_client(s).status('other'))).code,
        BuyBeamErrorCode.unexpectedAnswer,
      );
    });

    test('sandbox: a forced state is asked for with ":<state>"', () async {
      final s = FakeBuyBeamServer()..depositAddress = 'sbx_1_y';
      await _client(s, sandbox: true).status('sbx_1_y', forceState: 'expired');
      expect(s.requests.single.url.path, '/api/v1/buy/order/sbx_1_y%3Aexpired');
      // Not in production.
      await _client(s).status('sbx_1_y', forceState: 'expired');
      expect(s.requests.last.url.path, '/api/v1/buy/order/sbx_1_y');
    });
  });

  group('amounts', () {
    test('8 decimals (BTC): text to smallest unit, exactly', () {
      final a = _amount('0.0123', 8);
      expect(a.raw, BigInt.from(1230000));
      expect(a.value, 0.0123);
      expect(a.exact, isTrue);
      expect(_amount('.5', 8).text, '0.5');
      expect(_amount('007.10', 8).text, '7.1');
      expect(_amount('7.', 8).raw, BigInt.from(700000000));
    });

    test('6 decimals (USDT): 1024.07 is carried exactly', () {
      final a = _amount('1024.07', 6);
      expect(a.raw, BigInt.from(1024070000));
      // round(), not int(): 1024.07 * 1e6 is 1024069999.9999999.
      expect(BuyBeamAmount.serverRaw(a.value, 6), a.raw);
      expect(a.exact, isTrue);
    });

    test('18 decimals (ETH): most amounts are exact, some are not', () {
      final a = _amount('0.51234567', 18);
      expect(a.raw, BigInt.parse('512345670000000000'));
      expect(a.exact, isTrue);
      // buybeam.my reads 0.51587833 ETH as 64 wei more: refused up front,
      // with an amount it reads exactly.
      final b = _amount('0.51587833', 18);
      expect(BuyBeamAmount.serverRaw(b.value, 18) - b.raw, BigInt.from(64));
      expect(b.exact, isFalse);
      final c = _amount('9.51234567', 18);
      expect(c.exact, isFalse);
      expect(c.nearestExact(), '9.5123457');
      expect(_amount('9.5123457', 18).exact, isTrue);
    });

    test('24 decimals: no amount is exact', () {
      expect(_amount('250', 24).exact, isFalse);
      expect(_amount('250.12345678', 24).nearestExact(), isNull);
    });

    test('at most min(decimals, 8) digits after the point', () {
      expect(
        BuyBeamAmount.parse('0.123456789', decimals: 18).error,
        'Use at most 8 digits after the point',
      );
      expect(
        BuyBeamAmount.parse('1.1234567', decimals: 6).error,
        'Use at most 6 digits after the point',
      );
      expect(BuyBeamAmount.parse('1,5', decimals: 8).error, contains('dot'));
      expect(BuyBeamAmount.parse('abc', decimals: 8).error, isNotNull);
      expect(BuyBeamAmount.parse('', decimals: 8).amount, isNull);
      expect(BuyBeamAmount.parse('', decimals: 8).error, isNull);
    });

    test('the JSON number is the decimal typed', () async {
      final s = FakeBuyBeamServer();
      await _client(s).order(
        assetId: kUsdtTronId,
        amount: _amount('1024.07', 6),
        beamAddress: kFakeBeamAddress,
        refundAddress: 'TFakeTronRefundAddress000000000000',
      );
      final body = (jsonDecode(s.requests.single.body) as Map)
          .cast<String, Object?>();
      expect(body['amount'], 1024.07);
    });
  });
}
