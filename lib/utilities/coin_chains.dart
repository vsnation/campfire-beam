/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Coins from other chains, as the screens that list them show them: the
// chain ids cross-chain services use ("btc", "tron", "bsc"…) with the
// names people know, and one order for a coin picker (the coins people
// bring most first, then each chain's own coin, then the rest).

/// Chain names people know, by the chain id the services use.
const Map<String, String> kChainNames = {
  'btc': 'Bitcoin',
  'bitcoin': 'Bitcoin',
  'zec': 'Zcash',
  'ltc': 'Litecoin',
  'eth': 'Ethereum',
  'sol': 'Solana',
  'tron': 'Tron',
  'bsc': 'BNB Chain',
  'xrp': 'XRP Ledger',
  'doge': 'Dogecoin',
  'ton': 'TON',
  'bch': 'Bitcoin Cash',
  'dash': 'Dash',
  'cardano': 'Cardano',
  'sui': 'Sui',
  'avax': 'Avalanche',
  'pol': 'Polygon',
  'near': 'NEAR',
  'arb': 'Arbitrum',
  'base': 'Base',
  'op': 'Optimism',
  'gnosis': 'Gnosis',
  'stellar': 'Stellar',
  'aptos': 'Aptos',
  'bera': 'Berachain',
  'starknet': 'Starknet',
  'scroll': 'Scroll',
  'monad': 'Monad',
  'xlayer': 'X Layer',
  'movement': 'Movement',
  'plasma': 'Plasma',
  'aleo': 'Aleo',
  'hypercore': 'Hyperliquid',
  'abs': 'Abstract',
  'fogo': 'Fogo',
};

/// Chains whose addresses are Ethereum's (`0x` and 40 hex digits).
const Set<String> kEvmChains = {
  'eth',
  'arb',
  'base',
  'op',
  'bsc',
  'pol',
  'avax',
  'gnosis',
  'scroll',
  'bera',
  'monad',
  'xlayer',
  'plasma',
  'abs',
};

/// [compare] in picker order: the [popular] (symbol, chain) pairs first,
/// in their order; then each chain's own coin; then everything else; ties
/// by chain name, then symbol.
int compareByPopularity({
  required List<(String, String)> popular,
  required (String symbol, String chain, String chainName, bool native) a,
  required (String symbol, String chain, String chainName, bool native) b,
}) {
  int rank((String, String, String, bool) t) {
    final i = popular.indexWhere((p) => p.$1 == t.$1 && p.$2 == t.$2);
    if (i >= 0) return i;
    return popular.length + (t.$4 ? 0 : 1000);
  }

  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  final c = a.$3.compareTo(b.$3);
  return c != 0 ? c : a.$1.compareTo(b.$1);
}
