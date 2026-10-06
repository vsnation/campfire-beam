/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Recorded Minter answers (mainnet, 2026-10-06, height 4068189, the pinned
// shader, create_tx: false only; nothing was broadcast) and a fake shader
// built on them. create_token_cfbc.json is the transaction for the token
// in the recorded build, with the new token's owner key (derived from the
// recording wallet's master key) replaced by a synthetic one.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../airdrop/invoke_data_writer.dart';

const _dir = 'test/beam/contracts/minter/fixtures';
const _fakeKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';

Map<String, Object?> _result(String name) =>
    ((jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map)['result']!
            as Map)
        .cast<String, Object?>();

Matcher _code(MinterErrorCode c) =>
    throwsA(isA<BeamMinterException>().having((e) => e.code, 'code', c));

class _FakeMinter {
  /// Tokens this wallet owns: aid → (minted, limit).
  final owned = <int, (BigInt, BigInt)>{
    4242: (BigInt.from(10), BigInt.from(100)),
  };
  FakeInvokeEntry Function(FakeInvokeEntry e)? tamper;

  Map<String, Object?> call(Map<String, Object?> p) {
    if (p['create_tx'] != false) throw StateError('create_tx must be false');
    final args = p['args']! as String;
    expect(args, isNot(contains('role=')));
    final a = parseArgs(args);
    switch (a['action']) {
      case 'view_params':
        return _result('view_params');
      case 'view_owned':
        return {
          'output': jsonEncode({
            'res': [
              for (final o in owned.entries)
                {
                  'aid': o.key,
                  'mintedLo': o.value.$1.toInt(),
                  'mintedHi': 0,
                  'limitLo': o.value.$2.toInt(),
                  'limitHi': 0,
                  'owner_pk': _fakeKey,
                  'metadata': 'STD:SCH_VER=1;N=X;SN=X;UN=X;NTHUN=g;NTH_RATIO=1',
                },
            ],
          }),
        };
      case 'view_token':
        final aid = int.parse(a['aid']!);
        if (aid == 44) return _result('view_token_44');
        final o = owned[aid];
        if (o == null) return _result('view_token_missing');
        return {
          'output': jsonEncode({
            'res': {
              'mintedLo': o.$1.toInt(),
              'mintedHi': 0,
              'limitLo': o.$2.toInt(),
              'limitHi': 0,
              'owner_pk': _fakeKey,
              'is_owner': 1,
            },
          }),
        };
      case 'create_token':
        final meta = utf8.encode(a['metadata']!);
        final lo = BigInt.parse(a['limit']!);
        final hi = BigInt.parse(a['limitHi']!);
        return _built(
          FakeInvokeEntry(
            method: MinterMethod.createToken,
            cid: kMinterContractId,
            args: [
              ...InvokeDataWriter.le(BigInt.zero, 4),
              ...InvokeDataWriter.le(lo, 8),
              ...InvokeDataWriter.le(hi, 8),
              ...InvokeDataWriter.hexBytes(_fakeKey),
              ...InvokeDataWriter.le(BigInt.from(meta.length), 4),
              ...meta,
            ],
            funds: {0: BigInt.from(6000000000)},
            comment: MinterKernelComment.createToken,
            charge: kMinterCreateTokenCharge,
          ),
        );
      case 'withdraw':
        final aid = int.parse(a['aid']!);
        final v = BigInt.parse(a['value']!);
        return _built(
          FakeInvokeEntry(
            method: MinterMethod.withdraw,
            cid: kMinterContractId,
            args: [
              ...InvokeDataWriter.le(BigInt.from(aid), 4),
              ...InvokeDataWriter.le(v, 8),
            ],
            funds: {aid: -v},
            comment: MinterKernelComment.mint,
            sigs: [List.filled(32, 7)],
          ),
        );
    }
    return {'output': '{"error": "unknown action"}'};
  }

  Map<String, Object?> _built(FakeInvokeEntry e) {
    final t = tamper;
    return {
      'output': '{}',
      'raw_data': InvokeDataWriter.write([t == null ? e : t(e)]),
      'txid': '00000000000000000000000000000000',
    };
  }
}

void main() {
  const g = BigInt.from;
  late _FakeMinter shader;
  late FakeTransport t;
  late BeamMinterService service;
  final meta = BeamTokenMetadata(
    name: 'Campfire build check',
    shortName: 'CFBC',
    unitName: 'CFBC',
    shortDescription: 'Built and decoded by a test, never sent.',
  );

  setUp(() {
    shader = _FakeMinter();
    t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) => shader(p),
      'process_invoke_data': (Map<String, Object?> p) => {'txid': 'ef' * 16},
    });
    service = BeamMinterService(
      BeamApi(t),
      minterAppShader(const FileShaderSource('assets/beam/shaders')),
    );
  });

  test('the recorded create_token: 60 BEAM out, 0.0167 BEAM fee', () {
    final raw = [
      for (final b in _result('create_token_cfbc')['raw_data']! as List)
        b as int,
    ];
    final d = BeamInvokeData.decode(raw);
    final e = d.entries.single;
    expect(e.contractId, kMinterContractId);
    expect(e.method, MinterMethod.createToken);
    expect(e.charge, kMinterCreateTokenCharge);
    expect(e.comment, MinterKernelComment.createToken);
    expect(e.signatureCount, 0);
    expect(d.spend, {0: g(6000000000)});
    expect(d.fee, g(1670000));
    // Aid 0 | limit 1000 × 10^8 (lo, hi) | owner key | size | metadata.
    expect(e.args.sublist(0, 4), [0, 0, 0, 0]);
    expect(e.args.sublist(4, 12), InvokeDataWriter.le(g(100000000000), 8));
    expect(e.args.sublist(12, 20), List.filled(8, 0));
    expect(e.args.sublist(20, 53), InvokeDataWriter.hexBytes(_fakeKey));
    final text = utf8.encode(meta.encode());
    expect(e.args.sublist(53, 57), InvokeDataWriter.le(g(text.length), 4));
    expect(e.args.sublist(57), text);
  });

  test('view_params, view_token and a missing token (recorded)', () async {
    final p = await service.params();
    expect(p.issueFee, g(5000000000));
    expect(p.daoVaultCid, startsWith('0066b120'));
    final cto = await service.token(44);
    expect(cto!.isOwner, isFalse);
    expect(cto.limit, g(100000000000000));
    expect(cto.metadata, startsWith('STD:SCH_VER=1;N=CTO;'));
    expect(await service.token(0xfffffff0), isNull);
  });

  test('view_owned', () async {
    final owned = await service.ownedTokens();
    expect(owned.single.assetId, 4242);
    expect(owned.single.isOwner, isTrue);
    expect(owned.single.mintable, g(90));
  });

  test('create a token: the issuance fee comes from view_params', () async {
    final p = await service.prepareCreateToken(
      metadata: meta,
      limit: meta.supplyOf(g(1000)),
    );
    expect(p.summary.pays, {0: g(6000000000)});
    expect(p.summary.issueFee, g(5000000000));
    expect(p.summary.assetDeposit, g(1000000000));
    expect(p.summary.networkFee, g(1670000));
    expect(p.summary.beamOut, g(6001670000));
    expect(p.summary.lines, [
      'Create a new token',
      'Issuance fee to the BEAM DAO: 50 BEAM',
      'Asset deposit, never returned: 10 BEAM',
      'Network fee: 0.0167 BEAM',
      'Total BEAM out: 60.0167 BEAM',
    ]);
    // A double tap does not build a second 60 BEAM token.
    await expectLater(
      service.prepareCreateToken(metadata: meta, limit: g(1)),
      _code(MinterErrorCode.busy),
    );
    expect(await service.execute(p), 'ef' * 16);
    expect(t.callsTo('process_invoke_data'), hasLength(1));
    expect(service.isBusy, isFalse);
  });

  test('a different issuance fee on chain is what the user sees', () async {
    t.reply('invoke_contract', (Map<String, Object?> p) {
      final r = shader(p);
      if ((p['args']! as String).contains('view_params')) {
        return {
          'output': (r['output']! as String).replaceFirst(
            '5000000000',
            '7000000000',
          ),
        };
      }
      return r;
    });
    // The fake shader still locks 60 BEAM: the transaction disagrees with
    // the contract's own fee, so it is refused.
    await expectLater(
      service.prepareCreateToken(metadata: meta, limit: g(1)),
      _code(MinterErrorCode.unexpectedTransaction),
    );
  });

  test('tampered create_token transactions are refused', () async {
    FakeInvokeEntry Function(FakeInvokeEntry) withArgs(
      List<int> Function(List<int>) f,
    ) =>
        (e) => FakeInvokeEntry(
          method: e.method,
          cid: e.cid,
          args: f(List.of(e.args)),
          funds: e.funds,
          comment: e.comment,
          charge: e.charge,
          sigs: e.sigs,
        );
    for (final tamper in [
      withArgs((a) => a..[60] ^= 1), // metadata
      withArgs((a) => a..[4] ^= 1), // limit
      withArgs((a) => a..[52] = 2), // owner key parity
      (FakeInvokeEntry e) => FakeInvokeEntry(
        method: e.method,
        cid: e.cid,
        args: e.args,
        funds: {0: g(6000000001)},
        comment: e.comment,
        charge: e.charge,
      ),
      (FakeInvokeEntry e) => FakeInvokeEntry(
        method: e.method,
        cid: e.cid,
        args: e.args,
        funds: e.funds,
        comment: e.comment,
        charge: e.charge + 1,
      ),
    ]) {
      shader.tamper = tamper;
      await expectLater(
        service.prepareCreateToken(metadata: meta, limit: g(100000000000)),
        _code(MinterErrorCode.unexpectedTransaction),
      );
      expect(service.isBusy, isFalse);
    }
    expect(t.callsTo('process_invoke_data'), isEmpty);
  });

  group('mint', () {
    test('within the limit, receives exactly the amount', () async {
      final p = await service.prepareMint(assetId: 4242, value: g(90));
      expect(p.summary.receives, {4242: g(90)});
      expect(p.summary.pays, isEmpty);
      expect(p.summary.networkFee, g(1100000));
      expect(p.summary.lines.first, 'Mint 90 units of asset 4242');
      service.discard(p);
      await expectLater(service.execute(p), _code(MinterErrorCode.expired));
    });

    test('above the limit, not mine, or not a Minter token', () async {
      await expectLater(
        service.prepareMint(assetId: 4242, value: g(91)),
        _code(MinterErrorCode.aboveLimit),
      );
      await expectLater(
        service.prepareMint(assetId: 44, value: g(1)),
        _code(MinterErrorCode.notOwner),
      );
      await expectLater(
        service.prepareMint(assetId: 999, value: g(1)),
        _code(MinterErrorCode.noSuchToken),
      );
      expect(service.isBusy, isFalse);
    });

    test('a mint that pays out more is refused', () async {
      shader.tamper = (e) => FakeInvokeEntry(
        method: e.method,
        cid: e.cid,
        args: e.args,
        funds: {4242: g(-91)},
        comment: e.comment,
        charge: e.charge,
        sigs: e.sigs,
      );
      await expectLater(
        service.prepareMint(assetId: 4242, value: g(90)),
        _code(MinterErrorCode.unexpectedTransaction),
      );
    });
  });

  test('shader refusals map to codes', () async {
    t.reply('invoke_contract', {'output': '{"error": "no such contract"}'});
    await expectLater(service.params(), _code(MinterErrorCode.noSuchContract));
    expect(
      () => ShaderOutput.decode('{"error": "not owner"}'),
      throwsA(isA<BeamShaderException>()),
    );
  });
}
