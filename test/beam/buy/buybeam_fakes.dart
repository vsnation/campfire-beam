/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A buybeam.my stand-in for tests: an http.Client that answers the buy
// API's five calls the way buybeam.my does (shapes taken from its real
// answers), records every request, and can be told to fail in each of
// the ways the real one can; and a clock whose timers run when told.
//
// Every address here is made up.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_controller.dart';

/// A made-up BEAM address (66 characters, as a regular one is).
const kFakeBeamAddress =
    '1111111111111111111111111111111111111111111111111111111111111111aa';
const kFakeBeamAddress2 =
    '2222222222222222222222222222222222222222222222222222222222222222bb';

/// Made-up refund addresses.
const kFakeBtcRefund = 'bc1qfake0refund0address0for0tests0only00000';
const kFakeEthRefund = '0x1111111111111111111111111111111111111111';

const kBtcId = 'coin:btc';
const kEthId = 'coin:eth';
const kUsdtTronId = 'coin:tron-usdt';

Map<String, Object?> assetJson(
  String id,
  String symbol,
  String chain,
  int decimals, {
  String? contract,
  double? price,
}) => {
  'asset_id': id,
  'symbol': symbol,
  'blockchain': chain,
  'decimals': decimals,
  'contract_address': contract,
  'price_usd': price,
  'price_updated_at': null,
  'coingecko_id': null,
};

/// A few of buybeam.my's coins, deliberately out of order.
final List<Map<String, Object?>> kFakeAssets = [
  assetJson('coin:eth-aave', 'AAVE', 'eth', 18, contract: '0x7fc6', price: 140),
  assetJson('coin:ltc', 'LTC', 'ltc', 8, price: 63.31),
  assetJson(kEthId, 'ETH', 'eth', 18, price: 2476.84),
  assetJson(
    kUsdtTronId,
    'USDT',
    'tron',
    6,
    contract: 'TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t',
    price: 0.9992,
  ),
  assetJson('coin:kaia', 'KAIA', 'kaia', 18, price: 0.12),
  assetJson(kBtcId, 'BTC', 'btc', 8, price: 82306),
  assetJson('coin:zec', 'ZEC', 'zec', 8, price: 1201.81),
];

Map<String, Object?> envelope(Map<String, Object?> body) => {
  'ok': true,
  'error': null,
  'api_version': '1.0.0',
  'server_time': 1791576000,
  ...body,
};

Map<String, Object?> errorJson(
  String code, {
  double? minimumUsd,
  double? orderValueUsd,
  double? retryAfter,
}) => {
  'ok': false,
  'api_version': '1.0.0',
  'server_time': 1791576000,
  'error': {
    'code': code,
    'message': 'words that change',
    'minimum_usd': ?minimumUsd,
    'order_value_usd': ?orderValueUsd,
    'retry_after': ?retryAfter,
  },
};

/// What the real /quote answers for 0.0123 BTC.
Map<String, Object?> quoteJson({
  String assetId = kBtcId,
  String raw = '1230000',
  double beam = 192460.19775695,
  String? beamRaw = '19246019775695',
  int eta = 810,
}) => envelope({
  'asset_id': assetId,
  'symbol': 'BTC',
  'blockchain': 'btc',
  'decimals': 8,
  'send_amount': 0.0123,
  'send_amount_raw': raw,
  'order_value_usd': 1012.36,
  'beam_estimate': beam,
  'beam_estimate_raw': beamRaw,
  'eta_seconds': eta,
  'deadline': null,
});

Map<String, Object?> orderJson({
  String deposit = 'bc1qfake0deposit0address0000000000000000000',
  String assetId = kBtcId,
  String beamWallet = kFakeBeamAddress,
  String? raw = '1230000',
  double sendAmount = 0.0123,
  bool payable = true,
  bool created = true,
  Object? deadline,
}) => envelope({
  'order_id': deposit,
  'deposit_address': deposit,
  'asset_id': assetId,
  'symbol': 'BTC',
  'blockchain': 'btc',
  'send_amount': sendAmount,
  'send_amount_raw': ?raw,
  'beam_wallet': beamWallet,
  'beam_estimate': 192460.19775695,
  'order_value_usd': 1012.36,
  'deadline': deadline,
  'eta_seconds': 810,
  'payable': payable,
  'created': created,
});

Map<String, Object?> statusJson(
  String state, {
  String deposit = 'bc1qfake0deposit0address0000000000000000000',
  bool? terminal,
  num? pollAfter = 15,
  String? txId,
}) => envelope({
  'order_id': deposit,
  'deposit_address': deposit,
  'state': state,
  'state_description': 'words that change',
  'terminal':
      terminal ??
      const {'delivered', 'refunded', 'expired', 'failed'}.contains(state),
  'poll_after_seconds': pollAfter,
  'beam_txid': txId,
  'beam_estimate': 192460.19775695,
  'deadline': null,
  'raw': {'payin_status': 'anything'},
});

/// One canned answer.
class FakeAnswer {
  FakeAnswer(this.status, this.body, {this.headers = const {}});

  FakeAnswer.json(Map<String, Object?> j, {int status = 200})
    : this(
        status,
        jsonEncode(j),
        headers: {'content-type': 'application/json'},
      );

  /// What a proxy in front of buybeam.my sends: a page, not JSON.
  FakeAnswer.html(int status)
    : this(status, '<!DOCTYPE html><html><body>Blocked</body></html>');

  final int status;
  final String body;
  final Map<String, String> headers;
}

/// buybeam.my, in memory. Each call is answered by the first queued
/// answer for its path ([queue]), else by the defaults below.
class FakeBuyBeamServer {
  final List<http.Request> requests = [];

  /// Answers to use first, by path ("/quote", "/order", "/order/<addr>").
  final Map<String, List<Object>> _queued = {};

  /// Fails every request without an answer (no network, Tor down).
  bool offline = false;

  /// Waits for this before answering /quote (latest-wins tests).
  Completer<void>? holdQuotes;

  String depositAddress = 'bc1qfake0deposit0address0000000000000000000';
  String state = 'awaiting_deposit';
  String? txId;

  /// [answer] is a [FakeAnswer], a JSON map, or an exception to throw.
  void queue(String path, Object answer) => (_queued[path] ??= []).add(answer);

  http.Client client() => MockClient(_handle);

  int count(String path) =>
      requests.where((r) => r.url.path.endsWith(path)).length;

  Future<http.Response> _handle(http.Request r) async {
    requests.add(r);
    if (offline) throw http.ClientException('offline', r.url);
    final path = r.url.path.replaceFirst('/api/v1/buy', '');
    final queued = _queued[path];
    if (queued != null && queued.isNotEmpty) {
      return _answer(r, queued.removeAt(0));
    }
    if (path == '/quote') await holdQuotes?.future;
    return _answer(r, _default(r, path));
  }

  Future<http.Response> _answer(http.Request r, Object a) async {
    if (a is Exception) throw a;
    if (a is Error) throw a;
    final FakeAnswer f = a is FakeAnswer
        ? a
        : FakeAnswer.json((a as Map).cast<String, Object?>());
    return http.Response(f.body, f.status, headers: f.headers, request: r);
  }

  Object _default(http.Request r, String path) {
    switch (path) {
      case '/assets':
        return envelope({
          'count': kFakeAssets.length,
          'blockchains': ['btc', 'eth', 'ltc', 'tron', 'zec', 'kaia'],
          'cache_age_s': 0,
          'assets': kFakeAssets,
        });
      case '/limits':
        return envelope({
          'our_minimum_usd': 5.0,
          'maximum_usd': null,
          'upstream_observed_minimum_usd': 1000.0,
          'upstream_observed_at': 1791576000,
        });
      case '/quote':
        final q = r.url.queryParameters;
        final id = q['asset_id']!;
        final amount = double.parse(q['amount']!);
        final asset = kFakeAssets.firstWhere((a) => a['asset_id'] == id);
        final dec = asset['decimals']! as int;
        final usd = amount * ((asset['price_usd'] as num?) ?? 1);
        if (usd < 1000) {
          return FakeAnswer.json(
            errorJson('amount_below_upstream_minimum', minimumUsd: 1000),
            status: 400,
          );
        }
        final raw = BigInt.from(
          (amount * double.parse('1e$dec')).roundToDouble(),
        );
        return quoteJson(
          assetId: id,
          raw: raw.toString(),
          beam: usd * 110,
          beamRaw: BigInt.from((usd * 110 * 1e8).round()).toString(),
        );
      case '/order':
        final b = (jsonDecode(r.body) as Map).cast<String, Object?>();
        final id = b['asset_id']! as String;
        final asset = kFakeAssets.firstWhere((a) => a['asset_id'] == id);
        final dec = asset['decimals']! as int;
        final amount = (b['amount']! as num).toDouble();
        return orderJson(
          deposit: depositAddress,
          assetId: id,
          beamWallet: b['beam_wallet']! as String,
          raw: BigInt.from((amount * double.parse('1e$dec')).roundToDouble())
              .toString(),
          sendAmount: amount,
        );
    }
    if (path.startsWith('/order/')) {
      return statusJson(state, deposit: depositAddress, txId: txId);
    }
    return FakeAnswer.json(errorJson('not_found'), status: 404);
  }
}

/// A clock that stands still until [advance]d; timers fire in order.
class FakeBuyBeamClock implements BuyBeamClock {
  FakeBuyBeamClock([DateTime? start])
    : _now = start ?? DateTime.utc(2026, 10, 9, 12);

  DateTime _now;
  final List<FakeTimer> _timers = [];

  @override
  DateTime now() => _now;

  @override
  Timer schedule(Duration after, void Function() callback) {
    final t = FakeTimer(_now.add(after), callback, _timers);
    _timers.add(t);
    return t;
  }

  /// Timers still to fire.
  int get pending => _timers.length;

  /// Moves time on by [d], firing every timer due on the way, and lets
  /// what they started finish.
  Future<void> advance(Duration d) async {
    final end = _now.add(d);
    while (true) {
      await drain();
      final due = _timers.where((t) => !t.at.isAfter(end)).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      _timers.remove(t);
      if (t.at.isAfter(_now)) _now = t.at;
      t.callback();
    }
    _now = end;
    await drain();
  }
}

class FakeTimer implements Timer {
  FakeTimer(this.at, this.callback, this._list);

  final DateTime at;
  final void Function() callback;
  final List<FakeTimer> _list;

  @override
  void cancel() => _list.remove(this);

  @override
  bool get isActive => _list.contains(this);

  @override
  int get tick => 0;
}

/// Lets queued futures and microtasks run.
Future<void> drain() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
