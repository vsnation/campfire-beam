/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// NEAR Intents' 1Click Swap API: any coin on any chain it supports into ETH
// on Ethereum, delivered to the Campfire wallet's own address.
//
// https://1click.chaindefuser.com (OpenAPI: /docs/v0/openapi.yaml, read
// 2026-10-09):
//   GET  /v0/tokens                  the coins and chains it supports
//   POST /v0/quote  (dry: true)      a price, no deposit address
//   POST /v0/quote  (dry: false)     a price and a deposit address
//   GET  /v0/status?depositAddress=  where a swap is
//
// Every quote is signed by 1Click (ed25519, key in [kOneClickManagerKey],
// the one its TypeScript SDK 0.1.26 verifies with). Campfire checks the
// signature before it shows a deposit address, so an address that 1Click
// did not issue is never shown, whatever happens between the app and the
// API. Requests go through Campfire's Ethereum HTTP client: through Tor
// when Tor is on.
//
// Without a partner key 1Click adds 0.25% to each quote (its "Fees" page);
// the quote's amounts already include it.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dart_bs58/dart_bs58.dart';
import 'package:http/http.dart' as http;
import 'package:pinenacl/ed25519.dart' as nacl;

import '../../../utilities/coin_chains.dart';

const kOneClickBaseUrl = 'https://1click.chaindefuser.com';

/// 1Click's quote-signing key ("ONE_CLICK_MANAGER_PUB_KEY").
const kOneClickManagerKey =
    'ed25519:reYaWhvwu8Jzo3WUM3zhn6VrhuMEF4eADL17qtRVifc';

/// ETH on Ethereum, as 1Click names it.
const kOneClickEthOnEthereum = 'nep141:eth.omft.near';

class OneClickError implements Exception {
  OneClickError(this.message, {this.status});

  /// 1Click's own words when it gave any ("Amount is too low…").
  final String message;
  final int? status;

  @override
  String toString() => 'OneClickError($status): $message';
}

/// A coin on a chain that 1Click swaps.
class OneClickToken {
  const OneClickToken({
    required this.assetId,
    required this.symbol,
    required this.blockchain,
    required this.decimals,
    this.priceUsd,
    this.contractAddress,
  });

  factory OneClickToken.fromJson(Map<String, dynamic> j) => OneClickToken(
    assetId: j['assetId'] as String,
    symbol: j['symbol'] as String,
    blockchain: j['blockchain'] as String,
    decimals: (j['decimals'] as num).toInt(),
    priceUsd: (j['price'] as num?)?.toDouble(),
    contractAddress: j['contractAddress'] as String?,
  );

  final String assetId;
  final String symbol;
  final String blockchain;
  final int decimals;
  final double? priceUsd;

  /// Null for a chain's own coin (BTC, ZEC, SOL…).
  final String? contractAddress;

  bool get isNative => contractAddress == null;

  /// "Bitcoin", "Tron", "BNB Chain"… for a chain id.
  String get chainName => kOneClickChainNames[blockchain] ?? blockchain;

  Map<String, dynamic> toJson() => {
    'assetId': assetId,
    'symbol': symbol,
    'blockchain': blockchain,
    'decimals': decimals,
    if (priceUsd != null) 'price': priceUsd,
    if (contractAddress != null) 'contractAddress': contractAddress,
  };

  @override
  bool operator ==(Object other) =>
      other is OneClickToken && other.assetId == assetId;

  @override
  int get hashCode => assetId.hashCode;
}

/// Chain names people know (shared with every other coin list).
const Map<String, String> kOneClickChainNames = kChainNames;

/// The coins people bring most, first (BTC, ZEC, LTC and the other main
/// coins by traffic), as (symbol, chain).
const List<(String, String)> kOneClickPopular = [
  ('BTC', 'btc'),
  ('ZEC', 'zec'),
  ('LTC', 'ltc'),
  ('USDT', 'tron'),
  ('USDT', 'eth'),
  ('USDC', 'sol'),
  ('USDC', 'base'),
  ('SOL', 'sol'),
  ('XRP', 'xrp'),
  ('DOGE', 'doge'),
  ('BNB', 'bsc'),
  ('USDT', 'bsc'),
  ('TRX', 'tron'),
  ('TON', 'ton'),
  ('BCH', 'bch'),
  ('DASH', 'dash'),
  ('ADA', 'cardano'),
  ('SUI', 'sui'),
  ('AVAX', 'avax'),
  ('POL', 'pol'),
  ('wNEAR', 'near'),
  ('ETH', 'arb'),
  ('ETH', 'base'),
  ('ETH', 'op'),
];

/// [tokens] in the order the picker shows them: [kOneClickPopular] first,
/// then each chain's own coin, then everything else, by chain and symbol.
List<OneClickToken> sortOneClickTokens(Iterable<OneClickToken> tokens) =>
    tokens.toList()..sort(
      (a, b) => compareByPopularity(
        popular: kOneClickPopular,
        a: (a.symbol, a.blockchain, a.chainName, a.isNative),
        b: (b.symbol, b.blockchain, b.chainName, b.isNative),
      ),
    );

/// What 1Click quoted, with everything it signed.
class OneClickQuote {
  OneClickQuote(this.raw);

  /// The whole response, kept as it came (1Click asks integrators to keep
  /// the quote and its signature to resolve any dispute).
  final Map<String, dynamic> raw;

  Map<String, dynamic> get _q => raw['quote'] as Map<String, dynamic>;
  Map<String, dynamic> get request =>
      raw['quoteRequest'] as Map<String, dynamic>;

  bool get dry => request['dry'] == true;
  String get originAsset => request['originAsset'] as String;
  String get refundTo => request['refundTo'] as String;
  String get recipient => request['recipient'] as String;

  BigInt get amountIn => BigInt.parse(_q['amountIn'] as String);
  BigInt get amountOut => BigInt.parse(_q['amountOut'] as String);
  BigInt get minAmountOut => BigInt.parse(_q['minAmountOut'] as String);
  String? get amountInUsd => _q['amountInUsd'] as String?;
  String? get amountOutUsd => _q['amountOutUsd'] as String?;

  /// Seconds from the deposit being confirmed to the coins arriving.
  int? get timeEstimate => (_q['timeEstimate'] as num?)?.toInt();

  String? get depositAddress => _q['depositAddress'] as String?;

  /// Some chains need this memo with the deposit, or the coins are lost.
  String? get depositMemo => _q['depositMemo'] as String?;

  /// After this, the deposit address no longer works.
  DateTime? get deadline =>
      _q['deadline'] == null ? null : DateTime.parse(_q['deadline'] as String);

  String get signature => raw['signature'] as String;
  String get timestamp => raw['timestamp'] as String;
}

/// Where a swap is.
enum OneClickState {
  pendingDeposit('PENDING_DEPOSIT'),
  knownDepositTx('KNOWN_DEPOSIT_TX'),
  processing('PROCESSING'),
  success('SUCCESS'),
  incompleteDeposit('INCOMPLETE_DEPOSIT'),
  refunded('REFUNDED'),
  failed('FAILED');

  const OneClickState(this.wire);
  final String wire;

  bool get isFinal => this == success || this == refunded || this == failed;

  static OneClickState? parse(String s) =>
      values.where((v) => v.wire == s).firstOrNull;
}

class OneClickStatus {
  const OneClickStatus(this.state, this.raw);

  final OneClickState state;
  final Map<String, dynamic> raw;

  Map<String, dynamic>? get _details =>
      raw['swapDetails'] as Map<String, dynamic>?;

  /// What arrived (smallest unit), once it did.
  BigInt? get amountOut {
    final v = _details?['amountOut'];
    return v is String && v.isNotEmpty ? BigInt.tryParse(v) : null;
  }

  BigInt? get refunded {
    final v = _details?['refundedAmount'];
    return v is String && v.isNotEmpty ? BigInt.tryParse(v) : null;
  }

  String? get refundReason => _details?['refundReason'] as String?;

  /// Transactions that delivered the coins on Ethereum.
  List<String> get destinationTxs => [
    for (final t
        in (_details?['destinationChainTxHashes'] as List?) ?? const [])
      if (t is Map && t['hash'] is String) t['hash'] as String,
  ];
}

class OneClickClient {
  OneClickClient({
    required this.clientFactory,
    this.baseUrl = kOneClickBaseUrl,
    this.apiKey,
    this.timeout = const Duration(seconds: 45),
  });

  final http.Client Function() clientFactory;
  final String baseUrl;

  /// A partner JWT, if the owner has one (lower fees); none by default.
  final String? apiKey;
  final Duration timeout;

  Future<List<OneClickToken>> tokens() async {
    final body = await _send('GET', '/v0/tokens');
    return [
      for (final t in (body as List).cast<Map<String, dynamic>>())
        OneClickToken.fromJson(t),
    ];
  }

  /// A quote for swapping exactly [amountIn] of [origin] into ETH on
  /// Ethereum for [recipient] (the wallet's address); refunds go to
  /// [refundTo] on [origin]'s chain. [dry]: a price only. Otherwise the
  /// answer carries a deposit address, and it is refused unless 1Click's
  /// signature over it checks out.
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
    final deadline = (now ?? DateTime.now().toUtc()).add(depositWindow);
    final body = await _send('POST', '/v0/quote', {
      'dry': dry,
      'swapType': 'EXACT_INPUT',
      'slippageTolerance': slippageBips,
      'originAsset': origin.assetId,
      'depositType': 'ORIGIN_CHAIN',
      'destinationAsset': destinationAsset,
      'amount': amountIn.toString(),
      'refundTo': refundTo,
      'refundType': 'ORIGIN_CHAIN',
      'recipient': recipient,
      'recipientType': 'DESTINATION_CHAIN',
      'deadline': deadline.toUtc().toIso8601String(),
    });
    final q = OneClickQuote((body as Map).cast<String, dynamic>());
    if (!verifyOneClickQuote(q.raw)) {
      throw OneClickError(
        'The quote is not signed by NEAR Intents. Nothing to send to.',
      );
    }
    // What was asked for is what was quoted (the signature covers both).
    if (q.recipient.toLowerCase() != recipient.toLowerCase() ||
        q.refundTo != refundTo ||
        q.amountIn != amountIn) {
      throw OneClickError('The quote does not match what was asked for.');
    }
    if (!dry && (q.depositAddress == null || q.depositAddress!.isEmpty)) {
      throw OneClickError('NEAR Intents gave no deposit address.');
    }
    return q;
  }

  Future<OneClickStatus> status(String depositAddress, {String? memo}) async {
    final query =
        'depositAddress=${Uri.encodeQueryComponent(depositAddress)}'
        '${memo == null ? '' : '&depositMemo=${Uri.encodeQueryComponent(memo)}'}';
    final body = await _send('GET', '/v0/status?$query');
    final m = (body as Map).cast<String, dynamic>();
    final state = OneClickState.parse(m['status'] as String? ?? '');
    if (state == null) throw OneClickError('Unknown status ${m['status']}');
    return OneClickStatus(state, m);
  }

  Future<Object?> _send(String method, String path, [Object? json]) async {
    final client = clientFactory();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final headers = {
        'accept': 'application/json',
        if (json != null) 'content-type': 'application/json',
        if (apiKey != null) 'x-api-key': apiKey!,
      };
      final response =
          await (method == 'GET'
                  ? client.get(uri, headers: headers)
                  : client.post(uri, headers: headers, body: jsonEncode(json)))
              .timeout(timeout);
      Object? body;
      try {
        body = jsonDecode(response.body);
      } on FormatException {
        body = null;
      }
      if (response.statusCode >= 400) {
        final msg = body is Map ? body['message'] : null;
        throw OneClickError(
          msg is String && msg.isNotEmpty
              ? msg
              : 'NEAR Intents answered HTTP ${response.statusCode}',
          status: response.statusCode,
        );
      }
      if (body == null) throw OneClickError('NEAR Intents sent no JSON');
      return body;
    } finally {
      client.close();
    }
  }
}

// ------------------------------------------------------------- signature

/// Checks 1Click's signature on a quote response, as its SDK does
/// (`verifyQuoteSignature`, 0.1.26): ed25519 over the base58 of SHA-256 of
/// the stable JSON of the signed request fields, the signed quote fields
/// and the timestamp.
bool verifyOneClickQuote(
  Map<String, dynamic> response, {
  String managerKey = kOneClickManagerKey,
}) {
  try {
    final message = utf8.encode(oneClickQuoteHash(response));
    final sig = _ed25519(response['signature'] as String);
    final key = _ed25519(managerKey);
    return nacl.VerifyKey(key).verify(
      signature: nacl.Signature(sig),
      message: Uint8List.fromList(message),
    );
  } catch (_) {
    return false;
  }
}

/// The message 1Click signs for [response].
String oneClickQuoteHash(Map<String, dynamic> response) {
  final r = (response['quoteRequest'] as Map).cast<String, dynamic>();
  final q = (response['quote'] as Map).cast<String, dynamic>();
  bool truthy(Object? v) =>
      v != null && v != false && v != 0 && v != '' && v != 0.0;
  final signed = <String, Object?>{
    for (final k in [
      'dry',
      'swapType',
      'slippageTolerance',
      'originAsset',
      'depositType',
      'destinationAsset',
      'amount',
      'refundTo',
      'refundType',
      'recipient',
      'recipientType',
      'deadline',
    ])
      if (r.containsKey(k) && r[k] != null) k: r[k],
    for (final k in [
      'quoteWaitingTimeMs',
      'referral',
      'virtualChainRecipient',
      'virtualChainRefundRecipient',
      'customRecipientMsg',
    ])
      if (truthy(r[k])) k: r[k],
    for (final k in [
      'amountIn',
      'amountInFormatted',
      'amountInUsd',
      'minAmountIn',
      'amountOut',
      'amountOutFormatted',
      'amountOutUsd',
      'minAmountOut',
    ])
      if (q.containsKey(k) && q[k] != null) k: q[k],
    if (r['dry'] != true)
      for (final k in [
        'depositAddress',
        'depositMemo',
        'deadline',
        'timeWhenInactive',
        'timeEstimate',
        'refundFee',
        'withdrawFee',
      ])
        if (truthy(q[k])) k: q[k],
    'timestamp': response['timestamp'],
  };
  final digest = crypto.sha256.convert(utf8.encode(stableJson(signed)));
  return bs58.encode(Uint8List.fromList(digest.bytes));
}

/// JSON with every object's keys sorted, no spaces (json-stable-stringify).
String stableJson(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${[for (final k in keys) '${jsonEncode(k)}:${stableJson(v[k])}'].join(',')}}';
  }
  if (v is List) return '[${v.map(stableJson).join(',')}]';
  return jsonEncode(v);
}

Uint8List _ed25519(String s) =>
    bs58.decode(s.startsWith('ed25519:') ? s.substring(8) : s);
