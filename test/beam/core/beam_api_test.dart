/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'fixtures.dart';

void main() {
  late FakeTransport t;
  late BeamApi api;

  setUp(() {
    t = FakeTransport({
      for (final name in [
        'wallet_status',
        'tx_list',
        'addr_list',
        'assets_list',
        'get_utxo',
        'get_version',
        'validate_address',
        'calc_change',
      ])
        name: fixtureEnvelope(name),
      'get_asset_info': fixtureEnvelope('get_asset_info_174'),
      'tx_send': {'txId': 'ab' * 16},
      'tx_split': {'txId': 'cd' * 16},
      'tx_status': (Map<String, Object?> p) => fixtureList('tx_list').first,
      'tx_cancel': true,
      'tx_delete': true,
      'create_address': 'token',
      'edit_address': 'done',
      'delete_address': 'done',
      'ev_subunsub': true,
      'set_confirmations_count': (Map<String, Object?> p) => {
        'count': p['count'],
      },
      'get_confirmations_count': {'count': 5},
      'generate_tx_id': 'ef' * 16,
      'export_payment_proof': {'payment_proof': '00ff'},
      'invoke_contract': {
        'output': '{}',
        'raw_data': [1, 2],
      },
      'process_invoke_data': {'txid': '12' * 16},
    });
    api = BeamApi(t);
  });

  test('status calls parse fixtures', () async {
    expect((await api.getVersion()).apiVersion, '7.4');
    final s = await api.walletStatus();
    expect(s.totals, isNotEmpty);
    expect(t.lastParams('wallet_status'), isEmpty);
    await api.walletStatus(nzTotals: true);
    expect(t.lastParams('wallet_status'), {'nz_totals': true});
  });

  test('subscribeEvents asks for all seven streams', () async {
    expect(await api.subscribeEvents(), isTrue);
    expect(t.lastParams('ev_subunsub'), {
      'ev_sync_progress': true,
      'ev_system_state': true,
      'ev_assets_changed': true,
      'ev_addrs_changed': true,
      'ev_utxos_changed': true,
      'ev_txs_changed': true,
      'ev_connection_changed': true,
    });
    await api.subscribeEvents(utxosChanged: false);
    expect(t.lastParams('ev_subunsub')['ev_utxos_changed'], isFalse);
  });

  test('txList puts status, asset and height under filter', () async {
    final txs = await api.txList();
    expect(txs, hasLength(fixtureList('tx_list').length));
    expect(t.lastParams('tx_list'), isEmpty);

    await api.txList(
      count: 5,
      skip: 10,
      assetId: 174,
      status: BeamTxStatus.completed,
      height: 100,
    );
    expect(t.lastParams('tx_list'), {
      'count': 5,
      'skip': 10,
      'filter': {'status': 3, 'asset_id': 174, 'height': 100},
    });
    expect(() => api.txList(count: 0), throwsArgumentError);
    expect(() => api.txList(status: BeamTxStatus.unknown), throwsArgumentError);
  });

  test('txSend sends groth as JSON ints and leaves out unset params', () async {
    final id = await api.txSend(
      address: 'addr',
      value: BigInt.from(1234),
    );
    expect(id, 'ab' * 16);
    expect(t.lastParams('tx_send'), {'address': 'addr', 'value': 1234});

    await api.txSend(
      address: 'tok',
      value: BigInt.parse('9000000000000000000'),
      fee: BigInt.from(1100000),
      assetId: 174,
      comment: 'c',
      offline: true,
      txId: 'ef' * 16,
    );
    expect(t.lastParams('tx_send'), {
      'address': 'tok',
      'value': 9000000000000000000,
      'fee': 1100000,
      'asset_id': 174,
      'comment': 'c',
      'offline': true,
      'txId': 'ef' * 16,
    });
  });

  test('amounts are refused before sending when invalid', () async {
    final before = t.calls.length;
    expect(
      () => api.txSend(address: 'a', value: BigInt.zero),
      throwsArgumentError,
    );
    expect(
      () => api.txSend(address: 'a', value: BigInt.from(-5)),
      throwsArgumentError,
    );
    expect(
      () => api.txSend(address: 'a', value: BigInt.two.pow(63)),
      throwsArgumentError,
    );
    expect(() => api.txSplit(coins: const []), throwsArgumentError);
    expect(t.calls.length, before);
  });

  test('txSplit, txStatus, cancel, delete, generate id', () async {
    expect(
      await api.txSplit(
        coins: [BigInt.from(5), BigInt.from(6)],
        fee: BigInt.from(200000),
        assetId: 7,
      ),
      'cd' * 16,
    );
    expect(t.lastParams('tx_split'), {
      'coins': [5, 6],
      'fee': 200000,
      'asset_id': 7,
    });
    final tx = await api.txStatus('aa' * 16);
    expect(tx.txId, hasLength(32));
    expect(t.lastParams('tx_status'), {'txId': 'aa' * 16});
    expect(await api.txCancel('x'), isTrue);
    expect(t.lastParams('tx_cancel'), {'txId': 'x'});
    expect(await api.txDelete('y'), isTrue);
    expect(t.lastParams('tx_delete'), {'txId': 'y'});
    expect(await api.generateTxId(), 'ef' * 16);
  });

  test('calcChange and payment proofs', () async {
    final c = await api.calcChange(
      amount: BigInt.from(1000),
      assetId: 0,
      isPushTransaction: true,
    );
    expect(c.explicitFee, BigInt.from(100000));
    expect(t.lastParams('calc_change'), {
      'amount': 1000,
      'asset_id': 0,
      'is_push_transaction': true,
    });
    expect(await api.exportPaymentProof('t'), '00ff');
    expect(t.lastParams('export_payment_proof'), {'txId': 't'});
  });

  test('createAddress uses wallet-api type and expiration names', () async {
    expect(await api.createAddress(), 'token');
    expect(t.lastParams('create_address'), {'type': 'regular'});

    final expected = {
      BeamAddressType.regular: 'regular',
      BeamAddressType.regularNew: 'regular_new',
      BeamAddressType.offline: 'offline',
      BeamAddressType.maxPrivacy: 'max_privacy',
      BeamAddressType.publicOffline: 'public_offline',
    };
    for (final e in expected.entries) {
      await api.createAddress(type: e.key);
      expect(t.lastParams('create_address')['type'], e.value);
    }
    await api.createAddress(
      type: BeamAddressType.offline,
      expiration: BeamAddressExpiration.hours24,
      comment: 'shop',
      offlinePayments: 3,
    );
    expect(t.lastParams('create_address'), {
      'type': 'offline',
      'expiration': '24h',
      'comment': 'shop',
      'offline_payments': 3,
    });
    expect(
      () => api.createAddress(type: BeamAddressType.unknown),
      throwsArgumentError,
    );
  });

  test('address list, validation, edit, delete', () async {
    final list = await api.addrList(own: true);
    expect(list, hasLength(fixtureList('addr_list').length));
    expect(t.lastParams('addr_list'), {'own': true});

    final v = await api.validateAddress('abc');
    expect(v.isValid, isTrue);
    expect(t.lastParams('validate_address'), {'address': 'abc'});

    await api.editAddress('abc', expiration: BeamAddressExpiration.never);
    expect(t.lastParams('edit_address'), {
      'address': 'abc',
      'expiration': 'never',
    });
    expect(() => api.editAddress('abc'), throwsArgumentError);

    await api.deleteAddress('abc');
    expect(t.lastParams('delete_address'), {'address': 'abc'});
  });

  test('getUtxo filter and sort', () async {
    final coins = await api.getUtxo();
    expect(coins, hasLength(fixtureList('get_utxo').length));
    expect(t.lastParams('get_utxo'), isEmpty);
    await api.getUtxo(
      assetId: 174,
      count: 10,
      skip: 20,
      sortField: 'amount',
      sortDescending: true,
    );
    expect(t.lastParams('get_utxo'), {
      'count': 10,
      'skip': 20,
      'filter': {'asset_id': 174},
      'sort': {'field': 'amount', 'direction': 'desc'},
    });
  });

  test('assets', () async {
    final assets = await api.assetsList(refresh: true);
    expect(assets, isNotEmpty);
    expect(t.lastParams('assets_list'), {'refresh': true});
    final fomo = await api.getAssetInfo(174);
    expect(fomo.metadata.unitName, 'FOMO');
    expect(t.lastParams('get_asset_info'), {'asset_id': 174});
    expect(() => api.getAssetInfo(0), throwsArgumentError);
  });

  test('invokeContract sends the shader as bytes, never a file path', () async {
    final r = await api.invokeContract(
      createTx: false,
      args: 'role=manager,action=view',
      contractBytes: const [0, 97, 115, 109],
    );
    expect(r.rawData, [1, 2]);
    expect(t.lastParams('invoke_contract'), {
      'contract': [0, 97, 115, 109],
      'args': 'role=manager,action=view',
      'create_tx': false,
    });
    expect(t.lastParams('invoke_contract').containsKey('contract_file'), false);

    expect(await api.processInvokeData(r.rawData!), '12' * 16);
    expect(t.lastParams('process_invoke_data'), {
      'data': [1, 2],
    });
  });

  test('confirmations count', () async {
    expect(await api.setConfirmationsCount(3), 3);
    expect(t.lastParams('set_confirmations_count'), {'count': 3});
    expect(await api.getConfirmationsCount(), 5);
  });

  test('core errors propagate; bad shapes are FormatExceptions', () async {
    t.reply('tx_cancel', const BeamRpcException(-32001, 'Invalid tx status'));
    await expectLater(
      api.txCancel('x'),
      throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', -32001)),
    );
    t.reply('get_version', 'not an object');
    await expectLater(api.getVersion(), throwsFormatException);
    t.reply('tx_list', {'not': 'a list'});
    await expectLater(api.txList(), throwsFormatException);
  });
}
