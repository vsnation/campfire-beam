/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// buybeam.my's buy API: pay with a coin from another chain, get BEAM in a
// BEAM wallet. buybeam.my buys the BEAM and sends it to the wallet; this
// file only asks it questions:
//
//   GET  /assets                    the coins it takes
//   GET  /limits                    the smallest buy, as a hint
//   GET  /quote                     what an amount buys, nothing created
//   POST /order                     a deposit address for one buy
//   GET  /order/{deposit address}   where that buy is
//
// Every answer is `{ "ok": true, … }` or `{ "ok": false, "error": { "code"
// … } }`; Campfire branches on `ok` and the code only. An answer that is
// not JSON at all (a proxy's HTML page) or a request that never got an
// answer (TLS, socket, Tor) is "could not reach buybeam.my", never "the
// order failed": a user who already paid must not be told it failed.
//
// Requests go through the client Campfire's Ethereum code uses
// (`createEthHttpClient`): through Tor when Tor is on, nothing sent while
// Tor is on but not connected, direct when it is off. Addresses and amounts
// are never logged, and never put in a URL except the deposit address
// (the order's only handle) and the quote's own fields.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../../../utilities/coin_chains.dart';
import '../../../utilities/logger.dart';

const kBuyBeamBaseUrl = 'https://buybeam.my/api/v1/buy';

/// buybeam.my's own site, where its support is.
const kBuyBeamSite = 'https://buybeam.my';

/// The product name only: no version, nothing that singles a user out.
const kBuyBeamUserAgent = 'Campfire';

// ----------------------------------------------------------------- errors

/// Why buybeam.my said no, or why there was no usable answer.
enum BuyBeamErrorCode {
  amountBelowUpstreamMinimum('amount_below_upstream_minimum'),
  amountBelowOurMinimum('amount_below_our_minimum'),
  badAmount('bad_amount'),
  amountTooSmall('amount_too_small'),
  unknownAsset('unknown_asset'),
  assetUnavailable('asset_unavailable'),
  noLiquidity('no_liquidity'),
  refundAddressRequired('refund_address_required'),
  beamWalletRequired('beam_wallet_required'),
  beamWalletTooShort('beam_wallet_too_short'),
  beamWalletTooLong('beam_wallet_too_long'),
  beamWalletInvalid('beam_wallet_invalid'),
  assetIdRequired('asset_id_required'),
  badBody('bad_body'),
  orderNotFound('order_not_found'),
  priceUnavailable('price_unavailable'),
  upstreamAbsent('upstream_absent'),
  upstreamUnavailable('upstream_unavailable'),
  quoteFailed('quote_failed'),
  noDepositAddress('no_deposit_address'),

  /// Not JSON (a proxy's page instead of buybeam.my's answer).
  blocked('blocked'),

  /// No answer: TLS, socket, Tor, or the time ran out.
  network('network'),

  /// JSON, but not what was asked for; nothing in it is used.
  unexpectedAnswer('unexpected_answer'),

  /// A code this version does not know ([BuyBeamError.rawCode] keeps it).
  unknown('unknown');

  const BuyBeamErrorCode(this.wire);

  final String wire;

  static BuyBeamErrorCode parse(String? code) {
    for (final c in values) {
      if (c.wire == code && c != unknown) return c;
    }
    return unknown;
  }

  /// The amount is under the smallest buy.
  bool get belowMinimum =>
      this == amountBelowUpstreamMinimum || this == amountBelowOurMinimum;

  /// No answer from buybeam.my at all.
  bool get unreachable => this == blocked || this == network;
}

class BuyBeamError implements Exception {
  const BuyBeamError(
    this.code, {
    String? rawCode,
    this.minimumUsd,
    this.orderValueUsd,
    this.retryAfter,
    this.httpStatus,
  }) : rawCode = rawCode ?? '';

  /// Not JSON: a proxy's page, or no page at all.
  const BuyBeamError.blocked({int? httpStatus})
    : this(
        BuyBeamErrorCode.blocked,
        rawCode: 'blocked',
        httpStatus: httpStatus,
      );

  /// No answer.
  const BuyBeamError.network()
    : this(BuyBeamErrorCode.network, rawCode: 'network');

  /// An answer that does not match the question.
  const BuyBeamError.unexpectedAnswer({int? httpStatus})
    : this(
        BuyBeamErrorCode.unexpectedAnswer,
        rawCode: 'unexpected_answer',
        httpStatus: httpStatus,
      );

  factory BuyBeamError.fromJson(
    Map<String, dynamic> e, {
    int? httpStatus,
    Duration? retryAfter,
  }) {
    final raw = e['code'] is String ? e['code'] as String : '';
    return BuyBeamError(
      BuyBeamErrorCode.parse(raw),
      rawCode: raw,
      minimumUsd: _double(e['minimum_usd']),
      orderValueUsd: _double(e['order_value_usd']),
      retryAfter: _seconds(e['retry_after']) ?? retryAfter,
      httpStatus: httpStatus,
    );
  }

  final BuyBeamErrorCode code;

  /// The code exactly as sent ("blocked" / "network" for Campfire's own).
  final String rawCode;

  /// The smallest buy, in US dollars, when the amount was under it.
  final double? minimumUsd;

  /// What the amount was worth, when buybeam.my said.
  final double? orderValueUsd;

  /// Ask again no sooner than this.
  final Duration? retryAfter;
  final int? httpStatus;

  @override
  String toString() =>
      'BuyBeamError(${code.wire}'
      '${rawCode.isEmpty || rawCode == code.wire ? '' : ' $rawCode'}'
      '${httpStatus == null ? '' : ', HTTP $httpStatus'})';
}

// ---------------------------------------------------------------- amounts

/// An amount the user typed, in a coin with [decimals] decimals.
///
/// buybeam.my reads amounts as JSON numbers and works out the coin's
/// smallest unit from them itself, rounding `amount × 10^decimals` in
/// floating point. Campfire keeps the exact amount from the text
/// ([raw]) and checks that buybeam.my's figure is the same before it shows
/// a deposit address. Where floating point cannot carry an amount exactly
/// (most fractions of an 18-decimal coin above about 9 coins, any
/// 24-decimal coin) the amount is refused before anything is asked, and
/// [nearestExact] offers one that it can carry.
class BuyBeamAmount {
  const BuyBeamAmount._(this.text, this.raw, this.decimals);

  /// "0.0122": no grouping, no leading or trailing zeros to speak of.
  final String text;

  /// In the coin's smallest unit.
  final BigInt raw;
  final int decimals;

  /// Digits after the point that may be typed: the coin's own, at most 8
  /// (a double carries 8 exactly for every amount a person buys with).
  static int maxFractionDigits(int decimals) => math.min(decimals, 8);

  static final _number = RegExp(r'^[0-9]*\.?[0-9]*$');

  /// [text] as typed; an error in plain words when it is not an amount.
  static ({BuyBeamAmount? amount, String? error}) parse(
    String text, {
    required int decimals,
  }) {
    final t = text.trim();
    if (t.isEmpty) return (amount: null, error: null);
    if (t.contains(',')) {
      return (amount: null, error: 'Use a dot for decimals, like 0.5');
    }
    if (!_number.hasMatch(t) || t == '.') {
      return (amount: null, error: 'Enter a number, like 0.5');
    }
    final dot = t.indexOf('.');
    final whole = (dot < 0 ? t : t.substring(0, dot)).replaceFirst(
      RegExp('^0+(?=.)'),
      '',
    );
    var frac = dot < 0 ? '' : t.substring(dot + 1);
    final max = maxFractionDigits(decimals);
    if (frac.length > max) {
      return (
        amount: null,
        error:
            'Use at most $max digit${max == 1 ? '' : 's'} after the '
            'point',
      );
    }
    if (whole.length > 15) {
      return (amount: null, error: 'That amount is too large');
    }
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    final w = whole.isEmpty ? '0' : whole;
    final normal = frac.isEmpty ? w : '$w.$frac';
    final unit = BigInt.from(10).pow(decimals);
    final raw =
        BigInt.parse(w) * unit +
        (frac.isEmpty
            ? BigInt.zero
            : BigInt.parse(frac.padRight(decimals, '0')));
    return (amount: BuyBeamAmount._(normal, raw, decimals), error: null);
  }

  /// Exactly [raw] (for amounts Campfire works out, e.g. the smallest buy).
  static BuyBeamAmount? fromDecimalText(String text, int decimals) =>
      parse(text, decimals: decimals).amount;

  bool get isPositive => raw > BigInt.zero;

  /// The number sent to buybeam.my.
  double get value => double.parse(text);

  /// The smallest-unit figure buybeam.my works out from [value]
  /// (`round(value * 10**decimals)` in IEEE doubles, as Python does it).
  static BigInt serverRaw(double value, int decimals) =>
      BigInt.from((value * double.parse('1e$decimals')).roundToDouble());

  /// buybeam.my's figure for this amount is exactly [raw].
  bool get exact => serverRaw(value, decimals) == raw;

  /// The closest amount with fewer digits after the point that buybeam.my
  /// carries exactly; null when there is none (or this one already is).
  String? nearestExact() {
    if (exact) return null;
    final dot = text.indexOf('.');
    final digits = dot < 0 ? 0 : text.length - dot - 1;
    for (var f = digits - 1; f >= 0; f--) {
      final c = _rounded(f);
      if (c == null || !c.isPositive) continue;
      if (c.exact) return c.text;
    }
    return null;
  }

  /// This amount rounded half up to [places] digits after the point.
  BuyBeamAmount? _rounded(int places) {
    final step = BigInt.from(10).pow(decimals - places);
    final r = (raw + step ~/ BigInt.two) ~/ step * step;
    final unit = BigInt.from(10).pow(decimals);
    final whole = r ~/ unit;
    final frac = (r % unit)
        .toString()
        .padLeft(decimals, '0')
        .substring(0, places);
    return fromDecimalText(places == 0 ? '$whole' : '$whole.$frac', decimals);
  }

  @override
  bool operator ==(Object other) =>
      other is BuyBeamAmount && other.raw == raw && other.decimals == decimals;

  @override
  int get hashCode => Object.hash(raw, decimals);

  @override
  String toString() => text;
}

// ---------------------------------------------------------------- answers

/// A coin buybeam.my takes, on one chain.
class BuyBeamAsset {
  const BuyBeamAsset({
    required this.assetId,
    required this.symbol,
    required this.blockchain,
    required this.decimals,
    this.contractAddress,
    this.priceUsd,
  });

  /// Null for an entry this version cannot read.
  static BuyBeamAsset? fromJson(Map<String, dynamic> j) {
    final id = j['asset_id'];
    final symbol = j['symbol'];
    final chain = j['blockchain'];
    final decimals = j['decimals'];
    if (id is! String || id.isEmpty) return null;
    if (symbol is! String || chain is! String || decimals is! num) {
      return null;
    }
    if (decimals < 0 || decimals > 36) return null;
    final contract = j['contract_address'];
    return BuyBeamAsset(
      assetId: id,
      symbol: symbol,
      blockchain: chain,
      decimals: decimals.toInt(),
      contractAddress: contract is String && contract.isNotEmpty
          ? contract
          : null,
      priceUsd: _double(j['price_usd']),
    );
  }

  final String assetId;
  final String symbol;
  final String blockchain;
  final int decimals;

  /// Null for a chain's own coin (BTC, ETH on Ethereum, SOL…).
  final String? contractAddress;
  final double? priceUsd;

  bool get isNative => contractAddress == null;

  /// "Bitcoin", "Tron", "BNB Chain"…
  String get chainName => kChainNames[blockchain] ?? blockchain.toUpperCase();

  /// Addresses on this chain are Ethereum's.
  bool get isEvm => kEvmChains.contains(blockchain);

  Map<String, dynamic> toJson() => {
    'asset_id': assetId,
    'symbol': symbol,
    'blockchain': blockchain,
    'decimals': decimals,
    'contract_address': contractAddress,
    'price_usd': priceUsd,
  };

  @override
  bool operator ==(Object other) =>
      other is BuyBeamAsset && other.assetId == assetId;

  @override
  int get hashCode => assetId.hashCode;
}

/// The coins people bring most, first, as (symbol, chain).
const List<(String, String)> kBuyBeamPopular = [
  ('BTC', 'btc'),
  ('BTC', 'bitcoin'),
  ('ETH', 'eth'),
  ('USDT', 'tron'),
  ('USDT', 'eth'),
  ('USDC', 'sol'),
  ('USDC', 'base'),
  ('SOL', 'sol'),
  ('LTC', 'ltc'),
  ('ZEC', 'zec'),
  ('DOGE', 'doge'),
  ('XRP', 'xrp'),
  ('BNB', 'bsc'),
  ('TRX', 'tron'),
  ('TON', 'ton'),
  ('BCH', 'bch'),
  ('DASH', 'dash'),
  ('ADA', 'cardano'),
];

/// [assets] in picker order: [kBuyBeamPopular] first, then each chain's
/// own coin, then the rest.
List<BuyBeamAsset> sortBuyBeamAssets(Iterable<BuyBeamAsset> assets) =>
    assets.toList()..sort(
      (a, b) => compareByPopularity(
        popular: kBuyBeamPopular,
        a: (a.symbol, a.blockchain, a.chainName, a.isNative),
        b: (b.symbol, b.blockchain, b.chainName, b.isNative),
      ),
    );

/// Whether [a] is one of [kBuyBeamPopular].
bool isPopularBuyBeamAsset(BuyBeamAsset a) =>
    kBuyBeamPopular.any((p) => p.$1 == a.symbol && p.$2 == a.blockchain);

/// The smallest buy, as a hint for the form. `/quote` decides.
class BuyBeamLimits {
  const BuyBeamLimits({this.ourMinimumUsd, this.upstreamObservedMinimumUsd});

  factory BuyBeamLimits.fromJson(Map<String, dynamic> j) => BuyBeamLimits(
    ourMinimumUsd: _double(j['our_minimum_usd']),
    upstreamObservedMinimumUsd: _double(j['upstream_observed_minimum_usd']),
  );

  final double? ourMinimumUsd;

  /// The last smallest buy buybeam.my was held to, if it knows one.
  final double? upstreamObservedMinimumUsd;

  /// What to say up front: the observed figure, else buybeam.my's own.
  double? get hintUsd => upstreamObservedMinimumUsd ?? ourMinimumUsd;
}

/// What an amount buys, right now. Nothing is created.
class BuyBeamQuote {
  const BuyBeamQuote({
    required this.assetId,
    required this.beamEstimate,
    this.beamEstimateRaw,
    this.sendAmountRaw,
    this.orderValueUsd,
    this.etaSeconds,
  });

  final String assetId;

  /// The BEAM that arrives, as buybeam.my says it (nothing to subtract).
  final double beamEstimate;
  final BigInt? beamEstimateRaw;
  final BigInt? sendAmountRaw;
  final double? orderValueUsd;

  /// Usual time from the payment to the BEAM.
  final int? etaSeconds;

  /// [beamEstimate] in groth.
  BigInt get beamGroth =>
      beamEstimateRaw ?? BigInt.from((beamEstimate * 1e8).round());
}

/// buybeam.my's answer to an order, checked against what was asked.
class BuyBeamOrderAnswer {
  const BuyBeamOrderAnswer({
    required this.depositAddress,
    required this.assetId,
    required this.beamWallet,
    required this.payable,
    required this.created,
    this.sendAmountRaw,
    this.beamEstimate,
    this.beamEstimateRaw,
    this.deadline,
    this.etaSeconds,
  });

  /// Where the user pays, and the order's only handle.
  final String depositAddress;
  final String assetId;
  final String beamWallet;
  final bool payable;

  /// False when the same order already existed (a retry): still success.
  final bool created;
  final BigInt? sendAmountRaw;
  final double? beamEstimate;
  final BigInt? beamEstimateRaw;

  /// After this, the address no longer takes payments.
  final DateTime? deadline;
  final int? etaSeconds;
}

/// Where a buy is.
enum BuyBeamState {
  awaitingDeposit('awaiting_deposit'),
  depositDetected('deposit_detected'),
  swapping('swapping'),
  buying('buying'),
  processing('processing'),
  sending('sending'),
  delivered('delivered'),
  refunded('refunded'),
  expired('expired'),
  failed('failed'),

  /// buybeam.my is looking at it by hand.
  attention('attention'),

  /// A state this version does not know: still going, keep asking.
  inProgress('');

  const BuyBeamState(this.wire);

  final String wire;

  static BuyBeamState parse(String? s) {
    for (final v in values) {
      if (v.wire == s && v != inProgress) return v;
    }
    return inProgress;
  }

  bool get isFinal =>
      this == delivered ||
      this == refunded ||
      this == expired ||
      this == failed;
}

class BuyBeamOrderStatus {
  const BuyBeamOrderStatus({
    required this.depositAddress,
    required this.state,
    required this.rawState,
    required this.terminal,
    this.pollAfter,
    this.beamTxId,
    this.beamEstimate,
    this.deadline,
  });

  final String depositAddress;
  final BuyBeamState state;

  /// The state exactly as sent.
  final String rawState;

  /// buybeam.my will not change it again.
  final bool terminal;

  /// When to ask again.
  final Duration? pollAfter;

  /// The BEAM transaction that delivered it.
  final String? beamTxId;
  final double? beamEstimate;
  final DateTime? deadline;
}

// ----------------------------------------------------------------- client

class BuyBeamClient {
  BuyBeamClient({
    required this.clientFactory,
    this.baseUrl = kBuyBeamBaseUrl,
    this.sandbox = false,
    this.timeout = const Duration(seconds: 60),
  });

  /// A new HTTP client per request (`createEthHttpClient` in the app).
  final http.Client Function() clientFactory;
  final String baseUrl;

  /// buybeam.my's test mode: no funds, nothing payable. Sent as a query
  /// parameter on every call (in a JSON body it would be ignored).
  final bool sandbox;

  /// Tor is slow; generous.
  final Duration timeout;

  Future<List<BuyBeamAsset>> assets() async {
    final j = await _send('GET', '/assets');
    final list = j['assets'];
    if (list is! List) throw const BuyBeamError.unexpectedAnswer();
    return [
      for (final a in list)
        if (a is Map)
          if (BuyBeamAsset.fromJson(a.cast<String, dynamic>()) case final x?) x,
    ];
  }

  Future<BuyBeamLimits> limits() async =>
      BuyBeamLimits.fromJson(await _send('GET', '/limits'));

  /// What [amount] of [assetId] buys now; refunds would go to
  /// [refundAddress] (on the coin's chain).
  Future<BuyBeamQuote> quote({
    required String assetId,
    required BuyBeamAmount amount,
    required String refundAddress,
  }) async {
    final j = await _send(
      'GET',
      '/quote',
      query: {
        'asset_id': assetId,
        'amount': amount.value.toString(),
        'refund_address': refundAddress,
      },
    );
    final echoed = j['asset_id'];
    final raw = _bigInt(j['send_amount_raw']);
    final estimate = _double(j['beam_estimate']);
    if ((echoed != null && echoed != assetId) ||
        (raw != null && raw != amount.raw) ||
        estimate == null ||
        estimate < 0) {
      throw const BuyBeamError.unexpectedAnswer();
    }
    return BuyBeamQuote(
      assetId: assetId,
      beamEstimate: estimate,
      beamEstimateRaw: _bigInt(j['beam_estimate_raw']),
      sendAmountRaw: raw,
      orderValueUsd: _double(j['order_value_usd']),
      etaSeconds: _int(j['eta_seconds']),
    );
  }

  /// A deposit address for buying with [amount] of [assetId], the BEAM
  /// going to [beamAddress]. Asking again with the same four values
  /// returns the same order. Refused ([BuyBeamErrorCode.unexpectedAnswer])
  /// unless the answer is exactly this order and can be paid.
  Future<BuyBeamOrderAnswer> order({
    required String assetId,
    required BuyBeamAmount amount,
    required String beamAddress,
    required String refundAddress,
  }) async {
    final j = await _send(
      'POST',
      '/order',
      body: {
        'asset_id': assetId,
        'amount': amount.value,
        'beam_wallet': beamAddress,
        'refund_address': refundAddress,
      },
    );
    final deposit = j['deposit_address'];
    final raw = _bigInt(j['send_amount_raw']);
    final sent = _double(j['send_amount']);
    final payable = j['payable'] == true;
    final sameAmount = raw != null
        ? raw == amount.raw
        // Sandbox orders carry no raw figure: the number must be ours.
        : sandbox && sent == amount.value;
    if (deposit is! String ||
        deposit.trim().isEmpty ||
        j['asset_id'] != assetId ||
        j['beam_wallet'] != beamAddress ||
        !sameAmount ||
        (!sandbox && !payable)) {
      Logging.instance.w('buybeam: order answer refused');
      throw const BuyBeamError.unexpectedAnswer();
    }
    return BuyBeamOrderAnswer(
      depositAddress: deposit,
      assetId: assetId,
      beamWallet: beamAddress,
      payable: payable,
      created: j['created'] != false,
      sendAmountRaw: raw,
      beamEstimate: _double(j['beam_estimate']),
      beamEstimateRaw: _bigInt(j['beam_estimate_raw']),
      deadline: _time(j['deadline']),
      etaSeconds: _int(j['eta_seconds']),
    );
  }

  /// Where the buy paid at [depositAddress] is. [forceState]: sandbox
  /// only, buybeam.my answers with that state (to test every ending).
  Future<BuyBeamOrderStatus> status(
    String depositAddress, {
    String? forceState,
  }) async {
    final id = forceState != null && sandbox
        ? '$depositAddress:$forceState'
        : depositAddress;
    final j = await _send('GET', '/order/${Uri.encodeComponent(id)}');
    if (j['deposit_address'] != depositAddress) {
      throw const BuyBeamError.unexpectedAnswer();
    }
    final raw = j['state'] is String ? j['state'] as String : '';
    final state = BuyBeamState.parse(raw);
    final after = _seconds(j['poll_after_seconds']);
    return BuyBeamOrderStatus(
      depositAddress: depositAddress,
      state: state,
      rawState: raw,
      // Only a state Campfire knows as an ending ends the polling.
      terminal: j['terminal'] == true && state.isFinal,
      pollAfter: after == null || after <= Duration.zero ? null : after,
      beamTxId: j['beam_txid'] is String && (j['beam_txid'] as String) != ''
          ? j['beam_txid'] as String
          : null,
      beamEstimate: _double(j['beam_estimate']),
      deadline: _time(j['deadline']),
    );
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    final base = Uri.parse('$baseUrl$path');
    final params = {...?query, if (sandbox) 'sandbox': 'true'};
    final uri = params.isEmpty ? base : base.replace(queryParameters: params);
    final headers = {
      'user-agent': kBuyBeamUserAgent,
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
    };
    final client = clientFactory();
    final http.Response response;
    try {
      response =
          await (method == 'GET'
                  ? client.get(uri, headers: headers)
                  : client.post(uri, headers: headers, body: jsonEncode(body)))
              .timeout(timeout);
    } catch (e) {
      // TLS, socket, Tor not connected, time out: nothing came back.
      Logging.instance.w('buybeam: network (${e.runtimeType})');
      throw const BuyBeamError.network();
    } finally {
      client.close();
    }
    final status = response.statusCode;
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map) {
      Logging.instance.w('buybeam: blocked (HTTP $status, not JSON)');
      throw BuyBeamError.blocked(httpStatus: status);
    }
    final j = decoded.cast<String, dynamic>();
    if (j['ok'] == true && status < 400) return j;
    final e = j['error'];
    if (j['ok'] == false && e is Map) {
      final err = BuyBeamError.fromJson(
        e.cast<String, dynamic>(),
        httpStatus: status,
        retryAfter:
            _seconds(j['retry_after']) ??
            _seconds(response.headers['retry-after']),
      );
      Logging.instance.w('buybeam: $err');
      throw err;
    }
    Logging.instance.w('buybeam: unexpected envelope (HTTP $status)');
    throw BuyBeamError.unexpectedAnswer(httpStatus: status);
  }
}

// ---------------------------------------------------------------- reading

double? _double(Object? v) {
  if (v is num) return v.isFinite ? v.toDouble() : null;
  if (v is String) return double.tryParse(v);
  return null;
}

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num && v.isFinite) return v.round();
  if (v is String) return int.tryParse(v);
  return null;
}

BigInt? _bigInt(Object? v) {
  if (v is int) return BigInt.from(v);
  if (v is String && RegExp(r'^[0-9]+$').hasMatch(v)) return BigInt.parse(v);
  return null;
}

Duration? _seconds(Object? v) {
  final d = _double(v);
  if (d == null || d < 0) return null;
  return Duration(milliseconds: (d * 1000).round());
}

DateTime? _time(Object? v) {
  if (v is num && v > 0) {
    return DateTime.fromMillisecondsSinceEpoch((v * 1000).round(), isUtc: true);
  }
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v)?.toUtc();
  return null;
}
