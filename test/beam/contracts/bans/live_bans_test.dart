/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Read-only BANS proof against a real wallet-api on mainnet, with the
// pinned shader. Skipped unless BEAM_LIVE_BANS=1.
//
// Use a THROWAWAY wallet (never the funder). wallet-api runs in TCP mode
// with an ACL key, started by scripts/beam/live/wapi.py, which writes the
// port and key to a 0600 state file; this test reads them from there, so
// the key is never in the environment or on a command line:
//
//   python3 -I scripts/beam/live/wapi.py start banstmp --port 10103 --tcp
//   python3 -I scripts/beam/live/wapi.py wait-sync banstmp
//   BEAM_LIVE_BANS=1 flutter test test/beam/contracts/bans/live_bans_test.dart
//   python3 -I scripts/beam/live/wapi.py stop banstmp
//
// BEAM_LIVE_BANS_STATE overrides the state file
// (default ~/beam-campfire-test/run/banstmp.json).
//
// The guard below refuses every method except wallet_status and
// invoke_contract with create_tx=false, so nothing can be signed or sent:
// process_invoke_data is never called. Output: public chain data (names,
// keys of public names, heights, prices) only; never the ACL key.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

import 'bans_fixtures.dart';

class _ReadOnlyGuard implements BeamTransport {
  _ReadOnlyGuard(this.inner);

  final BeamTransport inner;
  final sent = <String>[];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    final ok =
        method == 'wallet_status' ||
        (method == 'invoke_contract' && params['create_tx'] == false);
    if (!ok) throw StateError('live test refused $method');
    sent.add(method);
    return inner.call(method, params, timeout);
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

String _randomName(int length) {
  final rnd = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final tail = List.generate(length - 3, (_) => chars[rnd.nextInt(36)]);
  return 'cfb${tail.join()}';
}

void main() {
  final enabled = Platform.environment['BEAM_LIVE_BANS'] == '1';
  final statePath =
      Platform.environment['BEAM_LIVE_BANS_STATE'] ??
      '${Platform.environment['HOME']}/beam-campfire-test/run/banstmp.json';

  test('BANS on mainnet, read-only', () async {
    final st = (jsonDecode(File(statePath).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final tcp = TcpLineTransport(
      port: st['port']! as int,
      aclKey: st['key']! as String,
      log: (_) {},
    );
    final guard = _ReadOnlyGuard(tcp);
    final api = BeamApi(guard);
    await guard.connect();
    final svc = BeamBansService(
      api,
      BeamExplorerClient(proxyInfo: () => null),
      shader: repoShader(),
    );

    final ws = await api.walletStatus();
    print(
      'wallet: height ${ws.currentHeight}, is_in_sync ${ws.isInSync}, '
      'block ${ws.currentStateTime.toIso8601String()}',
    );
    expect(ws.currentHeight, greaterThan(3928666));

    // 1. resolve `beam`
    final beam = await svc.resolve(BansName('beam'));
    print(
      'resolve beam: key ${beam.ownerKey}, hExpire '
      '${beam.domain?.expireHeight}, status ${beam.status.name}, '
      'expires ~${beam.expiresAt?.toIso8601String()}',
    );
    expect(beam.ownerKey, isNotNull);
    expect(BansKey.isValid(beam.ownerKey!), isTrue);
    expect(beam.domain!.expireHeight, greaterThan(ws.currentHeight));

    // 2. resolve a random unregistered name
    final freeName = BansName(_randomName(14));
    final free = await svc.resolve(freeName);
    print(
      'resolve $freeName: domain ${free.domain}, status ${free.status.name}',
    );
    expect(free.domain, isNull);
    expect(free.status, BansNameStatus.available);

    // 3. `Beam` is rejected by our rules ...
    Object? err;
    try {
      BansName('Beam');
    } on BansInvalidName catch (e) {
      err = e;
    }
    print('BansName("Beam"): ${(err! as BansInvalidName).problem.name}');
    expect(err, isA<BansInvalidName>());
    // ... and by the shader itself, the same way (bypassing our check).
    final raw = await api.invokeContract(
      createTx: false,
      args: 'role=manager,action=view_name,cid=$kBansCid,name=Beam',
      contractBytes: await repoShader().load(),
    );
    print('shader view_name name=Beam: ${raw.output}');
    expect(
      () => BansOutput.decode(raw.output),
      throwsA(
        isA<BansShaderRefused>().having(
          (e) => e.refusal,
          'refusal',
          BansRefusal.nameInvalid,
        ),
      ),
    );

    // 4. view_params / price
    final p = await svc.params();
    print(
      'view_params: vault ${p.vaultCid}, dao-vault ${p.daoVaultCid}, '
      'oracle ${p.oracleCid}, median ${p.usdPerBeamText} USD/BEAM, '
      'h0 ${p.activationHeight}',
    );
    expect(p.priceFeedLive, isTrue);

    // 5. exact register quote for a 5+ char unregistered name (built, not
    //    sent)
    final quoteName = BansName(_randomName(12));
    expect((await svc.resolve(quoteName)).domain, isNull);
    final est = p.estimate(quoteName, 1)!;
    final q = await svc.prepareRegister(quoteName, 1);
    print('register quote for $quoteName, 1 year:');
    for (final l in q.summary.lines) {
      print('  $l');
    }
    print(
      '  exact price ${q.summary.youPay.single.amount} groth; estimate '
      'from the 5-decimal median: ${est.minGroth}..${est.maxGroth}',
    );
    print('  kernel comment ${q.invokeData.comments}, '
        'charge ${q.invokeData.entries.single.charge}, '
        'raw_data ${q.rawData.length} bytes');
    final price = q.summary.youPay.single.amount;
    expect(price >= est.minGroth && price <= est.maxGroth, isTrue);
    expect(q.summary.fee, BigInt.from(1100000));
    expect(q.summary.ownerKey, await svc.myKey());

    // 6. a payment to `beam`, built only: shows the resolved owner
    final pay = await svc.preparePay(BansName('beam'), 0, BigInt.from(10000));
    print('pay quote to beam.beam, 10000 groth:');
    for (final l in pay.summary.lines) {
      print('  $l');
    }
    expect(pay.summary.ownerKey, beam.ownerKey);

    // 7. my names (a fresh wallet has none) and the claim mapping
    final mine = await svc.myNames();
    print('my names: ${mine.names.length}');
    expect(mine.names, isEmpty);
    try {
      await svc.prepareClaimAll();
      fail('stock wallet-api should refuse receive_all');
    } on BansClaimUnsupported catch (e) {
      print('receive_all -> BansClaimUnsupported: ${e.message}');
      print('  core detail: ${e.coreDetail}');
    }

    // 8. the same name without a wallet, from the explorer (display only)
    try {
      final u = await svc.lookupWithoutWallet(BansName('beam'));
      print(
        'explorer lookup beam: key ${u.domain?.ownerKey}, verified '
        '${u.verified}, explorer h ${u.explorerHeight}, status '
        '${u.status.name}',
      );
      expect(u.domain?.ownerKey, beam.ownerKey);
    } on BeamExplorerException catch (e) {
      print('explorer lookup unavailable: $e');
    }

    print('methods sent: ${guard.sent.toSet()} (${guard.sent.length} calls)');
    expect(guard.sent.toSet(), {'wallet_status', 'invoke_contract'});
    await guard.close();
  }, skip: enabled ? null : 'set BEAM_LIVE_BANS=1 to run',
     timeout: const Timeout(Duration(minutes: 5)));
}
