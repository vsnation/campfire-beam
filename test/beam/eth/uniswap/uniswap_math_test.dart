/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Pool prices and v2's formula against what mainnet said on 2026-10-09:
// the ETH/WBEAM v4 pool's sqrtPriceX96 and the WETH/WBEAM v2 pair's
// reserves with its router's getAmountsOut.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_discovery.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_quoter.dart';

void main() {
  test('a v4 price from sqrtPriceX96 (2^96 must not overflow)', () {
    final s = UniPoolState(
      sqrtPriceX96: BigInt.parse('452332567505986722683818525'),
      liquidity: BigInt.one,
    );
    // Raw WBEAM per wei: (sqrtP / 2^96)^2 = 3.2595e-5, i.e. ~325,950 WBEAM
    // per ETH after the 18 → 8 decimals.
    expect(s.price0to1, closeTo(3.2595e-5, 1e-8));
    expect(s.price0to1!.isFinite, isTrue);
  });

  test('a v2 price from reserves', () {
    final s = UniPoolState(
      reserve0: BigInt.parse('403461114461472693'),
      reserve1: BigInt.parse('13022386628314'),
    );
    expect(s.price0to1, closeTo(13022386628314 / 403461114461472693, 1e-12));
    expect(s.isLive, isTrue);
  });

  test("v2's getAmountOut, as the router answered", () {
    // V2 router getAmountsOut(0.01 ETH, [WETH, WBEAM]) = 314038276614.
    expect(
      v2AmountOut(
        BigInt.from(10).pow(16),
        BigInt.parse('403461114461472693'),
        BigInt.parse('13022386628314'),
      ),
      BigInt.parse('314038276614'),
    );
    expect(v2AmountOut(BigInt.zero, BigInt.one, BigInt.one), BigInt.zero);
  });

  test('depth is comparable within a pair', () {
    final v2 = UniPoolState(
      reserve0: BigInt.from(4) * BigInt.from(10).pow(18),
      reserve1: BigInt.from(9) * BigInt.from(10).pow(18),
    );
    expect(UniswapQuoter.depth(v2), BigInt.from(6) * BigInt.from(10).pow(18));
    final v4 = UniPoolState(
      sqrtPriceX96: BigInt.one,
      liquidity: BigInt.from(77),
    );
    expect(UniswapQuoter.depth(v4), BigInt.from(77));
  });
}
