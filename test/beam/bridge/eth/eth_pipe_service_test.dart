/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// EthPipeService without a network: a fake JSON-RPC answers what each
// test sets, and records what was asked. What is checked here is the
// service's own judgement — what it refuses, how long it trusts a freeze
// check, which steps a lock takes, what it lets the wallet sign. That the
// bytes are right on the real contracts is the fork test's job.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/ethereum/bridge/bridge_price_feed.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_calls.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_service.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import '../../eth/fake_socks.dart';
import 'lock_fixture.dart';

/// A contract call's answer: (success, return data).
typedef CallAnswer = (bool, Uint8List);

class FakeChain {
  final List<({String method, List<Object?> params})> requests = [];

  /// Throws for every request (the RPC is down).
  bool down = false;

  /// Answers a plain eth_call or one call inside a multicall. Null: revert.
  CallAnswer? Function(String to, Uint8List data, String? from) contract = (
    _,
    _,
    _,
  ) => null;

  Object? Function(List<Object?> params)? estimateGas;
  Object? Function(List<Object?> params)? receipt;
  Object? Function(List<Object?> params)? storage;
  Object? Function(List<Object?> params)? feeHistory;
  String balance = '0x0';

  int count(String method) => requests.where((r) => r.method == method).length;

  EthRpc rpc() => EthRpc(
    url: 'http://rpc.test',
    clientFactory: () => MockClient((req) async {
      final m = jsonDecode(req.body) as Map<String, dynamic>;
      final method = m['method'] as String;
      final params = (m['params'] as List).cast<Object?>();
      requests.add((method: method, params: params));
      if (down) throw const SocketException('down');
      Object? result;
      Map<String, Object?>? error;
      try {
        result = _answer(method, params);
      } on _Revert {
        error = {'code': 3, 'message': 'execution reverted'};
      }
      return http.Response(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': m['id'],
          if (error != null) 'error': error else 'result': result,
        }),
        200,
      );
    }),
  );

  Object? _answer(String method, List<Object?> params) {
    switch (method) {
      case 'eth_call':
        final tx = params[0]! as Map;
        final to = tx['to'] as String;
        final data = hexToBytes(tx['data'] as String);
        if (to == UniswapAddresses.multicall3) {
          final calls =
              abiDecode('(address,bool,bytes)[]', data.sublist(4)).first
                  as List;
          final out = [
            for (final c in calls)
              switch (contract(
                (c as List)[0] as String,
                c[2] as Uint8List,
                null,
              )) {
                (final ok, final bytes) => [ok, bytes],
                null => [false, Uint8List(0)],
              },
          ];
          return bytesToHex(abiEncode('(bool,bytes)[]', [out]));
        }
        final a = contract(to, data, tx['from'] as String?);
        if (a == null || !a.$1) throw _Revert();
        return bytesToHex(a.$2);
      case 'eth_estimateGas':
        final r = estimateGas?.call(params);
        if (r == null) throw _Revert();
        return r;
      case 'eth_feeHistory':
        return feeHistory?.call(params) ??
            {
              'baseFeePerGas': ['0x3b9aca00', '0x3b9aca00'],
              'reward': [
                ['0x5f5e100'],
              ],
            };
      case 'eth_getBalance':
        return balance;
      case 'eth_getTransactionReceipt':
        return receipt?.call(params);
      case 'eth_getStorageAt':
        return storage?.call(params);
    }
    throw StateError('unexpected $method');
  }
}

class _Revert implements Exception {}

class FakeSigner implements UniSwapSigner {
  FakeSigner([this.address = '0x00000000000000000000000000000000000000aa']);

  @override
  final String address;

  final List<UniTxRequest> sent = [];
  bool fail = false;

  @override
  Future<Uint8List> signDigest(Uint8List digest) => throw UnimplementedError();

  @override
  Future<String> send(UniTxRequest tx) async {
    sent.add(tx);
    if (fail) throw const SocketException('broadcast, then lost');
    return '0x${'ab' * 32}';
  }
}

Uint8List word(Object v) => abiEncode('uint256', [v]);

final fees = UniFees(
  baseFee: BigInt.one,
  maxPriorityFeePerGas: BigInt.one,
  maxFeePerGas: BigInt.two,
);

Matcher bridgeError(BridgeErrorCode code) =>
    throwsA(isA<BridgeException>().having((e) => e.code, 'code', code));

final beam = bridgeRouteById('beam');
final eth = bridgeRouteById('eth');
final wbtc = bridgeRouteById('wbtc');
final usdt = bridgeRouteById('usdt');
final dai = bridgeRouteById('dai');

void main() {
  late FakeChain chain;
  late FakeSigner signer;
  late DateTime now;

  EthPipeService service({BridgePriceFeed? feed}) => EthPipeService(
    rpc: chain.rpc(),
    signer: signer,
    priceFeed:
        feed ??
        BridgePriceFeed(clientFactory: () => throw StateError('no prices')),
    clock: () => now,
  );

  setUp(() {
    chain = FakeChain();
    signer = FakeSigner();
    now = DateTime.utc(2026, 10, 9, 12);
  });

  group('freezes', () {
    /// Token state the multicall reads.
    void tokens({
      bool wbeamPaused = false,
      bool wbtcPaused = false,
      bool usdtPaused = false,
      bool blacklisted = false,
      int basisPoints = 0,
    }) {
      chain.contract = (to, data, _) {
        final sel = bytesToHex(data.sublist(0, 4));
        if (sel == '0x5c975abb') {
          final paused = {
            beam.ethToken: wbeamPaused,
            wbtc.ethToken: wbtcPaused,
            usdt.ethToken: usdtPaused,
          }[to]!;
          return (true, word(paused ? 1 : 0));
        }
        if (sel == '0xe47d6060') {
          expect(to, usdt.ethToken);
          expect(abiDecode('address', data.sublist(4)).single, usdt.ethPipe);
          return (true, word(blacklisted ? 1 : 0));
        }
        if (sel == '0xdd644f72') return (true, word(basisPoints));
        return null;
      };
    }

    List<String> reasons(List<BridgeFreeze> f) => [for (final x in f) x.reason];

    test('ETH and DAI have nothing to check (no request)', () async {
      final s = service();
      expect(await s.freezes(eth), isEmpty);
      expect(await s.freezes(dai), isEmpty);
      expect(chain.requests, isEmpty);
    });

    test('all clear: one multicall per route', () async {
      tokens();
      final s = service();
      for (final r in [beam, wbtc, usdt]) {
        expect(await s.freezes(r), isEmpty, reason: r.id);
      }
      expect(chain.count('eth_call'), 3);
    });

    test('each freeze, in plain words', () async {
      tokens(wbeamPaused: true);
      expect(reasons(await service().freezes(beam)), [
        'WBEAM is paused by its issuer',
      ]);
      tokens(wbtcPaused: true);
      expect(reasons(await service().freezes(wbtc)), [
        'WBTC is paused by its issuer',
      ]);
      tokens(usdtPaused: true, blacklisted: true, basisPoints: 10);
      expect(reasons(await service().freezes(usdt)), [
        'Tether has paused USDT',
        "Tether has frozen the bridge's USDT",
        'USDT now charges a transfer fee',
      ]);
      tokens(blacklisted: true);
      expect(reasons(await service().freezes(usdt)), [
        "Tether has frozen the bridge's USDT",
      ]);
    });

    test('kept 10 minutes; then asked again', () async {
      tokens();
      final s = service();
      await s.freezes(usdt);
      now = now.add(const Duration(minutes: 9, seconds: 59));
      await s.freezes(usdt);
      expect(chain.count('eth_call'), 1);
      tokens(blacklisted: true);
      now = now.add(const Duration(seconds: 1));
      expect(await s.freezes(usdt), hasLength(1));
      expect(chain.count('eth_call'), 2);
    });

    test('RPC down: the last answer for up to an hour, then refused', () async {
      tokens();
      final s = service();
      await s.freezes(usdt);
      chain.down = true;
      now = now.add(const Duration(minutes: 59));
      expect(await s.freezes(usdt), isEmpty);
      now = now.add(const Duration(minutes: 1));
      await expectLater(s.freezes(usdt), bridgeError(BridgeErrorCode.network));
    });

    test('RPC down and nothing known: refused (fail closed)', () async {
      chain.down = true;
      await expectLater(
        service().freezes(beam),
        bridgeError(BridgeErrorCode.network),
      );
    });

    test('a check that fails or answers nonsense: refused', () async {
      // isBlackListed reverts.
      tokens();
      final clear = chain.contract;
      chain.contract = (to, data, from) =>
          bytesToHex(data.sublist(0, 4)) == '0xe47d6060'
          ? null
          : clear(to, data, from);
      await expectLater(
        service().freezes(usdt),
        bridgeError(BridgeErrorCode.frozen),
      );
      // paused() says 2.
      chain.contract = (_, _, _) => (true, word(2));
      await expectLater(
        service().freezes(wbtc),
        bridgeError(BridgeErrorCode.frozen),
      );
      // A short answer.
      chain.contract = (_, _, _) => (true, Uint8List(31));
      await expectLater(
        service().freezes(beam),
        bridgeError(BridgeErrorCode.frozen),
      );
    });
  });

  group('relayer gas', () {
    test('reads eth_feeHistory(0xa, latest, [50])', () async {
      chain.feeHistory = (p) {
        expect(p, [
          '0xa',
          'latest',
          [50],
        ]);
        return {
          'baseFeePerGas': ['0x29cf7a1b'],
          'reward': [
            ['0x1dcd6500'],
          ],
        };
      };
      final gas = await service().relayerGas();
      expect(gas.baseFee, BigInt.from(0x29cf7a1b));
      expect(gas.tip, BigInt.from(500000000));
      expect(gas.at, now);
    });

    test('no answer, or a useless one: no price', () async {
      chain.feeHistory = (_) => {'baseFeePerGas': <String>[]};
      await expectLater(
        service().relayerGas(),
        bridgeError(BridgeErrorCode.noPrice),
      );
      chain.down = true;
      await expectLater(
        service().relayerGas(),
        bridgeError(BridgeErrorCode.noPrice),
      );
    });
  });

  group('balances', () {
    test('ETH from eth_getBalance, a token from balanceOf', () async {
      chain.balance = '0xde0b6b3a7640000';
      chain.contract = (to, data, _) {
        expect(to, usdt.ethToken);
        expect(
          bytesToHex(data),
          bytesToHex(encodeCall('balanceOf(address)', [signer.address])),
        );
        return (true, word(4157110300));
      };
      final s = service();
      expect(await s.ethBalance(), BigInt.from(10).pow(18));
      expect(await s.balance(eth), BigInt.from(10).pow(18));
      expect(await s.balance(usdt), BigInt.from(4157110300));
    });

    test('RPC down: network', () async {
      chain.down = true;
      await expectLater(
        service().balance(dai),
        bridgeError(BridgeErrorCode.network),
      );
    });
  });

  group('planLock refuses before asking anything', () {
    Future<void> refuses(
      BridgeRoute r,
      Object value,
      Object fee, {
      Uint8List? key,
      BridgeErrorCode code = BridgeErrorCode.badAmount,
    }) async {
      BigInt big(Object v) => v is BigInt ? v : BigInt.from(v as int);
      await expectLater(
        service().planLock(
          r,
          value: big(value),
          fee: big(fee),
          receiverKey: key ?? refKey,
        ),
        bridgeError(code),
        reason: '${r.id} $value $fee',
      );
    }

    test('nothing to move, a negative fee', () async {
      await refuses(beam, 0, 2000000);
      await refuses(beam, -1, 2000000);
      await refuses(beam, 100, -1);
      expect(chain.requests, isEmpty);
    });

    test('off the 8-decimal grid (ETH, DAI: steps of 10^10)', () async {
      final step = BigInt.from(10).pow(10);
      await refuses(eth, step + BigInt.one, step * BigInt.from(7));
      await refuses(eth, step, BigInt.from(63011920796));
      await refuses(dai, BigInt.from(10).pow(18) - BigInt.one, step);
      expect(chain.requests, isEmpty);
    });

    test('a sum that wraps the pipe, or that BEAM cannot hold', () async {
      final max = (BigInt.one << 256) - BigInt.one;
      // Grid 1 (WBTC): the overflow messages of 2026-05-17.
      await refuses(wbtc, max, 1);
      await refuses(usdt, max - BigInt.from(4471397801), 4471397802);
      // 2^63 groth.
      await refuses(beam, BigInt.one << 63, 0);
      await refuses(beam, (BigInt.one << 62), BigInt.one << 62);
      // ETH: 2^63 groth is 2^63 × 10^10 wei.
      await refuses(eth, (BigInt.one << 63) * BigInt.from(10).pow(10), 0);
      expect(chain.requests, isEmpty);
    });

    test('a receiver nobody can claim with', () async {
      for (final key in [
        Uint8List(33),
        refKey.sublist(0, 32),
        Uint8List.fromList(refKey)..[32] = 0x23,
      ]) {
        await refuses(
          beam,
          refValue,
          refFee,
          key: key,
          code: BridgeErrorCode.badPipe,
        );
      }
      expect(chain.requests, isEmpty);
    });

    test('a zero fee is allowed (the relayer delivers it)', () {
      EthPipeService.checkLockAmounts(
        wbtc,
        value: BigInt.from(1000),
        fee: BigInt.zero,
        receiverKey: refKey,
      );
    });
  });

  group('planLock steps', () {
    late BigInt allowance;
    late bool takesNonZeroChange;
    late List<String> estimated;

    setUp(() {
      allowance = BigInt.zero;
      takesNonZeroChange = true;
      estimated = [];
      chain.contract = (to, data, from) {
        final sel = bytesToHex(data.sublist(0, 4));
        if (sel == bytesToHex(selector('allowance(address,address)'))) {
          final v = abiDecode('address,address', data.sublist(4));
          expect(v, [signer.address, bridgeRouteForEthToken(to)!.ethPipe]);
          return (true, word(allowance));
        }
        if (sel == kApproveSelector) {
          expect(from, signer.address);
          return takesNonZeroChange ? (true, word(1)) : null;
        }
        return null;
      };
      chain.estimateGas = (p) {
        final tx = p[0]! as Map;
        final sel = (tx['data'] as String).substring(0, 10);
        estimated.add(sel);
        if (sel == kSendFundsSelector) {
          return tx['to'] == eth.ethPipe ? '0x7986' : '0xd365'; // 31110, 54117
        }
        if (sel == kApproveSelector) {
          final amount =
              abiDecode(
                    'address,uint256',
                    hexToBytes(tx['data'] as String).sublist(4),
                  )[1]
                  as BigInt;
          // USDT: non-zero to non-zero reverts while the allowance is set.
          if (!takesNonZeroChange && amount > BigInt.zero) return null;
          return '0xb3b0'; // 46000
        }
        return null;
      };
    });

    test('ETH: one sendFunds carrying value + fee, gas measured', () async {
      final value = BigInt.from(10).pow(17);
      final fee = BigInt.from(70000000000);
      final plan = await service().planLock(
        eth,
        value: value,
        fee: fee,
        receiverKey: refKey,
      );
      final tx = plan.steps.single;
      expect(tx.kind, UniTxKind.bridgeLock);
      expect(tx.to, eth.ethPipe);
      expect(tx.value, value + fee);
      expect(
        bytesToHex(tx.data),
        bytesToHex(sendFundsCall(value, fee, refKey)),
      );
      expect(tx.gasLimit, BigInt.from(31110 + 20000));
      expect(tx.note, 'Bridge: move 0.1 ETH to BEAM');
      expect(plan.fees.baseFee, BigInt.from(1000000000));
      expect(plan.maxGasCost, tx.gasLimit * plan.fees.maxFeePerGas);
      expect(chain.count('eth_call'), 0, reason: 'no allowance for ETH');
    });

    test('a token without allowance: exact approve, then sendFunds at the '
        'safe limit (its gas cannot be measured yet)', () async {
      final plan = await service().planLock(
        beam,
        value: refValue,
        fee: refFee,
        receiverKey: refKey,
      );
      expect(plan.steps.map((t) => t.kind), [
        UniTxKind.approve,
        UniTxKind.bridgeLock,
      ]);
      final approve = plan.steps.first;
      expect(approve.to, beam.ethToken);
      expect(approve.value, BigInt.zero);
      expect(
        bytesToHex(approve.data),
        bytesToHex(erc20ApproveCall(beam.ethPipe, refValue + refFee)),
      );
      expect(approve.gasLimit, BigInt.from(46000 + 20000));
      expect(approve.note, 'Approve 105.02 WBEAM for the BEAM bridge');
      final lock = plan.steps.last;
      expect(lock.value, BigInt.zero);
      expect(lock.gasLimit, kSendFundsGasToken);
      expect(lock.note, 'Bridge: move 105 WBEAM to BEAM');
      expect(estimated, [kApproveSelector], reason: 'sendFunds not measured');
    });

    test('never more than value + fee, never unlimited', () async {
      allowance = BigInt.from(5);
      for (final r in [beam, wbtc, dai]) {
        final value = r.ethGrid * BigInt.from(1000);
        final plan = await service().planLock(
          r,
          value: value,
          fee: r.ethGrid,
          receiverKey: refKey,
        );
        final approve = plan.steps.firstWhere(
          (t) => t.kind == UniTxKind.approve,
        );
        final amount =
            abiDecode('address,uint256', approve.data.sublist(4))[1] as BigInt;
        expect(amount, value + r.ethGrid, reason: r.id);
      }
    });

    test(
      'USDT with an allowance set: reset to 0, approve, sendFunds',
      () async {
        allowance = BigInt.from(1);
        takesNonZeroChange = false;
        final plan = await service().planLock(
          usdt,
          value: BigInt.from(100000000),
          fee: BigInt.from(157),
          receiverKey: refKey,
        );
        expect(plan.steps.map((t) => t.kind), [
          UniTxKind.approveReset,
          UniTxKind.approve,
          UniTxKind.bridgeLock,
        ]);
        expect(
          bytesToHex(plan.steps[0].data),
          bytesToHex(erc20ApproveCall(usdt.ethPipe, BigInt.zero)),
        );
        expect(plan.steps[0].gasLimit, BigInt.from(66000));
        expect(
          plan.steps[0].note,
          'Reset the USDT permission of the BEAM bridge to 0',
        );
        // Its estimate reverts until the reset is mined.
        expect(plan.steps[1].gasLimit, kApproveGas);
        expect(
          plan.steps[1].note,
          'Approve 100.000157 USDT for the BEAM bridge',
        );
        expect(plan.steps[2].gasLimit, kSendFundsGasToken);
      },
    );

    test('a token that takes the change: one approve, no reset', () async {
      allowance = BigInt.from(1);
      final plan = await service().planLock(
        dai,
        value: BigInt.from(10).pow(18),
        fee: BigInt.parse('156740000000000'),
        receiverKey: refKey,
      );
      expect(plan.steps.map((t) => t.kind), [
        UniTxKind.approve,
        UniTxKind.bridgeLock,
      ]);
    });

    test('allowance already enough: sendFunds alone, gas measured', () async {
      allowance = refValue + refFee;
      final plan = await service().planLock(
        beam,
        value: refValue,
        fee: refFee,
        receiverKey: refKey,
      );
      final tx = plan.steps.single;
      expect(tx.kind, UniTxKind.bridgeLock);
      expect(tx.gasLimit, BigInt.from(54117 + 20000));
    });

    test('sendFunds that reverts (no coins yet): the safe limit', () async {
      allowance = refValue + refFee;
      chain.estimateGas = (_) => null;
      final plan = await service().planLock(
        beam,
        value: refValue,
        fee: refFee,
        receiverKey: refKey,
      );
      expect(plan.steps.single.gasLimit, kSendFundsGasToken);
      final ethPlan = await service().planLock(
        eth,
        value: BigInt.from(10).pow(17),
        fee: BigInt.from(70000000000),
        receiverKey: refKey,
      );
      expect(ethPlan.steps.single.gasLimit, kSendFundsGasEth);
    });

    test('RPC down: network, nothing planned', () async {
      chain.down = true;
      await expectLater(
        service().planLock(
          beam,
          value: refValue,
          fee: refFee,
          receiverKey: refKey,
        ),
        bridgeError(BridgeErrorCode.network),
      );
    });
  });

  group('send', () {
    test('a planned step goes to the wallet once', () async {
      chain.estimateGas = (_) => '0x7986';
      final s = service();
      final plan = await s.planLock(
        eth,
        value: BigInt.from(10).pow(17),
        fee: BigInt.from(70000000000),
        receiverKey: refKey,
      );
      final tx = plan.steps.single;
      expect(await s.send(tx), '0x${'ab' * 32}');
      expect(signer.sent.single, same(tx));
      await expectLater(s.send(tx), bridgeError(BridgeErrorCode.alreadySent));
      expect(signer.sent, hasLength(1));
    });

    test('a wallet that throws: still never sent twice', () async {
      signer.fail = true;
      final s = service();
      final tx = UniTxRequest(
        kind: UniTxKind.approve,
        to: usdt.ethToken!,
        data: erc20ApproveCall(usdt.ethPipe, BigInt.from(100)),
        value: BigInt.zero,
        gasLimit: kApproveGas,
        fees: fees,
      );
      await expectLater(s.send(tx), throwsA(isA<SocketException>()));
      await expectLater(s.send(tx), bridgeError(BridgeErrorCode.alreadySent));
    });

    group('only bridge transactions', () {
      UniTxRequest tx(String to, Uint8List data, [BigInt? value]) =>
          UniTxRequest(
            kind: UniTxKind.bridgeLock,
            to: to,
            data: data,
            value: value ?? BigInt.zero,
            gasLimit: kSendFundsGasToken,
            fees: fees,
          );
      final v = BigInt.from(1000);
      final f = BigInt.from(10);

      test('accepted: exact approvals of a pipe, sendFunds as planned', () {
        for (final r in kBridgeRoutes) {
          if (!r.isNativeEth) {
            EthPipeService.checkBridgeTx(
              tx(r.ethToken!, erc20ApproveCall(r.ethPipe, v)),
            );
          }
          EthPipeService.checkBridgeTx(
            tx(
              r.ethPipe,
              sendFundsCall(v, f, refKey),
              r.isNativeEth ? v + f : null,
            ),
          );
        }
      });

      test('refused: anything else', () {
        final refused = <UniTxRequest>[
          // Approving someone else (Permit2), or the wrong pipe.
          tx(usdt.ethToken!, erc20ApproveCall(UniswapAddresses.permit2, v)),
          tx(usdt.ethToken!, erc20ApproveCall(dai.ethPipe, v)),
          // A transfer, not an approval.
          tx(
            usdt.ethToken!,
            encodeCall('transfer(address,uint256)', [usdt.ethPipe, v]),
          ),
          // ETH with the wrong msg.value; a token pipe with ETH attached.
          tx(eth.ethPipe, sendFundsCall(v, f, refKey), v),
          tx(dai.ethPipe, sendFundsCall(v, f, refKey), v + f),
          // An unclaimable receiver; a sum that wraps.
          tx(dai.ethPipe, sendFundsCall(v, f, Uint8List(33))),
          tx(
            wbtc.ethPipe,
            sendFundsCall((BigInt.one << 256) - BigInt.one, BigInt.one, refKey),
          ),
          // sendFunds to a token, or to an unknown contract.
          tx(dai.ethToken!, sendFundsCall(v, f, refKey)),
          tx(
            '0x0000000000000000000000000000000000000001',
            sendFundsCall(v, f, refKey),
          ),
          // Trailing bytes after the call.
          tx(
            dai.ethPipe,
            Uint8List.fromList([...sendFundsCall(v, f, refKey), 0]),
          ),
          tx(dai.ethPipe, Uint8List(3)),
        ];
        for (final (i, t) in refused.indexed) {
          expect(
            () => EthPipeService.checkBridgeTx(t),
            throwsA(isA<BridgeException>()),
            reason: 'case $i',
          );
        }
      });

      test('refused before the wallet sees it', () async {
        final s = service();
        await expectLater(
          s.send(tx(dai.ethPipe, sendFundsCall(v, f, refKey), v + f)),
          bridgeError(BridgeErrorCode.unexpectedTransaction),
        );
        expect(signer.sent, isEmpty);
      });
    });
  });

  group('after sending', () {
    Map<String, dynamic> fixture() => refReceipt();

    test('lockResult: null while pending, then the msgId', () async {
      signer = FakeSigner(refOwner);
      final s = service();
      chain.receipt = (_) => null;
      expect(
        await s.lockResult(
          beam,
          refHash,
          value: refValue,
          fee: refFee,
          receiverKey: refKey,
        ),
        isNull,
      );
      chain.receipt = (p) {
        expect(p, [refHash]);
        return fixture();
      };
      final lock = await s.lockResult(
        beam,
        refHash,
        value: refValue,
        fee: refFee,
        receiverKey: refKey,
      );
      expect(lock!.msgId, 222);
      expect(lock.success, isTrue);
      expect(await s.succeeded(refHash), isTrue);
    });

    test('lockResult: not this wallet\'s lock, or another hash', () async {
      chain.receipt = (_) => fixture();
      await expectLater(
        service().lockResult(
          beam,
          refHash,
          value: refValue,
          fee: refFee,
          receiverKey: refKey,
        ),
        bridgeError(BridgeErrorCode.unexpectedTransaction),
      );
      signer = FakeSigner(refOwner);
      await expectLater(
        service().lockResult(
          beam,
          '0x${'11' * 32}',
          value: refValue,
          fee: refFee,
          receiverKey: refKey,
        ),
        bridgeError(BridgeErrorCode.unexpectedTransaction),
      );
    });

    test('succeeded: null, true, false', () async {
      final s = service();
      chain.receipt = (_) => {'blockNumber': null};
      expect(await s.succeeded(refHash), isNull);
      chain.receipt = (_) => {'blockNumber': '0x1', 'status': '0x0'};
      expect(await s.succeeded(refHash), isFalse);
      chain.receipt = (_) => {'blockNumber': '0x1', 'status': '0x1'};
      expect(await s.succeeded(refHash), isTrue);
    });

    test('isPaid reads the pipe\'s map at the route\'s slot', () async {
      chain.storage = (p) {
        final key = p[1] as String;
        if (p[0] == eth.ethPipe && key == processedKey(107, 1)) return '0x1';
        if (p[0] == usdt.ethPipe && key == processedKey(108, 2)) {
          return '0x${'0' * 63}1';
        }
        return '0x${'0' * 64}';
      };
      final s = service();
      expect(await s.isPaid(eth, 107), isTrue);
      expect(await s.isPaid(eth, 108), isFalse);
      expect(await s.isPaid(usdt, 108), isTrue);
      expect(await s.isPaid(usdt, 109), isFalse);
      // Slot 1 of an ERC-20 pipe is its relayer, not the map.
      expect(await s.isPaid(usdt, 107), isFalse);
      expect(chain.requests.last.params.last, 'latest');
    });

    test('isPaid: a value a bool never has is refused', () async {
      chain.storage = (_) => '0x2';
      await expectLater(
        service().isPaid(beam, 639),
        bridgeError(BridgeErrorCode.badPipe),
      );
      chain.down = true;
      await expectLater(
        service().isPaid(beam, 639),
        bridgeError(BridgeErrorCode.network),
      );
    });
  });

  group('prices', () {
    late List<Uri> asked;
    late Map<String, Object?> answer;
    late int status;

    BridgePriceFeed feed({bool Function()? allowed}) => BridgePriceFeed(
      clientFactory: () => MockClient((req) async {
        asked.add(req.url);
        return http.Response(jsonEncode(answer), status);
      }),
      lookupsAllowed: allowed,
      clock: () => now,
    );

    setUp(() {
      asked = [];
      status = 200;
      answer = {
        'ethereum': {'usd': 2487.25},
        'beam': {'usd': 0.00783632},
        'wrapped-bitcoin': {'usd': 82567},
        'tether': {'usd': 0.999262},
        'dai': {'usd': 0.999917},
      };
    });

    test('one request for every bridged asset, kept two minutes', () async {
      final s = service(feed: feed());
      final p = await s.prices(['ethereum', 'beam']);
      expect(p.of('beam'), 0.00783632);
      expect(p.of('wrapped-bitcoin'), 82567);
      expect(p.at, now);
      expect(asked.single.path, '/api/v3/simple/price');
      expect(asked.single.queryParameters, {
        'ids': 'beam,dai,ethereum,tether,wrapped-bitcoin',
        'vs_currencies': 'usd',
      });
      now = now.add(const Duration(minutes: 1, seconds: 59));
      await s.prices(['ethereum', 'tether']);
      expect(asked, hasLength(1));
      now = now.add(const Duration(seconds: 1));
      await s.prices(['ethereum']);
      expect(asked, hasLength(2));
    });

    test('a missing or zero price: no price (never a guess)', () async {
      answer.remove('tether');
      answer['dai'] = {'usd': 0};
      final f = feed();
      await expectLater(
        f.usd(['ethereum', 'tether']),
        bridgeError(BridgeErrorCode.noPrice),
      );
      await expectLater(f.usd(['dai']), bridgeError(BridgeErrorCode.noPrice));
      expect((await f.usd(['beam'])).of('beam'), 0.00783632);
    });

    test('busy, broken, or switched off: no price', () async {
      status = 429;
      await expectLater(
        feed().usd(['beam']),
        bridgeError(BridgeErrorCode.noPrice),
      );
      status = 200;
      answer = {'status': 'not json prices'};
      await expectLater(
        feed().usd(['beam']),
        bridgeError(BridgeErrorCode.noPrice),
      );
      asked.clear();
      await expectLater(
        feed(allowed: () => false).usd(['beam']),
        bridgeError(BridgeErrorCode.noPrice),
      );
      expect(asked, isEmpty);
      await expectLater(feed().usd(['beam&x=1']), throwsArgumentError);
    });

    test('Tor on but down: nothing is sent, no price', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((req) async {
        requests++;
        await req.response.close();
      });
      final f = BridgePriceFeed(
        clientFactory: () => EthRpcHttpClient(
          route: (_) => throw const EthTorNotConnectedException(),
        ),
        baseUrl: 'http://127.0.0.1:${server.port}/api/v3',
      );
      await expectLater(
        f.usd(['beam']),
        throwsA(
          isA<BridgeException>()
              .having((e) => e.code, 'code', BridgeErrorCode.noPrice)
              .having((e) => e.message, 'message', contains('Tor')),
        ),
      );
      expect(requests, 0);
    });

    test('Tor on: through the proxy, by name', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final hosts = <String>[];
      server.listen((req) async {
        hosts.add(req.headers.host ?? '');
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(answer));
        await req.response.close();
      });
      final tor = await FakeSocksProxy.start(
        target: (host: InternetAddress.loopbackIPv4, port: server.port),
      );
      addTearDown(tor.close);
      final f = BridgePriceFeed(
        clientFactory: () => EthRpcHttpClient(route: (_) => tor.info),
        baseUrl: 'http://api.coingecko.com/api/v3',
      );
      expect((await f.usd(['beam'])).of('beam'), 0.00783632);
      // The proxy got the name (Tor resolves it; this device never did).
      expect(tor.connects.single, (
        addressType: 0x03,
        host: 'api.coingecko.com',
        port: 80,
      ));
      expect(hosts.single, 'api.coingecko.com');
    });
  });
}
