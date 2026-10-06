/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_quotes.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'dex_fixtures.dart';

const _zeroTxId = '00000000000000000000000000000000';

/// The recorded `result` of a fixture.
Map<String, Object?> recorded(String name) =>
    (dexEnvelope(name)['result']! as Map).cast<String, Object?>();

Map<String, Object?> outputOnly(String output) => {
  'output': output,
  'txid': _zeroTxId,
};

/// Answers `invoke_contract` from fixtures, keyed by the exact `args`.
class DexRouter {
  DexRouter(this.routes);

  final Map<String, Object? Function()> routes;
  final seen = <Map<String, Object?>>[];

  Object? call(Map<String, Object?> params) {
    seen.add(params);
    final args = params['args']! as String;
    final route = routes[args];
    if (route == null) throw StateError('unexpected args: $args');
    return route();
  }
}

String tradeArgs(
  int pay,
  int receive,
  BeamPoolKind kind,
  int amount, {
  bool predict = true,
}) => DexArgs.trade(
  payAsset: pay,
  receiveAsset: receive,
  kind: kind,
  payAmount: BigInt.from(amount),
  predictOnly: predict,
);

void main() {
  const g = BigInt.from;
  late Uint8List shaderBytes;
  late FakeTransport t;

  setUpAll(() async {
    shaderBytes = await ammAppShader(
      const FileShaderSource('assets/beam/shaders'),
    ).load();
  });

  BeamDexService serviceWith(DexRouter router, {PinnedShader? shader}) {
    t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) => router(p),
      'process_invoke_data': (Map<String, Object?> p) => {'txid': 'ab' * 16},
    });
    return BeamDexService(
      BeamApi(t),
      shader ?? ammAppShader(const FileShaderSource('assets/beam/shaders')),
    );
  }

  final poolsRoute = {
    DexArgs.poolsView(): () => recorded('pools_view'),
  };

  group('views and quotes', () {
    test('listPools sends the pinned shader, create_tx false', () async {
      final router = DexRouter(poolsRoute);
      final dex = serviceWith(router);
      final pools = await dex.listPools();
      expect(pools, hasLength(75));
      expect(await dex.listPools(includeEmpty: true), hasLength(97));
      final p = router.seen.first;
      expect(p['create_tx'], isFalse);
      expect(p['args'], 'action=pools_view,cid=$dexCid');
      expect(p['contract'], shaderBytes);
      expect((p['contract']! as List).length, kAmmAppShaderSize);
    });

    test('quote pay 0.1 BEAM → FOMO predicts with aid1=174, aid2=0',
        () async {
      final predict = tradeArgs(0, 174, BeamPoolKind.high, 10000000);
      final router = DexRouter({
        ...poolsRoute,
        predict: () => recorded('trade_pay_beam_get_fomo'),
      });
      final dex = serviceWith(router);
      final q = await dex.quote(
        payAsset: 0,
        payAmount: g(10000000),
        receiveAsset: 174,
      );
      expect(predict, contains('aid1=174,aid2=0'));
      expect(router.seen.last['args'], predict);
      expect(q.payAsset, 0);
      expect(q.receiveAsset, 174);
      expect(q.pay, g(10000000));
      expect(q.receive, g(80368764));
      expect(q.kind, BeamPoolKind.high);
      expect(q.pool.lpToken, 175);
    });

    test('quote picks the pool that delivers the most', () async {
      final high = BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.high,
        tok1: g(1000000000000),
        tok2: g(8000000000000),
        ctl: g(1),
        lpToken: 175,
      );
      final low = BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.low,
        tok1: g(1000000000),
        tok2: g(8000000000),
        ctl: g(1),
        lpToken: 300,
      );
      Map<String, Object?> prediction(BeamPoolKind kind, int buy) {
        final raw = g(99000000); // pay = raw + fee stays under 1 BEAM
        final fee = kind.tradeFee(raw);
        return outputOnly(
          '{"res": {"buy": $buy,"pay": ${raw + fee.pool + fee.dao},'
          '"pay_raw": $raw,"fee_pool": ${fee.pool},"fee_dao": ${fee.dao}}}',
        );
      }

      final router = DexRouter({
        tradeArgs(0, 174, BeamPoolKind.high, 100000000): () =>
            prediction(BeamPoolKind.high, 790000000),
        tradeArgs(0, 174, BeamPoolKind.low, 100000000): () =>
            prediction(BeamPoolKind.low, 720000000),
      });
      final dex = serviceWith(router);
      final q = await dex.quote(
        payAsset: 0,
        payAmount: g(100000000),
        receiveAsset: 174,
        pools: [low, high],
      );
      expect(q.kind, BeamPoolKind.high);
      expect(q.receive, g(790000000));
      expect(router.seen, hasLength(2));

      final onlyLow = await dex.quote(
        payAsset: 0,
        payAmount: g(100000000),
        receiveAsset: 174,
        kind: BeamPoolKind.low,
        pools: [low, high],
      );
      expect(onlyLow.kind, BeamPoolKind.low);
    });

    test('no pool, empty pool, nothing to receive', () async {
      final router = DexRouter({
        ...poolsRoute,
        tradeArgs(0, 174, BeamPoolKind.high, 1): () => outputOnly(
          '{"res": {"buy": 0,"pay": 1,"pay_raw": 0,"fee_pool": 1,'
          '"fee_dao": 0}}',
        ),
      });
      final dex = serviceWith(router);
      Matcher code(BeamDexErrorCode c) =>
          throwsA(isA<BeamDexException>().having((e) => e.code, 'code', c));

      await expectLater(
        dex.quote(payAsset: 0, payAmount: g(1), receiveAsset: 999999),
        code(BeamDexErrorCode.noPool),
      );
      // (0, 1) exists only as an empty kind-2 pool.
      await expectLater(
        dex.quote(payAsset: 0, payAmount: g(1), receiveAsset: 1),
        code(BeamDexErrorCode.poolEmpty),
      );
      await expectLater(
        dex.quote(payAsset: 0, payAmount: g(1), receiveAsset: 174),
        code(BeamDexErrorCode.amountTooSmall),
      );
    });

    test('shader errors map to codes', () async {
      final pool = BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.mid,
        tok1: g(1),
        tok2: g(1),
        ctl: g(1),
        lpToken: 1,
      );
      final router = DexRouter({
        tradeArgs(0, 174, BeamPoolKind.mid, 10000000): () =>
            recorded('error_no_such_pool'),
        DexArgs.addLiquidity(
          aid1: 0,
          aid2: 174,
          kind: BeamPoolKind.mid,
          amount1: g(10000000),
          amount2: g(10000000),
          predictOnly: true,
        ): () => recorded('add_both_too_large'),
      });
      final dex = serviceWith(router);
      await expectLater(
        dex.quotePool(pool: pool, payAsset: 0, payAmount: g(10000000)),
        throwsA(
          isA<BeamDexException>()
              .having((e) => e.code, 'code', BeamDexErrorCode.noPool)
              .having((e) => e.message, 'message', 'no such pool'),
        ),
      );
      await expectLater(
        dex.quoteAddLiquidity(
          pool: pool,
          amount1: g(10000000),
          amount2: g(10000000),
        ),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.ratioMismatch,
          ),
        ),
      );
    });

    test('exact receive: truncation is reported, not hidden', () async {
      final pools = (await serviceWith(DexRouter(poolsRoute)).listPools());
      final beamFomo = pools.singleWhere((p) => p.pairs(0, 174));
      final args = DexArgs.trade(
        payAsset: 0,
        receiveAsset: 174,
        kind: BeamPoolKind.high,
        receiveAmount: g(80000001),
        predictOnly: true,
      );
      final dex = serviceWith(
        DexRouter({args: () => recorded('trade_buy_exact_fomo')}),
      );
      await expectLater(
        dex.quoteReceive(
          pool: beamFomo,
          receiveAsset: 174,
          receiveAmount: g(80000001),
        ),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.amountTooLarge,
          ),
        ),
      );
    });

    test('add and withdraw predictions', () async {
      final pools = (await serviceWith(DexRouter(poolsRoute)).listPools());
      final beamFomo = pools.singleWhere((p) => p.pairs(0, 174));
      final dex = serviceWith(
        DexRouter({
          DexArgs.addLiquidity(
            aid1: 0,
            aid2: 174,
            kind: BeamPoolKind.high,
            amount1: g(10000000),
            predictOnly: true,
          ): () => recorded('add_beam_side'),
          DexArgs.withdraw(
            aid1: 0,
            aid2: 174,
            kind: BeamPoolKind.high,
            ctl: g(100000000),
            predictOnly: true,
          ): () => recorded('withdraw_ctl'),
        }),
      );
      final add = await dex.quoteAddLiquidity(
        pool: beamFomo,
        amount1: g(10000000),
      );
      expect(add.amount2, g(81173706));
      expect(add.lpMinted, g(33347624));
      final w = await dex.quoteWithdraw(pool: beamFomo, lpAmount: g(100000000));
      expect(w.amount1, g(29987143));
      expect(w.amount2, g(243416758));
    });

    test('a read-only call that returns raw_data is refused', () async {
      final dex = serviceWith(
        DexRouter({
          DexArgs.poolsView(): () => {
            ...recorded('pools_view'),
            'raw_data': rawDataVector('trade_plain'),
          },
        }),
      );
      await expectLater(
        dex.listPools(),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.unexpectedTransaction,
          ),
        ),
      );
    });

    test('a substituted shader is refused before any RPC', () async {
      final evil = Uint8List.fromList(shaderBytes)..[500] ^= 0x01;
      final dex = serviceWith(
        DexRouter(poolsRoute),
        shader: ammAppShader(_Bytes(evil)),
      );
      await expectLater(
        dex.listPools(),
        throwsA(isA<PinnedShaderException>()),
      );
      expect(t.calls, isEmpty);
    });

    test('invoke_contract calls never overlap', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      t = FakeTransport({
        'invoke_contract': (Map<String, Object?> p) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          inFlight--;
          return recorded('pools_view');
        },
      });
      final dex = BeamDexService(
        BeamApi(t),
        ammAppShader(const FileShaderSource('assets/beam/shaders')),
      );
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) dex.listPools(),
      ]);
      expect(results, hasLength(5));
      expect(maxInFlight, 1);
      expect(t.callsTo('invoke_contract'), hasLength(5));
    });
  });

  group('prepare and execute', () {
    late BeamPool beamFomo;
    setUp(() async {
      beamFomo = (await serviceWith(DexRouter(poolsRoute)).listPools())
          .singleWhere((p) => p.pairs(0, 174));
    });

    BeamSwapQuote quote() => BeamSwapQuote(
      pool: beamFomo,
      payAsset: 0,
      receiveAsset: 174,
      pay: g(10000000),
      payRaw: g(9900990),
      receive: g(80368764),
      feePool: g(69307),
      feeDao: g(29703),
    );

    final buildArgs = tradeArgs(
      0,
      174,
      BeamPoolKind.high,
      10000000,
      predict: false,
    );

    test('prepareSwap decodes what will be sent; execute sends it once',
        () async {
      final raw = rawDataVector('trade_plain');
      final router = DexRouter({
        buildArgs: () => {...outputOnly('{}'), 'raw_data': raw},
      });
      final dex = serviceWith(router);
      final prepared = await dex.prepareSwap(quote());

      expect(router.seen.single['create_tx'], isFalse);
      expect(router.seen.single['args'], buildArgs);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(prepared.action, BeamDexAction.swap);
      expect(prepared.pays, {0: g(10000000)});
      expect(prepared.receives, {174: g(80368764)});
      expect(prepared.fee, g(1100000));
      expect(prepared.contractId, dexCid);
      expect(prepared.quote, isA<BeamSwapQuote>());
      expect(prepared.isExecuted, isFalse);

      final txId = await dex.execute(prepared);
      expect(txId, 'ab' * 16);
      expect(t.lastParams('process_invoke_data')['data'], raw);
      expect(prepared.isExecuted, isTrue);
      expect(
        () => dex.execute(prepared),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.alreadyExecuted,
          ),
        ),
      );
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });

    test('a prepared swap that pays more than quoted is refused', () async {
      final dex = serviceWith(DexRouter({}));
      final q = quote();
      final cheaper = BeamSwapQuote(
        pool: q.pool,
        payAsset: 0,
        receiveAsset: 174,
        pay: g(9999999),
        payRaw: q.payRaw,
        receive: q.receive,
        feePool: q.feePool,
        feeDao: q.feeDao,
      );
      t.reply('invoke_contract', (Map<String, Object?> p) => {
        ...outputOnly('{}'),
        'raw_data': rawDataVector('trade_plain'),
      });
      await expectLater(
        dex.prepareSwap(cheaper),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.unexpectedTransaction,
          ),
        ),
      );
    });

    test('wrong method, wrong assets, no raw_data: all refused', () async {
      Future<void> refuses(List<int>? raw) async {
        final dex = serviceWith(
          DexRouter({
            buildArgs: () => {
              ...outputOnly('{}'),
              'raw_data': ?raw,
            },
          }),
        );
        await expectLater(
          dex.prepareSwap(quote()),
          throwsA(
            isA<BeamDexException>().having(
              (e) => e.code,
              'code',
              BeamDexErrorCode.unexpectedTransaction,
            ),
          ),
        );
        expect(t.callsTo('process_invoke_data'), isEmpty);
      }

      await refuses(rawDataVector('withdraw')); // method 6, other assets
      await refuses(rawDataVector('create_pool')); // method 3
      await refuses(null);
      await refuses([0x80]); // no entries
      await refuses([...rawDataVector('trade_plain'), 0]); // trailing byte
    });

    test('a call to another contract is refused', () async {
      final raw = rawDataVector('trade_plain');
      // The contract id is the last 32 bytes of this vector.
      final other = [...raw]..[raw.length - 1] ^= 0xff;
      final dex = serviceWith(
        DexRouter({
          buildArgs: () => {...outputOnly('{}'), 'raw_data': other},
        }),
      );
      await expectLater(
        dex.prepareSwap(quote()),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.message,
            'message',
            contains('not the DEX'),
          ),
        ),
      );
    });

    test('add liquidity: decoded deposit and stored args checked', () async {
      final args = DexArgs.addLiquidity(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.high,
        amount1: g(10000000),
        predictOnly: false,
      );
      final dex = serviceWith(
        DexRouter({
          args: () => {
            ...outputOnly('{}'),
            'raw_data': rawDataVector('add_dependent'),
          },
        }),
      );
      final prepared = await dex.prepareAddLiquidity(
        pool: beamFomo,
        amount1: g(10000000),
      );
      expect(prepared.action, BeamDexAction.addLiquidity);
      expect(prepared.pays, {0: g(10000000), 174: g(81173706)});
      expect(prepared.receives, {175: g(33347624)});
      expect(prepared.fee, g(1100000));
      expect(prepared.invoke.entries.single.isDependent, isTrue);
    });

    test('add liquidity: stored args that differ are refused', () async {
      // Same pool and amounts but a different fee tier: the vector stored
      // kind=2, the request says kind=1.
      final mid = BeamPool(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.mid,
        tok1: beamFomo.tok1,
        tok2: beamFomo.tok2,
        ctl: beamFomo.ctl,
        lpToken: 175,
      );
      final args = DexArgs.addLiquidity(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.mid,
        amount1: g(10000000),
        predictOnly: false,
      );
      final dex = serviceWith(
        DexRouter({
          args: () => {
            ...outputOnly('{}'),
            'raw_data': rawDataVector('add_dependent'),
          },
        }),
      );
      await expectLater(
        dex.prepareAddLiquidity(pool: mid, amount1: g(10000000)),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.message,
            'message',
            contains('kind'),
          ),
        ),
      );
    });

    test('withdraw', () async {
      final args = DexArgs.withdraw(
        aid1: 0,
        aid2: 174,
        kind: BeamPoolKind.high,
        ctl: g(100000000),
        predictOnly: false,
      );
      final dex = serviceWith(
        DexRouter({
          args: () => {
            ...outputOnly('{}'),
            'raw_data': rawDataVector('withdraw'),
          },
        }),
      );
      final prepared = await dex.prepareWithdraw(
        pool: beamFomo,
        lpAmount: g(100000000),
      );
      expect(prepared.pays, {175: g(100000000)});
      expect(prepared.receives, {0: g(29987143), 174: g(243416758)});

      // Asked to burn one more LP token than the transaction burns.
      t.reply('invoke_contract', (Map<String, Object?> p) => {
        ...outputOnly('{}'),
        'raw_data': rawDataVector('withdraw'),
      });
      await expectLater(
        dex.prepareWithdraw(pool: beamFomo, lpAmount: g(100000001)),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.unexpectedTransaction,
          ),
        ),
      );
    });

    test('create pool: 10 BEAM deposit, fee from the declared charge',
        () async {
      final args = DexArgs.createPool(
        aidA: 174,
        aidB: 0,
        kind: BeamPoolKind.high,
      );
      final dex = serviceWith(
        DexRouter({
          args: () => {
            ...outputOnly('{}'),
            'raw_data': rawDataVector('create_pool'),
          },
        }),
      );
      final prepared = await dex.prepareCreatePool(
        aidA: 174,
        aidB: 0,
        kind: BeamPoolKind.high,
      );
      expect(prepared.action, BeamDexAction.createPool);
      expect(prepared.pays, {0: kDexPoolCreateDeposit});
      expect(prepared.receives, isEmpty);
      expect(prepared.fee, kDexPoolCreateFee);
    });

    test('create pool for an existing pool', () async {
      final args = DexArgs.createPool(
        aidA: 0,
        aidB: 174,
        kind: BeamPoolKind.high,
      );
      final dex = serviceWith(
        DexRouter({
          args: () => outputOnly('{"error": "pool already exists"}'),
        }),
      );
      await expectLater(
        dex.prepareCreatePool(aidA: 0, aidB: 174, kind: BeamPoolKind.high),
        throwsA(
          isA<BeamDexException>().having(
            (e) => e.code,
            'code',
            BeamDexErrorCode.poolExists,
          ),
        ),
      );
    });
  });
}

class _Bytes implements ShaderSource {
  _Bytes(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(String name) async => bytes;
}
