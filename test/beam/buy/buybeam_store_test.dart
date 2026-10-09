/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where buys are kept: a round trip through the file, writes that replace
// the file whole (a temporary file renamed over it), a record this
// version cannot read kept as it was, and a file that is not JSON moved
// aside instead of overwritten.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_client.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_order.dart';
import 'package:stackwallet/wallets/beam/buy/buybeam_store.dart';

import 'buybeam_fakes.dart';

BuyBeamOrder _order(String deposit, {DateTime? at, BuyBeamState? state}) =>
    BuyBeamOrder(
      depositAddress: deposit,
      assetId: kBtcId,
      symbol: 'BTC',
      chain: 'btc',
      decimals: 8,
      sendAmount: '0.0123',
      sendAmountRaw: BigInt.from(1230000),
      beamAddress: kFakeBeamAddress,
      beamWalletId: 'w1',
      refundAddress: kFakeBtcRefund,
      createdAt: at ?? DateTime.utc(2026, 10, 9, 12),
      beamEstimate: 192460.19775695,
      deadline: DateTime.utc(2026, 10, 10, 12),
      etaSeconds: 810,
      lastState: state,
      beamTxId: state == BuyBeamState.delivered ? 'tx1' : null,
      terminal: state?.isFinal ?? false,
    );

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('buybeam_store_test_');
    file = File('${dir.path}/buybeam_orders.json');
  });

  tearDown(() => dir.delete(recursive: true));

  test('a buy comes back as it was saved, newest first', () async {
    final store = FileBuyBeamStore(() async => file);
    await store.save(_order('a', at: DateTime.utc(2026, 10, 9, 10)));
    await store.save(
      _order(
        'b',
        at: DateTime.utc(2026, 10, 9, 11),
        state: BuyBeamState.delivered,
      ),
    );
    final again = await FileBuyBeamStore(() async => file).all();
    expect(again.map((o) => o.depositAddress), ['b', 'a']);
    final b = again.first;
    expect(b.sendAmount, '0.0123');
    expect(b.sendAmountRaw, BigInt.from(1230000));
    expect(b.beamAddress, kFakeBeamAddress);
    expect(b.refundAddress, kFakeBtcRefund);
    expect(b.lastState, BuyBeamState.delivered);
    expect(b.beamTxId, 'tx1');
    expect(b.terminal, isTrue);
    expect(b.deadline, DateTime.utc(2026, 10, 10, 12));
    expect(b.beamEstimate, 192460.19775695);
    expect(b.chainName, 'Bitcoin');
    expect(again.last.isOpen, isTrue);
  });

  test('saving again replaces the buy, never adds a second', () async {
    final store = FileBuyBeamStore(() async => file);
    await store.save(_order('a'));
    await store.save(_order('a', state: BuyBeamState.buying));
    final all = await FileBuyBeamStore(() async => file).all();
    expect(all, hasLength(1));
    expect(all.single.lastState, BuyBeamState.buying);
  });

  test('a write goes through a temporary file renamed over it', () async {
    final store = FileBuyBeamStore(() async => file);
    await store.save(_order('a'));
    expect(file.existsSync(), isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    // A stale temporary file from a crash does not hide the real one.
    File('${file.path}.tmp').writeAsStringSync('[half of');
    expect(
      (await FileBuyBeamStore(() async => file).all()).single.depositAddress,
      'a',
    );
    await store.save(_order('b'));
    expect(File('${file.path}.tmp').existsSync(), isFalse);
    expect(jsonDecode(file.readAsStringSync()), hasLength(2));
  });

  test('saves are written one at a time, in order', () async {
    final store = FileBuyBeamStore(() async => file);
    await Future.wait([
      for (var i = 0; i < 10; i++)
        store.save(_order('x$i', at: DateTime.utc(2026, 10, 9, 0, i))),
    ]);
    expect(await FileBuyBeamStore(() async => file).all(), hasLength(10));
  });

  test('a record this version cannot read is kept, untouched', () async {
    file.writeAsStringSync(
      jsonEncode([
        _order('a').toJson(),
        {'from': 'a later version', 'depositAddress': 7},
      ]),
    );
    final store = FileBuyBeamStore(() async => file);
    expect((await store.all()).single.depositAddress, 'a');
    await store.save(_order('b'));
    final raw = jsonDecode(file.readAsStringSync()) as List;
    expect(raw, hasLength(3));
    expect(raw.last, {'from': 'a later version', 'depositAddress': 7});
  });

  test('a file that is not JSON is moved aside, never overwritten', () async {
    file.writeAsStringSync('this is not json');
    final store = FileBuyBeamStore(() async => file);
    expect(await store.all(), isEmpty);
    final aside = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('.unreadable-'))
        .toList();
    expect(aside, hasLength(1));
    expect(aside.single.readAsStringSync(), 'this is not json');
    await store.save(_order('a'));
    expect((await FileBuyBeamStore(() async => file).all()), hasLength(1));
  });

  test('no file yet: no buys', () async {
    expect(await FileBuyBeamStore(() async => file).all(), isEmpty);
  });
}
