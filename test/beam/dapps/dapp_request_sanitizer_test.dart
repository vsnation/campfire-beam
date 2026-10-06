/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_request_sanitizer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_rpc.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';

Matcher rpcError(int code, [Object? data]) => throwsA(
  isA<BeamRpcException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.data, 'data', data ?? anything),
);

void main() {
  const s = DappRequestSanitizer();
  Map<String, Object?> run(String method, Map<String, Object?> params) =>
      s.sanitize(DappRpcRequest(1, method, params));

  group('invoke_contract', () {
    test('contract_file and unknown keys are stripped', () {
      final out = run('invoke_contract', {
        'contract_file': '/etc/passwd',
        'contract': [1, 2, 3],
        'args': 'role=manager,action=view',
        'create_tx': false,
        'priority': 1,
        'surprise': true,
      });
      expect(out, {
        'contract': [1, 2, 3],
        'args': 'role=manager,action=view',
        'create_tx': false,
        'priority': 1,
      });
    });

    test('create_tx is forced false when absent', () {
      expect(run('invoke_contract', {'args': 'a=b'})['create_tx'], isFalse);
    });

    test('create_tx true is refused with the core error', () {
      expect(
        () => run('invoke_contract', {'args': 'a=b', 'create_tx': true}),
        rpcError(
          -32020,
          'Applications must set create_tx to false and use '
          'process_contract_data',
        ),
      );
      expect(
        () => run('invoke_contract', {'create_tx': 'false'}),
        rpcError(-32602),
      );
    });

    test('contract must be bytes within the size limit', () {
      for (final bad in [
        'AAEC',
        [1, 256],
        [-1],
        [1.5],
        null,
        {'0': 1},
      ]) {
        expect(
          () => run('invoke_contract', {'contract': bad}),
          rpcError(-32602),
          reason: '$bad',
        );
      }
      const small = DappRequestSanitizer(
        DappRequestLimits(maxShaderBytes: 4, maxArgsLength: 3),
      );
      expect(
        () => small.sanitize(
          const DappRpcRequest(1, 'invoke_contract', {
            'contract': [1, 2, 3, 4, 5],
          }),
        ),
        throwsA(isA<BeamRpcException>()),
      );
      expect(
        () => small.sanitize(
          const DappRpcRequest(1, 'invoke_contract', {'args': 'a=bc'}),
        ),
        throwsA(isA<BeamRpcException>()),
      );
    });

    test('contract_file is stripped from any other method too', () {
      expect(run('tx_status', {'txId': 'ab' * 16, 'contract_file': '/x'}), {
        'txId': 'ab' * 16,
      });
    });
  });

  group('tx_send', () {
    const ok = {'address': 'abc', 'value': 5};

    test('accepts the shown keys only', () {
      expect(
        run('tx_send', {
          ...ok,
          'asset_id': 7,
          'fee': 100000,
          'comment': 'c',
          'confirm_comment': 'cc',
          'from': 'def',
          'txId': '0123456789abcdef0123456789abcdef',
          'offline': true,
        }),
        hasLength(9),
      );
      for (final extra in ['coins', 'contract_file', 'key', 'session']) {
        expect(
          () => run('tx_send', {...ok, extra: 1}),
          rpcError(-32602),
          reason: extra,
        );
      }
    });

    test('checks types and ranges', () {
      for (final bad in <Map<String, Object?>>[
        {'value': 5},
        {'address': '', 'value': 5},
        {'address': 'abc', 'value': 0},
        {'address': 'abc', 'value': -5},
        {'address': 'abc', 'value': 5.0},
        {'address': 'abc', 'value': '5'},
        {...ok, 'fee': 0},
        {...ok, 'asset_id': -1},
        {...ok, 'asset_id': 0x100000000},
        {...ok, 'txId': 'xyz'},
        {...ok, 'offline': 'yes'},
        {...ok, 'confirm_comment': 'x' * 1025},
        {...ok, 'comment': 7},
      ]) {
        expect(() => run('tx_send', bad), rpcError(-32602), reason: '$bad');
      }
    });
  });

  group('process_invoke_data', () {
    test('needs data bytes, allows confirm_comment, nothing else', () {
      expect(
        run('process_invoke_data', {
          'data': [1, 2],
        }),
        {
          'data': [1, 2],
        },
      );
      expect(
        run('process_invoke_data', {
          'data': [1],
          'confirm_comment': 'Swap',
        }),
        {
          'data': [1],
          'confirm_comment': 'Swap',
        },
      );
      for (final bad in <Map<String, Object?>>[
        {},
        {'data': <int>[]},
        {'data': 'AQI='},
        {
          'data': [1],
          'create_tx': true,
        },
        {
          'data': [1],
          'confirm_comment': 'x' * 1025,
        },
      ]) {
        expect(
          () => run('process_invoke_data', bad),
          rpcError(-32602),
          reason: '$bad',
        );
      }
    });
  });

  group('ev_subunsub', () {
    test('apps may not subscribe to utxo or asset events', () {
      for (final e in ['ev_utxos_changed', 'ev_assets_changed']) {
        expect(
          () => run('ev_subunsub', {'ev_txs_changed': true, e: true}),
          rpcError(-32020),
        );
      }
      expect(
        run('ev_subunsub', {'ev_txs_changed': true, 'ev_sync_progress': false}),
        {'ev_txs_changed': true, 'ev_sync_progress': false},
      );
    });

    test('unknown, empty or non-bool is invalid', () {
      expect(
        () => run('ev_subunsub', {'ev_nope': true}),
        rpcError(-32602, "The event 'ev_nope' is unknown."),
      );
      expect(() => run('ev_subunsub', {}), rpcError(-32602));
      expect(() => run('ev_subunsub', {'ev_txs_changed': 1}), rpcError(-32602));
    });
  });

  group('request parsing', () {
    test('as the core parses it', () {
      final r = DappRpcRequest.parse(
        '{"jsonrpc":"2.0","id":"call-1","method":"get_version"}',
        maxLength: 100,
      );
      expect(r.id, 'call-1');
      expect(r.params, isEmpty);
      for (final bad in [
        '',
        'nope',
        '[]',
        '{"jsonrpc":"2.0","id":1.5,"method":"x"}',
        '{"jsonrpc":"2.0","id":null,"method":"x"}',
        '{"jsonrpc":"1.0","id":1,"method":"x"}',
        '{"jsonrpc":"2.0","id":1}',
        '{"jsonrpc":"2.0","id":1,"method":"x","params":[1]}',
        '{"jsonrpc":"2.0","id":1,"method":"${'x' * 100}"}',
      ]) {
        expect(
          () => DappRpcRequest.parse(bad, maxLength: 100),
          throwsA(isA<DappRpcFailure>()),
          reason: bad,
        );
      }
    });

    test('canonical JSON sorts keys at every level', () {
      expect(
        canonicalJson({
          'b': 1,
          'a': [
            {'z': true, 'y': null},
          ],
        }),
        '{"a":[{"y":null,"z":true}],"b":1}',
      );
    });
  });

  // Security review part 2, M-1: Campfire's wallet-api runs the BANS app
  // shader at privilege 1 for whoever sends its bytes (patch 0002 grants
  // privilege by the hash of `contract`), so a dApp sending them could read
  // every payment waiting for the user's names.
  group('M-1: privileged shaders', () {
    final bans = File('assets/beam/shaders/$kBansShaderName').readAsBytesSync();

    test('the bundled BANS shader is the privileged one', () {
      expect(crypto.sha256.convert(bans).toString(), kBansShaderSha256);
    });

    test('a dApp sending the BANS shader bytes is refused', () {
      expect(
        () => run('invoke_contract', {
          'contract': bans,
          'args': 'role=user,action=view,cid=$kBansCid',
        }),
        rpcError(-32020, contains('reserves for its own name service')),
      );
    });

    test('one byte different is just another shader (privilege 0)', () {
      final other = [...bans]..[100] ^= 1;
      expect(
        run('invoke_contract', {'contract': other, 'args': 'a=b'})['contract'],
        other,
      );
    });

    test('the list comes from the binaries manifest, and is injectable', () {
      final custom = DappRequestSanitizer(const DappRequestLimits(), [
        crypto.sha256.convert([1, 2, 3]).toString(),
      ]);
      expect(
        () => custom.sanitize(
          const DappRpcRequest(1, 'invoke_contract', {
            'contract': [1, 2, 3],
          }),
        ),
        rpcError(-32020),
      );
    });
  });

  // M-7: what a dApp may ask the wallet to sign.
  group('sign_message', () {
    test('only message and key_material, exactly', () {
      expect(run('sign_message', {'message': 'hi', 'key_material': 'aB01'}), {
        'message': 'hi',
        'key_material': 'aB01',
      });
      expect(
        () => run('sign_message', {
          'message': 'hi',
          'key_material': 'aa',
          'extra': 1,
        }),
        rpcError(-32602),
      );
    });

    test('key_material must be even-length hex: the core stops at the '
        'first non-hex digit, so anything else could sign with a key '
        'other than the one checked', () {
      for (final bad in ['', 'a', 'abc', 'zz', 'aa zz', '0xaa', 'aa\u0000']) {
        expect(
          () => run('sign_message', {'message': 'hi', 'key_material': bad}),
          rpcError(-32602),
          reason: bad,
        );
      }
    });

    test('a message with hidden characters is refused: the sheet must '
        'show exactly what is signed', () {
      for (final bad in ['pay \u202e01 BEAM', 'a\u0000b', 'x\u200by', '']) {
        expect(
          () => run('sign_message', {'message': bad, 'key_material': 'aa'}),
          rpcError(-32602),
          reason: bad,
        );
      }
      expect(
        run('sign_message', {
          'message': 'line 1\nline 2',
          'key_material': 'aa',
        }),
        containsPair('message', 'line 1\nline 2'),
      );
    });
  });
}
