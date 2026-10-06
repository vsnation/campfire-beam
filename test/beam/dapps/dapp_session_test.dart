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
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'dapp_session_fixtures.dart';

void main() {
  const g = BigInt.from;
  late FakeTransport t;
  late ScriptedPolicy policy;
  var sent = 0;

  setUp(() {
    sent = 0;
    policy = ScriptedPolicy();
    t = FakeTransport({
      'validate_address': {
        'is_valid': true,
        'is_mine': false,
        'type': 'regular',
      },
      'tx_send': (Map<String, Object?> p) => {'txId': txId(++sent)},
      'tx_status': (Map<String, Object?> p) => {'txId': p['txId']},
      'export_payment_proof': {'payment_proof': 'ab'},
      'invoke_contract': {'output': '{}', 'raw_data': <int>[]},
      'get_version': {'api_version': '7.4'},
      'sign_message': {'signature': 'aa'},
    });
  });

  Future<String> send(
    DappSession s,
    Map<String, Object?> params, {
    bool approve = true,
  }) async {
    final before = policy.shown.length;
    final pending = s.handle(rq('send', 'tx_send', params));
    await policy.waitShown(before + 1);
    policy.answer(before, approve);
    return pending;
  }

  group('envelope and gate', () {
    test('errors use the core envelope and echo the id', () async {
      final s = testSession(t, policy);
      final notAllowed = await s.handle(rq('call-7', 'get_utxo', {}));
      expect(decode(notAllowed), {
        'jsonrpc': '2.0',
        'id': 'call-7',
        'error': {'code': -32020, 'message': 'Call is not allowed'},
      });
      expect(errorCode(await s.handle(rq(8, 'export_owner_key'))), -32601);
      final bad = await s.handle('{nope');
      expect(errorCode(bad), -32600);
      expect(decode(bad).containsKey('id'), isFalse);
      expect(t.calls, isEmpty, reason: 'nothing reached the wallet');
    });

    test('results come back under the dApp\'s id', () async {
      final s = testSession(t, policy);
      final res = await s.handle(rq(41, 'get_version'));
      expect(decode(res), {
        'jsonrpc': '2.0',
        'id': 41,
        'result': {'api_version': '7.4'},
      });
    });

    test('invoke_contract reaches the wallet without contract_file and '
        'with create_tx false', () async {
      final s = testSession(t, policy);
      await s.handle(
        rq(1, 'invoke_contract', {
          'contract_file': '/etc/passwd',
          'contract': [0, 97, 115, 109],
          'args': 'role=manager,action=view',
        }),
      );
      expect(t.lastParams('invoke_contract'), {
        'contract': [0, 97, 115, 109],
        'args': 'role=manager,action=view',
        'create_tx': false,
      });
      final refused = await s.handle(
        rq(2, 'invoke_contract', {'args': 'x=y', 'create_tx': true}),
      );
      expect(errorCode(refused), -32020);
      expect(t.callsTo('invoke_contract'), hasLength(1));
    });

    test('shader calls run one at a time', () async {
      final gates = <Completer<Object?>>[];
      t.reply('invoke_contract', (Map<String, Object?> p) {
        final c = Completer<Object?>();
        gates.add(c);
        return c.future;
      });
      final s = testSession(t, policy);
      final a = s.handle(
        rq(1, 'invoke_contract', {
          'contract': [1],
          'args': 'a=1',
        }),
      );
      final b = s.handle(rq(2, 'invoke_contract', {'args': 'a=2'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.callsTo('invoke_contract'), hasLength(1));
      gates[0].complete({'output': '1'});
      await a;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(t.callsTo('invoke_contract'), hasLength(2));
      gates[1].complete({'output': '2'});
      expect(resultOf(await b), {'output': '2'});
    });

    test('a call without a shader reuses only this dApp\'s shader', () async {
      final s = testSession(t, policy);
      final first = await s.handle(rq(1, 'invoke_contract', {'args': 'a=1'}));
      expect(errorCode(first), -32602);
      expect(t.callsTo('invoke_contract'), isEmpty);

      await s.handle(
        rq(2, 'invoke_contract', {
          'contract': [7, 7],
          'args': 'a=2',
        }),
      );
      await s.handle(rq(3, 'invoke_contract', {'args': 'a=3'}));
      expect(t.lastParams('invoke_contract')['contract'], [7, 7]);
    });

    test('one dApp never inherits another dApp\'s shader', () async {
      final a = testSession(t, policy);
      final b = testSession(t, policy);
      await a.handle(
        rq(1, 'invoke_contract', {
          'contract': [1, 1],
          'args': 'x=1',
        }),
      );
      final res = await b.handle(rq(2, 'invoke_contract', {'args': 'x=2'}));
      expect(errorCode(res), -32602);
      expect(t.callsTo('invoke_contract'), hasLength(1));
    });

    test('a lost connection is reported as an unknown outcome', () async {
      t.reply('get_version', const BeamConnectionException('dropped'));
      final s = testSession(t, policy);
      final res = await s.handle(rq(1, 'get_version'));
      expect(errorCode(res), -32603);
      expect('${errorData(res)}', contains('unknown'));
    });

    test('a closed session answers nothing to the wallet', () async {
      final s = testSession(t, policy);
      await s.close();
      expect(errorCode(await s.handle(rq(1, 'get_version'))), -32603);
      expect(t.calls, isEmpty);
    });
  });

  group('tx_send', () {
    test(
      'shows amount, asset, fee, recipient; executes what was shown',
      () async {
        final s = testSession(t, policy);
        final res = await send(s, {
          'address': 'recipient-token',
          'value': 50000000,
          'comment': 'Order #12',
        });
        final r = policy.shown.single;
        expect(r.kind, DappConsentKind.send);
        expect(r.pays, [DappAssetAmount(0, g(50000000))]);
        expect(r.receives, isEmpty);
        expect(r.fee, g(100000));
        expect(r.send!.address, 'recipient-token');
        expect(r.send!.addressType, 'regular');
        expect(r.send!.isOnline, isTrue);
        expect(r.send!.txComment, 'Order #12');
        expect(r.dappMessage, 'Order #12');
        expect(t.lastParams('validate_address'), {
          'address': 'recipient-token',
        });

        expect(resultOf(res), {'txId': txId(1)});
        expect(t.lastParams('tx_send'), {
          'address': 'recipient-token',
          'value': 50000000,
          'comment': 'Order #12',
          'fee': 100000,
        });
      },
    );

    test('max privacy and offline sends cost 0.011 BEAM by default', () async {
      final s = testSession(t, policy);
      t.reply('validate_address', {'is_valid': true, 'type': 'max_privacy'});
      await send(s, {'address': 'mp', 'value': 1});
      expect(policy.shown.last.fee, g(1100000));
      expect(policy.shown.last.send!.isOnline, isFalse);

      t.reply('validate_address', {'is_valid': true, 'type': 'offline'});
      await send(s, {'address': 'off', 'value': 1});
      expect(policy.shown.last.fee, g(100000), reason: 'paid online');
      expect(policy.shown.last.send!.isOnline, isTrue);
      await send(s, {'address': 'off', 'value': 1, 'offline': true});
      expect(policy.shown.last.fee, g(1100000));
      expect(t.lastParams('tx_send')['fee'], 1100000);
    });

    test('an asset payment needs the asset plus the fee in BEAM', () async {
      final s = testSession(t, policy);
      await send(s, {'address': 'r', 'value': 7, 'asset_id': 174});
      final r = policy.shown.single;
      expect(r.pays, [DappAssetAmount(174, g(7))]);
      expect(r.required, {174: g(7), 0: g(100000)});
      expect(r.shortfall({174: g(7), 0: g(99999)}), {0: g(1)});
    });

    test(
      'refused without a prompt: bad address, low fee, foreign from',
      () async {
        final s = testSession(t, policy);
        t.reply('validate_address', {'is_valid': false});
        expect(
          errorCode(
            await s.handle(rq(1, 'tx_send', {'address': 'x', 'value': 1})),
          ),
          -32003,
        );
        t.reply('validate_address', {'is_valid': true, 'type': 'regular'});
        expect(
          errorCode(
            await s.handle(
              rq(2, 'tx_send', {'address': 'x', 'value': 1, 'fee': 99999}),
            ),
          ),
          -32602,
        );
        expect(
          errorCode(
            await s.handle(
              rq(3, 'tx_send', {'address': 'x', 'value': 1, 'from': 'main'}),
            ),
          ),
          -32003,
        );
        expect(policy.shown, isEmpty);
        expect(t.callsTo('tx_send'), isEmpty);
      },
    );

    test('a changed amount after approval is refused', () async {
      final s = testSession(t, policy)
        ..debugBeforeExecute = (p) => p['value'] = 999999999;
      final res = await send(s, {'address': 'r', 'value': 1});
      expect(errorCode(res), -32021);
      expect(t.callsTo('tx_send'), isEmpty);
    });

    test('rejected is -32021', () async {
      final s = testSession(t, policy);
      final res = await send(s, {'address': 'r', 'value': 1}, approve: false);
      expect(errorCode(res), -32021);
      expect(t.callsTo('tx_send'), isEmpty);
    });
  });

  group('scoping', () {
    test('a dApp sees only its own transactions', () async {
      final s = testSession(t, policy);
      // Before it made any, the wallet is not even asked.
      expect(resultOf(await s.handle(rq(1, 'tx_list', {}))), isEmpty);
      expect(t.callsTo('tx_list'), isEmpty);

      await send(s, {'address': 'r', 'value': 1});
      await send(s, {'address': 'r', 'value': 2});
      t.reply('tx_list', [
        {'txId': txId(1), 'value': 1},
        {'txId': txId(99), 'value': 500, 'comment': 'salary'},
        {'txId': txId(2), 'value': 2},
      ]);
      expect(resultOf(await s.handle(rq(2, 'tx_list', {'count': 10}))), [
        {'txId': txId(1), 'value': 1},
        {'txId': txId(2), 'value': 2},
      ]);
      expect(t.lastParams('tx_list'), isEmpty, reason: 'count applied after');
      expect(
        resultOf(await s.handle(rq(3, 'tx_list', {'skip': 1, 'count': 1}))),
        [
          {'txId': txId(2), 'value': 2},
        ],
      );

      expect(resultOf(await s.handle(rq(4, 'tx_status', {'txId': txId(1)}))), {
        'txId': txId(1),
      });
      expect(
        errorCode(await s.handle(rq(5, 'tx_status', {'txId': txId(99)}))),
        -32602,
      );
      expect(
        errorData(await s.handle(rq(6, 'tx_cancel', {'txId': txId(99)}))),
        'Unknown transaction ID.',
      );
      expect(
        errorCode(
          await s.handle(rq(7, 'export_payment_proof', {'txId': txId(99)})),
        ),
        -32007,
      );
      expect(t.callsTo('tx_cancel'), isEmpty);
      expect(t.callsTo('export_payment_proof'), isEmpty);
    });

    test('a dApp sees and edits only addresses it created', () async {
      final s = testSession(t, policy);
      t
        ..reply('create_address', 'dapp-addr')
        ..reply('addr_list', [
          {'address': 'main-addr', 'comment': 'mine'},
          {'address': 'dapp-addr', 'comment': ''},
        ])
        ..reply('edit_address', 'done')
        ..reply('delete_address', 'done');
      await s.handle(rq(1, 'create_address', {'type': 'regular'}));
      expect(resultOf(await s.handle(rq(2, 'addr_list', {'own': true}))), [
        {'address': 'dapp-addr', 'comment': ''},
      ]);
      expect(
        errorCode(
          await s.handle(
            rq(3, 'edit_address', {'address': 'main-addr', 'comment': 'x'}),
          ),
        ),
        -32003,
      );
      expect(
        errorCode(
          await s.handle(rq(4, 'delete_address', {'address': 'main-addr'})),
        ),
        -32003,
      );
      expect(
        resultOf(
          await s.handle(
            rq(5, 'edit_address', {'address': 'dapp-addr', 'comment': 'x'}),
          ),
        ),
        'done',
      );
      expect(t.callsTo('delete_address'), isEmpty);

      // The default address handed out with use_default_signature is not
      // the dApp's to edit.
      t.reply('create_address', 'default-addr');
      await s.handle(rq(6, 'create_address', {'use_default_signature': true}));
      expect(
        errorCode(
          await s.handle(rq(7, 'delete_address', {'address': 'default-addr'})),
        ),
        -32003,
      );
    });

    test('wallet_status carries no balances', () async {
      t.reply('wallet_status', {
        'current_height': 4068104,
        'current_state_hash': 'ab',
        'current_state_timestamp': 1,
        'prev_state_hash': 'cd',
        'is_in_sync': true,
        'available': 123456789,
        'totals': [
          {'asset_id': 0, 'available': 123456789},
        ],
      });
      final s = testSession(t, policy);
      expect(resultOf(await s.handle(rq(1, 'wallet_status'))), {
        'current_height': 4068104,
        'current_state_hash': 'ab',
        'current_state_timestamp': 1,
        'prev_state_hash': 'cd',
        'is_in_sync': true,
      });
    });

    test('events: only subscribed, filtered to the dApp', () async {
      t.reply('ev_subunsub', true);
      final s = testSession(t, policy);
      final got = <Map<String, Object?>>[];
      s.notifications.listen((n) => got.add(decode(n)));
      await send(s, {'address': 'r', 'value': 1});

      t.emit('ev_txs_changed', {
        'change_str': 'updated',
        'txs': [
          {'txId': txId(1)},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(got, isEmpty, reason: 'not subscribed yet');

      await s.handle(
        rq(1, 'ev_subunsub', {'ev_txs_changed': true, 'ev_system_state': true}),
      );
      t
        ..emit('ev_txs_changed', {
          'change_str': 'updated',
          'txs': [
            {'txId': txId(1)},
            {'txId': txId(99)},
          ],
        })
        ..emit('ev_txs_changed', {
          'change_str': 'updated',
          'txs': [
            {'txId': txId(99)},
          ],
        })
        ..emit('ev_txs_changed', {'change_str': 'reset', 'txs': <Object?>[]})
        ..emit('ev_sync_progress', {'done': 1})
        ..emit('ev_system_state', {'current_height': 5})
        ..emit('ev_utxos_changed', {'utxos': <Object?>[]});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(got, [
        {
          'jsonrpc': '2.0',
          'id': 'ev_txs_changed',
          'result': {
            'change_str': 'updated',
            'txs': [
              {'txId': txId(1)},
            ],
          },
        },
        {
          'jsonrpc': '2.0',
          'id': 'ev_txs_changed',
          'result': {'change_str': 'reset', 'txs': <Object?>[]},
        },
        {
          'jsonrpc': '2.0',
          'id': 'ev_system_state',
          'result': {'current_height': 5},
        },
      ]);
      expect(
        errorCode(
          await s.handle(rq(2, 'ev_subunsub', {'ev_utxos_changed': true})),
        ),
        -32020,
      );
    });
  });

  group('versions and activity', () {
    test('the web-extension handshake renegotiates the version', () {
      final s = testSession(t, policy);
      expect(s.handshake(apiver: '7.0', apivermin: '6.0'), isTrue);
      expect(s.apiVersion, DappApiVersion.v7_0);
      expect(s.handshake(apiver: '', apivermin: ''), isTrue);
      expect(s.apiVersion, DappApiVersion.v7_4, reason: 'empty = current');
      expect(s.handshake(apiver: '9.0', apivermin: '8.0'), isFalse);
      expect(s.apiVersion, DappApiVersion.v7_4);
    });

    test('the negotiated version decides what exists', () async {
      final s = testSession(t, policy, version: DappApiVersion.v7_0);
      expect(errorCode(await s.handle(rq(1, 'assets_list'))), -32601);
      expect(errorCode(await s.handle(rq(2, 'send_message'))), -32601);
    });

    // Security review part 2, M-7: sign_message used to run with no
    // consent (a flushbar afterwards), and with the BANS contract id as
    // key material it signed as the owner of the user's names.
    test('sign_message asks first, showing the message and the key; '
        'approved, exactly that is signed', () async {
      final s = testSession(t, policy);
      final pending = s.handle(
        rq(1, 'sign_message', {
          'message': 'Log in to Example',
          'key_material': 'AbCd01',
        }),
      );
      await policy.waitShown(1);
      expect(t.callsTo('sign_message'), isEmpty, reason: 'nothing before');
      final r = policy.shown.single;
      expect(r.kind, DappConsentKind.signMessage);
      expect(r.sign!.message, 'Log in to Example');
      expect(r.sign!.keyMaterial, 'abcd01');
      expect(r.pays, isEmpty);
      expect(r.fee, BigInt.zero);
      policy.answer(0, true);
      expect(resultOf(await pending), {'signature': 'aa'});
      expect(t.lastParams('sign_message'), {
        'message': 'Log in to Example',
        'key_material': 'AbCd01',
      });
    });

    test('sign_message rejected: -32021 and nothing is signed', () async {
      final s = testSession(t, policy);
      final pending = s.handle(
        rq(1, 'sign_message', {'message': 'hi', 'key_material': 'aa'}),
      );
      await policy.waitShown(1);
      policy.answer(0, false);
      expect(errorCode(await pending), -32021);
      expect(t.callsTo('sign_message'), isEmpty);
    });

    test('sign_message with the key of the user\'s names or airdrops is '
        'refused without asking', () async {
      final seen = <DappActivity>[];
      final s = testSession(t, policy, onActivity: seen.add);
      for (final key in [
        kBansCid,
        kBansCid.toUpperCase(),
        '${kAirdropContractId}00',
        'ad2a',
      ]) {
        final res = await s.handle(
          rq(1, 'sign_message', {'message': 'hi', 'key_material': key}),
        );
        expect(errorCode(res), -32020, reason: key);
        expect(errorData(res), contains('Nothing was signed'));
      }
      expect(policy.shown, isEmpty);
      expect(t.callsTo('sign_message'), isEmpty);
      expect(seen.map((a) => a.kind).toSet(), {DappActivityKind.refused});
    });

    test('the app id follows the core formula', () {
      // python3: sha256(b"Test dApp\0http://127.0.0.1:40000/app/index.html\0")
      expect(
        testIdentity().appId,
        'appid:'
        'a204a21536295b035f92c20b58f4eaa6753114a7aa32ba7fe7eec25f9995676e',
      );
    });
  });
}
