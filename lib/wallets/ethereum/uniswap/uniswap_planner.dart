/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Turns a quote — one route, or a swap shared between several — into one
// Universal Router `execute` call.
//
// The router runs a list of commands. The amount in is made ready first:
// paying with ETH, the part bound for WETH pools is wrapped (the exact
// amount, so the rest stays ETH for v4 pools); paying with a token, the
// signed Permit2 permit lets the router take the whole amount, a share at
// a time. Then each share runs on its own, pool by pool, keeping track of
// where its coins are (still in the user's wallet, or in the router
// between two pools) and in which form (ETH or WETH):
//
// * a v2 or v3 swap command per v2 or v3 pool;
// * one v4 command per run of v4 pools, inside it: pay the first pool
//   (SETTLE), swap through each pool (SWAP_EXACT_IN_SINGLE with "whatever
//   is owed", so the pools chain), and take the result (TAKE / TAKE_ALL);
// * WRAP_ETH / UNWRAP_WETH where one pool holds ETH and the next WETH.
//
// Each share's last pool carries that share's minimum, checked by the
// router on that pool, and pays the user directly when it gives the token
// wanted in the right form. A share that ends in WETH when ETH is wanted
// (or the other way round) leaves it in the router, which converts it and
// pays it out at the end, checking those shares' minimums once more.
//
// If any pool's price moves past the user's price protection before the
// transaction is mined, the whole transaction fails and nothing is swapped
// (only the gas is spent).

import 'dart:typed_data';

import 'abi.dart';
import 'permit2.dart';
import 'uniswap_constants.dart';
import 'uniswap_models.dart';

/// One `execute(commands, inputs, deadline)` call and the ETH it carries.
class UniSwapPlan {
  const UniSwapPlan({
    required this.commands,
    required this.inputs,
    required this.deadline,
    required this.value,
    required this.minimumOut,
  });

  final Uint8List commands;
  final List<Uint8List> inputs;
  final BigInt deadline;

  /// ETH sent with the transaction (the amount in, when paying with ETH).
  final BigInt value;

  /// The least the user receives, checked by the router.
  final BigInt minimumOut;

  String get to => UniswapAddresses.universalRouter;

  Uint8List get calldata => encodeCall('execute(bytes,bytes[],uint256)', [
    commands,
    inputs,
    deadline,
  ]);
}

enum _Holder { user, router }

class UniswapPlanner {
  const UniswapPlanner();

  /// The router call for [quote], each share paying out at least its
  /// quote less [slippageBips], before [deadline] (unix seconds). [permit]
  /// is required when the amount in is a token and Permit2 does not
  /// already allow the router to take it.
  UniSwapPlan build({
    required UniQuote quote,
    required int slippageBips,
    required BigInt deadline,
    SignedPermit? permit,
  }) {
    final commands = <int>[];
    final inputs = <Uint8List>[];
    void add(int command, Uint8List input) {
      commands.add(command);
      inputs.add(input);
    }

    final tokenIn = quote.tokenIn;
    final wanted = quote.tokenOut.address; // native for ETH, else the token
    final parts = quote.parts;
    final total = parts.fold(BigInt.zero, (s, p) => s + p.amountIn);
    if (total != quote.amountIn) {
      throw StateError('shares add up to $total, not ${quote.amountIn}');
    }

    if (permit != null) add(URCommand.permit2Permit, permit.routerInput);

    // The amount in, ready for each share's first pool.
    BigInt startingIn(String currency) => parts
        .where((p) => p.route.hops.first.currencyIn == currency)
        .fold(BigInt.zero, (s, p) => s + p.amountIn);
    if (tokenIn.isEth) {
      final weth = startingIn(UniswapAddresses.weth);
      if (weth > BigInt.zero) {
        add(
          URCommand.wrapEth,
          abiEncode('address,uint256', [URConstants.addressThis, weth]),
        );
      }
    } else if (tokenIn.isWeth) {
      final native = startingIn(UniswapAddresses.nativeEth);
      if (native > BigInt.zero) {
        add(
          URCommand.permit2TransferFrom,
          abiEncode('address,address,uint160', [
            UniswapAddresses.weth,
            URConstants.addressThis,
            native,
          ]),
        );
        add(
          URCommand.unwrapWeth,
          abiEncode('address,uint256', [URConstants.addressThis, native]),
        );
      }
    }

    // Shares whose result waits in the router, per form, with their
    // minimums added up.
    final waiting = <String, BigInt>{};

    for (final part in parts) {
      final hops = part.route.hops;
      final minimum = part.minimumOut(slippageBips);
      var form = hops.first.currencyIn;
      var holder =
          tokenIn.isEth ||
              (tokenIn.isWeth && form == UniswapAddresses.nativeEth)
          ? _Holder.router
          : _Holder.user;
      // The share's own amount for its first pool; after that, whatever
      // the previous pool gave.
      var first = true;

      // Moves the coins into the form [currency] the next pool holds
      // (between two pools, so they are in the router).
      void convertTo(String currency) {
        if (form == currency) return;
        if (form == UniswapAddresses.nativeEth &&
            currency == UniswapAddresses.weth) {
          add(
            URCommand.wrapEth,
            abiEncode('address,uint256', [
              URConstants.addressThis,
              URConstants.contractBalance,
            ]),
          );
        } else if (form == UniswapAddresses.weth &&
            currency == UniswapAddresses.nativeEth) {
          add(
            URCommand.unwrapWeth,
            abiEncode('address,uint256', [
              URConstants.addressThis,
              BigInt.zero,
            ]),
          );
        } else {
          throw StateError('cannot turn $form into $currency');
        }
        holder = _Holder.router;
        form = currency;
      }

      var i = 0;
      while (i < hops.length) {
        final hop = hops[i];
        convertTo(hop.currencyIn);
        final payerIsUser = holder == _Holder.user;
        final amountIn = first ? part.amountIn : URConstants.contractBalance;
        first = false;

        if (hop.pool is UniV4Pool) {
          // A run of v4 pools that hand over the same currency.
          var j = i;
          while (j + 1 < hops.length &&
              hops[j + 1].pool is UniV4Pool &&
              hops[j + 1].currencyIn == hops[j].currencyOut) {
            j++;
          }
          final last = hops[j];
          final ends = j == hops.length - 1;
          final toUser = ends && last.currencyOut == wanted;
          final actions = <int>[V4Action.settle];
          final params = <Uint8List>[
            abiEncode('address,uint256,bool', [
              hop.currencyIn,
              amountIn,
              payerIsUser,
            ]),
          ];
          for (var k = i; k <= j; k++) {
            final h = hops[k];
            final pool = h.pool as UniV4Pool;
            actions.add(V4Action.swapExactInSingle);
            params.add(
              abiEncode(
                '((address,address,uint24,int24,address),bool,uint128,uint128,bytes)',
                [
                  [
                    pool.key,
                    h.zeroForOne,
                    URConstants.openDelta,
                    ends && k == j ? minimum : BigInt.zero,
                    Uint8List(0),
                  ],
                ],
              ),
            );
          }
          if (toUser) {
            actions.add(V4Action.takeAll);
            params.add(
              abiEncode('address,uint256', [last.currencyOut, minimum]),
            );
          } else {
            actions.add(V4Action.take);
            params.add(
              abiEncode('address,address,uint256', [
                last.currencyOut,
                URConstants.addressThis,
                URConstants.openDelta,
              ]),
            );
            holder = _Holder.router;
          }
          add(
            URCommand.v4Swap,
            abiEncode('bytes,bytes[]', [Uint8List.fromList(actions), params]),
          );
          form = last.currencyOut;
          if (ends && !toUser) {
            waiting[form] = (waiting[form] ?? BigInt.zero) + minimum;
          }
          i = j + 1;
          continue;
        }

        final ends = i == hops.length - 1;
        final toUser = ends && hop.currencyOut == wanted;
        final recipient = toUser
            ? URConstants.msgSender
            : URConstants.addressThis;
        final minOut = ends ? minimum : BigInt.zero;
        switch (hop.pool) {
          case UniV2Pool():
            add(
              URCommand.v2SwapExactIn,
              abiEncode('address,uint256,uint256,address[],bool', [
                recipient,
                amountIn,
                minOut,
                [hop.currencyIn, hop.currencyOut],
                payerIsUser,
              ]),
            );
          case final UniV3Pool p:
            add(
              URCommand.v3SwapExactIn,
              abiEncode('address,uint256,uint256,bytes,bool', [
                recipient,
                amountIn,
                minOut,
                v3Path([hop.currencyIn, hop.currencyOut], [p.fee]),
                payerIsUser,
              ]),
            );
          case UniV4Pool():
            throw StateError('unreachable');
        }
        holder = _Holder.router;
        form = hop.currencyOut;
        if (ends && !toUser) {
          waiting[form] = (waiting[form] ?? BigInt.zero) + minimum;
        }
        i++;
      }
    }

    // What waits in the router, converted and paid out.
    for (final MapEntry(key: form, value: minimum) in waiting.entries) {
      if (wanted == UniswapAddresses.nativeEth &&
          form == UniswapAddresses.weth) {
        add(
          URCommand.unwrapWeth,
          abiEncode('address,uint256', [URConstants.msgSender, minimum]),
        );
      } else if (wanted == UniswapAddresses.weth &&
          form == UniswapAddresses.nativeEth) {
        add(
          URCommand.wrapEth,
          abiEncode('address,uint256', [
            URConstants.addressThis,
            URConstants.contractBalance,
          ]),
        );
        add(
          URCommand.sweep,
          abiEncode('address,address,uint256', [
            wanted,
            URConstants.msgSender,
            minimum,
          ]),
        );
      } else {
        throw StateError('route ends in $form, not $wanted');
      }
    }

    return UniSwapPlan(
      commands: Uint8List.fromList(commands),
      inputs: inputs,
      deadline: deadline,
      value: tokenIn.isEth ? quote.amountIn : BigInt.zero,
      minimumOut: quote.minimumOut(slippageBips),
    );
  }

  /// Whether [quote] takes a token from the wallet (so it needs Permit2).
  static bool needsPermit(UniQuote quote) => !quote.tokenIn.isEth;
}
