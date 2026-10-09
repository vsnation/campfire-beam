/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The common decoder against what the core really builds from the pinned
// pipe shaders (recorded on mainnet, never sent; see the fixture's
// comment): the packing of `SendFunds` and `ReceiveFunds`, the signature,
// the charge and the fee, confirmed on real bytes rather than assumed from
// the contract source.

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/beam_pipe_service.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_args.dart';
import 'package:stackwallet/wallets/beam/contracts/common/contract_args.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

import 'pipe_fixtures.dart';

void main() {
  const g = BigInt.from;

  test('the fixtures are the recorded bytes', () {
    expect(recordedBuildArgs, hasLength(8));
    for (final args in recordedBuildArgs) {
      final raw = recordedRawData(args);
      expect(
        crypto.sha256.convert(raw).toString(),
        recordedRawSha256(args),
        reason: args,
      );
    }
  });

  group('send, every route', () {
    for (final r in kBridgeRoutes) {
      test('${r.id}: method ${r.sendMethod}, receiver ‖ u64 LE amount ‖ '
          'u64 LE fee', () {
        final args = PipeArgs.send(
          cid: r.beamPipeCid,
          amount: recordedSendAmount,
          receiver: recordedReceiver,
          relayerFee: recordedSendFee,
        );
        final raw = recordedRawData(args);
        expect(raw, hasLength(91));
        final d = BeamInvokeData.decode(raw);
        final e = d.entries.single;
        // A plain call: not dependent, nothing stored to re-run.
        expect(e.flags, 0);
        expect(d.isRebuildable, isFalse);
        expect(d.appArgs, isNull);
        expect(d.spendMax, isNull);
        expect(e.method, r.sendMethod);
        expect(e.contractId, r.beamPipeCid);
        expect(e.comment, 'Send funds');
        expect(e.charge, 0);
        expect(e.signatureCount, 0);
        expect(e.dataLength, 0);

        expect(e.args, hasLength(36));
        final a = BeamArgsReader(e.args);
        expect(a.bytes(20), hexBytes(recordedReceiver));
        expect(a.u64(), recordedSendAmount);
        expect(a.u64(), recordedSendFee);
        expect(a.atEnd, isTrue);
        // Little-endian, as written: 1.0 = 0x05f5e100.
        expect(e.args.sublist(20, 28), [0x00, 0xe1, 0xf5, 0x05, 0, 0, 0, 0]);

        // amount + fee leave the wallet in the route's asset; the fee is
        // separate and in BEAM.
        expect(e.spend, {r.beamAssetId: g(101000000)});
        expect(d.pays, {r.beamAssetId: g(101000000)});
        expect(d.receives, isEmpty);
        expect(d.fee, g(1100000));
        expect(d.fee, kBridgeSendFeeGroth);
      });
    }
  });

  group('receive, forward and reverse', () {
    for (final entry in recordedReceives.entries) {
      final r = bridgeRouteById(entry.key);
      final (msgId, amount) = entry.value;
      test('${r.id} $msgId: method ${r.receiveMethod}, u64 LE msgId, '
          'signed with the pipe key, charge 1,200,000', () {
        final raw = recordedRawData(
          PipeArgs.receive(cid: r.beamPipeCid, msgId: msgId),
        );
        final d = BeamInvokeData.decode(raw);
        final e = d.entries.single;
        expect(e.flags, 0);
        expect(d.isRebuildable, isFalse);
        expect(e.method, r.receiveMethod);
        expect(e.contractId, r.beamPipeCid);
        expect(e.comment, 'Receive funds');

        expect(e.args, le(msgId, 8));
        expect(BeamArgsReader(e.args).u64(), g(msgId));

        // One signature, by the key `get_pk` derives from the cid: the
        // same hash for every wallet, so the fixture holds nothing private.
        expect(e.signatureCount, 1);
        expect(e.signatureKeyHashes, [
          BeamPipeService.pipeKeyHash(r.beamPipeCid),
        ]);

        expect(e.charge, 1200000);
        expect(e.spend, {r.beamAssetId: g(-amount)});
        expect(d.receives, {r.beamAssetId: g(amount)});
        expect(d.pays, isEmpty);
        expect(d.fee, g(12100000));
        expect(d.fee, kBridgeClaimFeeGroth);
      });
    }
  });
}
