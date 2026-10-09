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
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_output.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';

import 'pipe_fixtures.dart';

Matcher _refused(BridgeErrorCode code) =>
    throwsA(isA<BridgeException>().having((e) => e.code, 'code', code));

final _badPipe = _refused(BridgeErrorCode.badPipe);

/// x of the secp256k1 generator: a point.
const _gx = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

/// The secp256k1 field prime, in hex.
const _p = 'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f';

/// The smallest x that is not on secp256k1 (x³ + 7 a non-square mod p).
String _offCurveX() {
  final p = BigInt.parse(_p, radix: 16);
  for (var x = BigInt.one; ; x += BigInt.one) {
    final rhs = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    if (rhs.modPow((p - BigInt.one) >> 1, p) != BigInt.one) {
      return x.toRadixString(16).padLeft(64, '0');
    }
  }
}

void main() {
  const g = BigInt.from;
  final beam = bridgeRouteById('beam');
  final eth = bridgeRouteById('eth');

  String view(BridgeRoute r, String args) => recordedView(r.shader, args)!;

  group('get_pk', () {
    test('recorded shapes: pk (forward), pubkey (reverse)', () {
      for (final r in kBridgeRoutes) {
        final key = PipeOutput.receiveKey(
          view(r, PipeArgs.getPk(cid: r.beamPipeCid)),
          r.shader,
        );
        expect(key, hexBytes('${_gx}00'));
      }
    });

    test('each shader must use its own name for the key', () {
      expect(
        () => PipeOutput.receiveKey('{"pk": "${_gx}00"}', BridgeShader.reverse),
        _badPipe,
      );
      expect(
        () => PipeOutput.receiveKey(
          '{"pubkey": "${_gx}00"}',
          BridgeShader.forward,
        ),
        _badPipe,
      );
    });

    test('both parities of a real point', () {
      PipeOutput.checkKey(hexBytes('${_gx}00'));
      PipeOutput.checkKey(hexBytes('${_gx}01'));
    });

    test('bad keys: 32 bytes, 34 bytes, parity 02, zero X, X ≥ p, '
        'off the curve, not hex, upper case', () {
      for (final out in [
        '{"pk": "$_gx"}', // 32 bytes
        '{"pk": "${_gx}0000"}', // 34 bytes
        '{"pk": "${_gx}02"}',
        '{"pk": "${_gx}ff"}',
        '{"pk": "${'0' * 64}00"}',
        '{"pk": "${_p}00"}',
        '{"pk": "${'f' * 64}01"}',
        '{"pk": "${_offCurveX()}00"}',
        '{"pk": "${'zz' * 33}"}',
        '{"pk": "${_gx.toUpperCase()}00"}',
        '{"pk": 5}',
        '{}',
        '{"error": "no params"}',
        'not json',
      ]) {
        expect(
          () => PipeOutput.receiveKey(out, BridgeShader.forward),
          _badPipe,
          reason: out,
        );
      }
      expect(() => PipeOutput.checkKey(hexBytes(_gx)), _badPipe);
    });
  });

  group('local_msg_count and local_msg', () {
    test('recorded counts', () {
      final counts = {
        for (final r in kBridgeRoutes)
          r.id: PipeOutput.count(
            view(r, PipeArgs.localMsgCount(cid: r.beamPipeCid)),
          ),
      };
      expect(counts, {
        'beam': 639,
        'eth': 107,
        'wbtc': 19,
        'usdt': 108,
        'dai': 40,
      });
    });

    test('a recorded message, exact amounts, 0x receiver', () {
      final m = PipeOutput.localMessage(
        view(beam, PipeArgs.localMsg(cid: beam.beamPipeCid, msgId: 639)),
      )!;
      expect(m.amount, g(23759052883550));
      expect(m.relayerFee, g(2986536262));
      expect(m.receiver, '0x${'5b' * 20}');
      expect(m.height, 4072516);
    });

    test('absent ids are null, on both shaders', () {
      expect(
        PipeOutput.localMessage(
          view(beam, PipeArgs.localMsg(cid: beam.beamPipeCid, msgId: 640)),
        ),
        isNull,
      );
      expect(
        PipeOutput.localMessage(
          view(eth, PipeArgs.localMsg(cid: eth.beamPipeCid, msgId: 108)),
        ),
        isNull,
      );
    });

    test('amounts past 2^63 stay exact (the overflow messages 563, 570)', () {
      final m = PipeOutput.localMessage(
        '{"amount": 18446744068709551617,"relayerFee": 5000000000,'
        '"receiver": "${'5b' * 20}","height": 3500000}',
      )!;
      expect(m.amount, BigInt.parse('18446744068709551617'));
    });

    test('anything else is badPipe', () {
      for (final out in [
        '{"error": "no params"}',
        '{"error": "invalid Action."}',
        '{"amount": 1,"relayerFee": 1,"receiver": "${'5b' * 19}",'
            '"height": 1}',
        '{"amount": 1,"relayerFee": 1,"receiver": "0x${'5b' * 20}",'
            '"height": 1}',
        '{"amount": -1,"relayerFee": 1,"receiver": "${'5b' * 20}",'
            '"height": 1}',
        '{"amount": 1.5,"relayerFee": 1,"receiver": "${'5b' * 20}",'
            '"height": 1}',
        '{"amount": 1,"relayerFee": 1,"receiver": "${'5b' * 20}"}',
        '{"amount": "1","relayerFee": 1,"receiver": "${'5b' * 20}",'
            '"height": 1}',
        '',
      ]) {
        expect(() => PipeOutput.localMessage(out), _badPipe, reason: out);
      }
      expect(() => PipeOutput.count('{"count": -1}'), _badPipe);
      expect(() => PipeOutput.count('{"count": 1e3}'), _badPipe);
      expect(() => PipeOutput.count('{}'), _badPipe);
    });
  });

  group('remote_msg', () {
    test('recorded unclaimed messages, exact, 33-byte receiver', () {
      final usdt = bridgeRouteById('usdt');
      final m = PipeOutput.remoteMessage(
        view(usdt, PipeArgs.remoteMsg(cid: usdt.beamPipeCid, msgId: 78)),
      )!;
      expect(m.amount, g(91049000)); // 0.91049 USDT, ×100 into groth
      expect(m.relayerFee, g(59200));
      expect(m.receiver, hexBytes('${_gx}00'));
      final b = PipeOutput.remoteMessage(
        view(beam, PipeArgs.remoteMsg(cid: beam.beamPipeCid, msgId: 226)),
      )!;
      expect(b.amount, g(2000000));
    });

    test('a claimed message is absent: null', () {
      expect(
        PipeOutput.remoteMessage(
          view(eth, PipeArgs.remoteMsg(cid: eth.beamPipeCid, msgId: 163)),
        ),
        isNull,
      );
    });

    test('anything else is badPipe', () {
      for (final out in [
        '{"error": "msg is processed"}',
        '{"amount": 1,"relayerFee": 1,"receiver": "$_gx"}',
        '{"amount": 1,"relayerFee": 1}',
        'nonsense',
      ]) {
        expect(() => PipeOutput.remoteMessage(out), _badPipe, reason: out);
      }
    });
  });

  group('view_incoming', () {
    test('recorded: empty on every pipe', () {
      for (final r in kBridgeRoutes) {
        expect(
          PipeOutput.incoming(
            view(r, PipeArgs.viewIncoming(cid: r.beamPipeCid, startFrom: 0)),
          ),
          isEmpty,
        );
      }
    });

    test('entries, with every spelling of the id', () {
      final list = PipeOutput.incoming(
        '{"incoming": [{"MsgId": 226,"amount": 2000000},'
        '{"msgId": 227,"amount": 9223372036854775809},'
        '{"id": 0,"amount": 1},'
        '{"MsgId": 5,"msgId": 5,"amount": 3}]}',
      );
      expect([for (final i in list) i.msgId], [226, 227, 0, 5]);
      expect(list[0].amount, g(2000000));
      // Exact past 2^63: never a double.
      expect(list[1].amount, BigInt.parse('9223372036854775809'));
    });

    test('the asset-owner cid prints invalid JSON: badPipe, not []', () {
      final owner = recordedView(
        BridgeShader.forward,
        'action=view_incoming,cid='
        'acefc4bed717cf94de3868e9979f72184aee00627bd3ebe1b8c0f086ab968b9f',
      )!;
      expect(owner, '{"incoming": ["error": "no params"]}');
      expect(() => PipeOutput.incoming(owner), _badPipe);
    });

    test('anything else is badPipe', () {
      for (final out in [
        '{"error": "no params"}',
        '{"incoming": {}}',
        '{}',
        '{"incoming": [5]}',
        '{"incoming": [{"amount": 1}]}',
        '{"incoming": [{"MsgId": 1}]}',
        '{"incoming": [{"MsgId": -1,"amount": 1}]}',
        '{"incoming": [{"MsgId": 1,"msgId": 2,"amount": 1}]}',
        '{"incoming": [{"MsgId": 1.0,"amount": 1}]}',
        '{"incoming": [{"MsgId": 18446744073709551615,"amount": 1}]}',
        '',
      ]) {
        expect(() => PipeOutput.incoming(out), _badPipe, reason: out);
      }
    });
  });
}
