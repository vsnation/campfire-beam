/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/burn/burn.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../airdrop/invoke_data_writer.dart';

Matcher _code(BurnErrorCode c) =>
    throwsA(isA<BeamBurnException>().having((e) => e.code, 'code', c));

void main() {
  const g = BigInt.from;
  const cid = kBlackHoleContractId;
  late FakeTransport t;
  late BeamBurnService service;
  FakeInvokeEntry Function(FakeInvokeEntry)? tamper;

  /// A deposit as the BlackHole shader builds it (`On_manager_deposit`):
  /// Deposit{aid, amount}, FundsLock of exactly that, no key, no charge.
  Map<String, Object?> fakeShader(Map<String, Object?> p) {
    if (p['create_tx'] != false) throw StateError('create_tx must be false');
    final a = parseArgs(p['args']! as String);
    expect(a['role'], 'manager');
    if (a['action'] == 'view_funds') {
      return (jsonDecode(
            File('test/beam/contracts/burn/fixtures/view_funds.json')
                .readAsStringSync(),
          ) as Map)['result']!
          as Map<String, Object?>;
    }
    final aid = int.parse(a['aid']!);
    final amount = BigInt.parse(a['amount']!);
    var e = FakeInvokeEntry(
      method: kBlackHoleDepositMethod,
      cid: a['cid']!,
      args: [
        ...InvokeDataWriter.le(BigInt.from(aid), 4),
        ...InvokeDataWriter.le(amount, 8),
      ],
      funds: {aid: amount},
      comment: kBlackHoleDepositComment,
    );
    final f = tamper;
    if (f != null) e = f(e);
    return {
      'output': '{}',
      'raw_data': InvokeDataWriter.write([e]),
      'txid': '00000000000000000000000000000000',
    };
  }

  setUp(() {
    tamper = null;
    t = FakeTransport({
      'invoke_contract': fakeShader,
      'process_invoke_data': (Map<String, Object?> p) => {'txid': '12' * 16},
    });
    service = BeamBurnService(
      BeamApi(t),
      blackHoleAppShader(const FileShaderSource('assets/beam/shaders')),
    );
  });

  test('args', () {
    expect(
      BurnArgs.deposit(assetId: 174, amount: g(5)),
      'role=manager,action=deposit,cid=$cid,aid=174,amount=5',
    );
    expect(BurnArgs.viewFunds(), 'role=manager,action=view_funds,cid=$cid');
    // BEAM itself, zero and malformed input are refused.
    expect(
      () => BurnArgs.deposit(assetId: 0, amount: g(1)),
      throwsArgumentError,
    );
    expect(
      () => BurnArgs.deposit(assetId: 1, amount: BigInt.zero),
      throwsArgumentError,
    );
    expect(
      () => BurnArgs.deposit(assetId: 1, amount: g(1), cid: 'x'),
      throwsArgumentError,
    );
  });

  test(
    'the shader pin is the bundled file, byte-identical to the tag',
    () async {
      final bytes = await blackHoleAppShader(
        const FileShaderSource('assets/beam/shaders'),
      ).load();
      expect(PinnedShader.digestOf(bytes), kBlackHoleAppShaderSha256);
      expect(bytes, hasLength(kBlackHoleAppShaderSize));
    },
  );

  test('a burn says, in its own type, that it is forever', () async {
    final p = await service.prepareBurn(assetId: 174, amount: g(250));
    final s = p.summary;
    expect(s.irreversible, isTrue);
    expect(s.assetId, 174);
    expect(s.amount, g(250));
    expect(s.networkFee, g(1100000));
    expect(s.contractId, cid);
    expect(s.warning, contains('forever'));
    expect(s.lines, [
      'Burn (destroy forever): 250 units of asset 174',
      'Network fee: 0.011 BEAM',
      'This destroys 250 units of asset 174 forever. Nobody, including you, '
          'can ever get them back.',
    ]);
    expect(p.invoke.pays, {174: g(250)});
  });

  test('nothing is sent without the acknowledgement', () async {
    final p = await service.prepareBurn(assetId: 174, amount: g(1));
    await expectLater(
      service.execute(p, acknowledgedPermanentLoss: false),
      _code(BurnErrorCode.notAcknowledged),
    );
    expect(t.callsTo('process_invoke_data'), isEmpty);
    expect(
      await service.execute(p, acknowledgedPermanentLoss: true),
      '12' * 16,
    );
    await expectLater(
      service.execute(p, acknowledgedPermanentLoss: true),
      _code(BurnErrorCode.alreadyExecuted),
    );
    expect(t.callsTo('process_invoke_data'), hasLength(1));
  });

  test('one burn at a time', () async {
    final a = service.prepareBurn(assetId: 174, amount: g(1));
    final b = service.prepareBurn(assetId: 174, amount: g(1));
    await expectLater(b, _code(BurnErrorCode.busy));
    final p = await a;
    service.discard(p);
    expect(service.isBusy, isFalse);
    await expectLater(
      service.execute(p, acknowledgedPermanentLoss: true),
      _code(BurnErrorCode.expired),
    );
  });

  test('a deposit that is not exactly the request is refused', () async {
    FakeInvokeEntry alter({
      required FakeInvokeEntry e,
      String? cid,
      Map<int, BigInt>? funds,
      List<int>? args,
      int? charge,
      List<List<int>>? sigs,
    }) => FakeInvokeEntry(
      method: e.method,
      cid: cid ?? e.cid,
      args: args ?? e.args,
      funds: funds ?? e.funds,
      comment: e.comment,
      charge: charge ?? e.charge,
      sigs: sigs ?? e.sigs,
    );
    for (final f in <FakeInvokeEntry Function(FakeInvokeEntry)>[
      (e) => alter(e: e, cid: 'ee' * 32),
      (e) => alter(e: e, funds: {174: g(2)}),
      (e) => alter(e: e, funds: {174: g(1), 0: g(1)}),
      (e) => alter(e: e, args: [...e.args.sublist(0, 4), ...List.filled(8, 9)]),
      (e) => alter(e: e, charge: 1),
      (e) => alter(e: e, sigs: [List.filled(32, 1)]),
    ]) {
      tamper = f;
      await expectLater(
        service.prepareBurn(assetId: 174, amount: g(1)),
        _code(BurnErrorCode.unexpectedTransaction),
      );
      expect(service.isBusy, isFalse);
    }
  });

  test('burned totals (recorded view_funds)', () async {
    final totals = await service.burnedTotals();
    expect(totals, hasLength(16));
    expect(totals[0], g(105120000));
    expect(totals[174], g(2431214));
  });

  test('the fee constant', () {
    expect(kBurnFee, BeamContractFee.minimum);
    expect(kBurnFee, g(1100000));
  });
}
