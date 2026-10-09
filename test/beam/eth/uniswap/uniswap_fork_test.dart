/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Uniswap swap against a copy of mainnet (fork_support.dart): pools are
// found, priced and swapped through for real — ETH ⇄ WBEAM on the v4 pool,
// tokens paid with a Permit2 signature, two-pool routes, and routes that
// mix v2, v3 and v4 so the router has to wrap and unwrap ETH between
// pools. Every swap checks the coins that actually arrived against the
// quote and the user's minimum.
//
// The first run against a new fork is slow: the fork fetches every pool's
// state from its source node one read at a time (a real node answers the
// same reads in one call).
@Timeout(Duration(minutes: 15))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_discovery.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_quoter.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import 'fork_support.dart';

const wbeam = UniToken(
  address: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
  symbol: 'WBEAM',
  decimals: 8,
);
const usdc = UniToken(
  address: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
  symbol: 'USDC',
  decimals: 6,
);
const usdt = UniToken(
  address: '0xdac17f958d2ee523a2206206994597c13d831ec7',
  symbol: 'USDT',
  decimals: 6,
);
const weth = UniToken(
  address: UniswapAddresses.weth,
  symbol: 'WETH',
  decimals: 18,
);

/// KAS (wrapped Kaspa): on Uniswap only in a v4 pool against WBEAM, so
/// ETH → KAS needs two pools.
const kas = UniToken(
  address: '0x112b08621e27e10773ec95d250604a041f36c582',
  symbol: 'KAS',
  decimals: 8,
);

final eth = BigInt.from(10).pow(18);

late String? skip;

Future<UniTxOutcome> swap(
  UniswapService svc,
  ForkSigner who,
  UniQuote q, {
  int slippageBips = 100,
}) async {
  final approval = await svc.approvalFor(q, who.address);
  if (approval.kind == UniApprovalKind.resetThenApprove) {
    final reset = await svc.approvalTx(
      token: q.tokenIn,
      amount: BigInt.zero,
      owner: who.address,
    );
    expect((await svc.waitForReceipt(await who.send(reset)))!.success, isTrue);
  }
  if (approval.kind != UniApprovalKind.none) {
    final tx = await svc.approvalTx(
      token: q.tokenIn,
      amount: q.amountIn,
      owner: who.address,
    );
    expect((await svc.waitForReceipt(await who.send(tx)))!.success, isTrue);
  }
  final prepared = await svc.prepareSwap(
    quote: q,
    slippageBips: slippageBips,
    signer: who,
  );
  expect(prepared.permitSigned, !q.tokenIn.isEth);
  final hash = await who.send(prepared.tx);
  final out = await svc.waitForReceipt(
    hash,
    owner: who.address,
    tokenOut: q.tokenOut,
    every: const Duration(milliseconds: 200),
  );
  expect(out, isNotNull);
  expect(out!.success, isTrue, reason: 'swap reverted: $hash');
  expect(out.received, isNotNull);
  expect(out.received! >= prepared.minimumOut, isTrue);
  // Nothing else trades on the fork, so the swap gets its quote exactly.
  expect(out.received, prepared.quote.amountOut);
  expect(out.gasUsed <= prepared.tx.gasLimit, isTrue);
  return out;
}

void main() {
  setUpAll(() async => skip = await forkUnavailable());
  rollBackForkAfterEachTest();

  UniswapService service() => UniswapService(rpc: forkRpc());

  test('finds the WBEAM pools on v2 and v4', () async {
    if (skip != null) return markTestSkipped(skip!);
    final d = UniswapDiscovery(rpc: forkRpc());
    final native = await d.poolsBetween(
      UniswapAddresses.nativeEth,
      wbeam.address,
    );
    expect(
      native.whereType<UniV4Pool>().map((p) => p.id),
      contains(
        '0xce7ff1b044aaee5bf9e632a3b537e10fbca0222004ee50348d492c1e5b54419c',
      ),
    );
    final wrapped = await d.poolsBetween(UniswapAddresses.weth, wbeam.address);
    expect(
      wrapped.whereType<UniV2Pool>().map((p) => p.pair),
      contains('0xc821395f890913b9ce7415b36db10ddc5281c53a'),
    );
    final states = await d.liveState([...native, ...wrapped]);
    expect(states.values.where((s) => s.isLive), isNotEmpty);
  });

  test('ETH → WBEAM: best route, swapped, exactly the quote arrives', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final q = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: wbeam,
      amountIn: eth ~/ BigInt.from(100),
    );
    expect(q.amountOut > BigInt.zero, isTrue);
    // 0.01 ETH in a pool this deep moves the price well under 5%.
    expect(q.priceImpact, isNotNull);
    expect(q.priceImpact!, lessThan(0.05));
    await swap(svc, who, q);
    expect(await svc.balanceOf(wbeam, who.address), q.amountOut);
  });

  test('WBEAM → ETH: exact approval, Permit2 signature, ETH arrives', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final buy = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: wbeam,
      amountIn: eth ~/ BigInt.from(50),
    );
    await swap(svc, who, buy);
    final have = await svc.balanceOf(wbeam, who.address);
    final sell = await svc.quote(
      tokenIn: wbeam,
      tokenOut: UniToken.eth,
      amountIn: have,
    );
    final approval = await svc.approvalFor(sell, who.address);
    expect(approval.kind, UniApprovalKind.approve);
    await swap(svc, who, sell);
    expect(await svc.balanceOf(wbeam, who.address), BigInt.zero);
    // Exactly the amount was approved, and the swap used all of it.
    expect(
      await svc.approvalFor(sell, who.address).then((a) => a.current),
      BigInt.zero,
    );
  });

  test('ETH → USDC and back (deep v3/v4 pools)', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final buy = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: usdc,
      amountIn: eth ~/ BigInt.from(10),
    );
    await swap(svc, who, buy);
    final have = await svc.balanceOf(usdc, who.address);
    final sell = await svc.quote(
      tokenIn: usdc,
      tokenOut: UniToken.eth,
      amountIn: have,
    );
    await swap(svc, who, sell);
  });

  test('ETH → KAS: the best of the direct v3 pools and the routes '
      'through WBEAM, swapped', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final q = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: kas,
      amountIn: eth ~/ BigInt.from(1000),
    );
    await swap(svc, who, q);
  });

  test('ETH → KAS without its direct pools goes through WBEAM (two v4 '
      'pools in one router command) and arrives', () async {
    if (skip != null) return markTestSkipped(skip!);
    final rpc = forkRpc();
    final svc = UniswapService(
      rpc: rpc,
      // KAS also trades directly with ETH (v3) and with the stablecoins;
      // hide all of those so WBEAM is the only way through.
      discovery: _WithoutPair(rpc, UniswapAddresses.nativeEth, kas.address)
        ..hide(UniswapAddresses.weth, kas.address)
        ..hide(usdc.address, kas.address)
        ..hide(usdt.address, kas.address)
        ..hide('0x6b175474e89094c44da98b954eedeac495271d0f', kas.address)
        ..hide('0x2260fac5e5542a773aa44fbcfedf7c193bc2c599', kas.address),
    );
    final who = await ForkSigner.funded();
    final q = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: kas,
      amountIn: eth ~/ BigInt.from(1000),
    );
    expect(q.route.hops.length, 2);
    expect(q.route.hops.first.currencyOut, wbeam.address);
    await swap(svc, who, q);
  });

  test(
    'a v4 pool whose hook quotes a price it does not give is skipped',
    () async {
      // Seen on mainnet 2026-10-09: this USDC/WETH 0.3% pool's hook tells the
      // quoter ~20% more USDC than any other pool, and the real swap reverts.
      if (skip != null) return markTestSkipped(skip!);
      const trap = '0x0e6690b6bbcc55a8b7c7da2f0ee43e2e2bf840c0';
      final svc = service();
      final who = await ForkSigner.funded();
      final q = await svc.quote(
        tokenIn: UniToken.eth,
        tokenOut: usdc,
        amountIn: BigInt.from(6) * BigInt.from(10).pow(14),
        owner: who.address,
      );
      expect(
        q.pools.whereType<UniV4Pool>().map((p) => p.hooks),
        isNot(contains(trap)),
      );
      await swap(svc, who, q);
    },
  );

  test('USDT: a non-zero allowance is reset to zero first', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final buy = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: usdt,
      amountIn: eth ~/ BigInt.from(20),
    );
    await swap(svc, who, buy);
    // Leave a small allowance behind, as an earlier approval might.
    final small = await svc.approvalTx(
      token: usdt,
      amount: BigInt.one,
      owner: who.address,
    );
    expect((await svc.waitForReceipt(await who.send(small)))!.success, isTrue);
    final have = await svc.balanceOf(usdt, who.address);
    final sell = await svc.quote(
      tokenIn: usdt,
      tokenOut: wbeam,
      amountIn: have,
    );
    expect(
      (await svc.approvalFor(sell, who.address)).kind,
      UniApprovalKind.resetThenApprove,
    );
    await swap(svc, who, sell);
  });

  group('routes mixing versions (the router wraps and unwraps ETH)', () {
    Future<UniQuote> forced(
      UniswapService svc,
      UniToken tokenIn,
      UniToken tokenOut,
      BigInt amountIn,
      List<UniHop> hops,
    ) => svc.quoter.requote(
      UniQuote.single(
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        amountIn: amountIn,
        amountOut: BigInt.zero,
        route: UniRoute(hops),
        hopOutputs: const [],
        gasEstimate: BigInt.zero,
        block: 0,
      ),
    );

    final v2WbeamWeth = UniV2Pool(
      pair: '0xc821395f890913b9ce7415b36db10ddc5281c53a',
      currency0: UniswapAddresses.weth,
      currency1: wbeam.address,
    );
    final v4EthWbeam = UniV4Pool.key(
      currency0: UniswapAddresses.nativeEth,
      currency1: wbeam.address,
      fee: 10000,
      tickSpacing: 200,
      hooks: UniswapAddresses.nativeEth,
    );
    // USDC/WETH 0.05% on v3 (factory.getPool, checked on chain).
    const v3UsdcWeth = UniV3Pool(
      pool: '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
      currency0: '0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48',
      currency1: UniswapAddresses.weth,
      fee: 500,
      tickSpacing: 10,
    );

    test('USDC → (v3) WETH → unwrap → (v4) ETH → WBEAM', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded();
      await swap(
        svc,
        who,
        await svc.quote(
          tokenIn: UniToken.eth,
          tokenOut: usdc,
          amountIn: eth ~/ BigInt.from(10),
        ),
      );
      final have = await svc.balanceOf(usdc, who.address);
      final q = await forced(svc, usdc, wbeam, have, [
        UniHop(v3UsdcWeth, usdc.address, UniswapAddresses.weth),
        UniHop(v4EthWbeam, UniswapAddresses.nativeEth, wbeam.address),
      ]);
      await swap(svc, who, q);
    });

    test('WBEAM → (v4) ETH → wrap → (v3) USDC', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded();
      await swap(
        svc,
        who,
        await svc.quote(
          tokenIn: UniToken.eth,
          tokenOut: wbeam,
          amountIn: eth ~/ BigInt.from(50),
        ),
      );
      final have = await svc.balanceOf(wbeam, who.address);
      final q = await forced(svc, wbeam, usdc, have, [
        UniHop(v4EthWbeam, wbeam.address, UniswapAddresses.nativeEth),
        UniHop(v3UsdcWeth, UniswapAddresses.weth, usdc.address),
      ]);
      await swap(svc, who, q);
    });

    test('ETH → wrap → (v2) WBEAM; WBEAM → (v2) WETH → unwrap → ETH', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded();
      final buy = await forced(
        svc,
        UniToken.eth,
        wbeam,
        eth ~/ BigInt.from(1000),
        [UniHop(v2WbeamWeth, UniswapAddresses.weth, wbeam.address)],
      );
      await swap(svc, who, buy);
      final have = await svc.balanceOf(wbeam, who.address);
      final sell = await forced(svc, wbeam, UniToken.eth, have, [
        UniHop(v2WbeamWeth, wbeam.address, UniswapAddresses.weth),
      ]);
      await swap(svc, who, sell);
    });

    test('WETH (the token) → unwrap → (v4) WBEAM', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded();
      // Wrap 0.01 ETH by hand: WETH.deposit().
      final dep = UniTxRequest(
        kind: UniTxKind.swap,
        to: UniswapAddresses.weth,
        data: selector('deposit()'),
        value: eth ~/ BigInt.from(100),
        gasLimit: BigInt.from(60000),
        fees: await svc.fees(),
      );
      expect((await svc.waitForReceipt(await who.send(dep)))!.success, isTrue);
      final q = await forced(svc, weth, wbeam, eth ~/ BigInt.from(100), [
        UniHop(v4EthWbeam, UniswapAddresses.nativeEth, wbeam.address),
      ]);
      await swap(svc, who, q);
    });
  });

  group('one swap shared between pools', () {
    // Front-running feeds on a swap that moves one pool a lot. A large
    // purchase is spread over every WBEAM pool that adds to it, each
    // share with its own minimum on its own pool.
    UniswapService singleRouteOnly() {
      final rpc = forkRpc();
      final d = UniswapDiscovery(rpc: rpc);
      return UniswapService(
        rpc: rpc,
        discovery: d,
        quoter: UniswapQuoter(rpc: rpc, discovery: d, maxParts: 1),
      );
    }

    test('2 ETH → WBEAM: shared, more than any one route gives, and '
        'exactly the quote arrives', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded(eth: eth * BigInt.from(5));
      final amount = eth * BigInt.two;
      final q = await svc.quote(
        tokenIn: UniToken.eth,
        tokenOut: wbeam,
        amountIn: amount,
      );
      expect(q.isSplit, isTrue, reason: 'one route: ${q.route.id}');
      final ids = q.pools.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'a pool used twice');
      expect(q.parts.fold(BigInt.zero, (s, p) => s + p.amountIn), amount);
      final single = await singleRouteOnly().quote(
        tokenIn: UniToken.eth,
        tokenOut: wbeam,
        amountIn: amount,
      );
      expect(q.amountOut > single.amountOut, isTrue);
      expect(q.priceImpact!, lessThan(single.priceImpact!));
      for (final p in q.parts) {
        final pools = p.route.pools.map((x) => '${x.version.label}/${x.fee}');
        printOnFailure(
          '${p.amountIn * BigInt.from(100) ~/ amount}% '
          '${pools.join(' > ')} → ${p.amountOut}',
        );
      }
      await swap(svc, who, q);
      expect(await svc.balanceOf(wbeam, who.address), q.amountOut);

      // Selling it all back: one Permit2 signature pays every share.
      final sell = await svc.quote(
        tokenIn: wbeam,
        tokenOut: UniToken.eth,
        amountIn: q.amountOut,
      );
      expect(sell.isSplit, isTrue);
      await swap(svc, who, sell);
      expect(await svc.balanceOf(wbeam, who.address), BigInt.zero);
    });

    test('a small purchase stays in one pool: a second would cost more gas '
        'than it saves', () async {
      if (skip != null) return markTestSkipped(skip!);
      final q = await service().quote(
        tokenIn: UniToken.eth,
        tokenOut: wbeam,
        amountIn: eth ~/ BigInt.from(2000),
      );
      expect(q.parts.length, 1);
    });

    test('USDC → WBEAM, shared between the direct pools and the routes '
        'through ETH', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = service();
      final who = await ForkSigner.funded(eth: eth * BigInt.from(5));
      final buy = await svc.quote(
        tokenIn: UniToken.eth,
        tokenOut: usdc,
        amountIn: eth,
      );
      await swap(svc, who, buy);
      final have = await svc.balanceOf(usdc, who.address);
      final q = await svc.quote(tokenIn: usdc, tokenOut: wbeam, amountIn: have);
      final ids = q.pools.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      await swap(svc, who, q);
    });
  });

  test('a price that moved past the protection stops the swap', () async {
    if (skip != null) return markTestSkipped(skip!);
    final svc = service();
    final who = await ForkSigner.funded();
    final whale = await ForkSigner.funded(eth: BigInt.from(10).pow(21));
    final q = await svc.quote(
      tokenIn: UniToken.eth,
      tokenOut: wbeam,
      amountIn: eth ~/ BigInt.from(100),
    );
    // Someone buys a lot of WBEAM first, in the same pools.
    await swap(
      svc,
      whale,
      await svc.quoter.requote(q, amountIn: eth * BigInt.two),
      slippageBips: 5000,
    );
    await expectLater(
      svc.prepareSwap(quote: q, slippageBips: 50, signer: who),
      throwsA(isA<UniPriceMoved>()),
    );
  });

  test('an RPC error is an EthRpcError, not a crash', () async {
    if (skip != null) return markTestSkipped(skip!);
    await expectLater(
      forkRpc().call('eth_noSuchMethod', const []),
      throwsA(isA<EthRpcError>()),
    );
  });
}

/// Discovery that pretends some pairs have no pool, to make the quoter go
/// through a middle token.
class _WithoutPair extends UniswapDiscovery {
  _WithoutPair(EthRpc rpc, String a, String b) : super(rpc: rpc) {
    hide(a, b);
  }

  final Set<String> _hidden = {};

  void hide(String a, String b) => _hidden.add(_key(a, b));

  static String _key(String a, String b) {
    final (x, y) = sortCurrencies(a, b);
    return '$x/$y';
  }

  @override
  Future<List<UniPool>> poolsBetween(String a, String b, {int? head}) async =>
      _hidden.contains(_key(a, b))
      ? const []
      : super.poolsBetween(a, b, head: head);
}
