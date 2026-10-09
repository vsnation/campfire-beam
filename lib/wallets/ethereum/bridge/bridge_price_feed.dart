/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// USD prices for the bridge's fee, from the source its relayer prices
// with: CoinGecko's `simple/price` (beam-bridge-ethrelay, utils/eth_fee.js).
// A fee priced anywhere else is a different number from the one the
// relayer checks.
//
// The request goes out through Campfire's Ethereum HTTP client: through
// Tor when Tor is on, and not at all while Tor is on but not connected
// (`createEthHttpClient`). One request asks for every bridged asset at
// once and is kept for two minutes, so moving between screens does not
// spend CoinGecko's small free allowance.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../bridge/bridge_fees.dart';
import '../../bridge/bridge_routes.dart';
import '../../bridge/bridge_sides.dart';

class BridgePriceFeed {
  BridgePriceFeed({
    required this.clientFactory,
    this.baseUrl = 'https://api.coingecko.com/api/v3',
    this.maxAge = const Duration(minutes: 2),
    this.timeout = const Duration(seconds: 30),
    this.lookupsAllowed,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// A new HTTP client per request (`createEthHttpClient` in the app).
  final http.Client Function() clientFactory;
  final String baseUrl;

  /// How long one answer is used.
  final Duration maxAge;
  final Duration timeout;

  /// The user's "price lookups" switch, when the app has one: off means
  /// nothing is asked, and there is no fee to quote.
  final bool Function()? lookupsAllowed;

  final DateTime Function() _clock;

  Map<String, double> _usd = const {};
  DateTime? _at;
  Future<void>? _loading;

  /// Every id the bridge prices: ETH for gas, and each route's asset.
  static final Set<String> bridgeIds = {
    'ethereum',
    for (final r in kBridgeRoutes) r.coingeckoId,
  };

  /// USD prices of [ids] (and of every bridged asset), at most [maxAge]
  /// old. Throws [BridgeException] (noPrice) when any of [ids] has no
  /// positive price: a fee is never quoted from a guess.
  Future<BridgePrices> usd(List<String> ids) async {
    for (final id in ids) {
      if (!RegExp(r'^[a-z0-9-]{1,64}$').hasMatch(id)) {
        throw ArgumentError('not a CoinGecko id: $id');
      }
    }
    if (lookupsAllowed?.call() == false) {
      throw const BridgeException(
        BridgeErrorCode.noPrice,
        'Price lookups are off in Settings, so the bridge fee cannot be '
        'worked out.',
      );
    }
    if (!_fresh(ids)) {
      await (_loading ??= _load({...bridgeIds, ...ids}).whenComplete(() {
        _loading = null;
      }));
      // Another request was already loading without [ids]: ask again.
      if (!_fresh(ids)) await _load({...bridgeIds, ..._usd.keys, ...ids});
    }
    final prices = BridgePrices(Map.unmodifiable(_usd), _at!);
    for (final id in ids) {
      if (prices.of(id) == null) {
        throw BridgeException(
          BridgeErrorCode.noPrice,
          'CoinGecko gave no price for $id, so the bridge fee cannot be '
          'worked out.',
        );
      }
    }
    return prices;
  }

  bool _fresh(List<String> ids) {
    final at = _at;
    return at != null &&
        _clock().difference(at) < maxAge &&
        ids.every(_usd.containsKey);
  }

  Future<void> _load(Set<String> ids) async {
    final uri = Uri.parse('$baseUrl/simple/price').replace(
      queryParameters: {
        'ids': (ids.toList()..sort()).join(','),
        'vs_currencies': 'usd',
      },
    );
    final client = clientFactory();
    final http.Response response;
    try {
      response = await client
          .get(uri, headers: const {'accept': 'application/json'})
          .timeout(timeout);
    } catch (e) {
      throw BridgeException(
        BridgeErrorCode.noPrice,
        'Prices could not be read ($e).',
      );
    } finally {
      client.close();
    }
    if (response.statusCode == 429) {
      throw const BridgeException(
        BridgeErrorCode.noPrice,
        'CoinGecko is busy (too many requests); try again in a minute.',
      );
    }
    if (response.statusCode != 200) {
      throw BridgeException(
        BridgeErrorCode.noPrice,
        'CoinGecko answered HTTP ${response.statusCode}.',
      );
    }
    final usd = <String, double>{};
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in body.entries) {
        final v = value is Map ? value['usd'] : null;
        if (v is num && v.isFinite && v > 0) usd[key] = v.toDouble();
      }
    } catch (_) {
      throw const BridgeException(
        BridgeErrorCode.noPrice,
        'CoinGecko did not answer with prices.',
      );
    }
    _usd = usd;
    _at = _clock();
  }
}
