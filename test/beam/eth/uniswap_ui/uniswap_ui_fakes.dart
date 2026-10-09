/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A Uniswap service that answers like mainnet did on 2026-10-09 (the ETH /
// WBEAM v4 pool, the WBEAM v4 pools with KAS, wXTM, USDT…), without a
// network, for the Uniswap screens' tests.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:stackwallet/pages/eth/uniswap/uniswap_deps.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_discovery.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_planner.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_quoter.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

final BigInt ethUnit = BigInt.from(10).pow(18);
final BigInt beamUnit = BigInt.from(10).pow(8);

const usdt = UniToken(
  address: '0xdac17f958d2ee523a2206206994597c13d831ec7',
  symbol: 'USDT',
  decimals: 6,
  name: 'Tether',
);
const kas = UniToken(
  address: '0x112b08621e27e10773ec95d250604a041f36c582',
  symbol: 'KAS',
  decimals: 8,
  name: 'Wrapped Kaspa',
);
const wxtm = UniToken(
  address: '0xfd36fa88bb3fea8d1264fc89d70723b6a2b56958',
  symbol: 'wXTM',
  decimals: 6,
  name: 'Wrapped Tari',
);

/// A copy of USDT someone made: same ticker, another address.
const fakeUsdt = UniToken(
  address: '0x9999999999999999999999999999999999999999',
  symbol: 'USDT',
  decimals: 6,
  name: 'Tether USD',
);

final v4EthWbeam = UniV4Pool.key(
  currency0: UniswapAddresses.nativeEth,
  currency1: kWbeamToken.address,
  fee: 10000,
  tickSpacing: 200,
  hooks: UniswapAddresses.nativeEth,
);
const v2WethWbeam = UniV2Pool(
  pair: '0xc821395f890913b9ce7415b36db10ddc5281c53a',
  currency0: UniswapAddresses.weth,
  currency1: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
);
final v4KasWbeam = UniV4Pool.key(
  currency0: kas.address,
  currency1: kWbeamToken.address,
  fee: 10000,
  tickSpacing: 200,
  hooks: UniswapAddresses.nativeEth,
);

class FakeDiscovery extends UniswapDiscovery {
  FakeDiscovery() : super(rpc: _noRpc());

  @override
  Future<List<UniPool>> poolsBetween(String a, String b, {int? head}) async {
    final set = {a, b};
    if (set.contains(kWbeamToken.address) &&
        set.contains(UniswapAddresses.nativeEth)) {
      return [v4EthWbeam];
    }
    if (set.contains(kWbeamToken.address) &&
        set.contains(UniswapAddresses.weth)) {
      return [v2WethWbeam];
    }
    return const [];
  }

  @override
  Future<Map<String, UniPoolState>> liveState(List<UniPool> pools) async => {
    for (final p in pools)
      p.id: p is UniV2Pool
          ? UniPoolState(
              reserve0: BigInt.parse('403461114461472693'),
              reserve1: BigInt.parse('13022386628314'),
            )
          : UniPoolState(
              sqrtPriceX96: BigInt.parse('452332567505986722683818525'),
              liquidity: BigInt.parse('74399137579714199'),
              lpFee: 10000,
            ),
  };
}

EthRpc _noRpc() => EthRpc(
  url: 'http://127.0.0.1:9',
  clientFactory: () => throw StateError('no network in this test'),
);

/// What the next quote does.
enum FakeQuoteMode {
  normal,
  bigImpact,
  noPool,

  /// ETH → WBEAM shared: 70% through the v4 pool, 30% through v2.
  split,
}

class FakeUniswapService extends UniswapService {
  FakeUniswapService() : super(rpc: _noRpc(), discovery: FakeDiscovery());

  FakeQuoteMode mode = FakeQuoteMode.normal;
  bool approveNeeded = true;
  bool swapFails = false;
  final List<String> calls = [];

  static final fakeFees = UniFees(
    baseFee: BigInt.from(320000000),
    maxPriorityFeePerGas: BigInt.from(50000000),
    maxFeePerGas: BigInt.from(690000000),
  );

  @override
  Future<UniFees> fees() async => fakeFees;

  @override
  Future<UniQuote> quote({
    required UniToken tokenIn,
    required UniToken tokenOut,
    required BigInt amountIn,
    String? owner,
  }) async {
    calls.add('quote ${tokenIn.symbol}->${tokenOut.symbol} $amountIn');
    if (mode == FakeQuoteMode.noPool) throw const UniswapNoRoute('noPool');
    // 1 ETH ≈ 322,127.46 WBEAM, as the v4 pool priced it.
    final ethToBeam = tokenIn.isEth;
    final out = ethToBeam
        ? amountIn * BigInt.from(32212746) ~/ BigInt.from(10).pow(12)
        : amountIn * BigInt.from(10).pow(12) ~/ BigInt.from(33000000);
    final impact = mode == FakeQuoteMode.bigImpact ? 0.142 : 0.0031;
    final hop = UniHop(
      v4EthWbeam,
      ethToBeam ? UniswapAddresses.nativeEth : kWbeamToken.address,
      ethToBeam ? kWbeamToken.address : UniswapAddresses.nativeEth,
    );
    if (mode == FakeQuoteMode.split && ethToBeam) {
      final viaV4 = amountIn * BigInt.from(7) ~/ BigInt.from(10);
      final viaV2 = amountIn - viaV4;
      final outV4 = out * BigInt.from(7) ~/ BigInt.from(10);
      final outV2 = out * BigInt.from(3) ~/ BigInt.from(10);
      return UniQuote(
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: amountIn,
        parts: [
          UniPart(
            route: UniRoute([hop]),
            amountIn: viaV4,
            amountOut: outV4,
            hopOutputs: [outV4],
            gas: BigInt.from(150000),
          ),
          UniPart(
            route: UniRoute([
              UniHop(
                v2WethWbeam,
                UniswapAddresses.weth,
                kWbeamToken.address,
              ),
            ]),
            amountIn: viaV2,
            amountOut: outV2,
            hopOutputs: [outV2],
            gas: BigInt.from(90000),
          ),
        ],
        gasEstimate: BigInt.from(320000),
        priceImpact: 0.0019,
        block: 26155432,
      );
    }
    return UniQuote.single(
      tokenIn: tokenIn,
      tokenOut: tokenOut,
      amountIn: amountIn,
      amountOut: mode == FakeQuoteMode.bigImpact
          ? out * BigInt.from(86) ~/ BigInt.from(100)
          : out,
      route: UniRoute([hop]),
      hopOutputs: [out],
      gasEstimate: BigInt.from(150000),
      priceImpact: impact,
      block: 26155432,
    );
  }

  @override
  Future<UniApproval> approvalFor(UniQuote quote, String owner) async =>
      UniApproval(
        quote.tokenIn.isEth || !approveNeeded
            ? UniApprovalKind.none
            : UniApprovalKind.approve,
        quote.tokenIn,
        quote.amountIn,
        BigInt.zero,
      );

  @override
  Future<UniTxRequest> approvalTx({
    required UniToken token,
    required BigInt amount,
    required String owner,
    UniFees? withFees,
  }) async => UniTxRequest(
    kind: UniTxKind.approve,
    to: token.address,
    data: Uint8List(4),
    value: BigInt.zero,
    gasLimit: BigInt.from(66000),
    fees: fakeFees,
  );

  @override
  Future<UniSwapReview> reviewSwap({
    required UniQuote quote,
    required int slippageBips,
    required String owner,
    UniFees? withFees,
  }) async => UniSwapReview(
    quote: quote,
    slippageBips: slippageBips,
    minimumOut: quote.minimumOut(slippageBips),
    deadline: BigInt.from(1791557000),
    needsPermit: UniswapPlanner.needsPermit(quote),
    gasLimit: BigInt.from(190000),
    fees: fakeFees,
    priceMoved: 0,
  );

  @override
  Future<UniPreparedSwap> finalizeSwap({
    required UniSwapReview review,
    required UniSwapSigner signer,
  }) async {
    calls.add('finalize');
    final plan = const UniswapPlanner().build(
      quote: review.quote,
      slippageBips: review.slippageBips,
      deadline: review.deadline,
    );
    return UniPreparedSwap(
      quote: review.quote,
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
      priceMoved: 0,
      permitSigned: review.needsPermit,
    );
  }

  @override
  Future<UniTxOutcome?> waitForReceipt(
    String hash, {
    String? owner,
    UniToken? tokenOut,
    Duration every = const Duration(seconds: 4),
    Duration limit = const Duration(minutes: 10),
  }) async => UniTxOutcome(
    hash: hash,
    success: !swapFails,
    blockNumber: 26155440,
    gasUsed: BigInt.from(122669),
    effectiveGasPrice: BigInt.from(370000000),
    received: tokenOut == null ? null : BigInt.parse('322127460965'),
  );

  @override
  Future<List<String>> partnersOf(UniToken token) async => [
    kas.address,
    wxtm.address,
    usdt.address,
    UniswapAddresses.nativeEth,
  ];

  @override
  Future<List<UniToken>> tokenInfo(List<String> addresses) async => [
    for (final a in addresses)
      if (a == kas.address)
        kas
      else if (a == wxtm.address)
        wxtm
      else if (a == fakeUsdt.address)
        fakeUsdt,
  ];

  @override
  Future<BigInt> balanceOf(UniToken token, String owner) async {
    if (token.isEth) return BigInt.parse('4200000000000000'); // 0.0042 ETH
    if (token.address == kWbeamToken.address) {
      return BigInt.from(1234) * beamUnit + BigInt.from(50000000);
    }
    return BigInt.zero;
  }
}

class FakeSigner implements UniSwapSigner {
  final List<UniTxRequest> sent = [];

  @override
  String get address => '0xbf2d26f518d5a17233c9d674828250d3df394374';

  @override
  Future<Uint8List> signDigest(Uint8List digest) async => Uint8List(65);

  @override
  Future<String> send(UniTxRequest tx) async {
    sent.add(tx);
    return '0x${'ab' * 32}';
  }
}

/// Counts PIN prompts; answers [answer].
class FakeUniGate {
  FakeUniGate({this.answer = true});

  bool? answer;
  final List<String> reasons = [];

  Future<bool?> call(BuildContext context, {required String reason}) async {
    reasons.add(reason);
    return answer;
  }
}

UniswapDeps fakeUniswapDeps({
  required bool desktop,
  FakeUniswapService? service,
  FakeSigner? signer,
  FakeUniGate? gate,
}) => UniswapDeps(
  service: service ?? FakeUniswapService(),
  signer: signer ?? FakeSigner(),
  walletTokens: () => const [kWbeamToken, usdt],
  fiatPerToken: (t) => t.isEthLike
      ? 2490.57
      : t.address == kWbeamToken.address
      ? 0.00786769
      : null,
  authenticate: (gate ?? FakeUniGate()).call,
  explorerTx: (h) => Uri.parse('https://etherscan.io/tx/$h'),
  isDesktop: desktop,
);
