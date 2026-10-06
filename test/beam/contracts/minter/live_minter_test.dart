/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Read-only Minter and BlackHole calls against a real wallet-api on
// mainnet, plus a create_token and a 1-unit burn that are BUILT
// (create_tx: false) and decoded, never sent.
//
// Skipped unless BEAM_LIVE_MINT=1. Same funder state file and guard as
// test/beam/contracts/airdrop/live_airdrop_test.dart:
//
//   python3 -I scripts/beam/live/wapi.py start funder --port 10104 --tcp
//   CFB_HOST_WORKDIR=/private/tmp/cfb-air BEAM_LIVE_MINT=1 \
//     scripts/beam/host_test.sh --no-analyze \
//     test/beam/contracts/minter/live_minter_test.dart
//   python3 -I scripts/beam/live/wapi.py stop funder
//
// Prints public contract data, decoded summaries and fees. The asset
// burned is picked from the wallet's non-zero balances; no balance is
// printed.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/burn/burn.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter.dart';

import '../airdrop/invoke_data_writer.dart';
import '../airdrop/live_support.dart';

void main() {
  final enabled = Platform.environment['BEAM_LIVE_MINT'] == '1';
  final skip = enabled ? null : 'set BEAM_LIVE_MINT=1 to run';
  const shaders = FileShaderSource('assets/beam/shaders');

  test(
    'minter views, a built create_token and a built burn on mainnet',
    () async {
      final guard = BuildOnlyGuard(funderTransport(), {
        'view_params',
        'view_owned',
        'view_token',
        'create_token',
        'view_funds',
        'deposit',
        'withdraw',
      });
      await guard.connect();
      final api = BeamApi(guard);
      final minter = BeamMinterService(api, minterAppShader(shaders));
      final burn = BeamBurnService(api, blackHoleAppShader(shaders));

      final status = await api.walletStatus();
      print(
        'wallet_status: height ${status.currentHeight}, '
        'is_in_sync ${status.isInSync}',
      );
      expect(status.isInSync, isTrue);

      final params = await minter.params();
      print(
        'view_params: tokenIssueFee ${params.issueFee} groth, '
        'cidDaoVault ${params.daoVaultCid}',
      );
      final owned = await minter.ownedTokens();
      print('view_owned: ${owned.length} tokens created by this wallet');
      final cto = await minter.token(44);
      print(
        'view_token 44: minted ${cto?.minted}, limit ${cto?.limit}, '
        'is_owner ${cto?.isOwner}, metadata ${cto?.metadata}',
      );
      final none = await minter.token(0xfffffff0);
      print('view_token 4294967280: ${none ?? 'no such token'}');
      expect(none, isNull);

      // Build (never send) a token, to read the BEAM it would take.
      final meta = BeamTokenMetadata(
        name: 'Campfire build check',
        shortName: 'CFBC',
        unitName: 'CFBC',
        shortDescription: 'Built and decoded by a test, never sent.',
      );
      final created = await minter.prepareCreateToken(
        metadata: meta,
        limit: meta.supplyOf(BigInt.from(1000)),
      );
      print('--- create_token, built with create_tx:false, NOT sent ---');
      created.summary.lines.forEach(print);
      final ce = created.invoke.entries.single;
      print(
        'decoded: cid ${ce.contractId}, method ${ce.method}, charge '
        '${ce.charge}, comment "${ce.comment}", args ${ce.args.length} '
        'bytes, keys ${ce.signatureCount}, spend ${created.invoke.spend}, '
        'network fee ${created.invoke.fee} groth',
      );
      expect(created.invoke.spend, {0: kMinterAssetDeposit + params.issueFee});
      expect(created.invoke.fee, kMinterCreateTokenFee);
      minter.discard(created);

      // Build (never send) a burn of 1 unit of an asset this wallet holds.
      final held = [
        for (final t in status.totals)
          if (t.assetId != 0 && t.available > BigInt.zero) t.assetId,
      ]..sort();
      print('assets held besides BEAM: ${held.length}');
      expect(held, isNotEmpty, reason: 'needs some token to build a burn');
      final aid = held.first;
      final burned = await burn.prepareBurn(assetId: aid, amount: BigInt.one);
      print('--- BlackHole deposit, built with create_tx:false, NOT sent ---');
      burned.summary.lines.forEach(print);
      final be = burned.invoke.entries.single;
      print(
        'decoded: cid ${be.contractId}, method ${be.method}, charge '
        '${be.charge}, comment "${be.comment}", args ${be.args.length} '
        'bytes, keys ${be.signatureCount}, spend ${burned.invoke.spend}, '
        'network fee ${burned.invoke.fee} groth',
      );
      expect(burned.invoke.spend, {aid: BigInt.one});
      expect(burned.invoke.fee, kBurnFee);
      burn.discard(burned);

      // Build (never send) a mint of 1 unit of a token this wallet created.
      final mintable = owned.where((t) => t.mintable > BigInt.zero).toList();
      print('owned tokens with room to mint: ${mintable.length}');
      if (mintable.isNotEmpty) {
        final t = mintable.first;
        final minted = await minter.prepareMint(
          assetId: t.assetId,
          value: BigInt.one,
        );
        print(
          '--- Minter withdraw (mint), built with create_tx:false, NOT '
          'sent ---',
        );
        minted.summary.lines.forEach(print);
        final me = minted.invoke.entries.single;
        print(
          'decoded: method ${me.method}, charge ${me.charge}, comment '
          '"${me.comment}", args ${me.args.length} bytes, keys '
          '${me.signatureCount}, network fee ${minted.invoke.fee} groth',
        );
        expect(minted.invoke.fee, kMinterMintFee);
        minter.discard(minted);
        // The signing key the shader asks for: SHA-256("bvm.m.key\0" ||
        // m_hv), m_hv = SHA-256(cid || leb128(limitLo) || leb128(limitHi)
        // || metadata) (minter/app.cpp MyKeyID::Set).
        List<int> leb(BigInt v) {
          final out = <int>[];
          var x = v;
          while (x >= BigInt.from(0x80)) {
            out.add((x & BigInt.from(0x7f)).toInt() | 0x80);
            x >>= 7;
          }
          return out..add(x.toInt());
        }

        final mask = (BigInt.one << 64) - BigInt.one;
        final hv = crypto.sha256.convert([
          ...hexToBytes(kMinterContractId),
          ...leb(t.limit & mask),
          ...leb(t.limit >> 64),
          ...utf8.encode(t.metadata!),
        ]).bytes;
        final sig = crypto.sha256.convert([
          ...'bvm.m.key'.codeUnits,
          0,
          ...hv,
        ]).bytes;
        expect(
          InvokeDataWriter.write([
            FakeInvokeEntry(
              method: me.method,
              cid: me.contractId!,
              args: me.args,
              funds: minted.invoke.spend,
              comment: me.comment,
              charge: me.charge,
              sigs: [sig],
            ),
          ]),
          minted.rawData,
        );
        print(
          'the mint raw_data re-encodes byte for byte, signing key '
          'preimage included',
        );
      }

      final totals = await burn.burnedTotals();
      print('view_funds: ${totals.length} assets ever burned');

      // The test writer reproduces both transactions byte for byte.
      for (final (p, data) in [
        (created.rawData, created.invoke),
        (burned.rawData, burned.invoke),
      ]) {
        final e = data.entries.single;
        expect(
          InvokeDataWriter.write([
            FakeInvokeEntry(
              method: e.method,
              cid: e.contractId!,
              args: e.args,
              funds: data.spend,
              comment: e.comment,
              charge: e.charge,
            ),
          ]),
          p,
        );
      }
      print('InvokeDataWriter reproduces both raw_data byte for byte');

      // Fixtures. The new token's owner key (args bytes 20..52) is derived
      // from this wallet's master key: replace it.
      final rawDir = rawFixtureDir('campfire-minter');
      final cleanDir = rawFixtureDir('campfire-minter-sanitized');
      final ownerKey = ce.args.sublist(20, 53);
      final (cleanToken, hits) = replaceBytes(
        created.rawData,
        ownerKey,
        hexToBytes(fakeKey),
      );
      expect(hits, 1);
      expect(BeamInvokeData.decode(cleanToken).spend, created.invoke.spend);
      writeEnvelope(File('${rawDir.path}/create_token.json'), {
        'output': '{}',
        'txid': '00000000000000000000000000000000',
        'raw_data': created.rawData,
      });
      writeEnvelope(File('${cleanDir.path}/create_token.json'), {
        'output': '{}',
        'txid': '00000000000000000000000000000000',
        'raw_data': cleanToken,
      });
      writeEnvelope(File('${rawDir.path}/burn_1.json'), {
        'output': '{}',
        'txid': '00000000000000000000000000000000',
        'raw_data': burned.rawData,
      });
      for (final r in guard.recorded) {
        final action = RegExp(r'action=([a-z_]+)')
            .firstMatch(r.args ?? '')
            ?.group(1);
        if (action == null) continue;
        final aidArg = RegExp(r'aid=(\d+)').firstMatch(r.args!)?.group(1);
        final name = aidArg == null ? action : '${action}_$aidArg';
        writeEnvelope(File('${rawDir.path}/$name.json'), r.result);
        if (const {'view_params', 'view_funds'}.contains(action) ||
            name == 'view_token_44' ||
            name == 'view_token_4294967280') {
          writeEnvelope(File('${cleanDir.path}/$name.json'), r.result);
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
}
