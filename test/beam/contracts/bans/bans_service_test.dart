// BeamBansService over FakeTransport with recorded wallet-api answers, and
// the wallet-less explorer lookup over a fake HTTP layer.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/networking/http.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'bans_fixtures.dart';

const _tip = 4068103;

/// Shader bytes from a callback, standing in for the app's asset bundle.
class _BytesSource implements ShaderSource {
  _BytesSource(this._bytes);

  final List<int> Function() _bytes;

  @override
  Future<Uint8List> read(String name) async {
    expect(name, kBansShaderName);
    return Uint8List.fromList(_bytes());
  }
}

/// yas compacted unsigned / signed, as `raw_data` carries them.
List<int> _u(int v) {
  if (v < 128) return [0x80 | v];
  final b = <int>[];
  for (var x = v; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [b.length, ...b];
}

List<int> _s(int v) {
  final a = v.abs();
  final sign = v < 0 ? 0x80 : 0;
  if (a < 64) return [sign | 0x40 | a];
  final b = <int>[];
  for (var x = a; x > 0; x >>= 8) {
    b.add(x & 0xff);
  }
  return [sign | b.length, ...b];
}

List<int> _hexBytes(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

/// An Anon-Vault receive the way the BANS shader builds it for a claim
/// (`vault_anon/app_impl.h:440`): an advanced kernel (flags Adv |
/// HasCommitment) that carries its own fee and validity window.
List<int> _advancedClaim({required int amount, required int fee}) => [
  ..._u(1),
  ..._u(0x80000000 | 0x11),
  ..._u(BansMethod.vaultWithdraw),
  ..._u(3),
  9,
  9,
  9,
  ..._u(0),
  ..._u(0),
  ..._u(BansKernelComment.receiveAnon.length),
  ...BansKernelComment.receiveAnon.codeUnits,
  ..._u(1),
  ..._u(0),
  ..._s(-amount),
  ..._hexBytes(vaultCid),
  ..._u(_tip),
  ..._u(15),
  ..._u(fee),
  ...List.filled(65, 1), // signature
  ...List.filled(32, 2), // key preimage hash
  ...List.filled(33, 3), // kernel commitment
];

Map<String, Object?> _walletStatus({int height = _tip, bool inSync = true}) => {
  'current_height': height,
  'current_state_hash': 'ab' * 32,
  'current_state_timestamp': 1791276300,
  'prev_state_hash': 'cd' * 32,
  'is_in_sync': inSync,
};

String _action(Map<String, Object?> params) {
  final args = params['args']! as String;
  return RegExp(r'action=([a-z_]+)').firstMatch(args)!.group(1)!;
}

String _argOf(Map<String, Object?> params, String key) {
  final args = params['args']! as String;
  return RegExp('(?:^|,)$key=([^,]*)').firstMatch(args)!.group(1)!;
}

/// Answers invoke_contract from fixtures by action and name. [overrides]
/// maps `action` or `action:name` to a fixture name or an envelope/value.
FakeHandler _invoker(Map<String, Object?> overrides) => (params) {
  expect(params['create_tx'], isFalse, reason: 'never create_tx: true');
  final contract = params['contract'];
  expect(contract, isA<List<int>>());
  expect((contract! as List<int>).length, kBansShaderSize);
  final action = _action(params);
  final args = params['args']! as String;
  final name = RegExp(r'name=([^,]*)').firstMatch(args)?.group(1);
  final reply = overrides['$action:$name'] ?? overrides[action];
  if (reply == null) throw StateError('no fixture for $args');
  if (reply is String) return bansEnvelope(reply);
  return reply;
};

void main() {
  late FakeTransport t;
  late BeamBansService svc;

  void setUpService(
    Map<String, Object?> invoke, {
    BeamExplorerClient? explorer,
    PinnedShader? shader,
  }) {
    t = FakeTransport({
      'wallet_status': _walletStatus(),
      'invoke_contract': _invoker(invoke),
      'process_invoke_data': (Map<String, Object?> p) => {'txid': 'ee' * 16},
    });
    svc = BeamBansService(
      BeamApi(t),
      explorer,
      shader: shader ?? repoShader(),
    );
  }

  group('reads', () {
    setUp(
      () => setUpService({
        'view_name:beam': 'view_name_beam',
        'view_name:nephrite': 'view_name_listed',
        'view_name:beamer': 'view_name_hold',
        'view_name': 'view_name_free',
        'my_key': 'my_key',
        'view_domain': 'view_domain_pk',
        'view_params': 'view_params',
        'view': 'user_view',
      }),
    );

    test('resolve a registered name', () async {
      final r = await svc.resolve(BansName('beam'));
      expect(r.ownerKey, beamOwnerKey);
      expect(r.domain!.expireHeight, 4918184);
      expect(r.status, BansNameStatus.active);
      expect(r.tipHeight, _tip);
      expect(r.walletInSync, isTrue);
      // (4918184 - tip) minutes after the tip block
      expect(
        r.expiresAt,
        DateTime.utc(2026, 10, 6, 8, 45).add(
          const Duration(minutes: 4918184 - _tip),
        ),
      );
      expect(
        _argOf(t.lastParams('invoke_contract'), 'role'),
        'manager',
      );
    });

    test('resolve a free name, a listed one and one on hold', () async {
      expect(
        (await svc.resolve(BansName('zzzzz'))).status,
        BansNameStatus.available,
      );
      expect(
        (await svc.resolve(BansName('nephrite'))).status,
        BansNameStatus.forSale,
      );
      final hold = await svc.resolve(BansName('beamer'));
      expect(hold.status, BansNameStatus.onHold);
      expect(
        hold.holdEndsAt,
        hold.clock.dateOf(3998572 + kBansHoldBlocks),
      );
    });

    test('my names: my_key once, then view_domain filtered by it', () async {
      final mine = await svc.myNames();
      expect(mine.key, fakeMyKey);
      expect(mine.names.map((d) => d.name), ['amir', 'beam', 'foundation']);
      await svc.myNames();
      final actions = [
        for (final c in t.callsTo('invoke_contract')) _action(c.params),
      ];
      expect(actions, ['my_key', 'view_domain', 'view_domain']);
      expect(_argOf(t.lastParams('invoke_contract'), 'pk'), fakeMyKey);
    });

    test('params', () async {
      final p = await svc.params();
      expect(p.vaultCid, vaultCid);
      expect(p.usdPerBeamText, '0.00860');
    });

    test('inbox on stock wallet-api is BansClaimUnsupported', () async {
      await expectLater(
        svc.inbox(),
        throwsA(
          isA<BansClaimUnsupported>().having(
            (e) => e.message,
            'message',
            startsWith(
              'Claiming name payments needs the Campfire BEAM build of '
              'wallet-api',
            ),
          ),
        ),
      );
    });

    test('other core errors are not mistaken for the privilege failure', () {
      expect(
        BeamBansService.isPrivilegeFailure(
          const BeamRpcException(-32019, 'Contract call failed', 'Error: x'),
        ),
        isFalse,
      );
      expect(
        BeamBansService.isPrivilegeFailure(
          BeamRpcException(
            -32019,
            'Contract call failed',
            bansEnvelope('receive_all')['error'],
          ),
        ),
        isTrue,
      );
    });
  });

  group('prepare', () {
    test('register: exact price from the kernel, fee, expiry', () async {
      setUpService({
        'view_params': 'view_params',
        'my_key': 'my_key',
        'domain_register': 'register5',
      });
      final p = await svc.prepareRegister(BansName(quotedName5), 1);
      final s = p.summary;
      expect(p.action, BansAction.register);
      expect(s.youPay, [BansAmount(0, BigInt.from(116213166091))]);
      expect(s.fee, BigInt.from(1100000));
      expect(s.totalBeam, BigInt.from(116213166091 + 1100000));
      expect(s.ownerKey, fakeMyKey);
      expect(s.contractId, daoVaultCid);
      expect(s.usdTotal, 10);
      expect(s.expireHeight, _tip + 1 + kBansBlocksPerPeriod);
      expect(s.comments, [BansKernelComment.register]);
      expect(s.lines.first, 'Register $quotedName5 for 1 year');
      expect(s.lines, contains('You pay: 1162.13166091 BEAM'));
      expect(s.lines, contains('Network fee: 0.011 BEAM'));
      expect(p.rawData, bansRaw('register5'));
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(
        t.callsTo('invoke_contract').map((c) => c.params['create_tx']),
        everyElement(isFalse),
      );
    });

    test('register a taken name: the shader refusal is typed', () async {
      setUpService({
        'view_params': 'view_params',
        'domain_register': 'register_taken',
      });
      await expectLater(
        svc.prepareRegister(BansName('beam'), 1),
        throwsA(
          isA<BansShaderRefused>().having(
            (e) => e.refusal,
            'refusal',
            BansRefusal.ownedByOther,
          ),
        ),
      );
    });

    test('a kernel that does not match the request is refused', () async {
      // The core answers a register with a payment kernel.
      setUpService({
        'view_params': 'view_params',
        'my_key': 'my_key',
        'domain_register': 'pay_beam',
      });
      await expectLater(
        svc.prepareRegister(BansName(quotedName5), 1),
        throwsA(isA<BansUnexpectedTransaction>()),
      );
      // The right kernel for another name is refused too.
      setUpService({
        'view_params': 'view_params',
        'my_key': 'my_key',
        'domain_register': 'register5',
      });
      await expectLater(
        svc.prepareRegister(BansName('someoneelse'), 1),
        throwsA(isA<BansUnexpectedTransaction>()),
      );
      await expectLater(
        svc.prepareRegister(BansName(quotedName5), 2),
        throwsA(isA<BansUnexpectedTransaction>()),
      );
    });

    test('a register built for another key is refused', () async {
      setUpService({
        'view_params': 'view_params',
        'my_key': {
          'output': '{"res": {"key": "$beamOwnerKey"}}',
          'txid': '',
        },
        'domain_register': 'register5',
      });
      await expectLater(
        svc.prepareRegister(BansName(quotedName5), 1),
        throwsA(isA<BansUnexpectedTransaction>()),
      );
    });

    test('buy: pays exactly the listing, keeps the expiry', () async {
      setUpService({
        'view_name': 'view_name_listed',
        'my_key': 'my_key',
        'domain_buy': 'buy_listed',
      });
      final p = await svc.prepareBuy(BansName('nephrite'));
      expect(p.summary.youPay, [BansAmount(0, BigInt.from(10000000000000))]);
      expect(p.summary.expireHeight, 4524205);
      expect(p.summary.ownerKey, fakeMyKey);
      expect(p.summary.fee, BigInt.from(1100000));
    });

    test('pay: re-resolves, carries the owner, checks the kernel', () async {
      setUpService({
        'view_params': 'view_params',
        'view_name': 'view_name_beam',
        'pay': 'pay_beam',
      });
      final p = await svc.preparePay(
        BansName('beam'),
        0,
        BigInt.from(12345),
        expectedOwnerKey: beamOwnerKey,
      );
      expect(p.summary.ownerKey, beamOwnerKey);
      expect(p.summary.contractId, vaultCid);
      expect(p.summary.youPay, [BansAmount(0, BigInt.from(12345))]);
      expect(p.summary.fee, BigInt.from(1100000));
      expect(p.summary.lines.first, contains('beam.beam'));
      final actions = [
        for (final c in t.callsTo('invoke_contract')) _action(c.params),
      ];
      expect(actions, ['view_params', 'view_name', 'pay', 'view_name']);
    });

    test('pay: an amount other than the request is refused', () async {
      setUpService({
        'view_params': 'view_params',
        'view_name': 'view_name_beam',
        'pay': 'pay_beam',
      });
      await expectLater(
        svc.preparePay(BansName('beam'), 0, BigInt.from(99999)),
        throwsA(isA<BansUnexpectedTransaction>()),
      );
    });

    test('pay: a key the user was not shown aborts before building', () async {
      setUpService({
        'view_params': 'view_params',
        'view_name': 'view_name_beam',
        'pay': 'pay_beam',
      });
      await expectLater(
        svc.preparePay(
          BansName('beam'),
          0,
          BigInt.from(12345),
          expectedOwnerKey: fakeMyKey,
        ),
        throwsA(isA<BansOwnerChanged>()),
      );
      expect(
        t.callsTo('invoke_contract').map((c) => _action(c.params)),
        isNot(contains('pay')),
      );
    });

    test('pay: an owner change while building aborts', () async {
      var n = 0;
      setUpService({});
      // The second view_name answers with a different owner key.
      t.reply('invoke_contract', (Map<String, Object?> params) {
        final a = _action(params);
        if (a == 'view_name') {
          return ++n == 1
              ? bansEnvelope('view_name_beam')
              : bansEnvelope('view_name_listed');
        }
        return bansEnvelope(a == 'pay' ? 'pay_beam' : 'view_params');
      });
      await expectLater(
        svc.preparePay(BansName('beam'), 0, BigInt.from(12345)),
        throwsA(
          isA<BansOwnerChanged>()
              .having((e) => e.expectedKey, 'expected', beamOwnerKey)
              .having((e) => e.currentKey, 'current', isNot(beamOwnerKey)),
        ),
      );
    });

    test('pay to an unregistered or expired name is the shader\'s refusal',
        () async {
      setUpService({
        'view_params': 'view_params',
        'view_name': 'view_name_free',
        'pay': 'pay_unreg',
      });
      await expectLater(
        svc.preparePay(BansName('zzzzz'), 0, BigInt.one),
        throwsA(
          isA<BansShaderRefused>().having(
            (e) => e.refusal,
            'refusal',
            BansRefusal.notRegistered,
          ),
        ),
      );
    });

    test('claim all on stock wallet-api is BansClaimUnsupported', () async {
      setUpService({
        'view_params': 'view_params',
        'receive_all': 'receive_all',
      });
      await expectLater(
        svc.prepareClaimAll(),
        throwsA(isA<BansClaimUnsupported>()),
      );
    });

    test('claim all: advanced vault receives, fee fixed in the kernel',
        () async {
      final raw = _advancedClaim(amount: 480000000000, fee: 1100000);
      setUpService({
        'view_params': 'view_params',
        'receive_all': {
          'output': '{}',
          'raw_data': raw,
          'txid': '0' * 32,
        },
      });
      final p = await svc.prepareClaimAll();
      final s = p.summary;
      expect(p.action, BansAction.claimAll);
      expect(s.youPay, isEmpty);
      expect(s.youReceive, [BansAmount(0, BigInt.from(480000000000))]);
      expect(s.fee, BigInt.from(1100000));
      expect(s.contractId, vaultCid);
      expect(s.comments, [BansKernelComment.receiveAnon]);
      expect(p.invokeData.entries.single.isAdvanced, isTrue);
      expect(p.invokeData.entries.single.maxHeight, BigInt.from(_tip + 15));
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('an advanced kernel anywhere but a claim is refused', () async {
      setUpService({
        'view_params': 'view_params',
        'my_key': 'my_key',
        'domain_register': {
          'output': '{}',
          'raw_data': _advancedClaim(amount: 5, fee: 1100000),
        },
      });
      await expectLater(
        svc.prepareRegister(BansName(quotedName5), 1),
        throwsA(
          isA<BansUnexpectedTransaction>().having(
            (e) => e.detail,
            'detail',
            contains('undecodable'),
          ),
        ),
      );
    });

    test('claim sale proceeds with nothing waiting', () async {
      setUpService({
        'view_params': 'view_params',
        'receive': 'receive_raw',
      });
      await expectLater(
        svc.prepareClaimSaleProceeds(0),
        throwsA(
          isA<BansShaderRefused>().having(
            (e) => e.refusal,
            'refusal',
            BansRefusal.noFunds,
          ),
        ),
      );
      expect(
        _argOf(t.lastParams('invoke_contract'), 'pkOwner'),
        BansKey.zero,
      );
    });
  });

  group('execute', () {
    test('sends the prepared raw data, once', () async {
      setUpService({
        'view_params': 'view_params',
        'my_key': 'my_key',
        'domain_register': 'register5',
      });
      final p = await svc.prepareRegister(BansName(quotedName5), 1);
      expect(await svc.execute(p), 'ee' * 16);
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      expect(t.lastParams('process_invoke_data')['data'], bansRaw('register5'));
    });

    test('pay: checks the owner once more and sends nothing if it changed',
        () async {
      var owner = 'view_name_beam';
      setUpService({});
      t.reply('invoke_contract', (Map<String, Object?> params) {
        final a = _action(params);
        if (a == 'view_name') return bansEnvelope(owner);
        return bansEnvelope(a == 'pay' ? 'pay_beam' : 'view_params');
      });
      final p = await svc.preparePay(BansName('beam'), 0, BigInt.from(12345));
      owner = 'view_name_listed';
      await expectLater(svc.execute(p), throwsA(isA<BansOwnerChanged>()));
      expect(t.callsTo('process_invoke_data'), isEmpty);
      owner = 'view_name_beam';
      expect(await svc.execute(p), 'ee' * 16);
    });
  });

  group('shader pin', () {
    test('a modified shader is never sent', () async {
      final bad = Uint8List.fromList(
        File('assets/beam/shaders/bans_app.wasm').readAsBytesSync(),
      )..[100] ^= 1;
      setUpService(
        {'view_name': 'view_name_beam'},
        shader: bansAppShader(_BytesSource(() => bad)),
      );
      await expectLater(
        svc.resolve(BansName('beam')),
        throwsA(
          isA<BansShaderMismatch>().having(
            (e) => e.actualSize,
            'actualSize',
            kBansShaderSize,
          ),
        ),
      );
      expect(t.callsTo('invoke_contract'), isEmpty);
    });

    test('the source is read once and verified bytes are cached', () async {
      var reads = 0;
      final loader = bansAppShader(
        _BytesSource(() {
          reads++;
          return File('assets/beam/shaders/bans_app.wasm').readAsBytesSync();
        }),
      );
      final a = await loader.load();
      final b = await loader.load();
      expect(reads, 1);
      expect(identical(a, b), isTrue);
      expect(() => a[0] = 0, throwsUnsupportedError);
      // Concurrent first loads share one read.
      reads = 0;
      final fresh = bansAppShader(
        _BytesSource(() {
          reads++;
          return File('assets/beam/shaders/bans_app.wasm').readAsBytesSync();
        }),
      );
      final both = await Future.wait([fresh.load(), fresh.load()]);
      expect(reads, 1);
      expect(identical(both[0], both[1]), isTrue);
    });
  });

  group('wallet-less lookup (explorer)', () {
    final state = File(
      'test/beam/contracts/bans/fixtures/explorer_bans_state.json',
    ).readAsStringSync();

    BeamExplorerClient explorer() => BeamExplorerClient(
      proxyInfo: () => null,
      http: _FakeHttp((url) async {
        expect(url.path, endsWith('/contract'));
        expect(url.queryParameters['id'], kBansCid);
        expect(url.queryParameters['state'], '1');
        return Response(utf8.encode(state), 200);
      }),
    );

    test('found: display data, marked unverified', () async {
      setUpService({}, explorer: explorer());
      final beam = await svc.lookupWithoutWallet(BansName('beam'));
      expect(beam.verified, isFalse);
      expect(beam.domain!.ownerKey, beamOwnerKey);
      expect(beam.explorerHeight, 4068101);
      expect(beam.status, BansNameStatus.active);
      expect(t.calls, isEmpty, reason: 'no wallet needed');

      final neph = await svc.lookupWithoutWallet(BansName('nephrite'));
      expect(neph.status, BansNameStatus.forSale);
      expect(neph.domain!.salePrice, BansAmount(0, BigInt.from(1e13)));

      final hold = await svc.lookupWithoutWallet(BansName('beamer'));
      expect(hold.status, BansNameStatus.onHold);
      expect(hold.explorerStatusLabel, 'On Hold');

      final old = await svc.lookupWithoutWallet(BansName('0xredbeard'));
      expect(old.status, BansNameStatus.availableAgain);
      expect(old.explorerStatusLabel, 'Expired');
    });

    test('not found', () async {
      setUpService({}, explorer: explorer());
      final r = await svc.lookupWithoutWallet(BansName('zzzzzz'));
      expect(r.domain, isNull);
      expect(r.status, BansNameStatus.available);
    });

    test('no explorer configured', () async {
      setUpService({});
      await expectLater(
        svc.lookupWithoutWallet(BansName('beam')),
        throwsStateError,
      );
    });

    test('refuses an answer about another contract', () {
      expect(
        () => BeamBansService.parseExplorerLookup({
          'kind': 'DaoVault v0',
          'h': 1,
          'State': <String, Object?>{},
        }, BansName('beam')),
        throwsFormatException,
      );
    });
  });
}

class _FakeHttp extends HTTP {
  _FakeHttp(this.handler);

  final Future<Response> Function(Uri url) handler;

  @override
  Future<Response> get({
    required Uri url,
    Map<String, String>? headers,
    required ({InternetAddress host, int port})? proxyInfo,
    Duration? connectionTimeout,
  }) => handler(url);
}
