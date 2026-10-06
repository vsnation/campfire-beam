/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// invoke_contract calls on one wallet-api connection run one at a time
// (the core runs one app shader at a time), and an invoke result's all-zero
// txid is "no transaction", not a transaction id.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/models/beam_call_results.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

/// A wallet-api that holds every invoke_contract until the test releases
/// it, and fails like API 6.0 does if a second one arrives meanwhile.
class _OneShaderAtATime {
  final pending = <Completer<Object?>>[];
  final started = <String>[];
  var running = 0;
  var maxRunning = 0;

  Future<Object?> invoke(Map<String, Object?> params) async {
    if (running > 0) {
      throw const BeamRpcException(
        -32603,
        'Previous shader call is still in progress',
      );
    }
    running++;
    if (running > maxRunning) maxRunning = running;
    started.add(params['args']! as String);
    final c = Completer<Object?>();
    pending.add(c);
    try {
      return await c.future;
    } finally {
      running--;
    }
  }

  /// Lets the oldest held call answer with [reply] (or fail with [error]).
  void release({Object? reply, Object? error}) {
    final c = pending.removeAt(0);
    if (error != null) {
      c.completeError(error);
    } else {
      c.complete(reply ?? {'output': '{"n": ${started.length}}'});
    }
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('invokeContract is serialized per transport', () {
    late _OneShaderAtATime core;
    late FakeTransport t;

    setUp(() {
      core = _OneShaderAtATime();
      t = FakeTransport({
        'invoke_contract': core.invoke,
        'get_confirmations_count': {'count': 5},
        'process_invoke_data': {'txid': 'ab' * 16},
      });
    });

    test('two concurrent invokes are sent one after the other', () async {
      final api = BeamApi(t);
      final first = api.invokeContract(createTx: false, args: 'a=1');
      final second = api.invokeContract(createTx: false, args: 'a=2');
      await _settle();
      // Only the first reached the core; the second waits on our side.
      expect(t.callsTo('invoke_contract'), hasLength(1));
      expect(core.started, ['a=1']);

      core.release();
      expect((await first).output, '{"n": 1}');
      await _settle();
      expect(t.callsTo('invoke_contract'), hasLength(2));
      expect(core.started, ['a=1', 'a=2']);

      core.release();
      expect((await second).output, '{"n": 2}');
      expect(core.maxRunning, 1);
    });

    test('order is kept, and a failed call does not block the next',
        () async {
      final api = BeamApi(t);
      final calls = [
        for (var i = 0; i < 5; i++)
          api
              .invokeContract(createTx: false, args: 'i=$i')
              .then<Object>((r) => r.output, onError: (Object e) => e),
      ];
      for (var i = 0; i < 5; i++) {
        await _settle();
        expect(core.started, hasLength(i + 1));
        if (i == 2) {
          core.release(error: const BeamRpcException(-32019, 'boom'));
        } else {
          core.release();
        }
      }
      expect(core.started, ['i=0', 'i=1', 'i=2', 'i=3', 'i=4']);
      expect(core.maxRunning, 1);
      final results = await Future.wait(calls);
      expect(results[1], '{"n": 2}');
      expect(results[2], isA<BeamRpcException>());
      expect(results[3], '{"n": 4}');
    });

    test('separate BeamApi objects on one transport share the queue',
        () async {
      // Each contract service builds its own BeamApi over the wallet's one
      // connection; they must not overlap either.
      final dex = BeamApi(t);
      final bans = BeamApi(t);
      final a = dex.invokeContract(createTx: false, args: 'dex');
      final b = bans.invokeContract(createTx: true, args: 'bans');
      await _settle();
      expect(core.started, ['dex']);
      core.release();
      await a;
      await _settle();
      expect(core.started, ['dex', 'bans']);
      core.release();
      await b;
      expect(core.maxRunning, 1);
    });

    test('a different transport has its own queue', () async {
      final other = _OneShaderAtATime();
      final t2 = FakeTransport({'invoke_contract': other.invoke});
      final a = BeamApi(t).invokeContract(createTx: false, args: 'one');
      final b = BeamApi(t2).invokeContract(createTx: false, args: 'two');
      await _settle();
      expect(core.started, ['one']);
      expect(other.started, ['two']);
      core.release();
      other.release();
      await Future.wait([a, b]);
    });

    test('other calls and process_invoke_data do not wait for a shader',
        () async {
      final api = BeamApi(t);
      final view = api.invokeContract(createTx: false, args: 'slow=1');
      await _settle();
      expect(core.started, ['slow=1']);
      // A plain read and a confirmed send go straight through while the
      // shader is still running.
      expect(await api.getConfirmationsCount(), 5);
      expect(await api.processInvokeData(const [1, 2, 3]), 'ab' * 16);
      core.release();
      await view;
    });

    test('an invalid request is refused before it joins the queue',
        () async {
      final api = BeamApi(t);
      final held = api.invokeContract(createTx: false, args: 'held');
      await expectLater(
        api.invokeContract(createTx: false, contractBytes: const []),
        throwsArgumentError,
      );
      await _settle();
      expect(core.started, ['held']);
      core.release();
      await held;
      expect(t.callsTo('invoke_contract'), hasLength(1));
    });

    test('the timeout is passed for the call itself', () async {
      final api = BeamApi(t);
      final a = api.invokeContract(
        createTx: false,
        args: 'x',
        timeout: const Duration(seconds: 7),
      );
      await _settle();
      expect(
        t.callsTo('invoke_contract').single.timeout,
        const Duration(seconds: 7),
      );
      core.release();
      await a;
    });
  });

  group('BeamInvokeResult.txId', () {
    test('the all-zero TxID of a create_tx:false call is null', () {
      // Recorded from wallet-api (BANS `receive`, create_tx:false).
      final r = BeamInvokeResult.fromJson(const {
        'output': '{"error": "no funds"}',
        'txid': '00000000000000000000000000000000',
      });
      expect(r.txId, isNull);
      expect(r.rawData, isNull);
    });

    test('alongside raw_data the zero TxID is null too', () {
      final r = BeamInvokeResult.fromJson(const {
        'output': '{}',
        'raw_data': [1, 2],
        'txid': '00000000000000000000000000000000',
      });
      expect(r.txId, isNull);
      expect(r.rawData, [1, 2]);
    });

    test('a real tx id is kept; empty and missing are null', () {
      expect(
        BeamInvokeResult.fromJson(const {
          'output': '',
          'txid': '0000000000000000000000000000000a',
        }).txId,
        '0000000000000000000000000000000a',
      );
      expect(
        BeamInvokeResult.fromJson(const {'output': '', 'txid': ''}).txId,
        isNull,
      );
      expect(BeamInvokeResult.fromJson(const {'output': ''}).txId, isNull);
    });
  });
}
