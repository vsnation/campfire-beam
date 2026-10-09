/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// WBEAM (BEAM on Ethereum) is a default token, offered first, priced as
// BEAM; and the build lists BEAM and Ethereum together.

import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/models/isar/models/ethereum/eth_contract.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/utilities/default_eth_tokens.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/ethereum/eth_token_order.dart';
import 'package:stackwallet/wallets/ethereum/wbeam.dart';

EthContract _token(String address, String name) => EthContract(
  address: address,
  name: name,
  symbol: name,
  decimals: 18,
  type: EthContractType.erc20,
);

void main() {
  test('the build: BEAM and Ethereum; WBEAM, USDT, USDC offered', () {
    expect(AppConfig.coins, [
      Beam(CryptoCurrencyNetwork.main),
      Ethereum(CryptoCurrencyNetwork.main),
    ]);
    expect(AppConfig.isSingleCoinApp, isFalse);
    expect(AppConfig.defaultEthTokens.map((t) => t.symbol), [
      'WBEAM',
      'USDT',
      'USDC',
    ]);
  });

  test('WBEAM is the bridge token checked on chain', () {
    final w = DefaultTokens.wbeam;
    expect(w.address, '0xe5acbb03d73267c03349c76ead672ee4d941f499');
    expect(w.address, w.address.toLowerCase(), reason: 'like the others');
    expect(w.name, 'Wrapped BEAM');
    expect(w.symbol, 'WBEAM');
    expect(w.decimals, 8, reason: 'like BEAM: 1 WBEAM = 1 BEAM');
    expect(w.type, EthContractType.erc20);
    expect(isWbeam('0xE5ACBB03D73267C03349C76EAD672EE4D941F499'), isTrue);
    expect(isWbeam(DefaultTokens.usdt.address), isFalse);
    expect(isWbeam(null), isFalse);
  });

  test('WBEAM is worth what BEAM is worth; no BEAM price, no WBEAM price', () {
    final beam = (value: Decimal.parse('0.0287'), change24h: -1.5);
    final eth = (value: Decimal.parse('2500'), change24h: 0.3);
    final coins = {
      Beam(CryptoCurrencyNetwork.main): beam,
      Ethereum(CryptoCurrencyNetwork.main): eth,
    };
    final tokens = [
      DefaultTokens.usdt.address,
      '0xE5ACBB03D73267C03349C76EAD672EE4D941F499',
    ];
    expect(pricesFromCoins(coins, tokens), {DefaultTokens.wbeam.address: beam});
    expect(pricesFromCoins(coins, [DefaultTokens.usdt.address]), isEmpty);
    expect(
      pricesFromCoins({Ethereum(CryptoCurrencyNetwork.main): eth}, tokens),
      isEmpty,
    );
  });

  test(
    'the token lists start with the defaults in their order, WBEAM first',
    () {
      final byName = [
        _token('0xaaa', 'Aave'),
        DefaultTokens.usdt,
        DefaultTokens.usdc,
        DefaultTokens.wbeam,
        _token('0xbbb', 'Zebra'),
      ]..sort((a, b) => a.name.compareTo(b.name));
      expect(defaultEthTokensFirst(byName).map((t) => t.symbol), [
        'WBEAM',
        'USDT',
        'USDC',
        'Aave',
        'Zebra',
      ]);
    },
  );

  test('a BEAM build with a second coin still announces wallet changes '
      '(the desktop BEAM menu lists wallets from it)', () {
    expect(AppConfig.isSingleCoinApp, isFalse);
    expect(Wallets.firesWalletsChanged, isTrue);
  });
}
