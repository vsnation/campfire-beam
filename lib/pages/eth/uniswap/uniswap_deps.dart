/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Uniswap screens need from the app, in one object, so the
// screens can be tested with fakes: the swap service over the wallet's
// RPC, the wallet's signer, its tokens and balances, prices, and
// Campfire's PIN / password gate.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../utilities/util.dart';
import '../../../wallets/ethereum/uniswap/uniswap_constants.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';

typedef UniAuthGate = Future<bool?> Function(
  BuildContext context, {
  required String reason,
});

/// WBEAM on Ethereum (wrapped BEAM; 8 decimals, checked on chain).
const kWbeamToken = UniToken(
  address: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
  symbol: 'WBEAM',
  decimals: 8,
  name: 'Wrapped BEAM',
);

/// Tokens Campfire vouches for by address (anything else found on Uniswap
/// is shown with a warning: anyone can make a token called "USDT").
const kUniVerifiedTokens = <UniToken>[
  UniToken.eth,
  kWbeamToken,
  UniToken(
    address: '0xdac17f958d2ee523a2206206994597c13d831ec7',
    symbol: 'USDT',
    decimals: 6,
    name: 'Tether',
  ),
  UniToken(
    address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
    symbol: 'USDC',
    decimals: 6,
    name: 'USD Coin',
  ),
  UniToken(
    address: '0x6b175474e89094c44da98b954eedeac495271d0f',
    symbol: 'DAI',
    decimals: 18,
    name: 'Dai',
  ),
  UniToken(
    address: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
    symbol: 'WBTC',
    decimals: 8,
    name: 'Wrapped BTC',
  ),
  UniToken(
    address: UniswapAddresses.weth,
    symbol: 'WETH',
    decimals: 18,
    name: 'Wrapped Ether',
  ),
];

/// Signs with an [EthereumWallet]'s own key, inside the wallet.
class EthWalletSwapSigner implements UniSwapSigner {
  EthWalletSwapSigner(this.wallet, this.address);

  final EthereumWallet wallet;

  @override
  final String address;

  @override
  Future<Uint8List> signDigest(Uint8List digest) => wallet.signDigest(digest);

  @override
  Future<String> send(UniTxRequest tx) => wallet.sendContractCall(
    to: tx.to,
    data: tx.data,
    value: tx.value,
    gasLimit: tx.gasLimit,
    maxFeePerGas: tx.fees.maxFeePerGas,
    maxPriorityFeePerGas: tx.fees.maxPriorityFeePerGas,
    note: tx.note,
  );
}

class UniswapDeps implements DexLayout {
  UniswapDeps({
    required this.service,
    required this.signer,
    required this.walletTokens,
    required this.authenticate,
    required this.explorerTx,
    this.fiatPerToken,
    this.fiatCurrency = 'USD',
    this.onTokenAdded,
    this.isDesktop,
  });

  final UniswapService service;
  final UniSwapSigner signer;

  /// The ERC-20 tokens the wallet shows (its token list), besides ETH.
  final List<UniToken> Function() walletTokens;

  /// Fiat value of one whole [UniToken] (ETH from the price feed, WBEAM as
  /// BEAM); null when there is none.
  final double? Function(UniToken token)? fiatPerToken;
  final String fiatCurrency;

  final UniAuthGate authenticate;

  /// Etherscan (or the user's explorer) for a transaction.
  final Uri Function(String hash) explorerTx;

  /// Adds a token found on Uniswap to the wallet's token list.
  final Future<void> Function(UniToken token)? onTokenAdded;

  final bool? isDesktop;

  @override
  bool get desktop => isDesktop ?? Util.isDesktop;

  /// Ticks when balances change.
  final ValueNotifier<int> changes = ValueNotifier(0);

  final Map<String, BigInt> _balances = {};
  final Map<String, UniToken> _known = {
    for (final t in kUniVerifiedTokens) t.address: t,
  };

  /// ETH, then the wallet's tokens, then other verified ones.
  List<UniToken> get myTokens {
    final seen = <String>{};
    return [
      for (final t in [UniToken.eth, ...walletTokens(), ...kUniVerifiedTokens])
        if (seen.add(t.address)) t,
    ];
  }

  bool isVerified(UniToken t) =>
      kUniVerifiedTokens.any((v) => v.address == t.address) ||
      walletTokens().any((w) => w.address == t.address);

  /// A verified token whose symbol [t] copies (a fake "USDT"), if any.
  UniToken? impersonates(UniToken t) {
    if (isVerified(t)) return null;
    final s = t.symbol.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    for (final v in kUniVerifiedTokens) {
      if (v.symbol.toUpperCase() == s) return v;
    }
    return null;
  }

  UniToken? token(String address) => _known[address];

  void remember(UniToken t) => _known[t.address] = t;

  BigInt balance(UniToken t) => _balances[t.address] ?? BigInt.zero;

  bool hasBalance(UniToken t) => _balances.containsKey(t.address);

  /// Reads the balances of [tokens] from the RPC.
  Future<void> refreshBalances(Iterable<UniToken> tokens) async {
    final list = tokens.toSet().toList();
    final values = await Future.wait([
      for (final t in list)
        service
            .balanceOf(t, signer.address)
            .then<BigInt?>((v) => v, onError: (Object _) => null),
    ]);
    var changed = false;
    for (var i = 0; i < list.length; i++) {
      final v = values[i];
      if (v == null) continue;
      if (_balances[list[i].address] != v) changed = true;
      _balances[list[i].address] = v;
    }
    if (changed) changes.value++;
  }

  /// "≈ 25.40 USD" for [amount] of [t], or null when there is no price.
  String? worth(UniToken t, BigInt amount) {
    final per = fiatPerToken?.call(t);
    if (per == null) return null;
    final whole =
        amount.toDouble() / BigInt.from(10).pow(t.decimals).toDouble();
    final v = whole * per;
    return '≈ ${v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(2)} '
        '$fiatCurrency';
  }

  void dispose() => changes.dispose();
}
