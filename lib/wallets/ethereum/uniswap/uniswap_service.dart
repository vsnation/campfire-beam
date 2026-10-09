/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Uniswap swap, end to end, for one Ethereum wallet:
//
//   quote → (approve the token to Permit2, if needed) → prepare (price
//   again, sign the permit, build the router call, estimate its gas) →
//   send → wait for the receipt.
//
// Everything goes through the wallet's own RPC ([EthRpc], Tor when Tor is
// on). Keys never leave the wallet: [UniSwapSigner] signs digests and
// transactions inside it.

import 'dart:async';
import 'dart:typed_data';

import 'abi.dart';
import 'eth_rpc.dart';
import 'permit2.dart';
import 'uniswap_constants.dart';
import 'uniswap_discovery.dart';
import 'uniswap_models.dart';
import 'uniswap_planner.dart';
import 'uniswap_quoter.dart';

/// The wallet side: its address, and signing done with its own key.
abstract class UniSwapSigner {
  /// 0x-prefixed lowercase.
  String get address;

  /// Signs a 32-byte digest (EIP-712): r ‖ s ‖ v, 65 bytes, v = 27 or 28.
  Future<Uint8List> signDigest(Uint8List digest);

  /// Signs and broadcasts [tx]; returns its hash.
  Future<String> send(UniTxRequest tx);
}

/// What one transaction does, for the wallet's history.
enum UniTxKind { approve, approveReset, swap }

/// A transaction ready to sign.
class UniTxRequest {
  const UniTxRequest({
    required this.kind,
    required this.to,
    required this.data,
    required this.value,
    required this.gasLimit,
    required this.fees,
    this.note,
  });

  final UniTxKind kind;
  final String to;
  final Uint8List data;
  final BigInt value;
  final BigInt gasLimit;
  final UniFees fees;

  /// What the wallet's history says about it ("Swap 0.01 ETH for WBEAM on
  /// Uniswap").
  final String? note;

  UniTxRequest withNote(String note) => UniTxRequest(
    kind: kind,
    to: to,
    data: data,
    value: value,
    gasLimit: gasLimit,
    fees: fees,
    note: note,
  );

  /// The most this transaction can cost in gas (limit × max fee).
  BigInt get maxGasCost => gasLimit * fees.maxFeePerGas;

  /// What it will most likely cost (limit × (base fee + tip)); the real
  /// cost uses the gas actually burnt, usually less than the limit.
  BigInt get expectedGasCost =>
      gasLimit * (fees.baseFee + fees.maxPriorityFeePerGas);
}

/// EIP-1559 fees.
class UniFees {
  const UniFees({
    required this.baseFee,
    required this.maxPriorityFeePerGas,
    required this.maxFeePerGas,
  });

  final BigInt baseFee;
  final BigInt maxPriorityFeePerGas;
  final BigInt maxFeePerGas;
}

/// Whether the router may take the token yet.
enum UniApprovalKind {
  /// Paying with ETH, or Permit2 may already take enough.
  none,

  /// One `approve(Permit2, amount)` transaction.
  approve,

  /// Tokens like USDT refuse to change an allowance that is not zero:
  /// set it to zero first, then to the amount (two transactions).
  resetThenApprove,
}

class UniApproval {
  const UniApproval(this.kind, this.token, this.amount, this.current);

  final UniApprovalKind kind;
  final UniToken token;
  final BigInt amount;

  /// The token's allowance to Permit2 now.
  final BigInt current;
}

/// A swap ready to send, with what the review screen shows.
class UniPreparedSwap {
  const UniPreparedSwap({
    required this.quote,
    required this.tx,
    required this.plan,
    required this.slippageBips,
    required this.priceMoved,
    required this.permitSigned,
  });

  /// The fresh quote the transaction was built from.
  final UniQuote quote;
  final UniTxRequest tx;
  final UniSwapPlan plan;
  final int slippageBips;

  /// How much less the fresh quote gives than the one the user saw (0 when
  /// it gives as much or more), as a fraction.
  final double priceMoved;

  /// A Permit2 permit was signed for this swap (shown on the review).
  final bool permitSigned;

  BigInt get minimumOut => plan.minimumOut;
}

/// What the review screen shows; nothing signed yet.
class UniSwapReview {
  const UniSwapReview({
    required this.quote,
    required this.slippageBips,
    required this.minimumOut,
    required this.deadline,
    required this.needsPermit,
    required this.gasLimit,
    required this.fees,
    required this.priceMoved,
  });

  final UniQuote quote;
  final int slippageBips;
  final BigInt minimumOut;
  final BigInt deadline;

  /// The swap will carry a Permit2 signature (signed after the PIN).
  final bool needsPermit;
  final BigInt gasLimit;
  final UniFees fees;
  final double priceMoved;

  BigInt get maxGasCost => gasLimit * fees.maxFeePerGas;
  BigInt get expectedGasCost =>
      gasLimit * (fees.baseFee + fees.maxPriorityFeePerGas);
}

/// The route that was priced would not trade (a v4 pool whose hook quotes
/// one price and swaps another); [quote] is the best price without it.
class UniRouteChanged implements Exception {
  const UniRouteChanged(this.quote);

  final UniQuote quote;
}

/// The built swap needs more gas than the review showed.
class UniGasChanged implements Exception {
  const UniGasChanged(this.gasLimit);

  final BigInt gasLimit;
}

/// Gas a Permit2 permit adds to the swap (signature check and the
/// allowance it stores), with room to spare.
final BigInt kPermitGas = BigInt.from(80000);

class UniPriceMoved implements Exception {
  const UniPriceMoved(this.moved, this.fresh);

  final double moved;
  final UniQuote fresh;
}

/// How a sent transaction ended.
class UniTxOutcome {
  const UniTxOutcome({
    required this.hash,
    required this.success,
    required this.blockNumber,
    required this.gasUsed,
    required this.effectiveGasPrice,
    this.received,
  });

  final String hash;
  final bool success;
  final int blockNumber;
  final BigInt gasUsed;
  final BigInt effectiveGasPrice;

  /// What arrived, read from the receipt (tokens) or the balance change
  /// (ETH); null when it could not be read.
  final BigInt? received;

  BigInt get gasCost => gasUsed * effectiveGasPrice;
}

class UniswapService {
  UniswapService({
    required this.rpc,
    UniswapDiscovery? discovery,
    UniswapQuoter? quoter,
    DateTime Function()? clock,
  }) : discovery = discovery ?? UniswapDiscovery(rpc: rpc),
       _clock = clock ?? DateTime.now {
    this.quoter = quoter ?? UniswapQuoter(rpc: rpc, discovery: this.discovery);
  }

  final EthRpc rpc;
  final UniswapDiscovery discovery;
  late final UniswapQuoter quoter;
  final DateTime Function() _clock;
  final UniswapPlanner _planner = const UniswapPlanner();

  /// A swap must be mined within this long of signing, or it fails.
  static const deadline = Duration(minutes: 20);

  /// The Permit2 signature is good for this long.
  static const permitLife = Duration(minutes: 30);

  int get _now => _clock().millisecondsSinceEpoch ~/ 1000;

  // ---------------------------------------------------------------- price

  /// The best price. With [owner] (the wallet's address) and ETH paid, a
  /// route through a v4 pool with a hook is only chosen after its real
  /// swap was simulated from the wallet (see `UniswapQuoter.bestQuote`).
  Future<UniQuote> quote({
    required UniToken tokenIn,
    required UniToken tokenOut,
    required BigInt amountIn,
    String? owner,
  }) async {
    BigInt? gasPrice;
    try {
      final f = await fees();
      gasPrice = f.baseFee + f.maxPriorityFeePerGas;
    } catch (_) {
      // The price is still right without it; only the gas tie-break is off.
    }
    return quoter.bestQuote(
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      amountIn: amountIn,
      gasPriceWei: gasPrice,
      simulate: owner != null && tokenIn.isEth
          ? (q) => simulates(q, owner)
          : null,
    );
  }

  /// Whether the router transaction for [q] goes through when [owner]
  /// sends it now (an eth_call; nothing is signed or sent). Paying with
  /// ETH only: a token would need its approval in place first.
  Future<bool?> simulates(UniQuote q, String owner) async {
    try {
      // Without the ETH, the call fails for that reason, not the pool's.
      if (await balanceOf(UniToken.eth, owner) < q.amountIn) return null;
    } catch (_) {
      return null;
    }
    final plan = _planner.build(
      quote: q,
      minimumOut: q.minimumOut(100),
      deadline: BigInt.from(_now + deadline.inSeconds),
    );
    try {
      await rpc.ethCall(plan.to, plan.calldata, from: owner, value: plan.value);
      return true;
    } on EthRpcError catch (e) {
      // "execution reverted" is the pool's answer; anything else is the
      // node's, and tells nothing about the pool.
      return e.code == 3 || e.message.toLowerCase().contains('revert')
          ? false
          : null;
    } catch (_) {
      return null;
    }
  }

  /// [quote]'s route would not go through (its gas could not be measured):
  /// if it uses hooked v4 pools, they are left out from now on and the
  /// best other price is returned; otherwise null (a plain failure).
  Future<UniQuote?> _rerouteAround(UniQuote quote, String owner) async {
    final hooked = [
      for (final p in quote.route.pools)
        if (p is UniV4Pool && p.hasHooks) p.id,
    ];
    if (hooked.isEmpty) return null;
    quoter.distrusted.addAll(hooked);
    return this.quote(
      tokenIn: quote.tokenIn,
      tokenOut: quote.tokenOut,
      amountIn: quote.amountIn,
      owner: owner,
    );
  }

  /// EIP-1559 fees from the RPC's own fee history: the next block's base
  /// fee and the median tip of the last few blocks (at least 0.01 gwei),
  /// with room for the base fee to double before the transaction is
  /// mined.
  Future<UniFees> fees() async {
    final r = await rpc.call('eth_feeHistory', [
      '0x5',
      'latest',
      [50],
    ]);
    final m = r! as Map<String, dynamic>;
    final bases = [
      for (final b in m['baseFeePerGas'] as List) _hex(b as String),
    ];
    final next = bases.last;
    final tips = <BigInt>[
      for (final row in (m['reward'] as List?) ?? const [])
        if ((row as List).isNotEmpty) _hex(row.first as String),
    ]..sort();
    final floor = BigInt.from(10000000); // 0.01 gwei
    var tip = tips.isEmpty ? floor : tips[tips.length ~/ 2];
    if (tip < floor) tip = floor;
    return UniFees(
      baseFee: next,
      maxPriorityFeePerGas: tip,
      maxFeePerGas: next * BigInt.two + tip,
    );
  }

  // ------------------------------------------------------------- approval

  /// Whether paying [quote] needs an approval transaction first.
  Future<UniApproval> approvalFor(UniQuote quote, String owner) async {
    final token = quote.tokenIn;
    if (token.isEth) {
      return UniApproval(
        UniApprovalKind.none,
        token,
        quote.amountIn,
        BigInt.zero,
      );
    }
    final reader = Permit2Reader(rpc);
    final current = await reader.tokenAllowance(token.address, owner);
    if (current >= quote.amountIn) {
      return UniApproval(UniApprovalKind.none, token, quote.amountIn, current);
    }
    if (current > BigInt.zero) {
      // Ask the token whether it takes a change from non-zero (USDT says
      // no by reverting).
      try {
        await rpc.ethCall(
          token.address,
          approvePermit2Call(quote.amountIn),
          from: owner,
        );
      } on EthRpcError {
        return UniApproval(
          UniApprovalKind.resetThenApprove,
          token,
          quote.amountIn,
          current,
        );
      }
    }
    return UniApproval(UniApprovalKind.approve, token, quote.amountIn, current);
  }

  /// `approve(Permit2, amount)` (amount zero for the reset step).
  Future<UniTxRequest> approvalTx({
    required UniToken token,
    required BigInt amount,
    required String owner,
    UniFees? withFees,
  }) async {
    final data = approvePermit2Call(amount);
    final f = withFees ?? await fees();
    BigInt gas;
    try {
      gas = await rpc.estimateGas(from: owner, to: token.address, data: data);
    } on EthRpcError {
      gas = BigInt.from(70000);
    }
    return UniTxRequest(
      kind: amount == BigInt.zero ? UniTxKind.approveReset : UniTxKind.approve,
      to: token.address,
      data: data,
      value: BigInt.zero,
      gasLimit: _withHeadroom(gas),
      fees: f,
    );
  }

  // ----------------------------------------------------------------- swap

  /// Everything the review screen shows, without signing anything: prices
  /// the route again, refuses if the price moved more than [slippageBips]
  /// against [quote], and measures the gas. When the router will need a
  /// Permit2 signature, the gas is the quoters' estimate plus the permit's
  /// cost (the real measure needs the signature, see [finalizeSwap]).
  Future<UniSwapReview> reviewSwap({
    required UniQuote quote,
    required int slippageBips,
    required String owner,
    UniFees? withFees,
  }) async {
    final fresh = await quoter.requote(quote);
    final moved = fresh.amountOut >= quote.amountOut
        ? 0.0
        : (quote.amountOut - fresh.amountOut).toDouble() /
              quote.amountOut.toDouble();
    if (moved * 10000 > slippageBips) throw UniPriceMoved(moved, fresh);

    var needsPermit = false;
    if (UniswapPlanner.needsPermit(fresh)) {
      final allowance = await Permit2Reader(rpc)
          .permitAllowance(fresh.tokenIn.address, owner);
      needsPermit = !allowance.covers(fresh.amountIn, _now);
    }
    final minimumOut = fresh.minimumOut(slippageBips);
    final dl = BigInt.from(_now + deadline.inSeconds);
    final f = withFees ?? await fees();
    BigInt gas;
    if (needsPermit) {
      gas = fresh.gasEstimate + kPermitGas;
    } else {
      final plan = _planner.build(
        quote: fresh,
        minimumOut: minimumOut,
        deadline: dl,
      );
      try {
        gas = await rpc.estimateGas(
          from: owner,
          to: plan.to,
          data: plan.calldata,
          value: plan.value,
        );
      } on EthRpcError {
        final other = await _rerouteAround(fresh, owner);
        if (other == null) rethrow;
        throw UniRouteChanged(other);
      }
    }
    return UniSwapReview(
      quote: fresh,
      slippageBips: slippageBips,
      minimumOut: minimumOut,
      deadline: dl,
      needsPermit: needsPermit,
      gasLimit: _withHeadroom(gas),
      fees: f,
      priceMoved: moved,
    );
  }

  /// After the user confirmed [review]: signs the Permit2 permit if one is
  /// needed, builds the router call with the reviewed minimum and deadline,
  /// and checks its gas fits the limit the user saw (else
  /// [UniGasChanged], and the review is shown again). Nothing is sent.
  Future<UniPreparedSwap> finalizeSwap({
    required UniSwapReview review,
    required UniSwapSigner signer,
  }) async {
    final q = review.quote;
    SignedPermit? permit;
    if (review.needsPermit) {
      final allowance = await Permit2Reader(rpc)
          .permitAllowance(q.tokenIn.address, signer.address);
      final p = PermitSingle(
        token: q.tokenIn.address,
        amount: q.amountIn,
        expiration: _now + permitLife.inSeconds,
        nonce: allowance.nonce,
        spender: UniswapAddresses.universalRouter,
        sigDeadline: BigInt.from(_now + permitLife.inSeconds),
      );
      permit = SignedPermit(p, await signer.signDigest(p.digest()));
    }
    final plan = _planner.build(
      quote: q,
      minimumOut: review.minimumOut,
      deadline: review.deadline,
      permit: permit,
    );
    final BigInt gas;
    try {
      gas = await rpc.estimateGas(
        from: signer.address,
        to: plan.to,
        data: plan.calldata,
        value: plan.value,
      );
    } on EthRpcError {
      final other = await _rerouteAround(q, signer.address);
      if (other == null) rethrow;
      throw UniRouteChanged(other);
    }
    if (gas > review.gasLimit) throw UniGasChanged(_withHeadroom(gas));
    return UniPreparedSwap(
      quote: q,
      tx: UniTxRequest(
        kind: UniTxKind.swap,
        to: plan.to,
        data: plan.calldata,
        value: plan.value,
        gasLimit: review.gasLimit,
        fees: review.fees,
      ),
      plan: plan,
      slippageBips: review.slippageBips,
      priceMoved: review.priceMoved,
      permitSigned: permit != null,
    );
  }

  /// [reviewSwap] and [finalizeSwap] in one go (tests, scripts).
  Future<UniPreparedSwap> prepareSwap({
    required UniQuote quote,
    required int slippageBips,
    required UniSwapSigner signer,
    UniFees? withFees,
  }) async => finalizeSwap(
    review: await reviewSwap(
      quote: quote,
      slippageBips: slippageBips,
      owner: signer.address,
      withFees: withFees,
    ),
    signer: signer,
  );

  // -------------------------------------------------------------- receipt

  /// Waits for [hash] to be mined (polling every [every], up to [limit]).
  /// Null if it was not mined in time (it may still be).
  Future<UniTxOutcome?> waitForReceipt(
    String hash, {
    String? owner,
    UniToken? tokenOut,
    Duration every = const Duration(seconds: 4),
    Duration limit = const Duration(minutes: 10),
  }) async {
    final end = _clock().add(limit);
    while (_clock().isBefore(end)) {
      final r = await rpc.call('eth_getTransactionReceipt', [hash]);
      if (r is Map<String, dynamic> && r['blockNumber'] != null) {
        final block = int.parse(r['blockNumber'] as String);
        final success = r['status'] == '0x1';
        final gasUsed = _hex(r['gasUsed'] as String);
        final price = _hex((r['effectiveGasPrice'] as String?) ?? '0x0');
        BigInt? received;
        if (success && owner != null && tokenOut != null) {
          received = await _received(
            r,
            owner,
            tokenOut,
            block,
            gasUsed * price,
          );
        }
        return UniTxOutcome(
          hash: hash,
          success: success,
          blockNumber: block,
          gasUsed: gasUsed,
          effectiveGasPrice: price,
          received: received,
        );
      }
      await Future<void>.delayed(every);
    }
    return null;
  }

  Future<BigInt?> _received(
    Map<String, dynamic> receipt,
    String owner,
    UniToken tokenOut,
    int block,
    BigInt gasCost,
  ) async {
    final me = topicOfAddress(owner);
    const transfer =
        '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
    if (!tokenOut.isEth) {
      var sum = BigInt.zero;
      for (final l in (receipt['logs'] as List).cast<Map<String, dynamic>>()) {
        final topics = (l['topics'] as List).cast<String>();
        if ((l['address'] as String).toLowerCase() == tokenOut.address &&
            topics.length == 3 &&
            topics[0] == transfer &&
            topics[2].toLowerCase() == me) {
          sum += _hex(l['data'] as String);
        }
      }
      return sum;
    }
    try {
      final before = _hex(
        await rpc.call('eth_getBalance', [
          owner,
          '0x${(block - 1).toRadixString(16)}',
        ]) as String,
      );
      final after = _hex(
        await rpc.call('eth_getBalance', [
          owner,
          '0x${block.toRadixString(16)}',
        ]) as String,
      );
      return after - before + gasCost;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- tokens

  /// Symbol, decimals and name of ERC-20 [addresses] (one request); a
  /// token that does not answer is left out.
  Future<List<UniToken>> tokenInfo(List<String> addresses) async {
    final list = [for (final a in addresses) normAddress(a)];
    final calls = <EthCall>[
      for (final a in list) ...[
        EthCall(a, selector('symbol()')),
        EthCall(a, selector('decimals()')),
        EthCall(a, selector('name()')),
      ],
    ];
    final r = await rpc.multicall(calls, chunk: 150);
    final out = <UniToken>[];
    for (var i = 0; i < list.length; i++) {
      final sym = _string(r[i * 3]);
      final dec = r[i * 3 + 1];
      if (sym == null || !dec.success || dec.data.length < 32) continue;
      final decimals = bytesToBigInt(dec.data.sublist(0, 32));
      if (decimals > BigInt.from(36)) continue;
      out.add(
        UniToken(
          address: list[i],
          symbol: sym,
          decimals: decimals.toInt(),
          name: _string(r[i * 3 + 2]),
        ),
      );
    }
    return out;
  }

  /// Tokens with a live Uniswap pool against [token] (every version).
  Future<List<String>> partnersOf(UniToken token) async {
    final pools = <UniPool>[];
    for (final c in token.poolCurrencies) {
      pools.addAll(await discovery.poolsOf(c));
    }
    final states = await discovery.liveState(pools);
    final mine = token.poolCurrencies.toSet();
    final partners = <String>{};
    for (final p in pools) {
      if (!(states[p.id]?.isLive ?? false)) continue;
      final other = mine.contains(p.currency0) ? p.currency1 : p.currency0;
      partners.add(
        other == UniswapAddresses.weth ? UniswapAddresses.nativeEth : other,
      );
    }
    partners.removeAll(mine);
    return partners.toList();
  }

  /// Balance of [token] held by [owner].
  Future<BigInt> balanceOf(UniToken token, String owner) async {
    if (token.isEth) {
      return _hex(
        await rpc.call('eth_getBalance', [owner, 'latest']) as String,
      );
    }
    final r = await rpc.ethCall(
      token.address,
      encodeCall('balanceOf(address)', [owner]),
    );
    return abiDecode('uint256', r)[0] as BigInt;
  }

  // --------------------------------------------------------------- private

  static BigInt _withHeadroom(BigInt gas) {
    final more = gas * BigInt.from(125) ~/ BigInt.from(100);
    return more - gas < BigInt.from(20000) ? gas + BigInt.from(20000) : more;
  }

  static BigInt _hex(String h) =>
      h == '0x' ? BigInt.zero : BigInt.parse(h.substring(2), radix: 16);

  /// A `string` return value (or a bytes32 one, as old tokens like MKR
  /// return), or null.
  static String? _string(EthCallResult r) {
    if (!r.success || r.data.isEmpty) return null;
    try {
      if (r.data.length >= 64) {
        final s = (abiDecode('string', r.data).first as String).trim();
        return s.isEmpty ? null : s;
      }
    } catch (_) {}
    if (r.data.length == 32) {
      final end = r.data.indexOf(0);
      final bytes = end < 0 ? r.data : r.data.sublist(0, end);
      final s = String.fromCharCodes(bytes).trim();
      return s.isEmpty ? null : s;
    }
    return null;
  }
}
