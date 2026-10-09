/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Sharing one swap between routes, without a network: the allocator
// against a brute-force search, and the router commands a shared swap
// becomes (each share's own minimum, ETH wrapped only for the WETH pools,
// one Permit2 permit for every share).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/permit2.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_planner.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_quoter.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_split.dart';

const wbeam = UniToken(
  address: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
  symbol: 'WBEAM',
  decimals: 8,
);

final v4EthWbeam = UniV4Pool.key(
  currency0: UniswapAddresses.nativeEth,
  currency1: wbeam.address,
  fee: 10000,
  tickSpacing: 200,
  hooks: UniswapAddresses.nativeEth,
);
const v2WethWbeam = UniV2Pool(
  pair: '0xc821395f890913b9ce7415b36db10ddc5281c53a',
  currency0: UniswapAddresses.weth,
  currency1: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
);

/// A constant-product pool's output for [steps] steps of [stepIn].
List<BigInt?> curve(int steps, BigInt stepIn, BigInt rIn, BigInt rOut) => [
  BigInt.zero,
  for (var k = 1; k <= steps; k++) v2AmountOut(stepIn * BigInt.from(k), rIn, rOut),
];

BigInt b(num v) => BigInt.from(v);

/// The best sharing by trying every one (small cases only).
BigInt? bruteForce(List<UniSplitCurve> curves, int steps, int maxParts) {
  BigInt? best;
  void go(int i, int left, int parts, BigInt sum, Set<String> pools) {
    if (i == curves.length) {
      if (left == 0 && parts > 0 && (best == null || sum > best!)) best = sum;
      return;
    }
    go(i + 1, left, parts, sum, pools);
    final c = curves[i];
    if (parts == maxParts || c.pools.intersection(pools).isNotEmpty) return;
    for (var j = 1; j <= left; j++) {
      final out = c.outs[j];
      if (out == null || out <= BigInt.zero) continue;
      go(i + 1, left - j, parts + 1, sum + out - c.cost, {...pools, ...c.pools});
    }
  }

  go(0, steps, 0, BigInt.zero, {});
  return best;
}

void main() {
  group('bestSplit', () {
    test('two equal pools share the swap half and half', () {
      final c = curve(20, b(1e18), b(100e18), b(1e12));
      final split = bestSplit([
        UniSplitCurve(pools: {'a'}, outs: c, cost: BigInt.zero),
        UniSplitCurve(pools: {'b'}, outs: c, cost: BigInt.zero),
      ], steps: 20)!;
      expect(split.steps, [10, 10]);
    });

    test('a pool four times deeper takes about four fifths', () {
      final split = bestSplit([
        UniSplitCurve(
          pools: {'deep'},
          outs: curve(20, b(1e18), b(400e18), b(4e12)),
          cost: BigInt.zero,
        ),
        UniSplitCurve(
          pools: {'shallow'},
          outs: curve(20, b(1e18), b(100e18), b(1e12)),
          cost: BigInt.zero,
        ),
      ], steps: 20)!;
      expect(split.steps, [16, 4]);
    });

    test('a second pool is not used when its gas costs more than it saves',
        () {
      final c = curve(20, b(1e15), b(100e18), b(1e12));
      // A whole 1% of the output per extra route: far more than splitting
      // 0.02 ETH between two deep pools saves.
      final cost = c[20]! ~/ b(100);
      final split = bestSplit([
        UniSplitCurve(pools: {'a'}, outs: c, cost: cost),
        UniSplitCurve(pools: {'b'}, outs: c, cost: cost),
      ], steps: 20)!;
      expect(split.parts, 1);
      expect(split.steps.reduce((x, y) => x + y), 20);
    });

    test('routes through the same pool are never used together', () {
      final c = curve(10, b(1e18), b(50e18), b(5e11));
      final split = bestSplit([
        UniSplitCurve(pools: {'x', 'y'}, outs: c, cost: BigInt.zero),
        UniSplitCurve(pools: {'x', 'z'}, outs: c, cost: BigInt.zero),
        UniSplitCurve(pools: {'w'}, outs: c, cost: BigInt.zero),
      ], steps: 10)!;
      expect(split.steps[0] > 0 && split.steps[1] > 0, isFalse);
      expect(split.parts, 2);
    });

    test('many routes through one first pool: still never two of them',
        () {
      // Every way on from one pool: twelve routes, all sharing 'first'.
      final curves = [
        for (var i = 0; i < 12; i++)
          UniSplitCurve(
            pools: {'first', 'second$i'},
            outs: curve(20, b(1e17), b((10 + i) * 1e17), b((10 + i) * 1e10)),
            cost: BigInt.zero,
          ),
        UniSplitCurve(
          pools: {'other'},
          outs: curve(20, b(1e17), b(20e17), b(20e10)),
          cost: BigInt.zero,
        ),
      ];
      final split = bestSplit(curves, steps: 20)!;
      final usingFirst = [
        for (var i = 0; i < 12; i++)
          if (split.steps[i] > 0) i,
      ];
      expect(usingFirst.length <= 1, isTrue, reason: '$usingFirst');
      expect(split.steps.reduce((x, y) => x + y), 20);
    });

    test('matches a brute-force search on random pools', () {
      final rnd = math.Random(7);
      for (var round = 0; round < 60; round++) {
        const steps = 8;
        final n = 2 + rnd.nextInt(3);
        final names = ['p', 'q', 'r', 's'];
        final curves = [
          for (var i = 0; i < n; i++)
            UniSplitCurve(
              pools: {
                names[rnd.nextInt(4)],
                if (rnd.nextBool()) names[rnd.nextInt(4)],
              },
              outs: curve(
                steps,
                b(1e17),
                b((1 + rnd.nextInt(40)) * 1e17),
                b((1 + rnd.nextInt(40)) * 1e10),
              ),
              cost: b(rnd.nextInt(3) * 1e7),
            ),
        ];
        final maxParts = 1 + rnd.nextInt(3);
        final got = bestSplit(curves, steps: steps, maxParts: maxParts);
        final want = bruteForce(curves, steps, maxParts);
        expect(got?.net, want, reason: 'round $round');
        if (got != null) {
          expect(got.steps.reduce((x, y) => x + y), steps);
          expect(got.parts <= maxParts, isTrue);
          final used = [
            for (var i = 0; i < n; i++)
              if (got.steps[i] > 0) curves[i].pools,
          ];
          for (var i = 0; i < used.length; i++) {
            for (var j = i + 1; j < used.length; j++) {
              expect(used[i].intersection(used[j]), isEmpty);
            }
          }
        }
      }
    });
  });

  group('the router call for a shared swap', () {
    final deadline = BigInt.from(1791557000);
    final eth = BigInt.from(10).pow(18);

    UniPart part(UniHop hop, BigInt amountIn, BigInt amountOut) => UniPart(
      route: UniRoute([hop]),
      amountIn: amountIn,
      amountOut: amountOut,
      hopOutputs: [amountOut],
      gas: b(100000),
    );

    List<int> commandsOf(UniSwapPlan p) => p.commands.toList();

    test('ETH → WBEAM: wraps only the v2 share, each pool its own minimum',
        () {
      final q = UniQuote(
        tokenIn: UniToken.eth,
        tokenOut: wbeam,
        amountIn: eth,
        parts: [
          part(
            UniHop(v4EthWbeam, UniswapAddresses.nativeEth, wbeam.address),
            eth * b(7) ~/ b(10),
            b(220000e8),
          ),
          part(
            UniHop(v2WethWbeam, UniswapAddresses.weth, wbeam.address),
            eth * b(3) ~/ b(10),
            b(93000e8),
          ),
        ],
        gasEstimate: b(280000),
        block: 1,
      );
      final plan = const UniswapPlanner().build(
        quote: q,
        slippageBips: 50,
        deadline: deadline,
      );
      expect(commandsOf(plan), [
        URCommand.wrapEth,
        URCommand.v4Swap,
        URCommand.v2SwapExactIn,
      ]);
      expect(plan.value, eth);
      final minV4 = b(220000e8) * b(9950) ~/ b(10000);
      final minV2 = b(93000e8) * b(9950) ~/ b(10000);
      expect(plan.minimumOut, minV4 + minV2);

      // Exactly the v2 share is wrapped; the rest stays ETH for v4.
      final wrap = abiDecode('address,uint256', plan.inputs[0]);
      expect(wrap[1], eth * b(3) ~/ b(10));

      final v4 = abiDecode('bytes,bytes[]', plan.inputs[1]);
      final actions = (v4[0] as Uint8List).toList();
      final params = (v4[1] as List).cast<Uint8List>();
      expect(actions, [
        V4Action.settle,
        V4Action.swapExactInSingle,
        V4Action.takeAll,
      ]);
      final settle = abiDecode('address,uint256,bool', params[0]);
      expect(settle[1], eth * b(7) ~/ b(10));
      expect(settle[2], false); // paid from the ETH sent with the call
      final swap = abiDecode(
        '((address,address,uint24,int24,address),bool,uint128,uint128,bytes)',
        params[1],
      ).first as List;
      expect(swap[3], minV4);
      final take = abiDecode('address,uint256', params[2]);
      expect(take[1], minV4);

      final v2 = abiDecode(
        'address,uint256,uint256,address[],bool',
        plan.inputs[2],
      );
      expect(v2[0], URConstants.msgSender);
      expect(v2[1], eth * b(3) ~/ b(10));
      expect(v2[2], minV2);
      expect(v2[4], false);
    });

    test('WBEAM → ETH: one permit pays both shares; the WETH share is '
        'unwrapped at the end', () {
      final amount = b(300000e8);
      final q = UniQuote(
        tokenIn: wbeam,
        tokenOut: UniToken.eth,
        amountIn: amount,
        parts: [
          part(
            UniHop(v4EthWbeam, wbeam.address, UniswapAddresses.nativeEth),
            b(180000e8),
            b(55e16),
          ),
          part(
            UniHop(v2WethWbeam, wbeam.address, UniswapAddresses.weth),
            b(120000e8),
            b(36e16),
          ),
        ],
        gasEstimate: b(280000),
        block: 1,
      );
      final permit = SignedPermit(
        PermitSingle(
          token: wbeam.address,
          amount: amount,
          expiration: 1791557000,
          nonce: 0,
          spender: UniswapAddresses.universalRouter,
          sigDeadline: deadline,
        ),
        Uint8List(65),
      );
      final plan = const UniswapPlanner().build(
        quote: q,
        slippageBips: 100,
        deadline: deadline,
        permit: permit,
      );
      expect(commandsOf(plan), [
        URCommand.permit2Permit,
        URCommand.v4Swap,
        URCommand.v2SwapExactIn,
        URCommand.unwrapWeth,
      ]);
      expect(plan.value, BigInt.zero);
      final v4 = abiDecode('bytes,bytes[]', plan.inputs[1]);
      final settle = abiDecode(
        'address,uint256,bool',
        (v4[1] as List).cast<Uint8List>()[0],
      );
      expect(settle[1], b(180000e8));
      expect(settle[2], true); // taken from the wallet through Permit2
      final v2 = abiDecode(
        'address,uint256,uint256,address[],bool',
        plan.inputs[2],
      );
      expect(v2[0], URConstants.addressThis);
      expect(v2[1], b(120000e8));
      expect(v2[2], b(36e16) * b(99) ~/ b(100));
      expect(v2[4], true);
      final unwrap = abiDecode('address,uint256', plan.inputs[3]);
      expect(unwrap[0], URConstants.msgSender);
      expect(unwrap[1], b(36e16) * b(99) ~/ b(100));
    });

    test('shares that do not add up to the amount are refused', () {
      final q = UniQuote(
        tokenIn: UniToken.eth,
        tokenOut: wbeam,
        amountIn: eth,
        parts: [
          part(
            UniHop(v4EthWbeam, UniswapAddresses.nativeEth, wbeam.address),
            eth ~/ b(2),
            b(1),
          ),
        ],
        gasEstimate: b(1),
        block: 1,
      );
      expect(
        () => const UniswapPlanner().build(
          quote: q,
          slippageBips: 50,
          deadline: deadline,
        ),
        throwsStateError,
      );
    });
  });
}
