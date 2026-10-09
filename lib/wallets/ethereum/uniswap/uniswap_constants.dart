/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Uniswap on Ethereum mainnet: the contracts Campfire talks to, and the
// numbers their calls use.
//
// Every address is from Uniswap's deployment pages (v3 "Ethereum
// Deployments", v4 "Deployments", 2026-10-09) and was checked on chain
// the same day: SwapRouter02.factory() / factoryV2() / WETH9() and
// QuoterV2.factory() name the factories and WETH below,
// StateView.poolManager() names the PoolManager, and each factory and the
// PoolManager have no code one block before the deployment block given
// here. The command and action numbers are from Universal Router 2.0.0
// (contracts/libraries/Commands.sol) and v4-periphery at the commit that
// release pins (src/libraries/Actions.sol, ActionConstants.sol).

/// Ethereum mainnet.
const int kEthChainId = 1;

abstract final class UniswapAddresses {
  /// Wrapped ether: what v2 and v3 pools hold instead of ETH.
  static const weth = '0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2';

  static const v2Factory = '0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f';
  static const v3Factory = '0x1f98431c8ad98523631ae4a59f267346ea31f984';
  static const v3QuoterV2 = '0x61ffe014ba17989e743c5f6cb21bf9697530b21e';
  static const v4PoolManager = '0x000000000004444c5dc75cb358380d2e3de08a90';
  static const v4Quoter = '0x52f0e24d1c21c8a0cb1e5a5dd6198556bd9e1203';
  static const v4StateView = '0x7ffe42c4a5deea5b0fec41c94c136cf115597227';

  /// Universal Router 2.0: swaps on v2, v3 and v4 in one transaction.
  static const universalRouter = '0x66a9893cc07d91d95644aedd05d03f95e1dba8af';

  /// Permit2: the one contract a token is approved to; the router then
  /// moves exactly the amount the user signed for.
  static const permit2 = '0x000000000022d473030f116ddee9f6b43ac78ba3';

  /// Multicall3: many read-only calls in one RPC request.
  static const multicall3 = '0xca11bde05977b3631167028862be2a173976ca11';

  /// What v4 and the router call native ETH.
  static const nativeEth = '0x0000000000000000000000000000000000000000';
}

/// Blocks before which a factory has no pools (its deployment block).
abstract final class UniswapDeployBlocks {
  static const v2Factory = 10000835;
  static const v3Factory = 12369621;
  static const v4PoolManager = 21688329;
}

/// Event topics (keccak of the event signature).
abstract final class UniswapTopics {
  /// UniswapV2Factory PairCreated(address indexed token0, address indexed
  /// token1, address pair, uint256).
  static const v2PairCreated =
      '0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9';

  /// UniswapV3Factory PoolCreated(address indexed token0, address indexed
  /// token1, uint24 indexed fee, int24 tickSpacing, address pool).
  static const v3PoolCreated =
      '0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118';

  /// PoolManager Initialize(bytes32 indexed id, address indexed currency0,
  /// address indexed currency1, uint24 fee, int24 tickSpacing, address
  /// hooks, uint160 sqrtPriceX96, int24 tick).
  static const v4Initialize =
      '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';
}

/// The fee tiers the v3 factory has enabled (feeAmountTickSpacing returns
/// a non-zero tick spacing for exactly these, checked 2026-10-09). Used
/// only when the RPC will not search the factory's events.
const Map<int, int> kV3FeeTickSpacing = {100: 1, 500: 10, 3000: 60, 10000: 200};

/// v4 pools without hooks that are commonly created, tried when the RPC
/// will not search the PoolManager's events (fee in hundredths of a bip →
/// tick spacing). The event search finds every other pool.
const List<({int fee, int tickSpacing})> kV4ProbeKeys = [
  (fee: 100, tickSpacing: 1),
  (fee: 500, tickSpacing: 10),
  (fee: 3000, tickSpacing: 60),
  (fee: 10000, tickSpacing: 200),
  (fee: 9000, tickSpacing: 90),
  (fee: 10000, tickSpacing: 100),
];

/// v4 fees with this bit set are set by the pool's hook on every swap.
const int kV4DynamicFeeFlag = 0x800000;

/// Universal Router commands (Commands.sol).
abstract final class URCommand {
  static const v3SwapExactIn = 0x00;
  static const permit2TransferFrom = 0x02;
  static const sweep = 0x04;
  static const v2SwapExactIn = 0x08;
  static const permit2Permit = 0x0a;
  static const wrapEth = 0x0b;
  static const unwrapWeth = 0x0c;
  static const v4Swap = 0x10;
}

/// v4 router actions (Actions.sol).
abstract final class V4Action {
  static const swapExactInSingle = 0x06;
  static const settle = 0x0b;
  static const settleAll = 0x0c;
  static const take = 0x0e;
  static const takeAll = 0x0f;
}

/// Special values the router understands (ActionConstants.sol).
abstract final class URConstants {
  /// "Whoever called execute".
  static const msgSender = '0x0000000000000000000000000000000000000001';

  /// "The router itself" (holds coins between two pools).
  static const addressThis = '0x0000000000000000000000000000000000000002';

  /// "Everything the router holds of this token."
  static final contractBalance = BigInt.one << 255;

  /// "Whatever this swap owes / is owed" inside v4.
  static final openDelta = BigInt.zero;
}
