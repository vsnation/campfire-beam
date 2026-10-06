/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../contracts/dex/dex_fixtures.dart';
import 'dapp_invoke_builder.dart';
import 'dapp_session_fixtures.dart';

void main() {
  const g = BigInt.from;

  late FakeTransport t;
  late ScriptedPolicy policy;

  setUp(() {
    t = FakeTransport({
      'process_invoke_data': (Map<String, Object?> p) => {'txid': txId(1)},
      'tx_status': (Map<String, Object?> p) => {'txId': p['txId'], 'status': 3},
    });
    policy = ScriptedPolicy();
  });

  Future<String> contractCall(
    String vector, {
    String? confirm,
    Object id = 1,
    bool approve = true,
    List<int>? data,
  }) async {
    final s = testSession(t, policy);
    final before = policy.shown.length;
    final pending = s.handle(
      rq(id, 'process_invoke_data', {
        'data': data ?? rawDataVector(vector),
        'confirm_comment': ?confirm,
      }),
    );
    await policy.waitShown(before + 1);
    policy.answer(before, approve);
    return pending;
  }

  group('contract consent from DEX raw_data vectors', () {
    test('a trade: pays BEAM, receives FOMO, 0.011 BEAM fee', () async {
      final res = await contractCall(
        'trade_plain',
        confirm: 'Swap 0.1 BEAM for FOMO',
      );
      final r = policy.shown.single;
      expect(r.kind, DappConsentKind.contract);
      expect(r.dapp.name, 'Test dApp');
      expect(r.dapp.origin, testOrigin);
      expect(r.pays, [DappAssetAmount(0, g(10000000))]);
      expect(r.receives, [DappAssetAmount(174, g(80368764))]);
      expect(r.fee, g(1100000));
      expect(r.fee >= BeamContractFee.minimum, isTrue);
      expect(r.contractIds, [dexCid]);
      expect(r.calls.single.method, 7);
      expect(r.calls.single.shaderComment, 'Amm trade');
      expect(r.dappMessage, 'Swap 0.1 BEAM for FOMO');
      expect(r.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(r.isFeeOnly, isFalse);

      expect(resultOf(res), {'txid': txId(1)});
      final sent = t.lastParams('process_invoke_data');
      expect(sent['data'], rawDataVector('trade_plain'));
      expect(sent['confirm_comment'], 'Swap 0.1 BEAM for FOMO');
    });

    test('without confirm_comment the shader comment is the message', () async {
      await contractCall('trade_plain');
      expect(policy.shown.single.dappMessage, 'Amm trade');
    });

    // The recorded add-liquidity vector is dependent (HFT), which a dApp
    // may no longer submit (dapp_contract_policy_test.dart); the same
    // amounts as a plain call.
    test('add liquidity: two assets out, LP token in', () async {
      await contractCall(
        '',
        data: invokeData([
          invokeEntry(
            contractId: dexCid,
            method: 5,
            spend: {0: 10000000, 174: 81173706, 175: -33347624},
          ),
        ]),
      );
      final r = policy.shown.single;
      expect(r.pays, [
        DappAssetAmount(0, g(10000000)),
        DappAssetAmount(174, g(81173706)),
      ]);
      expect(r.receives, [DappAssetAmount(175, g(33347624))]);
      expect(r.fee, g(1100000));
      expect(r.required, {0: g(11100000), 174: g(81173706)});
    });

    test('pool_create: the declared charge raises the fee', () async {
      await contractCall('create_pool');
      final r = policy.shown.single;
      expect(r.fee, g(1471000));
      expect(r.pays, [DappAssetAmount(0, g(1000000000))]);
      expect(r.receives, isEmpty);
    });

    test('withdraw: LP token out, both assets in', () async {
      await contractCall('withdraw');
      final r = policy.shown.single;
      expect(r.pays, [DappAssetAmount(175, g(100000000))]);
      expect(r.receives, [
        DappAssetAmount(0, g(29987143)),
        DappAssetAmount(174, g(243416758)),
      ]);
    });

    test('a deployment is shown as one', () async {
      await contractCall(
        '',
        data: invokeData([invokeEntry(contractId: null, method: 0)]),
      );
      final r = policy.shown.single;
      expect(r.calls.single.deploys, isTrue);
      expect(r.contractIds, isEmpty);
    });

    test('shortfall names what is missing', () async {
      await contractCall('trade_plain');
      final r = policy.shown.single;
      expect(r.shortfall({0: g(11100000)}), isEmpty);
      expect(r.shortfall({0: g(11000000)}), {0: g(100000)});
      expect(r.shortfall({}), {0: g(11100000)});
    });

    test('raw_data it cannot fully read is refused without a prompt', () async {
      final trade = rawDataVector('trade_plain');
      final advanced = [
        0x81,
        0x04,
        0x01,
        0x00,
        0x00,
        0x80,
        0x87,
        ...trade.sublist(2),
      ];
      final s = testSession(t, policy);
      for (final bad in [
        advanced,
        [...trade, 0],
        trade.sublist(0, 10),
      ]) {
        final res = await s.handle(rq(1, 'process_invoke_data', {'data': bad}));
        expect(errorCode(res), -32020);
      }
      expect(policy.shown, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });
  });

  group('approval', () {
    test('rejection is -32021 and nothing executes', () async {
      final res = await contractCall('trade_plain', approve: false);
      expect(errorCode(res), -32021);
      expect(decode(res)['id'], 1);
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('a policy error is a rejection', () async {
      final s = testSession(t, _ThrowingPolicy());
      final res = await s.handle(
        rq(1, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      expect(errorCode(res), -32021);
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('two concurrent requests are shown one after the other', () async {
      final s = testSession(t, policy);
      final first = s.handle(
        rq('a', 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      final second = s.handle(
        rq('b', 'process_invoke_data', {'data': rawDataVector('withdraw')}),
      );
      await policy.waitShown(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(policy.shown, hasLength(1), reason: 'second waits its turn');
      expect(policy.shown.single.requestId, 'a');

      policy.answer(0, true);
      await policy.waitShown(2);
      expect(policy.shown[1].requestId, 'b');
      expect(policy.maxShowing, 1);
      policy.answer(1, false);

      expect(resultOf(await first), {'txid': txId(1)});
      expect(errorCode(await second), -32021);
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });

    test('a change after approval is refused, not executed', () async {
      final s = testSession(t, policy)
        ..debugBeforeExecute = (p) {
          final data = List<Object?>.of(p['data']! as List<Object?>);
          data[data.length - 1] = ((data.last! as int) ^ 1);
          p['data'] = data;
        };
      final pending = s.handle(
        rq(1, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      await policy.waitShown(1);
      policy.answer(0, true);
      final res = await pending;
      expect(errorCode(res), -32021);
      expect(errorData(res), 'The request changed after it was approved');
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('changing only the dApp text after approval is refused too', () async {
      final s = testSession(t, policy)
        ..debugBeforeExecute = (p) => p['confirm_comment'] = 'different';
      final pending = s.handle(
        rq(1, 'process_invoke_data', {
          'data': rawDataVector('trade_plain'),
          'confirm_comment': 'shown',
        }),
      );
      await policy.waitShown(1);
      policy.answer(0, true);
      expect(errorCode(await pending), -32021);
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('at most 5 waiting per dApp; the sixth is throttled', () async {
      final s = testSession(t, policy);
      final pending = [
        for (var i = 0; i < 5; i++)
          s.handle(
            rq(i, 'process_invoke_data', {
              'data': rawDataVector('trade_plain'),
            }),
          ),
      ];
      await policy.waitShown(1);
      final sixth = await s.handle(
        rq(6, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      expect(errorCode(sixth), -32014);
      await s.close();
      for (final p in pending) {
        expect(errorCode(await p), -32021);
      }
    });

    test('closing the session withdraws its requests', () async {
      final queue = DappConsentQueue(policy);
      final a = testSession(t, policy, queue: queue);
      final b = testSession(
        t,
        policy,
        queue: queue,
        identity: testIdentity(guid: 'ab' * 16, name: 'Other'),
      );
      final fromA = a.handle(
        rq(1, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      final fromB = b.handle(
        rq(2, 'process_invoke_data', {'data': rawDataVector('withdraw')}),
      );
      await policy.waitShown(1);
      final shownA = policy.shown.single;
      var cancelled = false;
      unawaited(shownA.cancelled.then((_) => cancelled = true));

      await a.close();
      expect(errorCode(await fromA), -32021);
      expect(cancelled, isTrue);
      // A's sheet freed the queue even though the UI never answered it.
      await policy.waitShown(2);
      expect(policy.shown[1].dapp.name, 'Other');
      policy.answer(1, true);
      expect(resultOf(await fromB), {'txid': txId(1)});
      // A late "yes" to the withdrawn sheet does nothing.
      policy.answer(0, true);
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });

    test('a sheet closed without approving is a rejection', () async {
      final queue = DappConsentQueue(_NullPolicy());
      final s = testSession(t, policy, queue: queue);
      final res = await s.handle(
        rq(1, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
      );
      expect(errorCode(res), -32021);
    });
  });
}

class _ThrowingPolicy implements DappConsentPolicy {
  @override
  Future<bool> approve(DappConsentRequest request) =>
      Future.error(StateError('sheet crashed'));
}

/// A sheet dismissed by back, swipe or an outside tap.
class _NullPolicy implements DappConsentPolicy {
  @override
  Future<bool> approve(DappConsentRequest request) async => false;
}
