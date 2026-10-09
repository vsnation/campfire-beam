/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds: one airdrop round trip on mainnet
// through BeamAirdropService, the service the airdrop screens use, between
// two test wallets:
//
//   1. the creator makes a batch of ONE voucher worth 0.01 BEAM
//      (fee 0.121 BEAM + the 1% creation fee);
//   2. the claimer checks the code, claims it (fee 0.121 BEAM), and the
//      voucher reads as redeemed.
//
// Skipped unless BEAM_LIVE_AIRDROP_RT=1. Both wallets must run in TCP mode
// (scripts/beam/live/wapi.py); labels BEAM_LIVE_CREATOR (default funder2)
// and BEAM_LIVE_CLAIMER (default lwtest).
//
// The voucher code is a key to the funds: it is never printed. It is kept
// in memory, and also written 0600 to ~/beam-campfire-test/airdrop_codes/
// (outside the repo) the moment the batch is built, so a failed claim
// never strands the voucher.
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 45))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/beam_airdrop_service.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

import 'memory_code_store.dart';

final BigInt _voucher = BigInt.from(1000000); // 0.01 BEAM
final BigInt _maxFee = BigInt.from(20000000); // 0.2 BEAM

String _b(BigInt g) => (g.toDouble() / 1e8).toStringAsFixed(8);
String _short(String s) => s.length <= 12 ? s : s.substring(0, 12);

Future<(BeamApi, TcpLineTransport)> _open(String label) async {
  final home = Platform.environment['HOME']!;
  final state =
      jsonDecode(
            File('$home/beam-campfire-test/run/$label.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final t = TcpLineTransport(
    port: state['port']! as int,
    aclKey: state['key']! as String,
    log: (_) {},
  );
  await t.connect();
  return (BeamApi(t), t);
}

Future<BeamTransaction> _waitDone(BeamApi api, String txId) async {
  final sw = Stopwatch()..start();
  while (true) {
    final tx = await api.txStatus(txId);
    if (tx.status == BeamTxStatus.completed ||
        tx.status == BeamTxStatus.failed ||
        tx.status == BeamTxStatus.canceled) {
      print(
        '[evidence] tx ${_short(txId)} ${tx.statusString} at height '
        '${tx.height} after ${sw.elapsed.inSeconds} s',
      );
      return tx;
    }
    if (sw.elapsed > const Duration(minutes: 20)) {
      fail('tx ${_short(txId)} not done after 20 min: ${tx.statusString}');
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
}

void main() {
  final enabled = Platform.environment['BEAM_LIVE_AIRDROP_RT'] == '1';

  test(
    'create a one-voucher batch, then claim it from another wallet',
    () async {
      final env = Platform.environment;
      final (creatorApi, creatorT) = await _open(
        env['BEAM_LIVE_CREATOR'] ?? 'funder2',
      );
      final (claimerApi, claimerT) = await _open(
        env['BEAM_LIVE_CLAIMER'] ?? 'lwtest',
      );
      final shader = airdropAppShader(
        const FileShaderSource('assets/beam/shaders'),
      );
      final creator = BeamAirdropService(
        creatorApi,
        shader,
        store: MemoryCodeStore(),
      );
      final claimer = BeamAirdropService(claimerApi, shader);

      for (final api in [creatorApi, claimerApi]) {
        final s = await api.walletStatus();
        expect(s.isInSync, isTrue, reason: 'never call contracts out of sync');
      }

      // --- 1. create ---
      final create = await creator.prepareCreateBatch(
        assetId: 0,
        values: [_voucher],
      );
      final code = create.codes.single;
      final dir = Directory(
        '${env['HOME']}/beam-campfire-test/airdrop_codes',
      )..createSync(recursive: true);
      final keep = File(
        '${dir.path}/${DateTime.now().toUtc().millisecondsSinceEpoch}.txt',
      )..writeAsStringSync('$code\n');
      await Process.run('chmod', ['600', keep.path]);
      final c = create.summary;
      print(
        '[evidence] create built: pays '
        '${c.pays.map((k, v) => MapEntry(k, _b(v)))}'
        ', creation fee ${_b(c.creationFee!)}, network fee '
        '${_b(c.networkFee)} BEAM, vouchers ${c.voucherCount}',
      );
      expect(c.pays[0], _voucher + c.creationFee!);
      expect(c.networkFee <= _maxFee, isTrue);
      final createTx = await creator.execute(create);
      expect(
        () => creator.execute(create),
        throwsA(isA<BeamAirdropException>()),
      );
      final created = await _waitDone(creatorApi, createTx);
      expect(created.status, BeamTxStatus.completed);

      // --- 2. claim from the other wallet ---
      final info = await claimer.checkVoucher(code);
      expect(info, isNotNull, reason: 'the new voucher is on chain');
      expect(info!.value, _voucher);
      expect(info.redeemed, isFalse);
      final redeem = await claimer.prepareRedeem(code);
      final r = redeem.summary;
      print(
        '[evidence] claim built: receives '
        '${r.receives.map((k, v) => MapEntry(k, _b(v)))}, network fee '
        '${_b(r.networkFee)} BEAM',
      );
      expect(r.receives[0], _voucher);
      expect(r.networkFee <= _maxFee, isTrue);
      final claimTx = await claimer.execute(redeem);
      final claimed = await _waitDone(claimerApi, claimTx);
      expect(claimed.status, BeamTxStatus.completed);

      final after = await claimer.checkVoucher(code);
      expect(after!.redeemed, isTrue);
      print('[evidence] voucher now reads as redeemed');
      keep.deleteSync();
      await creatorT.close();
      await claimerT.close();
    },
    skip: enabled ? null : 'set BEAM_LIVE_AIRDROP_RT=1 to run',
  );
}
