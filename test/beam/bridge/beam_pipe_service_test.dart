/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/beam_pipe_service.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_args.dart';
import 'package:stackwallet/wallets/beam/contracts/bridge/pipe_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';

import '../contracts/airdrop/invoke_data_writer.dart';
import 'pipe_fixtures.dart';

Matcher _refused(BridgeErrorCode code) =>
    throwsA(isA<BridgeException>().having((e) => e.code, 'code', code));

final _unexpected = _refused(BridgeErrorCode.unexpectedTransaction);
final _badPipe = _refused(BridgeErrorCode.badPipe);
final _badAmount = _refused(BridgeErrorCode.badAmount);
final _network = _refused(BridgeErrorCode.network);

const _zeroTxId = '00000000000000000000000000000000';
const _gx = '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';

/// The bUSDT asset-owner contract beside the bUSDT pipe.
const _usdtOwnerCid =
    'd455975164b8260655a137b5531b395733306d14ed609e50a21015fcab04d194';

Map<String, Object?> _built(List<int> raw, {String output = '{}'}) => {
  'output': output,
  'txid': _zeroTxId,
  'raw_data': raw,
};

/// A `raw_data` with the core's "store the app invoke" flag: [entry], then
/// an empty app body and contract, [args], and [privilege]
/// (`bvm/invoke_data.h`). Only the services' own builds carry one, and
/// only when the core may rebuild them.
List<int> _withStoredArgs(
  FakeInvokeEntry entry,
  Map<String, String> args, {
  int privilege = 0,
}) {
  final plain = InvokeDataWriter.write([entry]);
  List<int> str(String s) => [0x80 | s.length, ...utf8.encode(s)];
  return [
    plain[0], // one entry
    0x04, 0x20, 0x00, 0x00, 0x80, // u32 0x80000020: flags SaveAppInvoke
    ...plain.sublist(1), // method and the rest of the entry
    0x80, // app body: empty
    0x80, // contract: empty
    0x80 | args.length,
    for (final e in args.entries) ...[...str(e.key), ...str(e.value)],
    0x80 | privilege,
  ];
}

void main() {
  const g = BigInt.from;
  final beam = bridgeRouteById('beam');
  final usdt = bridgeRouteById('usdt');
  final eth = bridgeRouteById('eth');
  late FakeTransport t;
  late PipeRouter router;

  BeamPipeService serviceWith(
    PipeRouter r, {
    Object? processReply,
    ShaderSource? shaders,
  }) {
    router = r;
    t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) => r(p),
      'process_invoke_data':
          processReply ?? (Map<String, Object?> p) => {'txid': 'ab' * 16},
    });
    return BeamPipeService(BeamApi(t), shaders ?? pipeShaders);
  }

  String sendArgs(
    BridgeRoute r, {
    String receiver = recordedReceiver,
    BigInt? amount,
    BigInt? fee,
  }) => PipeArgs.send(
    cid: r.beamPipeCid,
    amount: amount ?? recordedSendAmount,
    receiver: receiver,
    relayerFee: fee ?? recordedSendFee,
  );

  /// The `send` entry the pipe builds, with any field replaced.
  FakeInvokeEntry sendEntry(
    BridgeRoute r, {
    int? method,
    String? cid,
    List<int>? args,
    Map<int, BigInt>? funds,
    int charge = 0,
    List<List<int>> sigs = const [],
  }) => FakeInvokeEntry(
    method: method ?? r.sendMethod,
    cid: cid ?? r.beamPipeCid,
    args:
        args ??
        [
          ...hexBytes(recordedReceiver),
          ...le(recordedSendAmount.toInt(), 8),
          ...le(recordedSendFee.toInt(), 8),
        ],
    funds: funds ?? {r.beamAssetId: recordedSendAmount + recordedSendFee},
    comment: 'Send funds',
    charge: charge,
    sigs: sigs,
  );

  Future<BeamPipePrepared> prepareSend(BeamPipeService s, BridgeRoute r) =>
      s.prepareSend(
        r,
        ethReceiver: '0x$recordedReceiver',
        amount: recordedSendAmount,
        fee: recordedSendFee,
      );

  FakeInvokeEntry receiveEntry(
    BridgeRoute r,
    int msgId,
    int amount, {
    int? method,
    List<int>? args,
    Map<int, BigInt>? funds,
    int charge = 1200000,
    List<List<int>>? sigs,
  }) => FakeInvokeEntry(
    method: method ?? r.receiveMethod,
    cid: r.beamPipeCid,
    args: args ?? le(msgId, 8),
    funds: funds ?? {r.beamAssetId: g(-amount)},
    comment: 'Receive funds',
    charge: charge,
    sigs: sigs ?? [hexBytes(BeamPipeService.pipeKeyHash(r.beamPipeCid))],
  );

  group('views', () {
    test('each view sends its exact args with the route\'s pinned shader, '
        'create_tx false', () async {
      final s = serviceWith(PipeRouter());
      await s.receiveKey(beam);
      await s.localMessageCount(usdt);
      await s.localMessage(beam, 639);
      await s.remoteMessage(usdt, 78);
      await s.incoming(eth);
      expect(router.args, [
        'action=get_pk,cid=${beam.beamPipeCid}',
        'action=local_msg_count,cid=${usdt.beamPipeCid}',
        'action=local_msg,cid=${beam.beamPipeCid},msgId=639',
        'action=remote_msg,cid=${usdt.beamPipeCid},msgId=78',
        'action=view_incoming,cid=${eth.beamPipeCid},startFrom=0',
      ]);
      expect(
        [for (final p in router.seen) shaderOf(p)],
        [
          BridgeShader.reverse,
          BridgeShader.forward,
          BridgeShader.reverse,
          BridgeShader.forward,
          BridgeShader.forward,
        ],
      );
      final reverseBytes = await pipeAppShader(
        BridgeShader.reverse,
        pipeShaders,
      ).load();
      expect(router.seen.first['contract'], reverseBytes);
      for (final p in router.seen) {
        expect(p['create_tx'], isFalse);
      }
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('startFrom is passed through', () async {
      final s = serviceWith(
        PipeRouter(
          overrides: {
            'action=view_incoming,cid=${beam.beamPipeCid},startFrom=226': () =>
                {
                  'output': '{"incoming": [{"MsgId": 226,"amount": 2000000}]}',
                  'txid': _zeroTxId,
                },
          },
        ),
      );
      final list = await s.incoming(beam, startFrom: 226);
      expect(list.single.msgId, 226);
      expect(list.single.amount, g(2000000));
    });

    test('results are parsed: key, count, messages, absent → null', () async {
      final s = serviceWith(PipeRouter());
      expect(await s.receiveKey(usdt), hexBytes('${_gx}00'));
      expect(await s.localMessageCount(beam), 639);
      final m = (await s.localMessage(beam, 639))!;
      expect(m.amount, g(23759052883550));
      expect(await s.localMessage(beam, 640), isNull);
      expect((await s.remoteMessage(beam, 226))!.amount, g(2000000));
      expect(await s.remoteMessage(eth, 163), isNull);
      expect(await s.incoming(beam), isEmpty);
    });

    test('a view that builds a transaction is refused', () async {
      final args = PipeArgs.getPk(cid: usdt.beamPipeCid);
      final s = serviceWith(
        PipeRouter(
          overrides: {
            args: () => {
              'output': '{"pk": "${_gx}00"}',
              'txid': _zeroTxId,
              'raw_data': [1, 2, 3],
            },
          },
        ),
      );
      await expectLater(s.receiveKey(usdt), _unexpected);
      final s2 = serviceWith(
        PipeRouter(
          overrides: {
            args: () => {'output': '{"pk": "${_gx}00"}', 'txid': 'cd' * 16},
          },
        ),
      );
      await expectLater(s2.receiveKey(usdt), _unexpected);
    });

    test('shader errors and wrong shapes are badPipe', () async {
      final s = serviceWith(
        PipeRouter(
          overrides: {
            PipeArgs.localMsgCount(cid: usdt.beamPipeCid): () => {
              'output': '{"error": "no params"}',
              'txid': _zeroTxId,
            },
            PipeArgs.viewIncoming(cid: usdt.beamPipeCid, startFrom: 0): () => {
              'output': '{"incoming": ["error": "no params"]}',
              'txid': _zeroTxId,
            },
            PipeArgs.getPk(cid: beam.beamPipeCid): () => {
              'output': '{"pk": "${_gx}00"}', // the forward name
              'txid': _zeroTxId,
            },
          },
        ),
      );
      await expectLater(s.localMessageCount(usdt), _badPipe);
      await expectLater(s.incoming(usdt), _badPipe);
      await expectLater(s.receiveKey(beam), _badPipe);
    });

    test('a shader file that is not the pinned one is badPipe', () async {
      final s = serviceWith(PipeRouter(), shaders: _WrongShaders());
      await expectLater(s.receiveKey(usdt), _badPipe);
      expect(router.seen, isEmpty);
    });

    test('connection failures are network', () async {
      final s = serviceWith(PipeRouter());
      t.reply(
        'invoke_contract',
        const BeamRpcException(-32603, 'Internal JSON-RPC error.'),
      );
      await expectLater(s.localMessageCount(usdt), _network);
      t.reply('invoke_contract', const BeamConnectionException('gone'));
      await expectLater(s.localMessageCount(usdt), _network);
      t.reply(
        'invoke_contract',
        (Map<String, Object?> _) => throw TimeoutException('slow'),
      );
      await expectLater(s.localMessageCount(usdt), _network);
      // A failed call does not block the ones queued behind it.
      t.reply('invoke_contract', (Map<String, Object?> p) => router(p));
      expect(await s.localMessageCount(usdt), 108);
    });

    test('a route not in the registry is refused before any call', () async {
      final s = serviceWith(PipeRouter());
      const fake = BridgeRoute(
        id: 'usdt', // same id, so == says equal: the fields must be read
        beamSymbol: 'bUSDT',
        ethSymbol: 'USDT',
        name: 'Tether',
        beamAssetId: 37,
        beamPipeCid: _usdtOwnerCid,
        shader: BridgeShader.forward,
        sendMethod: 3,
        receiveMethod: 4,
        ethPipe: '0x7c3fe09e86b0d8661d261a49bfa385536b7077f9',
        ethToken: '0xdac17f958d2ee523a2206206994597c13d831ec7',
        ethDecimals: 6,
        relayGas: 120000,
        processedSlot: 2,
        coingeckoId: 'tether',
      );
      expect(fake, usdt);
      await expectLater(s.receiveKey(fake), throwsArgumentError);
      expect(router.seen, isEmpty);
    });
  });

  group('prepareSend', () {
    test('the recorded build of every route passes, decoded', () async {
      final s = serviceWith(PipeRouter());
      for (final r in kBridgeRoutes) {
        final p = await prepareSend(s, r);
        expect(router.args.last, sendArgs(r));
        expect(router.seen.last['create_tx'], isFalse);
        expect(p.route, r);
        expect(p.call, BeamPipeCall.send);
        expect(p.rawData, recordedRawData(sendArgs(r)));
        expect(p.networkFee, g(1100000));
        expect(p.amount, recordedSendAmount);
        expect(p.relayerFee, recordedSendFee);
        expect(p.ethReceiver, '0x$recordedReceiver');
        expect(p.msgId, isNull);
        expect(p.sent, isFalse);
        expect(() => p.rawData.add(0), throwsUnsupportedError);
      }
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test(
      'the receiver may be checksummed or bare; it is sent lower case',
      () async {
        final s = serviceWith(PipeRouter());
        for (final r in [
          '0x${recordedReceiver.toUpperCase()}',
          recordedReceiver,
        ]) {
          final p = await s.prepareSend(
            usdt,
            ethReceiver: r,
            amount: recordedSendAmount,
            fee: recordedSendFee,
          );
          expect(router.args.last, sendArgs(usdt));
          expect(p.ethReceiver, '0x$recordedReceiver');
        }
      },
    );

    test('bad receivers are refused before any call', () async {
      final s = serviceWith(PipeRouter());
      for (final r in [
        '0x${'0' * 40}',
        '0x${recordedReceiver.substring(2)}',
        '0x${recordedReceiver}5a',
        '0X$recordedReceiver',
        '0x${'g' * 40}',
      ]) {
        await expectLater(
          s.prepareSend(
            usdt,
            ethReceiver: r,
            amount: recordedSendAmount,
            fee: recordedSendFee,
          ),
          throwsArgumentError,
          reason: r,
        );
      }
      expect(router.seen, isEmpty);
    });

    test('bad amounts are badAmount, before any call', () async {
      final s = serviceWith(PipeRouter());
      final max = (BigInt.one << 63) - BigInt.one;
      final cap = beam.maxGroth!;
      Future<void> refused(BridgeRoute r, BigInt a, BigInt f) => expectLater(
        s.prepareSend(r, ethReceiver: '0x$recordedReceiver', amount: a, fee: f),
        _badAmount,
        reason: '${r.id} $a $f',
      );
      await refused(usdt, g(0), g(100));
      await refused(usdt, g(-100), g(100));
      await refused(usdt, g(100), g(0));
      await refused(beam, max, g(1));
      await refused(beam, BigInt.one << 62, BigInt.one << 62);
      // 3,000,000 BEAM per crossing, amount and fee each.
      await refused(beam, cap + BigInt.one, g(1000000));
      await refused(beam, g(100000000), cap + BigInt.one);
      // USDT moves in 100-groth steps (6 decimals on Ethereum).
      await refused(usdt, g(100000001), g(1000000));
      await refused(usdt, g(100000000), g(1000050));
      expect(router.seen, isEmpty);
    });

    test('at the cap and on the grid is fine', () async {
      final cap = beam.maxGroth!;
      final capArgs = sendArgs(beam, amount: cap, fee: cap);
      final s = serviceWith(
        PipeRouter(
          overrides: {
            capArgs: () => _built(
              InvokeDataWriter.write([
                sendEntry(
                  beam,
                  args: [
                    ...hexBytes(recordedReceiver),
                    ...le(cap.toInt(), 8),
                    ...le(cap.toInt(), 8),
                  ],
                  funds: {0: cap + cap},
                ),
              ]),
            ),
          },
        ),
      );
      final p = await s.prepareSend(
        beam,
        ethReceiver: '0x$recordedReceiver',
        amount: cap,
        fee: cap,
      );
      expect(p.amount, cap);
    });

    group('refuses a build that is not the request', () {
      Future<void> refusedWith(Object? Function() answer, [Matcher? m]) {
        final s = serviceWith(PipeRouter(overrides: {sendArgs(usdt): answer}));
        return expectLater(prepareSend(s, usdt), m ?? _unexpected);
      }

      List<int> raw(FakeInvokeEntry e) => InvokeDataWriter.write([e]);

      test('a synthetic entry equal to the request passes', () async {
        final s = serviceWith(
          PipeRouter(
            overrides: {sendArgs(usdt): () => _built(raw(sendEntry(usdt)))},
          ),
        );
        // The writer reproduces the recorded bytes exactly.
        expect(raw(sendEntry(usdt)), recordedRawData(sendArgs(usdt)));
        expect((await prepareSend(s, usdt)).networkFee, g(1100000));
      });

      test('another contract: a different pipe, the asset owner', () async {
        await refusedWith(
          () => _built(raw(sendEntry(usdt, cid: eth.beamPipeCid))),
        );
        await refusedWith(
          () => _built(raw(sendEntry(usdt, cid: _usdtOwnerCid))),
        );
      });

      test('another method', () async {
        await refusedWith(
          () => _built(raw(sendEntry(usdt, method: usdt.receiveMethod))),
        );
        // The reverse pipe's send method on a forward pipe.
        await refusedWith(() => _built(raw(sendEntry(usdt, method: 4))));
      });

      test('other argument bytes', () async {
        final receiver = hexBytes(recordedReceiver);
        final amount = le(recordedSendAmount.toInt(), 8);
        final fee = le(recordedSendFee.toInt(), 8);
        for (final args in [
          // amount + 1
          [...receiver, ...le(recordedSendAmount.toInt() + 1, 8), ...fee],
          // amount and fee swapped
          [...receiver, ...fee, ...amount],
          // another receiver
          [...hexBytes('5b' * 20), ...amount, ...fee],
          // big-endian amount
          [...receiver, ...amount.reversed, ...fee],
          // a trailing byte, a missing byte
          [...receiver, ...amount, ...fee, 0],
          [...receiver, ...amount, ...fee.sublist(1)],
        ]) {
          await refusedWith(() => _built(raw(sendEntry(usdt, args: args))));
        }
      });

      test('other funds: amount only, another asset, an extra asset, '
          'receiving', () async {
        final total = recordedSendAmount + recordedSendFee;
        for (final funds in [
          {37: recordedSendAmount},
          {37: total + BigInt.one},
          {36: total},
          {37: total, 0: g(1)},
          {37: -total},
          <int, BigInt>{},
        ]) {
          await refusedWith(() => _built(raw(sendEntry(usdt, funds: funds))));
        }
      });

      test('a signature, a charge (a higher fee)', () async {
        await refusedWith(
          () => _built(
            raw(
              sendEntry(
                usdt,
                sigs: [hexBytes(BeamPipeService.pipeKeyHash(usdt.beamPipeCid))],
              ),
            ),
          ),
        );
        await refusedWith(() => _built(raw(sendEntry(usdt, charge: 200000))));
      });

      test('a second entry', () async {
        await refusedWith(
          () => _built(
            InvokeDataWriter.write([sendEntry(usdt), sendEntry(usdt)]),
          ),
        );
      });

      test('nothing built, unreadable, a started transaction', () async {
        await refusedWith(() => {'output': '{}', 'txid': _zeroTxId});
        await refusedWith(() => _built([1, 2, 3]));
        await refusedWith(
          () => {
            'output': '{}',
            'txid': 'cd' * 16,
            'raw_data': raw(sendEntry(usdt)),
          },
        );
      });

      test('a shader error is badPipe', () async {
        await refusedWith(
          () => {'output': '{"error": "no params"}', 'txid': _zeroTxId},
          _badPipe,
        );
      });

      test('stored app args: equal passes, different or privileged is '
          'refused', () async {
        final asked = {
          for (final kv in sendArgs(usdt).split(','))
            kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
        };
        final ok = serviceWith(
          PipeRouter(
            overrides: {
              sendArgs(usdt): () =>
                  _built(_withStoredArgs(sendEntry(usdt), asked)),
            },
          ),
        );
        expect((await prepareSend(ok, usdt)).amount, recordedSendAmount);

        await refusedWith(
          () => _built(
            _withStoredArgs(sendEntry(usdt), {...asked, 'receiver': '5b' * 20}),
          ),
        );
        await refusedWith(
          () => _built(
            _withStoredArgs(sendEntry(usdt), {...asked, 'extra': '1'}),
          ),
        );
        await refusedWith(
          () => _built(_withStoredArgs(sendEntry(usdt), asked, privilege: 1)),
        );
      });
    });
  });

  group('prepareReceive', () {
    test('the recorded builds pass: forward and reverse', () async {
      final s = serviceWith(PipeRouter());
      for (final e in recordedReceives.entries) {
        final r = bridgeRouteById(e.key);
        final (msgId, amount) = e.value;
        final p = await s.prepareReceive(r, msgId: msgId, amount: g(amount));
        expect(
          router.args.last,
          PipeArgs.receive(cid: r.beamPipeCid, msgId: msgId),
        );
        expect(p.call, BeamPipeCall.receive);
        expect(p.networkFee, g(12100000));
        expect(p.amount, g(amount));
        expect(p.relayerFee, BigInt.zero);
        expect(p.msgId, msgId);
        expect(p.ethReceiver, isNull);
      }
    });

    test('a synthetic entry equal to the request reproduces the recording', () {
      for (final e in recordedReceives.entries) {
        final r = bridgeRouteById(e.key);
        final (msgId, amount) = e.value;
        expect(
          InvokeDataWriter.write([receiveEntry(r, msgId, amount)]),
          recordedRawData(PipeArgs.receive(cid: r.beamPipeCid, msgId: msgId)),
        );
      }
    });

    group('refuses a build that is not the request', () {
      final args = PipeArgs.receive(cid: usdt.beamPipeCid, msgId: 78);

      Future<void> refused(
        FakeInvokeEntry entry, {
        int amount = 91049000,
        Matcher? matcher,
      }) {
        final s = serviceWith(
          PipeRouter(
            overrides: {
              args: () => _built(InvokeDataWriter.write([entry])),
            },
          ),
        );
        return expectLater(
          s.prepareReceive(usdt, msgId: 78, amount: g(amount)),
          matcher ?? _unexpected,
        );
      }

      test('another amount than the message pays', () async {
        await refused(receiveEntry(usdt, 78, 91049000), amount: 91049001);
        await refused(receiveEntry(usdt, 78, 91048999));
      });

      test('another message id, method, or argument size', () async {
        await refused(receiveEntry(usdt, 78, 91049000, args: le(79, 8)));
        await refused(receiveEntry(usdt, 78, 91049000, args: le(78, 4)));
        await refused(receiveEntry(usdt, 78, 91049000, method: 3));
        await refused(receiveEntry(usdt, 78, 91049000, method: 6));
      });

      test('no signature, two, or another key', () async {
        final key = hexBytes(BeamPipeService.pipeKeyHash(usdt.beamPipeCid));
        final other = hexBytes(BeamPipeService.pipeKeyHash(eth.beamPipeCid));
        await refused(receiveEntry(usdt, 78, 91049000, sigs: []));
        await refused(receiveEntry(usdt, 78, 91049000, sigs: [key, key]));
        await refused(receiveEntry(usdt, 78, 91049000, sigs: [other]));
      });

      test(
        'paying instead of receiving, another asset, a lower charge',
        () async {
          await refused(
            receiveEntry(usdt, 78, 91049000, funds: {37: g(91049000)}),
          );
          await refused(
            receiveEntry(usdt, 78, 91049000, funds: {0: g(-91049000)}),
          );
          await refused(receiveEntry(usdt, 78, 91049000, charge: 0));
        },
      );

      test(
        'the message was claimed meanwhile: the pipe says so (badPipe)',
        () async {
          final s = serviceWith(
            PipeRouter(
              overrides: {
                args: () => {
                  'output': '{"error": "msg with current id is absent"}',
                  'txid': _zeroTxId,
                },
              },
            ),
          );
          await expectLater(
            s.prepareReceive(usdt, msgId: 78, amount: g(91049000)),
            _badPipe,
          );
        },
      );
    });

    test('a non-positive or impossible amount is badAmount', () async {
      final s = serviceWith(PipeRouter());
      await expectLater(
        s.prepareReceive(usdt, msgId: 78, amount: BigInt.zero),
        _badAmount,
      );
      await expectLater(
        s.prepareReceive(usdt, msgId: 78, amount: BigInt.one << 63),
        _badAmount,
      );
      expect(router.seen, isEmpty);
    });
  });

  group('execute', () {
    test('sends the checked bytes once', () async {
      final s = serviceWith(PipeRouter());
      final p = await prepareSend(s, usdt);
      expect(await s.execute(p), 'ab' * 16);
      expect(p.sent, isTrue);
      final sent = t.callsTo('process_invoke_data').single.params;
      expect(sent['data'], recordedRawData(sendArgs(usdt)));
      await expectLater(s.execute(p), _refused(BridgeErrorCode.alreadySent));
      // Resetting the public flag changes nothing.
      p.sent = false;
      await expectLater(s.execute(p), _refused(BridgeErrorCode.alreadySent));
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });

    test('a failed send still counts as sent', () async {
      final s = serviceWith(
        PipeRouter(),
        processReply: const BeamRpcException(-32001, 'Failed'),
      );
      final p = await s.prepareReceive(usdt, msgId: 78, amount: g(91049000));
      await expectLater(s.execute(p), _network);
      expect(p.sent, isTrue);
      await expectLater(s.execute(p), _refused(BridgeErrorCode.alreadySent));
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });

    test('nothing it did not prepare and check itself', () async {
      final s = serviceWith(PipeRouter());
      final forged = BeamPipePrepared(
        route: usdt,
        call: BeamPipeCall.send,
        rawData: recordedRawData(sendArgs(usdt)),
        networkFee: g(1100000),
        amount: recordedSendAmount,
        relayerFee: recordedSendFee,
        ethReceiver: '0x$recordedReceiver',
      );
      await expectLater(s.execute(forged), _unexpected);
      // Nor one another wallet's service prepared.
      final other = serviceWith(PipeRouter());
      final p = await prepareSend(other, usdt);
      await expectLater(s.execute(p), _unexpected);
      expect(p.sent, isFalse);
    });
  });

  group('wallet reads', () {
    Map<String, Object?> tx(int status, {int? height, String? reason}) {
      final base =
          ((jsonDecode(
                        File('test/beam/fixtures/tx_list.json')
                            .readAsStringSync(),
                      ) as Map)['result']!
                      as List)
                  .first
              as Map;
      return {
        ...base.cast<String, Object?>(),
        'status': status,
        'failure_reason': reason,
        'height': ?height,
        'tx_type': 12,
        'tx_type_string': 'contract',
      };
    }

    test('txStatus', () async {
      final s = serviceWith(PipeRouter());
      Future<BeamPipeTxStatus> status(Map<String, Object?> reply) {
        t.reply('tx_status', reply);
        return s.txStatus('ab' * 16);
      }

      final done = await status(tx(3, height: 4072900));
      expect(done.state, BeamPipeTxState.completed);
      expect(done.height, 4072900);
      expect(t.lastParams('tx_status'), {'txId': 'ab' * 16});
      expect((await status(tx(3))).state, BeamPipeTxState.pending);
      for (final code in [0, 1, 5, 6]) {
        expect((await status(tx(code))).state, BeamPipeTxState.pending);
      }
      final failed = await status(tx(4, reason: 'No inputs'));
      expect(failed.state, BeamPipeTxState.failed);
      expect(failed.reason, 'No inputs');
      expect((await status(tx(2))).state, BeamPipeTxState.failed);
      t.reply('tx_status', const BeamRpcException(-32001, 'Unknown tx'));
      await expectLater(s.txStatus('ab' * 16), _network);
    });

    test('tipHeight and available', () async {
      final s = serviceWith(PipeRouter());
      final status = (jsonDecode(
        File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
      ) as Map).cast<String, Object?>();
      t.reply('wallet_status', status);
      expect(await s.tipHeight(), 3677099);
      expect(await s.available(0), g(66707641121));
      expect(await s.available(174), g(56812972897));
      expect(await s.available(36), BigInt.zero);
      // A core that lists no totals: BEAM from the top level.
      final result = (status['result']! as Map).cast<String, Object?>();
      t.reply('wallet_status', {...result, 'totals': <Object?>[]});
      expect(await s.available(0), g(66707641121));
      expect(await s.available(36), BigInt.zero);
      t.reply('wallet_status', const BeamConnectionException('gone'));
      await expectLater(s.tipHeight(), _network);
    });
  });
}

class _WrongShaders implements ShaderSource {
  @override
  Future<Uint8List> read(String name) async => Uint8List(kPipeAppShaderSize);
}
