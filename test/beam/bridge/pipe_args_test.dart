/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_args.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';

void main() {
  const g = BigInt.from;
  final beam = bridgeRouteById('beam').beamPipeCid;
  final usdt = bridgeRouteById('usdt').beamPipeCid;
  const receiver = '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a';
  final max = (BigInt.one << 63) - BigInt.one;

  group('every action, exactly as sent (no role)', () {
    test('views', () {
      expect(PipeArgs.getPk(cid: beam), 'action=get_pk,cid=$beam');
      expect(
        PipeArgs.localMsgCount(cid: usdt),
        'action=local_msg_count,cid=$usdt',
      );
      expect(
        PipeArgs.localMsg(cid: beam, msgId: 639),
        'action=local_msg,cid=$beam,msgId=639',
      );
      expect(
        PipeArgs.remoteMsg(cid: usdt, msgId: 78),
        'action=remote_msg,cid=$usdt,msgId=78',
      );
      expect(
        PipeArgs.viewIncoming(cid: beam),
        'action=view_incoming,cid=$beam',
      );
      expect(
        PipeArgs.viewIncoming(cid: beam, startFrom: 226),
        'action=view_incoming,cid=$beam,startFrom=226',
      );
      for (final a in [
        PipeArgs.getPk(cid: beam),
        PipeArgs.viewIncoming(cid: beam, startFrom: 0),
      ]) {
        expect(a, isNot(contains('role')));
      }
    });

    test('send: canonical decimals, receiver without 0x', () {
      expect(
        PipeArgs.send(
          cid: usdt,
          amount: g(100000000),
          receiver: receiver,
          relayerFee: g(1000000),
        ),
        'action=send,cid=$usdt,amount=100000000,receiver=$receiver,'
        'relayerFee=1000000',
      );
      // The largest sum the core can hold: 2^63-1 in total.
      expect(
        PipeArgs.send(
          cid: beam,
          amount: max - BigInt.one,
          receiver: receiver,
          relayerFee: BigInt.one,
        ),
        contains('amount=9223372036854775806,'),
      );
    });

    test('receive', () {
      expect(
        PipeArgs.receive(cid: usdt, msgId: 78),
        'action=receive,cid=$usdt,msgId=78',
      );
    });

    test('e2b ids start at 0 (the Ethereum pipe counts from 0)', () {
      expect(
        PipeArgs.remoteMsg(cid: beam, msgId: 0),
        'action=remote_msg,cid=$beam,msgId=0',
      );
      expect(
        PipeArgs.receive(cid: beam, msgId: 0),
        'action=receive,cid=$beam,msgId=0',
      );
    });

    test('every route\'s pipe is accepted', () {
      for (final r in kBridgeRoutes) {
        expect(PipeArgs.getPk(cid: r.beamPipeCid), endsWith(r.beamPipeCid));
      }
    });
  });

  group('refusals', () {
    const bad = throwsArgumentError;

    test('cids not in the registry', () {
      const owner =
          'acefc4bed717cf94de3868e9979f72184aee00627bd3ebe1b8c0f086ab968b9f';
      const dex =
          '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';
      for (final cid in [owner, dex, beam.toUpperCase(), '', 'x']) {
        expect(() => PipeArgs.getPk(cid: cid), bad, reason: cid);
        expect(() => PipeArgs.receive(cid: cid, msgId: 1), bad);
        expect(
          () => PipeArgs.send(
            cid: cid,
            amount: g(1),
            receiver: receiver,
            relayerFee: g(1),
          ),
          bad,
        );
      }
    });

    test('message ids: b2e below 1, e2b and startFrom below 0', () {
      expect(() => PipeArgs.localMsg(cid: beam, msgId: 0), bad);
      expect(() => PipeArgs.localMsg(cid: beam, msgId: -1), bad);
      expect(() => PipeArgs.remoteMsg(cid: beam, msgId: -1), bad);
      expect(() => PipeArgs.receive(cid: beam, msgId: -1), bad);
      expect(() => PipeArgs.viewIncoming(cid: beam, startFrom: -1), bad);
    });

    test('send amounts: non-positive, too large, a sum that overflows', () {
      String send(BigInt a, BigInt f) => PipeArgs.send(
        cid: beam,
        amount: a,
        receiver: receiver,
        relayerFee: f,
      );
      expect(() => send(g(0), g(1)), bad);
      expect(() => send(g(-1), g(1)), bad);
      expect(() => send(g(1), g(0)), bad);
      expect(() => send(g(1), g(-1)), bad);
      expect(() => send(max + BigInt.one, g(1)), bad);
      expect(() => send(g(1), max + BigInt.one), bad);
      // Each fits, the sum does not: the contract would wrap it.
      expect(() => send(max, g(1)), bad);
      final half = BigInt.one << 62;
      expect(() => send(half, half), bad);
      // The real attack: 2^64 - 5e9 + 1 with a 50 BEAM fee wraps to 1.
      expect(
        () => send(BigInt.parse('18446744068709551617'), g(5000000000)),
        bad,
      );
    });

    test('receivers that are not 40 lowercase hex', () {
      String send(String r) =>
          PipeArgs.send(cid: beam, amount: g(1), receiver: r, relayerFee: g(1));
      for (final r in [
        '0x$receiver',
        receiver.toUpperCase(),
        receiver.substring(1),
        '${receiver}5a',
        '${receiver.substring(2)}zz',
        '',
      ]) {
        expect(() => send(r), bad, reason: r);
      }
    });
  });
}
