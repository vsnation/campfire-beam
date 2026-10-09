/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, read-only, no funds: the bridge's BEAM side against mainnet, with
// a throwaway wallet created from a fresh phrase for this run (it never
// holds anything; the phrase and password live only in this process, and
// the whole directory is deleted at the end).
//
//   BEAM_BRIDGE_LIVE=1 \
//   BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos \
//   scripts/beam/host_test.sh --no-analyze test/beam/bridge/live_pipe_test.dart
//
// Every call goes through [_ReadOnlyGuard]: views and `create_tx: false`
// builds only. `process_invoke_data` is refused before it reaches the core,
// so nothing built here can ever be sent. With BEAM_BRIDGE_RECORD=1 the raw
// answers are written to ~/beam-campfire-test/raw_fixtures/bridge (0700,
// outside the repo) as the material for the committed fixtures.
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/beam_pipe_service.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_output.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';

void _evidence(String line) {
  // ignore: avoid_print
  print('[evidence] $line');
}

String _rand(int n) {
  const chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

/// Lets through status reads and `invoke_contract` with `create_tx:
/// false` for the pipe actions only. Everything else, and
/// `process_invoke_data` above all, is refused before it reaches the core.
class _ReadOnlyGuard implements BeamTransport {
  _ReadOnlyGuard(this.inner);

  final BeamTransport inner;
  final recorded = <Map<String, Object?>>[];

  static const _actions = {
    'get_pk',
    'local_msg_count',
    'local_msg',
    'remote_msg',
    'view_incoming',
    'send',
    'receive',
  };

  static bool allows(String method, Map<String, Object?> params) {
    if (const {'get_version', 'wallet_status', 'tx_status'}.contains(method)) {
      return true;
    }
    if (method != 'invoke_contract' || params['create_tx'] != false) {
      return false;
    }
    final args = params['args'];
    if (args is! String) return false;
    final action = RegExp(r'(?:^|,)action=([a-z_]+)').firstMatch(args);
    return action != null && _actions.contains(action.group(1));
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (!allows(method, params)) {
      throw StateError('live bridge test refused $method');
    }
    final r = await inner.call(method, params, timeout);
    if (method == 'invoke_contract') {
      final res = (r! as Map).cast<String, Object?>();
      final raw = res['raw_data'] as List?;
      recorded.add({
        'args': params['args'],
        'shader_size': (params['contract']! as List).length,
        'output': res['output'],
        'txid': res['txid'],
        if (raw != null) 'raw_data_base64': base64.encode(raw.cast<int>()),
      });
    }
    return r;
  }

  @override
  Future<void> connect() => inner.connect();
  @override
  bool get isConnected => inner.isConnected;
  @override
  Stream<BeamEvent> get events => inner.events;
  @override
  Future<void> close() => inner.close();
}

const _nodes = [
  'eu-nodes.mainnet.beam.mw:8100',
  'eu-node01.mainnet.beam.mw:8100',
  'us-nodes.mainnet.beam.mw:8100',
];

/// The bETH asset-owner contract beside the bETH pipe (research 06 §B.3).
const _bethOwnerCid =
    'acefc4bed717cf94de3868e9979f72184aee00627bd3ebe1b8c0f086ab968b9f';

/// Unclaimed e2b messages pushed by the relayer long ago (indexer and
/// `remote_msg`, 2026-10-09): someone else's, so a claim built for them
/// could never be signed by this wallet. Built here only to read it.
const _unclaimed = {'usdt': 78, 'eth': 67, 'beam': 226};

/// A claimed one: `remote_msg` reads absent.
const _claimedEth = 163;

/// The b2e receiver every test build pays: not anyone's address.
const _receiver = '0x5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a';

void main() {
  final enabled = Platform.environment['BEAM_BRIDGE_LIVE'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final record = Platform.environment['BEAM_BRIDGE_RECORD'] == '1';
  final home = Platform.environment['HOME'];
  final skip = enabled && binDir != null
      ? null
      : 'set BEAM_BRIDGE_LIVE=1 and ${BeamBinaries.binDirEnv} to run';

  test('the guard refuses everything that could move funds', () {
    bool ok(String m, Map<String, Object?> p) => _ReadOnlyGuard.allows(m, p);
    expect(
      ok('process_invoke_data', {
        'data': <int>[1],
      }),
      isFalse,
    );
    expect(ok('tx_send', const {}), isFalse);
    expect(
      ok('invoke_contract', {'create_tx': true, 'args': 'action=send,cid=x'}),
      isFalse,
    );
    for (final a in ['push_remote', 'set_relayer', 'create', 'view']) {
      expect(
        ok('invoke_contract', {'create_tx': false, 'args': 'action=$a'}),
        isFalse,
      );
    }
    expect(
      ok('invoke_contract', {'create_tx': false, 'args': 'action=send,cid=x'}),
      isTrue,
    );
  });

  group('pipes on mainnet', () {
    late Directory root;
    late ProcessHost host;
    late _ReadOnlyGuard guard;
    late BeamPipeService pipes;
    BeamSession? session;
    final shaders = FileShaderSource(p.join('assets', 'beam', 'shaders'));

    setUpAll(() async {
      final base = p.join(home!, 'beam-campfire-test');
      await Directory(base).create(recursive: true);
      root = Directory(p.join(base, 'it-bridge-${_rand(8).toLowerCase()}'));
      await ensurePrivateDir(root.path);
      host = ProcessHost(
        rootDir: root.path,
        binaries: BeamBinaries(
          binDir: binDir!,
          platform: Platform.isMacOS ? 'macos-arm64' : null,
        ),
        log: (_) {},
        startupTimeout: const Duration(seconds: 30),
      );
      final walletDir = host.walletDirFor('bridge');
      final password = _rand(24);
      await host.initWallet(
        walletDir: walletDir,
        password: password,
        words: bip39.generateMnemonic().split(' '),
      );
      BeamHostException? lastError;
      for (final address in _nodes) {
        try {
          session = await host.openWallet(
            walletDir: walletDir,
            password: password,
            node: BeamNodeEndpoint.parse(address),
          );
          break;
        } on BeamHostException catch (e) {
          lastError = e;
        }
      }
      if (session == null) throw StateError('no node opened: $lastError');
      guard = _ReadOnlyGuard(session!.transport);
      final api = BeamApi(guard);
      final sw = Stopwatch()..start();
      while (!(await api.walletStatus()).isInSync) {
        if (sw.elapsed > const Duration(minutes: 5)) {
          throw StateError('the throwaway wallet never synced');
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      _evidence(
        'throwaway wallet in sync on ${session!.node} '
        'after ${sw.elapsed.inSeconds} s',
      );
      pipes = BeamPipeService(api, shaders);
    });

    tearDownAll(() async {
      await session?.close();
      await ProcessHost.shutdownAll();
      if (await root.exists()) await root.delete(recursive: true);
      _evidence('throwaway wallet deleted: ${!await root.exists()}');
      if (record) {
        final dir = Directory(
          p.join(home!, 'beam-campfire-test', 'raw_fixtures', 'bridge'),
        )..createSync(recursive: true);
        Process.runSync('chmod', ['700', dir.path]);
        final f = File(p.join(dir.path, 'recorded.json'))
          ..writeAsStringSync(
            const JsonEncoder.withIndent(' ').convert(guard.recorded),
          );
        Process.runSync('chmod', ['600', f.path]);
        _evidence('recorded ${guard.recorded.length} answers');
      }
    });

    test('tip, balance, an unknown transaction', () async {
      final tip = await pipes.tipHeight();
      _evidence('tip $tip');
      expect(tip, greaterThan(4072000));
      expect(await pipes.available(0), BigInt.zero);
      expect(await pipes.available(36), BigInt.zero);
      await expectLater(
        pipes.txStatus('0' * 31 + '1'),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.code,
            'code',
            BridgeErrorCode.network,
          ),
        ),
      );
    });

    test('get_pk: a valid key per route, the same from both shaders', () async {
      for (final r in kBridgeRoutes) {
        final key = await pipes.receiveKey(r);
        expect(key, hasLength(33));
        PipeOutput.checkKey(key);
        _evidence('${r.id}: get_pk ok, 33 bytes, parity ${key[32]}');
      }
      // The forward shader on the reverse pipe answers `pk` with the same
      // key the reverse shader names `pubkey`.
      final beam = bridgeRouteById('beam');
      final viaReverse = await pipes.receiveKey(beam);
      final raw = await BeamApi(guard).invokeContract(
        createTx: false,
        args: 'action=get_pk,cid=${beam.beamPipeCid}',
        contractBytes: await pipeAppShader(
          BridgeShader.forward,
          shaders,
        ).load(),
      );
      expect(
        PipeOutput.receiveKey(raw.output, BridgeShader.forward),
        viaReverse,
      );
      _evidence('forward and reverse shaders derive the same BEAM-pipe key');
    });

    test('local_msg_count and local_msg on every pipe', () async {
      for (final r in kBridgeRoutes) {
        final n = await pipes.localMessageCount(r);
        expect(n, greaterThan(0));
        final last = await pipes.localMessage(r, n);
        expect(last, isNotNull);
        expect(last!.receiver, matches(RegExp(r'^0x[0-9a-f]{40}$')));
        expect(last.height, greaterThan(2000000));
        expect(await pipes.localMessage(r, n + 1), isNull);
        _evidence(
          '${r.id}: count $n; msg $n amount ${last.amount} '
          'fee ${last.relayerFee} height ${last.height}',
        );
      }
      final m639 = await pipes.localMessage(bridgeRouteById('beam'), 639);
      expect(m639, isNotNull);
      _evidence(
        'beam msg 639: amount ${m639!.amount} fee ${m639.relayerFee} '
        'height ${m639.height}',
      );
    });

    test('view_incoming parses on every pipe', () async {
      for (final r in kBridgeRoutes) {
        final list = await pipes.incoming(r);
        _evidence('${r.id}: view_incoming ${list.length} entries');
        expect(list, isEmpty); // a fresh key has nothing waiting
      }
    });

    test('the asset-owner cid: view_incoming is not JSON → badPipe', () async {
      final raw = await BeamApi(guard).invokeContract(
        createTx: false,
        args: 'action=view_incoming,cid=$_bethOwnerCid',
        contractBytes: await pipeAppShader(
          BridgeShader.forward,
          shaders,
        ).load(),
      );
      _evidence('owner cid view_incoming output: ${raw.output}');
      expect(
        () => PipeOutput.incoming(raw.output),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.code,
            'code',
            BridgeErrorCode.badPipe,
          ),
        ),
      );
    });

    test('remote_msg: unclaimed ones read, claimed ones are absent', () async {
      for (final e in _unclaimed.entries) {
        final m = await pipes.remoteMessage(bridgeRouteById(e.key), e.value);
        expect(m, isNotNull, reason: '${e.key} ${e.value}');
        expect(m!.receiver, hasLength(33));
        _evidence(
          '${e.key} remote_msg ${e.value}: amount ${m.amount} '
          'fee ${m.relayerFee}',
        );
      }
      expect(
        await pipes.remoteMessage(bridgeRouteById('eth'), _claimedEth),
        isNull,
      );
    });

    test('send: a real build passes every check on every route', () async {
      for (final r in kBridgeRoutes) {
        final prepared = await pipes.prepareSend(
          r,
          ethReceiver: _receiver,
          amount: BigInt.from(100000000),
          fee: BigInt.from(1000000),
        );
        expect(prepared.networkFee, kBridgeSendFeeGroth);
        expect(prepared.sent, isFalse);
        _evidence(
          '${r.id}: send built, ${prepared.rawData.length} bytes, '
          'fee ${prepared.networkFee}',
        );
      }
    });

    test('receive: a real build passes every check (never sent)', () async {
      for (final e in _unclaimed.entries) {
        final r = bridgeRouteById(e.key);
        final m = (await pipes.remoteMessage(r, e.value))!;
        final prepared = await pipes.prepareReceive(
          r,
          msgId: e.value,
          amount: m.amount,
        );
        expect(prepared.networkFee, kBridgeClaimFeeGroth);
        _evidence(
          '${r.id}: receive of ${e.value} built, '
          '${prepared.rawData.length} bytes, fee ${prepared.networkFee}',
        );
      }
    });
  }, skip: skip);
}
