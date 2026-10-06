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
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'airdrop_fixtures.dart';
import 'invoke_data_writer.dart';
import 'memory_code_store.dart';

class _MemorySource implements ShaderSource {
  _MemorySource(this.bytes);

  final Uint8List bytes;

  @override
  Future<Uint8List> read(String name) async => bytes;
}

Matcher _code(AirdropErrorCode c) =>
    throwsA(isA<BeamAirdropException>().having((e) => e.code, 'code', c));

void main() {
  const g = BigInt.from;
  late FakeAirdropShader shader;
  late FakeTransport t;
  late List<String> log;
  late MemoryCodeStore store;
  late BeamAirdropService service;

  BeamAirdropService make({
    VoucherCodeStore? withStore,
    bool noStore = false,
    DateTime Function()? clock,
  }) => BeamAirdropService(
    BeamApi(t),
    airdropAppShader(const FileShaderSource('assets/beam/shaders')),
    store: noStore ? null : (withStore ?? store),
    random: Random(11),
    clock: clock,
  );

  setUp(() {
    log = [];
    shader = FakeAirdropShader();
    store = MemoryCodeStore(log);
    t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) => shader(p),
      'process_invoke_data': (Map<String, Object?> p) {
        log.add('sent');
        return {'txid': 'cd' * 16};
      },
      'wallet_status': jsonDecode(
        File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
      ),
      'tx_status': (Map<String, Object?> p) => {
        'txId': p['txId'],
        'status': 3,
        'status_string': 'completed',
        'tx_type': 12,
        'create_time': 1790000000,
      },
    });
    service = make();
  });

  group('create batch', () {
    test('locks the vouchers plus 1%, read back from raw_data', () async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000), g(100000)],
      );
      expect(p.action, AirdropAction.createBatch);
      expect(p.summary.pays, {0: g(202000)});
      expect(p.summary.creationFee, g(2000));
      expect(p.summary.networkFee, g(12100000));
      expect(p.summary.beamOut, g(12302000));
      expect(p.summary.receives, isEmpty);
      expect(p.codes, hasLength(2));
      for (final c in p.codes) {
        expect(AirdropVoucherCode.isWellFormed(c), isTrue);
      }
      expect(p.summary.lines, [
        'Create 2 vouchers of 0.001 BEAM each',
        'You lock: 0.00202 BEAM',
        'Contract fee (1%, included above): 0.00002 BEAM',
        'Network fee: 0.121 BEAM',
        'Total BEAM out: 0.12302 BEAM',
        'The codes are the only key to these funds. They are saved in this '
            'wallet before anything is sent.',
      ]);
      // The shader got the codes' hashes, never the codes.
      final args = shader.seen.last;
      for (final c in p.codes) {
        expect(args, isNot(contains(AirdropVoucherCode.normalise(c))));
        expect(args, contains(AirdropVoucherCode.hashHex(c)));
      }
      // Nothing saved or sent yet.
      expect(log, isEmpty);
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(t.lastParams('invoke_contract')['create_tx'], isFalse);
    });

    test('a token batch: the fee is in the token, gas in BEAM', () async {
      final p = await service.prepareCreateBatch(
        assetId: 174,
        values: [g(5000000), g(1), g(250)],
      );
      expect(p.summary.pays, {174: g(5000251 + 50002)});
      expect(p.summary.creationFee, g(50002));
      expect(p.summary.beamOut, g(12100000));
      expect(p.summary.lines.first, 'Create 3 vouchers');
    });

    test('codes are saved before the broadcast, then get the tx id', () async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      final tx = await service.execute(p);
      expect(tx, 'cd' * 16);
      expect(log, ['put unconfirmed', 'sent', 'put broadcast']);
      final saved = (await store.all()).single;
      expect(saved.txId, 'cd' * 16);
      expect(saved.txStatus, AirdropBatchTxStatus.broadcast);
      expect(saved.codes.single.code, p.codes.single);
      expect(
        saved.codes.single.hashHex,
        AirdropVoucherCode.hashHex(p.codes.single),
      );
      expect(t.lastParams('process_invoke_data')['data'], p.rawData);
    });

    test('nothing is sent when the codes cannot be saved', () async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      store.failNextPut = StateError('disk full');
      await expectLater(
        service.execute(p),
        _code(AirdropErrorCode.codesNotSaved),
      );
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(service.isBusy, isFalse);
    });

    test('a store that drops the write is caught by the read-back', () async {
      store.dropWrites = true;
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      await expectLater(
        service.execute(p),
        _code(AirdropErrorCode.codesNotSaved),
      );
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('a refused broadcast keeps the codes, marked failed', () async {
      t.reply(
        'process_invoke_data',
        const BeamRpcException(-32603, 'Not enough funds'),
      );
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      await expectLater(service.execute(p), throwsA(isA<BeamRpcException>()));
      final saved = (await store.all()).single;
      expect(saved.txStatus, AirdropBatchTxStatus.failed);
      expect(saved.codes, hasLength(1));
      expect(store.deletes, 0);
    });

    test('a lost connection keeps the codes, unconfirmed', () async {
      t.reply('process_invoke_data', TimeoutException('no answer'));
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      await expectLater(service.execute(p), throwsA(isA<TimeoutException>()));
      expect(
        (await store.all()).single.txStatus,
        AirdropBatchTxStatus.unconfirmed,
      );
      // And it cannot be sent again: the core may have it already.
      await expectLater(
        service.execute(p),
        _code(AirdropErrorCode.alreadyExecuted),
      );
    });

    test('needs a code store', () async {
      service = make(noStore: true);
      await expectLater(
        service.prepareCreateBatch(assetId: 0, values: [g(1)]),
        _code(AirdropErrorCode.noCodeStore),
      );
      expect(service.isBusy, isFalse);
      expect(t.calls, isEmpty);
    });

    test('refuses 0 or 101 vouchers before calling anything', () async {
      for (final n in [0, 101]) {
        await expectLater(
          service.prepareCreateBatch(assetId: 0, values: List.filled(n, g(1))),
          throwsArgumentError,
        );
      }
      expect(t.calls, isEmpty);
      expect(service.isBusy, isFalse);
    });
  });

  group('one airdrop transaction at a time', () {
    test('a second tap in the same frame is refused', () async {
      final first = service.prepareCreateBatch(assetId: 0, values: [g(100000)]);
      // No await between the two: the first has not reached the core.
      final second = service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      await expectLater(second, _code(AirdropErrorCode.busy));
      final p = await first;
      expect(service.isBusy, isTrue);
      // Still busy while the first awaits confirmation.
      await expectLater(
        service.prepareRedeem('ABCD-EFGH-JKLM-NPQR'),
        _code(AirdropErrorCode.busy),
      );
      await service.execute(p);
      expect(service.isBusy, isFalse);
      expect(t.callsTo('process_invoke_data'), hasLength(1));
      // Exactly one batch was built.
      expect(
        shader.seen.where((a) => a.contains('action=create_batch')),
        hasLength(1),
      );
    });

    test('discard releases; a discarded call cannot be sent', () async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      service.discard(p);
      expect(service.isBusy, isFalse);
      await expectLater(service.execute(p), _code(AirdropErrorCode.expired));
      expect(t.callsTo('process_invoke_data'), isEmpty);
      expect(await store.all(), isEmpty);
    });

    test('a failed prepare releases the service', () async {
      await expectLater(
        service.prepareRedeem('ABCD-EFGH-JKLM-NPQR'),
        _code(AirdropErrorCode.voucherNotFound),
      );
      expect(service.isBusy, isFalse);
    });

    test('execute twice sends once', () async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      final a = service.execute(p);
      final b = service.execute(p);
      await expectLater(b, _code(AirdropErrorCode.alreadyExecuted));
      await a;
      expect(t.callsTo('process_invoke_data'), hasLength(1));
    });
  });

  group('the prepared transaction must be exactly the request', () {
    Future<void> refused(FakeInvokeEntry Function(FakeInvokeEntry) f) async {
      shader.tamper = f;
      await expectLater(
        service.prepareCreateBatch(assetId: 0, values: [g(100000)]),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
      expect(service.isBusy, isFalse);
    }

    FakeInvokeEntry copy(
      FakeInvokeEntry e, {
      String? cid,
      int? method,
      List<int>? args,
      Map<int, BigInt>? funds,
      String? comment,
      int? charge,
      List<List<int>>? sigs,
    }) => FakeInvokeEntry(
      method: method ?? e.method,
      cid: cid ?? e.cid,
      args: args ?? e.args,
      funds: funds ?? e.funds,
      comment: comment ?? e.comment,
      charge: charge ?? e.charge,
      sigs: sigs ?? e.sigs,
    );

    test('another contract', () => refused((e) => copy(e, cid: 'ee' * 32)));
    test('another method', () => refused((e) => copy(e, method: 3)));
    test('more locked than asked', () {
      return refused((e) => copy(e, funds: {0: g(202000)}));
    });
    test('another asset as well', () {
      return refused((e) => copy(e, funds: {...e.funds, 7: g(1)}));
    });
    test('a different voucher hash', () {
      return refused((e) {
        final a = List<int>.of(e.args);
        a[45] ^= 1;
        return copy(e, args: a);
      });
    });
    test('another creator key', () {
      return refused((e) {
        final a = List<int>.of(e.args);
        a[0] ^= 1;
        return copy(e, args: a);
      });
    });
    test('a different BVM charge (so a different fee)', () {
      return refused((e) => copy(e, charge: 2000000));
    });
    test('another kernel comment', () {
      return refused((e) => copy(e, comment: 'Send to Black hole contract'));
    });
    test('two signing keys', () {
      return refused((e) => copy(e, sigs: [...e.sigs, List.filled(32, 1)]));
    });

    test('a read-only call that returns a transaction', () async {
      shader.viewsReturnRawData = true;
      await expectLater(
        service.myBatches(),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
    });

    test('a substituted shader file is never run', () async {
      final bytes = await airdropAppShader(
        const FileShaderSource('assets/beam/shaders'),
      ).load();
      final evil = Uint8List.fromList(bytes)..[100] ^= 1;
      service = BeamAirdropService(
        BeamApi(t),
        airdropAppShader(_MemorySource(evil)),
        store: store,
      );
      await expectLater(service.stats(), throwsA(isA<PinnedShaderException>()));
      expect(t.calls, isEmpty);
    });

    test('the dead v3 contract is refused outright', () {
      expect(
        () => BeamAirdropService(
          BeamApi(t),
          airdropAppShader(const FileShaderSource('assets/beam/shaders')),
          contractId: kAirdropDeadContractIds.single,
        ),
        throwsArgumentError,
      );
    });
  });

  group('redeem', () {
    const code = 'abcd-efgh-jklm-npqr';
    late String hash;

    setUp(() {
      hash = AirdropVoucherCode.hashHex(code);
      shader.addBatch(g(4), 174, {hash: g(1000000)});
    });

    test('sends the normalised code as the preimage, never the hash', () async {
      final p = await service.prepareRedeem(code);
      final args = shader.seen.last;
      expect(args, contains('action=redeem'));
      expect(args, contains(',code=ABCDEFGHJKLMNPQR'));
      expect(args, isNot(contains(hash)));
      expect(p.summary.receives, {174: g(1000000)});
      expect(p.summary.pays, isEmpty);
      expect(p.summary.networkFee, g(12100000));
      expect(p.summary.claimCostsMoreThanItPays, isFalse);
      expect(await service.execute(p), 'cd' * 16);
    });

    test('a BEAM voucher worth less than the fee is flagged', () async {
      const small = 'zzzz-zzzz-zzzz-zzzz';
      shader.addBatch(g(9), 0, {AirdropVoucherCode.hashHex(small): g(100000)});
      final p = await service.prepareRedeem(small);
      expect(p.summary.claimCostsMoreThanItPays, isTrue);
      expect(p.summary.lines.last, contains('worth less than the network fee'));
    });

    test('unknown, already claimed and empty codes', () async {
      await expectLater(
        service.prepareRedeem('ZZZZ-ZZZZ-ZZZZ-ZZZ2'),
        _code(AirdropErrorCode.voucherNotFound),
      );
      shader.vouchers[hash]!.redeemed = true;
      await expectLater(
        service.prepareRedeem(code),
        _code(AirdropErrorCode.alreadyRedeemed),
      );
      await expectLater(
        service.prepareRedeem(' - '),
        _code(AirdropErrorCode.invalidCode),
      );
      expect(t.callsTo('process_invoke_data'), isEmpty);
    });

    test('a claim that would pay out something else is refused', () async {
      shader.tamper = (e) => FakeInvokeEntry(
        method: e.method,
        cid: e.cid,
        args: e.args,
        funds: {174: g(-1)},
        comment: e.comment,
        charge: e.charge,
        sigs: e.sigs,
      );
      await expectLater(
        service.prepareRedeem(code),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
    });

    test('checkVoucher reports state without building anything', () async {
      final v = await service.checkVoucher(code);
      expect(v!.assetId, 174);
      expect(v.value, g(1000000));
      expect(v.redeemed, isFalse);
      expect(await service.checkVoucher('ZZZZ-ZZZZ-ZZZZ-ZZZ2'), isNull);
      expect(t.lastParams('invoke_contract')['create_tx'], isFalse);
    });
  });

  group('cancel batch', () {
    final hashes = {for (var i = 1; i <= 3; i++) '0$i' * 32: g(1000000)};

    setUp(() => shader.addBatch(g(21), 174, hashes));

    test('returns exactly the unclaimed vouchers', () async {
      shader.vouchers['01' * 32]!.redeemed = true;
      final p = await service.prepareCancelBatch(g(21));
      expect(p.summary.receives, {174: g(2000000)});
      expect(p.summary.voucherCount, 2);
      expect(p.summary.networkFee, g(18100000));
      expect(
        p.summary.lines.first,
        'Cancel batch 21 and take back its unclaimed vouchers',
      );
    });

    test('a claim between the view and the build is caught', () async {
      shader.tamper = (e) {
        // The shader saw one voucher fewer than the view did.
        final a = List<int>.of(e.args)
          ..removeRange(e.args.length - 32, e.args.length);
        a[41] = 2;
        return FakeInvokeEntry(
          method: e.method,
          cid: e.cid,
          args: a,
          funds: {174: g(-2000000)},
          comment: e.comment,
          charge: e.charge,
          sigs: e.sigs,
        );
      };
      await expectLater(
        service.prepareCancelBatch(g(21)),
        _code(AirdropErrorCode.unexpectedTransaction),
      );
    });

    test('not this wallet\'s batch, or nothing left', () async {
      await expectLater(
        service.prepareCancelBatch(g(6)),
        _code(AirdropErrorCode.batchNotFound),
      );
      for (final v in shader.vouchers.values) {
        v.redeemed = true;
      }
      await expectLater(
        service.prepareCancelBatch(g(21)),
        _code(AirdropErrorCode.nothingToCancel),
      );
    });
  });

  group('owner fees', () {
    test('withdraw within what was collected', () async {
      final p = await service.prepareWithdrawFees(
        assetId: 174,
        amount: g(1000),
      );
      expect(p.summary.receives, {174: g(1000)});
      expect(p.summary.networkFee, g(12100000));
    });

    test('more than collected, or an asset with none', () async {
      await expectLater(
        service.prepareWithdrawFees(assetId: 0, amount: g(34000001)),
        _code(AirdropErrorCode.insufficientFees),
      );
      await expectLater(
        service.prepareWithdrawFees(assetId: 7, amount: g(1)),
        _code(AirdropErrorCode.noFees),
      );
    });

    test('not the owner', () async {
      t.reply('invoke_contract', (Map<String, Object?> p) {
        if ((p['args']! as String).contains('action=view,')) {
          return {
            'output': airdropOutput('view')
                .replaceFirst('"is_owner": 1', '"is_owner": 0'),
          };
        }
        return shader(p);
      });
      await expectLater(
        service.prepareWithdrawFees(assetId: 0, amount: g(1)),
        _code(AirdropErrorCode.notOwner),
      );
    });
  });

  group('saved codes are never deleted behind the user\'s back', () {
    Future<AirdropSavedBatch> created({bool confirm = true}) async {
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000), g(100000)],
      );
      await service.execute(p);
      if (confirm) {
        shader.addBatch(g(8), 0, {
          for (final c in p.saved!.codes) c.hashHex: c.value,
        });
      }
      return (await store.all()).single;
    }

    test('refresh updates statuses and keeps every code', () async {
      final b = await created();
      shader.vouchers[b.codes.first.hashHex]!.redeemed = true;
      final r = await service.refreshSavedBatch(b);
      expect(r.txStatus, AirdropBatchTxStatus.confirmed);
      expect(r.codes.map((c) => c.status), [
        AirdropCodeStatus.claimed,
        AirdropCodeStatus.available,
      ]);
      expect((await store.all()).single.codes, hasLength(2));
      expect(store.deletes, 0);
    });

    test('forget is refused while a code is unclaimed', () async {
      final b = await created();
      await expectLater(
        service.forgetSavedBatch(b.localId),
        _code(AirdropErrorCode.stillHoldsFunds),
      );
      expect(store.deletes, 0);
    });

    test('forget waits for a synced wallet', () async {
      final b = await created();
      for (final c in b.codes) {
        shader.vouchers[c.hashHex]!.redeemed = true;
      }
      final status =
          (jsonDecode(
              File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
            ) as Map)
            ..['result'] = {
              ...((jsonDecode(
                    File('test/beam/fixtures/wallet_status.json')
                        .readAsStringSync(),
                  ) as Map)['result']!
                  as Map),
              'is_in_sync': false,
            };
      t.reply('wallet_status', status);
      await expectLater(
        service.forgetSavedBatch(b.localId),
        _code(AirdropErrorCode.walletNotSynced),
      );
      expect(store.deletes, 0);
    });

    test('forget is allowed once every code is claimed', () async {
      final b = await created();
      for (final c in b.codes) {
        shader.vouchers[c.hashHex]!.redeemed = true;
      }
      await service.forgetSavedBatch(b.localId);
      expect(await store.all(), isEmpty);
    });

    test('an unconfirmed batch with nothing on chain waits a day', () async {
      t.reply('process_invoke_data', TimeoutException('lost'));
      final p = await service.prepareCreateBatch(
        assetId: 0,
        values: [g(100000)],
      );
      await expectLater(service.execute(p), throwsA(isA<TimeoutException>()));
      final id = (await store.all()).single.localId;
      await expectLater(
        service.forgetSavedBatch(id),
        _code(AirdropErrorCode.stillHoldsFunds),
      );
      final later = make(
        clock: () => DateTime.now().add(const Duration(hours: 25)),
      );
      await later.forgetSavedBatch(id);
      expect(await store.all(), isEmpty);
    });

    test(
      'a code found on chain proves the batch, whatever the record',
      () async {
        t.reply('process_invoke_data', TimeoutException('lost'));
        final p = await service.prepareCreateBatch(
          assetId: 0,
          values: [g(100000)],
        );
        await expectLater(service.execute(p), throwsA(isA<TimeoutException>()));
        shader.addBatch(g(9), 0, {p.saved!.codes.single.hashHex: g(100000)});
        final r = await service.refreshSavedBatch((await store.all()).single);
        expect(r.txStatus, AirdropBatchTxStatus.confirmed);
        expect(r.codes.single.status, AirdropCodeStatus.available);
        final later = make(
          clock: () => DateTime.now().add(const Duration(days: 30)),
        );
        await expectLater(
          later.forgetSavedBatch(r.localId),
          _code(AirdropErrorCode.stillHoldsFunds),
        );
      },
    );
  });

  test('views', () async {
    shader.addBatch(g(21), 174, {'01' * 32: g(3), '02' * 32: g(3)});
    final batches = await service.myBatches();
    expect(batches.single.id, g(21));
    expect(batches.single.totalCount, 2);
    expect((await service.batchVouchers(g(21))), hasLength(2));
    expect((await service.stats()).totalBatches, g(13));
    expect((await service.settings()).isOwner, isTrue);
    expect(await service.myKey(), fakeKey);
    for (final c in t.callsTo('invoke_contract')) {
      expect(c.params['create_tx'], isFalse);
    }
  });
}
