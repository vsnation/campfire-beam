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
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/secure_voucher_code_store.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../contracts/airdrop/airdrop_fixtures.dart';
import 'beam_ui_harness.dart';

/// Records the order of writes.
class _LoggingStorage extends FakeSecureStorage {
  final keysWritten = <String>[];

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    keysWritten.add(key);
    await super.write(key: key, value: value);
  }
}

const _wallet = '0c5e6a6e-8a52-11f0-9d9b-3b1d0f6c2a11';

AirdropSavedBatch _batch(String id, int seed) {
  final c = AirdropVoucherCode.generate(Random(seed));
  return AirdropSavedBatch(
    localId: id,
    contractId: kAirdropContractId,
    assetId: 0,
    createdAt: DateTime.utc(2026, 10, 6),
    codes: [
      AirdropSavedCode(
        code: c,
        hashHex: AirdropVoucherCode.hashHex(c),
        value: BigInt.from(100000),
      ),
    ],
  );
}

void main() {
  test('round-trips batches; the index is written before the record', () async {
    final s = _LoggingStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    await store.put(_batch('batch_1', 1));
    expect(s.keysWritten, [
      'BEAM_AIRDROP_INDEX:$_wallet',
      'BEAM_AIRDROP_CODES:$_wallet:batch_1',
    ]);
    await store.put(_batch('batch_1', 1));
    await store.put(_batch('batch_2', 2));
    final all = await store.all();
    expect(all.map((b) => b.localId), ['batch_1', 'batch_2']);
    expect(all.first.codes.single.code, _batch('batch_1', 1).codes.single.code);
  });

  test('wallets do not see each other\'s codes', () async {
    final s = FakeSecureStorage();
    await SecureVoucherCodeStore(s, _wallet).put(_batch('batch_1', 1));
    expect(await SecureVoucherCodeStore(s, 'other-wallet').all(), isEmpty);
  });

  test('a failed record write leaves nothing visible and throws', () async {
    final s = FakeSecureStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    await store.put(_batch('batch_1', 1));
    // The index write succeeds, the record write fails.
    await expectLater(
      SecureVoucherCodeStore(_FailSecond(s), _wallet).put(_batch('batch_2', 2)),
      throwsA(isA<FileSystemException>()),
    );
    // The dangling index entry is skipped, the earlier batch is intact.
    expect((await store.all()).map((b) => b.localId), ['batch_1']);
  });

  test('an unreadable record is skipped and kept, never deleted', () async {
    final s = FakeSecureStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    await store.put(_batch('batch_1', 1));
    await store.put(_batch('batch_2', 2));
    await s.write(key: 'BEAM_AIRDROP_CODES:$_wallet:batch_2', value: '{"x":');
    expect((await store.all()).map((b) => b.localId), ['batch_1']);
    expect(store.unreadableCount, 1);
    expect(await s.read(key: 'BEAM_AIRDROP_CODES:$_wallet:batch_2'), isNotNull);
  });

  test('an unreadable index is an error, not an empty list', () async {
    final s = FakeSecureStorage();
    await s.write(key: 'BEAM_AIRDROP_INDEX:$_wallet', value: 'garbage{');
    await expectLater(
      SecureVoucherCodeStore(s, _wallet).all(),
      throwsA(isA<FormatException>()),
    );
  });

  test('delete removes the record and its index entry', () async {
    final s = FakeSecureStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    await store.put(_batch('batch_1', 1));
    await store.put(_batch('batch_2', 2));
    await store.delete('batch_1');
    expect((await store.all()).map((b) => b.localId), ['batch_2']);
    expect(await s.read(key: 'BEAM_AIRDROP_CODES:$_wallet:batch_1'), isNull);
  });

  test('deleteAll removes every batch and the index, and only this '
      "wallet's", () async {
    final s = FakeSecureStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    final other = SecureVoucherCodeStore(s, 'other-wallet');
    await store.put(_batch('batch_1', 1));
    await store.put(_batch('batch_2', 2));
    await other.put(_batch('batch_1', 3));
    await store.deleteAll();
    expect(await s.read(key: 'BEAM_AIRDROP_CODES:$_wallet:batch_1'), isNull);
    expect(await s.read(key: 'BEAM_AIRDROP_CODES:$_wallet:batch_2'), isNull);
    expect(await s.read(key: 'BEAM_AIRDROP_INDEX:$_wallet'), isNull);
    expect(await store.all(), isEmpty);
    expect((await other.all()).map((b) => b.localId), ['batch_1']);
  });

  test('deleteAll with an unreadable index still removes the index', () async {
    final s = FakeSecureStorage();
    await s.write(key: 'BEAM_AIRDROP_INDEX:$_wallet', value: 'garbage{');
    await SecureVoucherCodeStore(s, _wallet).deleteAll();
    expect(await s.read(key: 'BEAM_AIRDROP_INDEX:$_wallet'), isNull);
  });

  test('ids that could escape the key layout are refused', () {
    expect(
      () => SecureVoucherCodeStore(FakeSecureStorage(), 'a:b'),
      throwsArgumentError,
    );
    expect(
      () => SecureVoucherCodeStore(
        FakeSecureStorage(),
        _wallet,
      ).put(_batch('batch:1', 1)),
      throwsArgumentError,
    );
  });

  test('the service saves a batch here, reads it back, then sends', () async {
    final s = _LoggingStorage();
    final store = SecureVoucherCodeStore(s, _wallet);
    final shader = FakeAirdropShader();
    final events = <String>[];
    final t = FakeTransport({
      'invoke_contract': (Map<String, Object?> p) => shader(p),
      'process_invoke_data': (Map<String, Object?> p) {
        events.add('sent after ${s.keysWritten.length} writes');
        return {'txid': 'cd' * 16};
      },
      'wallet_status': jsonDecode(
        File('test/beam/fixtures/wallet_status.json').readAsStringSync(),
      ),
    });
    final service = BeamAirdropService(
      BeamApi(t),
      airdropAppShader(MemoryShaderSource()),
      store: store,
      random: Random(3),
    );
    final p = await service.prepareCreateBatch(
      assetId: 0,
      values: [BigInt.from(100000), BigInt.from(100000)],
    );
    await service.execute(p);
    // Index + record written before the broadcast.
    expect(events, ['sent after 2 writes']);
    final saved = (await store.all()).single;
    expect(saved.codes.map((c) => c.code), p.codes);
    expect(saved.txId, 'cd' * 16);
  });
}

/// Passes everything to [inner] except the second write, which fails.
class _FailSecond extends FakeSecureStorage {
  _FailSecond(this.inner);

  final FakeSecureStorage inner;
  var _n = 0;

  @override
  Future<String?> read({
    required String key,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) => inner.read(key: key);

  @override
  Future<void> write({
    required String key,
    required String? value,
    dynamic iOptions,
    dynamic aOptions,
    dynamic lOptions,
    dynamic webOptions,
    dynamic mOptions,
    dynamic wOptions,
  }) async {
    if (++_n == 2) throw const FileSystemException('disk full');
    await inner.write(key: key, value: value);
  }
}
