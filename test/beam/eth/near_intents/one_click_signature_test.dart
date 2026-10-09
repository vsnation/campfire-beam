/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// 1Click's quote signatures, on two real answers (2026-10-09, to a
// throwaway recipient): a price-only BTC quote and a ZEC quote with a
// deposit address. A deposit address 1Click did not sign must never be
// shown, so any change to a signed field must fail the check.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/near_intents/one_click_client.dart';

Map<String, dynamic> _fixture(String name) => (jsonDecode(
  File('test/beam/eth/near_intents/fixtures/$name').readAsStringSync(),
) as Map).cast<String, dynamic>();

Map<String, dynamic> _copy(Map<String, dynamic> m) =>
    (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

void main() {
  test('a real price-only quote verifies', () {
    expect(verifyOneClickQuote(_fixture('quote_dry_btc.json')), isTrue);
  });

  test('a real quote with a deposit address verifies', () {
    final q = _fixture('quote_zec.json');
    expect(OneClickQuote(q).depositAddress, startsWith('t1'));
    expect(verifyOneClickQuote(q), isTrue);
  });

  test('a changed deposit address, amount or recipient fails', () {
    final base = _fixture('quote_zec.json');
    final cases = <void Function(Map<String, dynamic>)>[
      (m) => (m['quote'] as Map)['depositAddress'] =
          't1RCMXfRc2EvLc6yoPbddg5YVJb2L5SWdxq',
      (m) => (m['quote'] as Map)['amountOut'] = '1',
      (m) => (m['quote'] as Map)['minAmountOut'] = '1',
      (m) => (m['quoteRequest'] as Map)['recipient'] =
          '0x1111111111111111111111111111111111111111',
      (m) => (m['quoteRequest'] as Map)['refundTo'] = 't1aaaa',
      (m) => m['timestamp'] = '2026-10-09T00:00:00.000Z',
      (m) => m['signature'] = 'ed25519:1111',
    ];
    for (final change in cases) {
      final m = _copy(base);
      change(m);
      expect(verifyOneClickQuote(m), isFalse);
    }
  });

  test('another key does not verify 1Click quotes', () {
    expect(
      verifyOneClickQuote(
        _fixture('quote_dry_btc.json'),
        managerKey: 'ed25519:4g54YR6MS9nHvDYR37N4xoUuu7N2ubPDA789sN18PYY3',
      ),
      isFalse,
    );
  });

  test('stable JSON sorts keys at every level, like json-stable-stringify', () {
    expect(
      stableJson({
        'b': 1,
        'a': [
          {'y': true, 'x': 'é'},
        ],
        'c': null,
      }),
      '{"a":[{"x":"é","y":true}],"b":1,"c":null}',
    );
  });

  test('the picker puts BTC, ZEC and LTC first', () {
    final t = sortOneClickTokens([
      const OneClickToken(
        assetId: 'a',
        symbol: 'AAVE',
        blockchain: 'eth',
        decimals: 18,
        contractAddress: '0x1',
      ),
      const OneClickToken(
        assetId: 'l',
        symbol: 'LTC',
        blockchain: 'ltc',
        decimals: 8,
      ),
      const OneClickToken(
        assetId: 'z',
        symbol: 'ZEC',
        blockchain: 'zec',
        decimals: 8,
      ),
      const OneClickToken(
        assetId: 'b',
        symbol: 'BTC',
        blockchain: 'btc',
        decimals: 8,
      ),
      const OneClickToken(
        assetId: 'k',
        symbol: 'KAIA',
        blockchain: 'kaia',
        decimals: 18,
      ),
    ]);
    expect(t.map((e) => e.symbol), ['BTC', 'ZEC', 'LTC', 'KAIA', 'AAVE']);
  });
}
