/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Read-only Airdrop calls against a real wallet-api on mainnet, plus one
// create_batch that is BUILT (create_tx: false) and decoded, never sent.
//
// Skipped unless BEAM_LIVE_AIRDROP=1. Reads the port and ACL key of a
// running TCP-mode wallet-api from ~/beam-campfire-test/run/funder.json:
//
//   python3 -I scripts/beam/live/wapi.py start funder --port 10104 --tcp
//   CFB_HOST_WORKDIR=/private/tmp/cfb-air BEAM_LIVE_AIRDROP=1 \
//     scripts/beam/host_test.sh --no-analyze \
//     test/beam/contracts/airdrop/live_airdrop_test.dart
//   python3 -I scripts/beam/live/wapi.py stop funder
//
// BuildOnlyGuard refuses process_invoke_data and any create_tx other than
// false before it reaches the core. Prints public contract data, the
// decoded summary and fees; never the ACL key, balances, codes or this
// wallet's key. Raw answers are written outside the repo, to
// ~/beam-campfire-test/raw_fixtures/campfire-airdrop/, and a sanitized copy
// (wallet key replaced by a synthetic one) beside it.

// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'invoke_data_writer.dart';
import 'live_support.dart';
import 'memory_code_store.dart';

void main() {
  final enabled = Platform.environment['BEAM_LIVE_AIRDROP'] == '1';
  final skip = enabled ? null : 'set BEAM_LIVE_AIRDROP=1 to run';

  test('the guard refuses everything that could send', () {
    final g = BuildOnlyGuard(FakeTransport(), {'create_batch'});
    expect(
      g.allows('process_invoke_data', {
        'data': <int>[1],
      }),
      isFalse,
    );
    expect(g.allows('tx_send', const {}), isFalse);
    expect(
      g.allows('invoke_contract', {
        'create_tx': true,
        'args': 'role=user,action=create_batch',
      }),
      isFalse,
    );
    expect(
      g.allows('invoke_contract', {'args': 'role=user,action=create_batch'}),
      isFalse,
    );
    expect(
      g.allows('invoke_contract', {
        'create_tx': false,
        'args': 'role=user,action=cancel_batch',
      }),
      isFalse,
    );
    expect(
      g.allows('invoke_contract', {
        'create_tx': false,
        'args': 'role=user,action=create_batch,cid=x',
      }),
      isTrue,
    );
  });

  test(
    'airdrop views and a built, never sent, create_batch on mainnet',
    () async {
      final guard = BuildOnlyGuard(funderTransport(), {
        'get_my_key',
        'check_voucher',
        'view_my_batches',
        'view',
        'view_stats',
        'view_fees',
        'create_batch',
        'redeem',
        'view_batch_vouchers',
        'cancel_batch',
        'withdraw_fees',
      });
      await guard.connect();
      final api = BeamApi(guard);
      final shader = airdropAppShader(
        const FileShaderSource('assets/beam/shaders'),
      );
      final store = MemoryCodeStore();
      final service = BeamAirdropService(api, shader, store: store);

      final status = await api.walletStatus();
      print(
        'wallet_status: height ${status.currentHeight}, '
        'is_in_sync ${status.isInSync}',
      );
      expect(status.isInSync, isTrue);

      final stats = await service.stats();
      print(
        'view_stats (role=manager): batches ${stats.totalBatches}, '
        'vouchers ${stats.totalVouchers}, redeemed ${stats.totalRedeemed}, '
        'available ${stats.availableVouchers}',
      );
      final settings = await service.settings();
      print(
        'view (role=manager): version ${settings.version}, paused '
        '${settings.paused}, this wallet is owner: ${settings.isOwner}',
      );
      final fees = await service.fees();
      print(
        'view_fees: ${[for (final f in fees) 'asset ${f.assetId}: '
              '${f.accumulated} collected, ${f.available} available']}',
      );
      final mine = await service.myBatches();
      print('view_my_batches: ${mine.length} batches for this wallet');

      final probe = AirdropVoucherCode.generate();
      final none = await service.checkVoucher(probe);
      print('check_voucher on a fresh random code: ${none ?? 'not found'}');
      expect(none, isNull);
      await expectLater(
        service.prepareRedeem(probe),
        throwsA(
          isA<BeamAirdropException>().having(
            (e) => e.code,
            'code',
            AirdropErrorCode.voucherNotFound,
          ),
        ),
      );
      // The shader's own refusal, without the service's pre-check.
      final direct = await api.invokeContract(
        createTx: false,
        args: AirdropArgs.redeem(
          normalisedCode: AirdropVoucherCode.normalise(probe),
        ),
        contractBytes: await shader.load(),
      );
      print('redeem of that code, straight to the shader: ${direct.output}');
      expect(direct.rawData, isNull);
      expect(
        () => ShaderOutput.decode(direct.output),
        throwsA(isA<BeamShaderException>()),
      );

      // Build (never send) a batch of 2 vouchers of 0.001 BEAM.
      final prepared = await service.prepareCreateBatch(
        assetId: 0,
        values: [BigInt.from(100000), BigInt.from(100000)],
      );
      final s = prepared.summary;
      print('--- create_batch, built with create_tx:false, NOT sent ---');
      s.lines.forEach(print);
      final e = prepared.invoke.entries.single;
      print(
        'decoded: cid ${e.contractId}, method ${e.method}, charge '
        '${e.charge}, comment "${e.comment}", args ${e.args.length} bytes, '
        'signing keys ${e.signatureCount}, spend ${prepared.invoke.spend}, '
        'network fee ${prepared.invoke.fee} groth',
      );
      expect(e.contractId, kAirdropContractId);
      expect(e.method, AirdropMethod.createBatch);
      expect(e.args.length, 41 + 2 * 40);
      expect(prepared.invoke.spend, {0: BigInt.from(202000)});
      expect(s.creationFee, BigInt.from(2000));
      expect(prepared.invoke.fee, kAirdropCallFee);
      expect(kAirdropCallFee, BigInt.from(12100000));
      service.discard(prepared);
      expect(store.deletes, 0);
      expect(await store.all(), isEmpty, reason: 'nothing was executed');

      // Owner and creator paths, built only when this wallet has them.
      if (settings.isOwner && fees.any((f) => f.available > BigInt.zero)) {
        final f = fees.firstWhere((f) => f.available > BigInt.zero);
        final w = await service.prepareWithdrawFees(
          assetId: f.assetId,
          amount: BigInt.one,
        );
        print('--- withdraw_fees of 1 unit, built, NOT sent ---');
        w.summary.lines.forEach(print);
        print(
          'decoded: method ${w.invoke.entries.single.method}, charge '
          '${w.invoke.entries.single.charge}, args '
          '${w.invoke.entries.single.args.length} bytes, spend '
          '${w.invoke.spend}, network fee ${w.invoke.fee} groth',
        );
        expect(w.invoke.fee, kAirdropCallFee);
        service.discard(w);
      }
      final open = mine.where((b) => b.unclaimedCount > 0).toList();
      if (open.isNotEmpty) {
        final c = await service.prepareCancelBatch(open.first.id);
        print(
          '--- cancel_batch of one of this wallet\'s batches '
          '(${c.summary.voucherCount} unclaimed), built, NOT sent ---',
        );
        c.summary.lines.forEach(print);
        print(
          'decoded: method ${c.invoke.entries.single.method}, charge '
          '${c.invoke.entries.single.charge}, args '
          '${c.invoke.entries.single.args.length} bytes, network fee '
          '${c.invoke.fee} groth',
        );
        expect(c.invoke.fee, kAirdropCancelFee);
        service.discard(c);
      }
      expect(service.isBusy, isFalse);

      // The test writer reproduces the core's bytes exactly, which also
      // confirms the signing-key preimage the shader asks for:
      // SHA-256("bvm.m.key\0" || cid || 00).
      final key = await service.myKey();
      final sig = crypto.sha256.convert([
        ...'bvm.m.key'.codeUnits,
        0,
        ...hexToBytes(kAirdropContractId),
        0,
      ]).bytes;
      final rebuilt = InvokeDataWriter.write([
        FakeInvokeEntry(
          method: AirdropMethod.createBatch,
          cid: kAirdropContractId,
          args: e.args,
          funds: prepared.invoke.spend,
          comment: e.comment,
          charge: e.charge,
          sigs: [sig],
        ),
      ]);
      expect(rebuilt, prepared.rawData);
      print('InvokeDataWriter reproduces the raw_data byte for byte');

      // Fixtures: raw outside the repo; sanitized beside it.
      final rawDir = rawFixtureDir('campfire-airdrop');
      final cleanDir = rawFixtureDir('campfire-airdrop-sanitized');
      final (clean, hits) = replaceBytes(
        prepared.rawData,
        hexToBytes(key),
        hexToBytes(fakeKey),
      );
      expect(hits, 1, reason: 'the creator key appears once, in the args');
      final cleanData = BeamInvokeData.decode(clean);
      expect(cleanData.spend, prepared.invoke.spend);
      writeEnvelope(File('${rawDir.path}/create_batch_2x0.001.json'), {
        'output': '{}',
        'txid': '00000000000000000000000000000000',
        'raw_data': prepared.rawData,
      });
      writeEnvelope(File('${cleanDir.path}/create_batch_2x0.001.json'), {
        'output': '{}',
        'txid': '00000000000000000000000000000000',
        'raw_data': clean,
      });
      for (final r in guard.recorded) {
        final action = RegExp(r'action=([a-z_]+)')
            .firstMatch(r.args ?? '')
            ?.group(1);
        if (action == null) continue;
        const keep = {
          'view_stats',
          'view',
          'view_fees',
          'check_voucher',
          'redeem',
        };
        writeEnvelope(File('${rawDir.path}/$action.json'), r.result);
        if (keep.contains(action)) {
          writeEnvelope(File('${cleanDir.path}/$action.json'), r.result);
        }
      }
      expect(
        guard.recorded.where((r) => r.method == 'process_invoke_data'),
        isEmpty,
      );
      print(
        'requests sent: ${guard.recorded.length}, none process_invoke_data',
      );
      await guard.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('a random probe code is uniformly drawn', () {
    // Not live: a sanity check that the probe above is a real code.
    final c = AirdropVoucherCode.generate(Random(1));
    expect(AirdropVoucherCode.isWellFormed(c), isTrue);
  });
}
