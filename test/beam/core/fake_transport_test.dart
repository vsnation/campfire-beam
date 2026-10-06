/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'fixtures.dart';

void main() {
  test('replays a recorded envelope and records the call', () async {
    final t = FakeTransport({'get_version': fixtureEnvelope('get_version')});
    final r = (await t.call('get_version'))! as Map;
    expect(r['api_version'], '7.4');
    expect(t.calls.single.method, 'get_version');
    expect(t.calls.single.params, isEmpty);
  });

  test('a handler sees the params and may be async', () async {
    final t = FakeTransport({
      'tx_send': (Map<String, Object?> p) async => {'txId': 'id-${p['value']}'},
    });
    expect(await t.call('tx_send', {'value': 5}), {'txId': 'id-5'});
    expect(t.lastParams('tx_send'), {'value': 5});
  });

  test('error envelopes and exceptions are thrown', () async {
    final t = FakeTransport({
      'tx_cancel': const BeamRpcException(-32001, 'Invalid tx status'),
      'tx_delete': {
        'jsonrpc': '2.0',
        'id': 1,
        'error': {'code': -32004, 'message': 'Invalid tx id'},
      },
    });
    await expectLater(
      t.call('tx_cancel'),
      throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', -32001)),
    );
    await expectLater(
      t.call('tx_delete'),
      throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', -32004)),
    );
  });

  test('unknown methods answer -32601 like the core', () async {
    final t = FakeTransport();
    await expectLater(
      t.call('nope'),
      throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', -32601)),
    );
    expect(t.callsTo('nope'), hasLength(1));
  });

  test('emit delivers events; disconnect and close behave', () async {
    final t = FakeTransport({'wallet_status': 1});
    final got = <BeamEvent>[];
    t.events.listen(got.add);
    t.emit('ev_txs_changed', {'change': 1});
    t.emitEnvelope({
      'jsonrpc': '2.0',
      'id': 'ev_system_state',
      'result': {'current_height': 7},
    });
    await Future<void>.delayed(Duration.zero);
    expect(got.map((e) => e.name), ['ev_txs_changed', 'ev_system_state']);
    expect(() => t.emit('txs'), throwsArgumentError);

    t.simulateDisconnect();
    expect(t.isConnected, isFalse);
    await expectLater(
      t.call('wallet_status'),
      throwsA(isA<BeamConnectionException>()),
    );
    await t.connect();
    expect(await t.call('wallet_status'), 1);

    await t.close();
    await expectLater(t.connect(), throwsA(isA<BeamConnectionException>()));
  });

  test('reply() changes an answer between calls', () async {
    final t = FakeTransport({'tx_list': <Object?>[]});
    expect(await t.call('tx_list'), isEmpty);
    t.reply('tx_list', [1]);
    expect(await t.call('tx_list'), [1]);
  });
}
