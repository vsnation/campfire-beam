/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The decoder against a real kernel: a DEX swap that wallet-api built on
// mainnet (create_tx false, bPredictOnly=0) and that was never sent. The
// other DEX raw_data tests use vectors serialized by BEAM's yas from
// hand-made values; this one is what the core actually returns, including
// the dependent (HFT) context and the stored app invoke it adds to a trade.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/contract_args.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_quotes.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_args.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'dex_fixtures.dart';

Map<String, Object?> _fixture() => (jsonDecode(
  File('$dexFixtureDir/trade_built_raw_data.json').readAsStringSync(),
) as Map).cast<String, Object?>();

List<int> _raw(Map<String, Object?> f) =>
    base64.decode((f['result']! as Map)['raw_data_base64']! as String);

void main() {
  const g = BigInt.from;
  final fixture = _fixture();
  final raw = _raw(fixture);
  final args = fixture['args']! as String;

  test('the fixture is the recorded bytes', () {
    expect(raw, hasLength(31674));
    expect(
      crypto.sha256.convert(raw).toString(),
      fixture['raw_data_sha256'],
    );
    // The app's own builder produces exactly the args that were sent.
    expect(
      DexArgs.trade(
        payAsset: 0,
        receiveAsset: 174,
        kind: BeamPoolKind.high,
        payAmount: g(10000000),
        predictOnly: false,
      ),
      args,
    );
  });

  group('the common decoder reads all of it', () {
    final d = BeamInvokeData.decode(raw); // strict: no advanced entries

    test('one dependent AMM trade, no signatures', () {
      final e = d.entries.single;
      expect(
        e.flags,
        BeamInvokeData.flagDependent | BeamInvokeData.flagSaveAppInvoke,
      );
      expect(e.method, DexMethod.trade);
      expect(e.contractId, kDexContractId);
      expect(e.comment, 'Amm trade');
      expect(d.comments, ['Amm trade']);
      expect(e.charge, 0);
      expect(e.signatureCount, 0);
      expect(e.signatureKeyHashes, isEmpty);
      expect(e.isAdvanced, isFalse);
      expect(e.isDependent, isTrue);
      // Built on the context after the wallet's tip, 4068244.
      expect(e.parentHeight, g(4068245));
      expect(e.dataLength, 0);
    });

    test('Amm::Method::Trade args: received, paid, kind, buy', () {
      final r = BeamArgsReader(d.entries.single.args);
      expect(r.u32(), 174); // aid1: the asset received
      expect(r.u32(), 0); // aid2: the asset paid
      expect(r.u8(), BeamPoolKind.high.wire);
      expect(r.u64(), g(80368764)); // m_Buy1
      expect(r.atEnd, isTrue);
    });

    test('pays 0.1 BEAM, receives 0.80368764 FOMO, fee 0.011 BEAM', () {
      // The prediction a moment earlier said buy 80368764, pay 10000000.
      expect(d.pays, {0: g(10000000)});
      expect(d.receives, {174: g(80368764)});
      expect(d.entries.single.spend, {0: g(10000000), 174: g(-80368764)});
      expect(d.fee, BeamContractFee.minimum);
      expect(d.fee, kDexCallFee);
      expect(d.spendMax, isNull);
    });

    test('the stored app invoke is the request, at privilege 0', () {
      expect(d.appArgs, {
        for (final kv in args.split(','))
          kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
      });
      expect(d.appPrivilege, 0);
      expect(d.contractShader, isEmpty);
      // The core stores its compiled form of amm_app.wasm, not the file.
      expect(d.appShader, hasLength(31396));
      expect(
        PinnedShader.digestOf(d.appShader!),
        'bdff009943b48d32af3253b7e61facd09777c8064e83934b23caa0443533dc8b',
      );
    });

    test('every byte is accounted for', () {
      expect(() => BeamInvokeData.decode([...raw, 0]), throwsFormatException);
      expect(
        () => BeamInvokeData.decode(raw.sublist(0, raw.length - 1)),
        throwsFormatException,
      );
    });
  });

  test('BeamDexService.prepareSwap accepts the real kernel', () async {
    final pools = dexEnvelope('pools_view');
    final t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) {
        final a = p['args']! as String;
        if (a == DexArgs.poolsView()) return pools;
        expect(a, args);
        expect(p['create_tx'], isFalse);
        final result = (fixture['result']! as Map).cast<String, Object?>();
        return {
          'output': result['output'],
          'txid': result['txid'],
          'raw_data': raw,
        };
      },
    });
    final dex = BeamDexService(
      BeamApi(t),
      ammAppShader(const FileShaderSource('assets/beam/shaders')),
    );
    final pool = (await dex.listPools()).singleWhere(
      (p) => p.pairs(0, 174) && p.kind == BeamPoolKind.high,
    );
    final prepared = await dex.prepareSwap(
      BeamSwapQuote(
        pool: pool,
        payAsset: 0,
        receiveAsset: 174,
        pay: g(10000000),
        payRaw: g(9900990),
        receive: g(80368764),
        feePool: g(69307),
        feeDao: g(29703),
      ),
    );
    expect(prepared.pays, {0: g(10000000)});
    expect(prepared.receives, {174: g(80368764)});
    expect(prepared.fee, g(1100000));
    expect(prepared.contractId, kDexContractId);
    expect(prepared.rawData, raw);
    expect(t.callsTo('process_invoke_data'), isEmpty);
  });
}
