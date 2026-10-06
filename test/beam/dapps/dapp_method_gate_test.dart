/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_method_gate.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_method_table.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';

Matcher rpcError(int code) =>
    throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', code));

void main() {
  group('api versions', () {
    test('parse and negotiate like the core and beam-ui', () {
      expect(DappApiVersion.tryParse('current'), DappApiVersion.v7_4);
      expect(DappApiVersion.tryParse('6.2'), DappApiVersion.v6_2);
      expect(DappApiVersion.tryParse('7.5'), isNull);
      expect(DappApiVersion.tryParse('7'), isNull);
      expect(DappApiVersion.tryParse(' 7.0'), isNull);
      expect(DappApiVersion.tryParse('7.0.0'), isNull);
      expect(DappApiVersion.tryParse(''), isNull);
      expect(DappApiVersion.negotiate(), DappApiVersion.v7_4);
      expect(
        DappApiVersion.negotiate(wanted: '9.9', minimum: '6.0'),
        DappApiVersion.v6_0,
      );
      expect(DappApiVersion.negotiate(wanted: '9.9', minimum: '9.0'), isNull);
      expect(DappApiVersion.negotiate(wanted: '9.9'), isNull);
      expect(DappApiVersion.v6_2.methodTable, DappApiVersion.v6_1);
    });
  });

  group('gate', () {
    test('allowed methods pass in every version that has them', () {
      for (final v in DappApiVersion.values) {
        final g = DappMethodGate(v);
        for (final m in [
          'tx_send',
          'process_invoke_data',
          'invoke_contract',
          'tx_status',
          'addr_list',
          'validate_address',
          'calc_change',
        ]) {
          expect(() => g.check(m), returnsNormally, reason: '$m in $v');
        }
      }
    });

    test('blocked methods are -32020', () {
      for (final v in DappApiVersion.values) {
        final g = DappMethodGate(v);
        for (final m in [
          'get_utxo',
          'tx_split',
          'tx_asset_issue',
          'tx_asset_consume',
          'change_password',
          'set_confirmations_count',
          'swap_create_offer',
        ]) {
          expect(() => g.check(m), rpcError(-32020), reason: '$m in $v');
        }
      }
    });

    test('unknown methods are -32601', () {
      final g = DappMethodGate(DappApiVersion.v7_4);
      for (final m in ['foo', 'tx_send ', 'TX_SEND', '', 'export_owner_key']) {
        expect(() => g.check(m), rpcError(-32601), reason: m);
      }
    });

    test('version differences follow the core', () {
      expect(
        () => DappMethodGate(DappApiVersion.v6_0).check('wallet_status'),
        rpcError(-32020),
        reason: '6.0 wallet_status is APPS_BLOCKED',
      );
      expect(
        () => DappMethodGate(DappApiVersion.v6_1).check('wallet_status'),
        returnsNormally,
      );
      expect(
        () => DappMethodGate(DappApiVersion.v6_0).check('ev_subunsub'),
        rpcError(-32601),
      );
      expect(
        () => DappMethodGate(DappApiVersion.v7_2).check('assets_list'),
        rpcError(-32601),
      );
      expect(
        () => DappMethodGate(DappApiVersion.v7_3).check('assets_list'),
        returnsNormally,
      );
      expect(
        () => DappMethodGate(DappApiVersion.v7_3).check('send_message'),
        rpcError(-32601),
      );
      expect(
        () => DappMethodGate(DappApiVersion.v7_4).check('send_message'),
        returnsNormally,
      );
      expect(
        DappMethodGate(DappApiVersion.v6_2).allowedMethods,
        DappMethodGate(DappApiVersion.v6_1).allowedMethods,
      );
    });

    test('the 7.4 allowlist is exactly research/04 §3.6', () {
      expect(DappMethodGate(DappApiVersion.v7_4).allowedMethods, [
        'addr_list',
        'assets_list',
        'block_details',
        'calc_change',
        'create_address',
        'delete_address',
        'derive_id',
        'edit_address',
        'ev_subunsub',
        'export_payment_proof',
        'generate_tx_id',
        'get_asset_info',
        'get_confirmations_count',
        'get_version',
        'invoke_contract',
        'ipfs_add',
        'ipfs_gc',
        'ipfs_get',
        'ipfs_hash',
        'ipfs_pin',
        'ipfs_unpin',
        'process_invoke_data',
        'read_messages',
        'send_message',
        'sign_message',
        'tx_asset_info',
        'tx_cancel',
        'tx_delete',
        'tx_list',
        'tx_send',
        'tx_status',
        'validate_address',
        'verify_payment_proof',
        'verify_signature',
        'wallet_status',
      ]);
    });
  });

  group('generated table', () {
    final core =
        Platform.environment['BEAM_CORE_SRC'] ??
        '${Platform.environment['HOME']}/beam';
    final hasCore = File('$core/wallet/api/v6_0/v6_api_defs.h').existsSync();

    test('matches the BEAM core checkout it was generated from', () async {
      final r = await Process.run('python3', [
        '-I',
        'test/beam/dapps/tool/gen_dapp_method_table.py',
        core,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      final committed = File('lib/wallets/beam/dapps/dapp_method_table.dart')
          .readAsStringSync();
      expect(r.stdout, committed);
    }, skip: hasCore ? false : 'no BEAM core checkout at $core');

    test('every version is present', () {
      expect(dappCoreMethodTable.keys, [
        for (final v in DappApiVersion.values) v.label,
      ]);
    });
  });
}
