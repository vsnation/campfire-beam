/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge's Ethereum side against a copy of mainnet (anvil, see
// ../../eth/uniswap/fork_support.dart): the five real pipes and tokens,
// fake money. For every pipe a fresh wallet plans a lock, sends each step
// through EthPipeService, reads its msgId back from the receipt, and the
// pipe's balance (WBEAM: its supply) moves by exactly value + fee. Then
// each pipe's own relayer pays a BEAM-side message and the paid flag
// flips; and the tokens' issuers freeze them, and the service says so.
//
// Every test puts the fork back as it found it (rollBackForkAfterEachTest),
// so the Uniswap fork tests see mainnet's state, not these locks.
@Timeout(Duration(minutes: 10))
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/ethereum/bridge/bridge_price_feed.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_calls.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_service.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import '../../eth/uniswap/fork_support.dart';
import 'lock_fixture.dart' show refKey;

late String? skip;

final rpc = forkRpc();

EthPipeService pipeService(ForkSigner who) => EthPipeService(
  rpc: rpc,
  signer: who,
  // Nothing here prices anything; a request would be a bug.
  priceFeed: BridgePriceFeed(clientFactory: () => throw StateError('price')),
);

BigInt hexInt(Object? h) {
  final s = h! as String;
  return s == '0x' ? BigInt.zero : BigInt.parse(s.substring(2), radix: 16);
}

String hexOf(BigInt v) => '0x${v.toRadixString(16)}';

Future<Map<String, dynamic>> mined(String hash) async {
  for (var i = 0; i < 150; i++) {
    final r = await rpc.call('eth_getTransactionReceipt', [hash]);
    if (r is Map && r['blockNumber'] != null) {
      return r.cast<String, dynamic>();
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('$hash not mined');
}

Future<BigInt> erc20Balance(String token, String who) async =>
    abiDecode(
          'uint256',
          await rpc.ethCall(token, encodeCall('balanceOf(address)', [who])),
        )[0]
        as BigInt;

Future<BigInt> ethBalanceOf(String who) async =>
    hexInt(await rpc.call('eth_getBalance', [who, 'latest']));

Future<BigInt> slot(String contract, int index) async => hexInt(
  await rpc.call('eth_getStorageAt', [
    contract,
    hexOf(BigInt.from(index)),
    'latest',
  ]),
);

/// What a fresh service says freezes [r] (a new one: no cached answer).
Future<List<String>> freezeReasons(BridgeRoute r) async => [
  for (final f in await pipeService(await ForkSigner.funded()).freezes(r))
    f.reason,
];

/// The pipe's next Ethereum-side message id: the uint64 at the bottom of
/// slot 0 (packed with the relayer in EthPipe, the token in ERC20Pipe).
Future<int> nextMsgId(BridgeRoute r) async =>
    (await slot(r.ethPipe, 0) & ((BigInt.one << 64) - BigInt.one)).toInt();

/// The pipe's relayer, from storage: EthPipe packs it above the counter in
/// slot 0; ERC20Pipe (and the WBEAM pipe) keep it alone in slot 1.
Future<String> relayerOf(BridgeRoute r) async {
  final mask = (BigInt.one << 160) - BigInt.one;
  final word = r.isNativeEth
      ? (await slot(r.ethPipe, 0) >> 64) & mask
      : await slot(r.ethPipe, 1) & mask;
  return '0x${word.toRadixString(16).padLeft(40, '0')}';
}

/// What [r]'s pipe holds (ETH or token); for WBEAM, its total supply (the
/// pipe burns and mints, it holds nothing).
Future<BigInt> pipeHoldings(BridgeRoute r) async {
  if (r.isNativeEth) return ethBalanceOf(r.ethPipe);
  if (r.isBeam) {
    return abiDecode(
          'uint256',
          await rpc.ethCall(r.ethToken!, selector('totalSupply()')),
        )[0]
        as BigInt;
  }
  return erc20Balance(r.ethToken!, r.ethPipe);
}

/// Gives [who] exactly [amount] of [token] by writing its balance slot
/// (found by trying the usual mapping slots and reading balanceOf back).
Future<void> setTokenBalance(String token, String who, BigInt amount) async {
  for (var i = 0; i < 20; i++) {
    final key = bytesToHex(keccak(abiEncode('address,uint256', [who, i])));
    final old = await rpc.call('eth_getStorageAt', [token, key, 'latest']);
    final value = '0x${amount.toRadixString(16).padLeft(64, '0')}';
    await rpc.call('anvil_setStorageAt', [token, key, value]);
    if (await erc20Balance(token, who) == amount) return;
    await rpc.call('anvil_setStorageAt', [
      token,
      key,
      '0x${hexInt(old).toRadixString(16).padLeft(64, '0')}',
    ]);
  }
  throw StateError('no balance slot found for $token');
}

/// Sends a transaction from [from] (impersonated, given ETH for gas).
Future<Map<String, dynamic>> sendAs(
  String from,
  String to,
  Uint8List data,
) async {
  await rpc.call('anvil_impersonateAccount', [from]);
  await rpc.call('anvil_setBalance', [from, hexOf(BigInt.from(10).pow(19))]);
  final hash = await rpc.call('eth_sendTransaction', [
    {'from': from, 'to': to, 'data': bytesToHex(data), 'gas': '0x7a120'},
  ]) as String;
  final r = await mined(hash);
  expect(r['status'], '0x1', reason: 'impersonated call reverted: $hash');
  return r;
}

/// What each route moves in the tests: on the grid, and well inside what
/// each pipe holds (so its relayer can pay it out too).
final amounts = <String, ({BigInt value, BigInt fee})>{
  'beam': (value: BigInt.from(10500000000), fee: BigInt.from(2000000)),
  'eth': (value: BigInt.from(10).pow(17), fee: BigInt.from(70000000000)),
  'wbtc': (value: BigInt.from(100000), fee: BigInt.one),
  'usdt': (value: BigInt.from(100000000), fee: BigInt.from(157)),
  'dai': (value: BigInt.from(10).pow(19), fee: BigInt.parse('156740000000000')),
};

/// Locks [route]'s amount from a fresh wallet, step by step through the
/// service, and checks what moved.
Future<void> lockThroughPipe(
  BridgeRoute route, {
  BigInt? existingAllowance,
  List<UniTxKind>? expectSteps,
}) async {
  final (:value, :fee) = amounts[route.id]!;
  final total = value + fee;
  final who = await ForkSigner.funded();
  final svc = pipeService(who);
  if (!route.isNativeEth) {
    await setTokenBalance(route.ethToken!, who.address, total);
    expect(await svc.balance(route), total);
  }
  if (existingAllowance != null) {
    // An approval left from before, sent straight from the key.
    final r = await mined(
      await who.send(
        UniTxRequest(
          kind: UniTxKind.approve,
          to: route.ethToken!,
          data: erc20ApproveCall(route.ethPipe, existingAllowance),
          value: BigInt.zero,
          gasLimit: BigInt.from(100000),
          fees: await walletFees(rpc),
        ),
      ),
    );
    expect(r['status'], '0x1');
  }
  expect(await svc.freezes(route), isEmpty);

  final id = await nextMsgId(route);
  final before = await pipeHoldings(route);
  final plan = await svc.planLock(
    route,
    value: value,
    fee: fee,
    receiverKey: refKey,
  );
  expect(
    plan.steps.map((t) => t.kind),
    expectSteps ??
        [if (!route.isNativeEth) UniTxKind.approve, UniTxKind.bridgeLock],
  );

  String? lockHash;
  for (final step in plan.steps) {
    final hash = await svc.send(step);
    final receipt = await mined(hash);
    expect(hexInt(receipt['gasUsed']) <= step.gasLimit, isTrue);
    if (step.kind == UniTxKind.bridgeLock) {
      lockHash = hash;
    } else {
      expect(await svc.succeeded(hash), isTrue, reason: '${step.kind}');
    }
  }
  final lock = await svc.lockResult(
    route,
    lockHash!,
    value: value,
    fee: fee,
    receiverKey: refKey,
  );
  expect(lock, isNotNull);
  expect(lock!.success, isTrue);
  expect(lock.msgId, id);
  expect(await nextMsgId(route), id + 1);

  final after = await pipeHoldings(route);
  expect(
    route.isBeam ? before - after : after - before,
    total,
    reason: route.isBeam ? 'WBEAM burnt' : 'the pipe took value + fee',
  );
  if (!route.isNativeEth) {
    expect(await svc.balance(route), BigInt.zero);
    expect(await svc.allowance(route), BigInt.zero, reason: 'exact approval');
  }
  // Read as another wallet's lock, it is refused.
  final other = Uint8List.fromList(refKey)..[0] ^= 1;
  await expectLater(
    svc.lockResult(route, lockHash, value: value, fee: fee, receiverKey: other),
    throwsA(isA<BridgeException>()),
  );
}

void main() {
  setUpAll(() async => skip = await forkUnavailable());
  rollBackForkAfterEachTest();

  group('e2b: lock in each pipe', () {
    for (final r in kBridgeRoutes) {
      test('${r.ethSymbol} → ${r.beamSymbol}', () async {
        if (skip != null) return markTestSkipped(skip!);
        await lockThroughPipe(r);
      });
    }

    test('USDT with an allowance already set: reset, approve, lock', () async {
      if (skip != null) return markTestSkipped(skip!);
      await lockThroughPipe(
        bridgeRouteById('usdt'),
        existingAllowance: BigInt.from(5),
        expectSteps: [
          UniTxKind.approveReset,
          UniTxKind.approve,
          UniTxKind.bridgeLock,
        ],
      );
    });

    test('a token that takes a direct change (DAI): no reset', () async {
      if (skip != null) return markTestSkipped(skip!);
      await lockThroughPipe(
        bridgeRouteById('dai'),
        existingAllowance: BigInt.from(5),
      );
    });
  });

  group('b2e: the paid flag', () {
    test('the verified historic messages', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = pipeService(await ForkSigner.funded());
      // Research note 06, Summary 13, plus WBTC and DAI checked the same
      // way with cast on this fork (block 26 155 400).
      final known = {
        ('eth', 107): true,
        ('eth', 108): false,
        ('usdt', 108): true,
        ('usdt', 109): false,
        ('beam', 639): true,
        ('beam', 640): false,
        ('beam', 563): false, // the uint64-overflow message, never paid
        ('wbtc', 19): true,
        ('wbtc', 20): false,
        ('dai', 40): true,
        ('dai', 41): false,
      };
      for (final MapEntry(key: (id, msg), value: paid) in known.entries) {
        expect(
          await svc.isPaid(bridgeRouteById(id), msg),
          paid,
          reason: '$id $msg',
        );
      }
    });

    for (final r in kBridgeRoutes) {
      test('${r.ethSymbol}: the relayer pays, the flag flips', () async {
        if (skip != null) return markTestSkipped(skip!);
        final svc = pipeService(await ForkSigner.funded());
        final (:value, :fee) = amounts[r.id]!;
        final relayer = await relayerOf(r);
        expect(relayer, isNot(kZeroAddress));
        final user = (await ForkSigner.funded(eth: BigInt.zero)).address;
        const msgId = 1000000; // far beyond any real BEAM-side id
        expect(await svc.isPaid(r, msgId), isFalse);

        final before = r.isNativeEth
            ? await ethBalanceOf(user)
            : await erc20Balance(r.ethToken!, user);
        // Note the order: (msgId, relayerFee, amount, receiver), not the
        // event's (msgId, amount, relayerFee, receiver).
        await sendAs(
          relayer,
          r.ethPipe,
          encodeCall('processRemoteMessage(uint64,uint256,uint256,address)', [
            msgId,
            fee,
            value,
            user,
          ]),
        );
        expect(await svc.isPaid(r, msgId), isTrue);
        expect(await svc.isPaid(r, msgId + 1), isFalse);
        final after = r.isNativeEth
            ? await ethBalanceOf(user)
            : await erc20Balance(r.ethToken!, user);
        expect(after - before, value, reason: 'the user is paid the amount');
      });
    }
  });

  group('freezes on the real tokens', () {
    test('today: nothing frozen', () async {
      if (skip != null) return markTestSkipped(skip!);
      final svc = pipeService(await ForkSigner.funded());
      for (final r in kBridgeRoutes) {
        expect(await svc.freezes(r), isEmpty, reason: r.id);
      }
    });

    test('WBEAM paused by its admin', () async {
      if (skip != null) return markTestSkipped(skip!);
      final wbeam = bridgeRouteById('beam').ethToken!;
      // The one key holding WBEAM's PAUSER_ROLE (and its admin and minter
      // roles): research note 06 §A.5, from the RoleGranted events.
      const admin = '0xd765e9dc55dc96e6b948f761f439d616ad341d4a';
      final pauser = keccak(Uint8List.fromList('PAUSER_ROLE'.codeUnits));
      final has = abiDecode(
        'bool',
        await rpc.ethCall(
          wbeam,
          encodeCall('hasRole(bytes32,address)', [pauser, admin]),
        ),
      )[0];
      expect(has, isTrue);
      await sendAs(admin, wbeam, selector('pause()'));
      expect(await freezeReasons(bridgeRouteById('beam')), [
        'WBEAM is paused by its issuer',
      ]);
      expect(await freezeReasons(bridgeRouteById('eth')), isEmpty);
    });

    test('USDT: Tether blacklists the pipe, pauses, charges a fee', () async {
      if (skip != null) return markTestSkipped(skip!);
      final usdt = bridgeRouteById('usdt');
      final owner =
          abiDecode(
                'address',
                await rpc.ethCall(usdt.ethToken!, selector('owner()')),
              )[0]
              as String;
      await sendAs(
        owner,
        usdt.ethToken!,
        encodeCall('addBlackList(address)', [usdt.ethPipe]),
      );
      expect(await freezeReasons(usdt), [
        "Tether has frozen the bridge's USDT",
      ]);
      await sendAs(owner, usdt.ethToken!, selector('pause()'));
      await sendAs(
        owner,
        usdt.ethToken!,
        encodeCall('setParams(uint256,uint256)', [10, 10]),
      );
      expect(await freezeReasons(usdt), [
        'Tether has paused USDT',
        "Tether has frozen the bridge's USDT",
        'USDT now charges a transfer fee',
      ]);
    });

    test('WBTC paused by its owner', () async {
      if (skip != null) return markTestSkipped(skip!);
      final wbtc = bridgeRouteById('wbtc');
      final owner =
          abiDecode(
                'address',
                await rpc.ethCall(wbtc.ethToken!, selector('owner()')),
              )[0]
              as String;
      await sendAs(owner, wbtc.ethToken!, selector('pause()'));
      expect(await freezeReasons(wbtc), ['WBTC is paused by its issuer']);
    });
  });
}
