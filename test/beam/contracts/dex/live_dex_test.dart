/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Predict-only DEX calls against a real wallet-api on mainnet: settles which
// pool_trade argument order pays BEAM and receives FOMO.
//
// Skipped unless BEAM_LIVE_DEX=1. Reads the port and ACL key of a running
// TCP-mode wallet-api from ~/beam-campfire-test/run/funder.json:
//
//   python3 -I scripts/beam/live/wapi.py start funder --port 10102 --tcp
//   BEAM_LIVE_DEX=1 flutter test test/beam/contracts/dex/live_dex_test.dart
//   python3 -I scripts/beam/live/wapi.py stop funder
//
// Only `pools_view`, `pool_view` and `bPredictOnly=1` calls with
// `create_tx: false` can pass the guard below; `process_invoke_data` is
// refused outright. Prints pool reserves and predictions (public chain
// data) only: never the key, balances or addresses.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_ratio.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

/// Lets through only calls that cannot build or send a transaction.
class PredictOnlyGuard implements BeamTransport {
  PredictOnlyGuard(this.inner);

  final BeamTransport inner;
  final sent = <String>[];

  static bool allows(String method, Map<String, Object?> params) {
    if (method == 'get_version' || method == 'wallet_status') return true;
    if (method != 'invoke_contract') return false;
    if (params['create_tx'] != false) return false;
    final args = params['args'];
    if (args is! String) return false;
    final kv = {
      for (final p in args.split(','))
        if (p.contains('=')) p.split('=').first: p.split('=').last,
    };
    final action = kv['action'];
    if (action == 'pools_view' || action == 'pool_view') return true;
    const predictable = {'pool_trade', 'pool_add_liquidity', 'pool_withdraw'};
    return predictable.contains(action) && kv['bPredictOnly'] == '1';
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    if (!allows(method, params)) {
      throw StateError('live DEX test refused $method ${params['args']}');
    }
    sent.add(method == 'invoke_contract' ? '${params['args']}' : method);
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

void main() {
  final enabled = Platform.environment['BEAM_LIVE_DEX'] == '1';
  final skip = enabled ? null : 'set BEAM_LIVE_DEX=1 to run';

  test('the guard refuses everything that could move funds', () {
    bool ok(String m, Map<String, Object?> p) => PredictOnlyGuard.allows(m, p);
    expect(ok('process_invoke_data', {'data': <int>[1]}), isFalse);
    expect(ok('tx_send', const {}), isFalse);
    expect(
      ok('invoke_contract', {
        'create_tx': true,
        'args': 'action=pools_view,cid=x',
      }),
      isFalse,
    );
    expect(
      ok('invoke_contract', {
        'create_tx': false,
        'args': 'action=pool_trade,bPredictOnly=0',
      }),
      isFalse,
    );
    expect(
      ok('invoke_contract', {
        'create_tx': false,
        'args': 'action=pool_trade,val2_pay=1',
      }),
      isFalse,
    );
    expect(
      ok('invoke_contract', {
        'create_tx': false,
        'args': 'action=pool_create,aid1=0,aid2=1,kind=2,bPredictOnly=1',
      }),
      isFalse,
    );
    expect(
      ok('invoke_contract', {
        'create_tx': false,
        'args': 'action=pool_trade,val2_pay=1,bPredictOnly=1',
      }),
      isTrue,
    );
  });

  test('pool_trade direction, verified with bPredictOnly=1', () async {
    final home = Platform.environment['HOME']!;
    final state =
        jsonDecode(
              File('$home/beam-campfire-test/run/funder.json')
                  .readAsStringSync(),
            )
            as Map<String, Object?>;
    final transport = PredictOnlyGuard(
      TcpLineTransport(
        port: state['port']! as int,
        aclKey: state['key']! as String,
        log: (_) {},
      ),
    );
    await transport.connect();
    final api = BeamApi(transport);
    final shader = ammAppShader(const FileShaderSource('assets/beam/shaders'));
    final bytes = await shader.load();
    final dex = BeamDexService(api, shader);

    final status = await api.walletStatus();
    print(
      'wallet_status: height ${status.currentHeight}, '
      'is_in_sync ${status.isInSync}',
    );
    expect(status.isInSync, isTrue);

    final pools = await dex.listPools(includeEmpty: true);
    final live = pools.where((p) => !p.isEmpty).toList();
    print('pools_view: ${pools.length} pools, ${live.length} with liquidity');
    final pool = live.singleWhere(
      (p) => p.aid1 == 0 && p.aid2 == 174 && p.kind == BeamPoolKind.high,
    );
    print(
      'BEAM/FOMO kind 2: tok1(BEAM) ${pool.tok1}, tok2(FOMO) ${pool.tok2}, '
      'ctl ${pool.ctl}, lp-token ${pool.lpToken}, k1_2 ${pool.shaderRate12}',
    );

    // Both orderings, raw, so the result does not depend on DexArgs.
    const pay = 10000000; // 0.1 of the paid asset
    Future<Map<String, Object?>> predict(int aid1, int aid2) async {
      final args =
          'action=pool_trade,cid=$kDexContractId,aid1=$aid1,aid2=$aid2,'
          'kind=2,val1_buy=0,val2_pay=$pay,bPredictOnly=1';
      final r = await api.invokeContract(
        createTx: false,
        args: args,
        contractBytes: bytes,
      );
      print('aid1=$aid1,aid2=$aid2,val2_pay=$pay -> ${r.output}');
      expect(r.rawData, isNull);
      return ShaderOutput.map(ShaderOutput.decode(r.output)['res'], 'res');
    }

    final a = await predict(174, 0);
    final b = await predict(0, 174);

    // Which asset was received? At spot, a raw pay of P buys about
    // P × reserve(received) / reserve(paid). Compare each prediction with
    // both hypotheses and keep the one within 0.1%.
    String received(Map<String, Object?> res) {
      final buy = ShaderOutput.amount(res, 'buy');
      final raw = ShaderOutput.amount(res, 'pay_raw');
      bool near(BigInt rRecv, BigInt rPay) {
        final expected = BeamRatio(raw * rRecv, rPay);
        final dev = (BeamRatio(buy, BigInt.one) - expected) / expected;
        return dev.numerator.abs() * BigInt.from(1000) <= dev.denominator;
      }

      final fomo = near(pool.tok2, pool.tok1);
      final beam = near(pool.tok1, pool.tok2);
      expect(fomo != beam, isTrue);
      return fomo ? 'pays BEAM, receives FOMO' : 'pays FOMO, receives BEAM';
    }

    final ra = received(a);
    final rb = received(b);
    print('VERDICT aid1=174,aid2=0: $ra');
    print('VERDICT aid1=0,aid2=174: $rb');
    expect(ra, 'pays BEAM, receives FOMO');
    expect(rb, 'pays FOMO, receives BEAM');

    // DexArgs encodes the verified rule.
    final built = DexArgs.trade(
      payAsset: 0,
      receiveAsset: 174,
      kind: BeamPoolKind.high,
      payAmount: BigInt.from(pay),
      predictOnly: true,
    );
    expect(built, contains('aid1=174,aid2=0'));

    final q = await dex.quote(
      payAsset: 0,
      payAmount: BigInt.from(pay),
      receiveAsset: 174,
      pools: pools,
    );
    print(
      'service quote: pay ${q.pay} BEAM-groth, receive ${q.receive} '
      'FOMO-groth, pool fee ${q.fee} (${q.kind.feePercent}), impact '
      '${q.priceImpact.toDecimalString(8)}, network fee ${q.networkFee}',
    );

    // Fee per kind, on the deepest BEAM pool of each kind.
    for (final kind in BeamPoolKind.values) {
      final ofKind = live.where((p) => p.kind == kind && p.aid1 == 0).toList()
        ..sort((x, y) => y.tok1.compareTo(x.tok1));
      final p = ofKind.first;
      // fromPrediction refuses fees that break the kind's rule.
      final kq = await dex.quotePool(
        pool: p,
        payAsset: 0,
        payAmount: BigInt.from(100000000),
      );
      final pct = BeamRatio(kq.fee, kq.payRaw) * BeamRatio.fromInt(100);
      print(
        'kind ${kind.wire} (${p.aid1}/${p.aid2}): fee ${kq.fee} on raw '
        '${kq.payRaw} = ${pct.toDecimalString(4)}%',
      );
    }

    print('methods sent: ${transport.sent.length}');
    expect(
      transport.sent.every(
        (s) =>
            s == 'wallet_status' ||
            s.contains('bPredictOnly=1') ||
            s.startsWith('action=pools_view'),
      ),
      isTrue,
    );
    await transport.close();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
}
