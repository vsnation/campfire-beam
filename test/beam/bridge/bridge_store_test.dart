/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Crossings on disk: every field survives the JSON file, a write replaces
// the file whole, a record this version cannot read is written back as it
// was, and a file that is not JSON is moved aside instead of overwritten.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_crossing.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_store.dart';

import 'bridge_fakes.dart';

BridgeCrossing full() {
  final t = DateTime.utc(2026, 10, 9, 16, 42, 5);
  return BridgeCrossing(
    id: 'x1',
    routeId: 'usdt',
    direction: BridgeDirection.toBeam,
    state: BridgeCrossingState.claiming,
    amount: BigInt.parse('100000000'),
    receives: BigInt.parse('10000000000'),
    relayerFee: BigInt.from(157),
    beamNetworkFee: BigInt.from(12100000),
    ethNetworkFee: BigInt.parse('247333500000000'),
    beamWalletId: 'beam-wallet',
    ethWalletId: 'eth-wallet',
    ethAddress: kFakeEthAddress,
    beamReceiveKey: '${'ab' * 32}01',
    approveHashes: ['0x${'1' * 64}', '0x${'2' * 64}'],
    lockHash: '0x${'3' * 64}',
    beamTxId: 'tx-send',
    claimTxId: 'tx-claim',
    msgId: 110,
    countBefore: 3,
    height: 26156200,
    createdAt: t,
    updatedAt: t.add(const Duration(minutes: 5)),
    dueAt: t.add(const Duration(minutes: 1)),
    lockedAt: t.add(const Duration(minutes: 2)),
    deliveredAt: t.add(const Duration(minutes: 3)),
    claimStartedAt: t.add(const Duration(minutes: 4)),
    finishedAt: t.add(const Duration(minutes: 6)),
    lastError: 'a reason',
    autoClaim: true,
  );
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('bridge_'));
  tearDown(() async => dir.delete(recursive: true));

  File fileIn(Directory d) => File('${d.path}/bridge_crossings.json');

  test('every field survives JSON', () {
    final a = full();
    final b = BridgeCrossing.fromJson(
      (jsonDecode(jsonEncode(a.toJson())) as Map).cast<String, dynamic>(),
    );
    expect(jsonEncode(b.toJson()), jsonEncode(a.toJson()));
    expect(b.route, usdtRoute);
    expect(b.isOpen, isTrue);
  });

  test('an unknown state is refused, not guessed', () {
    final j = full().toJson()..['state'] = 'teleported';
    expect(() => BridgeCrossing.fromJson(j), throwsFormatException);
  });

  test('the file store writes the whole file through a temporary one, '
      'and reads it back after a restart', () async {
    final f = fileIn(dir);
    final store = FileBridgeStore(() async => f);
    await store.save(full());
    await store.save(full().copyWith(state: BridgeCrossingState.claimed));
    expect(File('${f.path}.tmp').existsSync(), isFalse);
    final again = FileBridgeStore(() async => f);
    final all = await again.all();
    expect(all.single.state, BridgeCrossingState.claimed);
    expect(all.single.claimTxId, 'tx-claim');
  });

  test('a record this version cannot read is kept, never dropped', () async {
    final f = fileIn(dir);
    final future = {...full().toJson(), 'id': 'from-a-newer-campfire'}
      ..['state'] = 'somethingNew';
    await f.writeAsString(jsonEncode([future, full().toJson()]));
    final store = FileBridgeStore(() async => f);
    expect((await store.all()).single.id, 'x1');
    await store.save(full().copyWith(state: BridgeCrossingState.claimed));
    final raw = jsonDecode(await f.readAsString()) as List;
    expect(raw, hasLength(2));
    expect(raw.any((j) => (j as Map)['state'] == 'somethingNew'), isTrue);
  });

  test('a file that is not JSON is moved aside', () async {
    final f = fileIn(dir);
    await f.writeAsString('{not json');
    final store = FileBridgeStore(() async => f);
    expect(await store.all(), isEmpty);
    await store.save(full());
    final aside = dir.listSync().whereType<File>().where(
      (e) => e.path.contains('.unreadable-'),
    );
    expect(aside.single.readAsStringSync(), '{not json');
  });

  test('the file store refuses a second crossing with the same '
      'message', () async {
    final store = FileBridgeStore(() async => fileIn(dir));
    await store.save(full());
    final twin = BridgeCrossing.fromJson({...full().toJson(), 'id': 'x2'});
    await expectLater(store.save(twin), throwsA(isA<BridgeStoreConflict>()));
    expect((await store.all()).map((c) => c.id), ['x1']);
  });
}
