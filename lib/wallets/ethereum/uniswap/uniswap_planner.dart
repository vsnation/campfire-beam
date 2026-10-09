/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Turns a quoted route into one Universal Router `execute` call.
//
// The router runs a list of commands. This file walks the route pool by
// pool and keeps track of where the coins are (still in the user's wallet,
// or in the router between two pools) and in which form (ETH or WETH), and
// adds the commands that move them on:
//
// * the signed Permit2 permit first, when a token leaves the wallet;
// * a v2 or v3 swap command per v2 or v3 pool;
// * one v4 command per run of v4 pools, inside it: pay the first pool
//   (SETTLE), swap through each pool (SWAP_EXACT_IN_SINGLE with "whatever
//   is owed", so the pools chain), and take the result (TAKE / TAKE_ALL);
// * WRAP_ETH / UNWRAP_WETH where one pool holds ETH and the next WETH;
// * at the end, the coins to the user with the least they accept checked
//   by the router itself (TAKE_ALL, UNWRAP_WETH or SWEEP); a direct last
//   pool pays the user straight away with that same minimum.
//
// The last step always carries the user's minimum, so if the price moves
// past their price protection before the transaction is mined, the whole
// transaction fails and nothing is swapped (only the gas is spent).

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

  /// The router call for [quote], paying out at least [minimumOut] before
  /// [deadline] (unix seconds). [permit] is required when the amount in is
  /// a token and Permit2 does not already allow the router to take it.
  UniSwapPlan build({
    required UniQuote quote,
    required BigInt minimumOut,
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
    final tokenOut = quote.tokenOut;
    final wanted = tokenOut.address; // native for ETH, else the token
    var holder = tokenIn.isEth ? _Holder.router : _Holder.user;
    var form = tokenIn.address;
    var delivered = false;

    if (permit != null) add(URCommand.permit2Permit, permit.routerInput);

    // Moves the coins into the form [currency] the next pool holds.
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
        if (holder == _Holder.user) {
          add(
            URCommand.permit2TransferFrom,
            abiEncode('address,address,uint160', [
              UniswapAddresses.weth,
              URConstants.addressThis,
              quote.amountIn,
            ]),
          );
          holder = _Holder.router;
        }
        add(
          URCommand.unwrapWeth,
          abiEncode('address,uint256', [URConstants.addressThis, BigInt.zero]),
        );
      } else {
        throw StateError('cannot turn $form into $currency');
      }
      holder = _Holder.router;
      form = currency;
    }

    final hops = quote.route.hops;
    var i = 0;
    while (i < hops.length) {
      final hop = hops[i];
      convertTo(hop.currencyIn);
      final payerIsUser = holder == _Holder.user;
      final amountIn = payerIsUser
          ? quote.amountIn
          : URConstants.contractBalance;

      if (hop.pool is UniV4Pool) {
        // A run of v4 pools that hand over the same currency.
        var j = i;
        while (j + 1 < hops.length &&
            hops[j + 1].pool is UniV4Pool &&
            hops[j + 1].currencyIn == hops[j].currencyOut) {
          j++;
        }
        final last = hops[j];
        final toUser = j == hops.length - 1 && last.currencyOut == wanted;
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
                  BigInt.zero,
                  Uint8List(0),
                ],
              ],
            ),
          );
        }
        if (toUser) {
          actions.add(V4Action.takeAll);
          params.add(
            abiEncode('address,uint256', [last.currencyOut, minimumOut]),
          );
          delivered = true;
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
        i = j + 1;
        continue;
      }

      final toUser = i == hops.length - 1 && hop.currencyOut == wanted;
      final recipient = toUser
          ? URConstants.msgSender
          : URConstants.addressThis;
      final minOut = toUser ? minimumOut : BigInt.zero;
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
      delivered = toUser;
      holder = _Holder.router;
      form = hop.currencyOut;
      i++;
    }

    if (!delivered) {
      if (wanted == UniswapAddresses.nativeEth &&
          form == UniswapAddresses.weth) {
        add(
          URCommand.unwrapWeth,
          abiEncode('address,uint256', [URConstants.msgSender, minimumOut]),
        );
      } else {
        if (wanted == UniswapAddresses.weth &&
            form == UniswapAddresses.nativeEth) {
          convertTo(UniswapAddresses.weth);
        }
        if (form != wanted) {
          throw StateError('route ends in $form, not $wanted');
        }
        add(
          URCommand.sweep,
          abiEncode('address,address,uint256', [
            wanted,
            URConstants.msgSender,
            minimumOut,
          ]),
        );
      }
    }

    return UniSwapPlan(
      commands: Uint8List.fromList(commands),
      inputs: inputs,
      deadline: deadline,
      value: tokenIn.isEth ? quote.amountIn : BigInt.zero,
      minimumOut: minimumOut,
    );
  }

  /// Whether [quote] takes a token from the wallet (so it needs Permit2).
  static bool needsPermit(UniQuote quote) => !quote.tokenIn.isEth;
}
