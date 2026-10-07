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

import '../../../../utilities/flutter_secure_storage_interface.dart';
import 'voucher_code_store.dart';

/// The app's [VoucherCodeStore]: one wallet's airdrop codes in Campfire's
/// secure storage (the encrypted desktop store, or the platform keychain /
/// keystore on phones).
///
/// The codes are secrets (each one is a bearer claim on locked funds):
///
/// * they live only under this store's keys, which no Stack backup reads
///   (a backup carries a wallet's recovery phrase, not its other secure
///   values), so they leave the device only when the user exports them;
/// * nothing here logs a record or a code, and errors never carry one;
/// * a record that cannot be read is skipped, never deleted.
///
/// Layout, per wallet: one value per batch under
/// `BEAM_AIRDROP_CODES:<walletId>:<localId>`, plus an index of local ids
/// under `BEAM_AIRDROP_INDEX:<walletId>`. The index is written **before**
/// the record, so a crash in between leaves at worst an id with no record
/// (skipped), never codes that [all] cannot find; and since the service
/// broadcasts only after [put] completes, nothing was sent in that case.
/// The index also avoids listing every key of the secure storage, which on
/// phones would read every other secret of the app into memory.
class SecureVoucherCodeStore implements VoucherCodeStore {
  SecureVoucherCodeStore(this._storage, this.walletId) {
    if (!_id.hasMatch(walletId)) {
      throw ArgumentError.value(walletId, 'walletId', 'not a wallet id');
    }
  }

  final SecureStorageInterface _storage;
  final String walletId;

  static final _id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Operations per wallet run one at a time, across every instance in this
  /// isolate, so two index updates never overwrite each other.
  static final _tails = <String, Future<void>>{};

  String get _indexKey => 'BEAM_AIRDROP_INDEX:$walletId';
  String _recordKey(String localId) => 'BEAM_AIRDROP_CODES:$walletId:$localId';

  /// Records [all] skipped because they could not be read, last time.
  int get unreadableCount => _unreadable;
  int _unreadable = 0;

  @override
  Future<void> put(AirdropSavedBatch batch) => _serial(() async {
    _checkLocalId(batch.localId);
    final ids = await _readIndex();
    if (!ids.contains(batch.localId)) {
      await _writeIndex([...ids, batch.localId]);
    }
    await _storage.write(
      key: _recordKey(batch.localId),
      value: jsonEncode(batch.toJson()),
    );
  });

  @override
  Future<List<AirdropSavedBatch>> all() => _serial(() async {
    final out = <AirdropSavedBatch>[];
    var unreadable = 0;
    for (final id in await _readIndex()) {
      final raw = await _storage.read(key: _recordKey(id));
      if (raw == null) continue; // indexed, never written: nothing was sent
      try {
        final json = jsonDecode(raw);
        if (json is! Map) throw const FormatException('not an object');
        final b = AirdropSavedBatch.fromJson(json.cast<String, Object?>());
        if (b.localId != id) throw const FormatException('wrong record');
        out.add(b);
      } on FormatException {
        unreadable++;
      } on TypeError {
        unreadable++;
      }
    }
    _unreadable = unreadable;
    return out;
  });

  @override
  Future<void> delete(String localId) => _serial(() async {
    _checkLocalId(localId);
    await _storage.delete(key: _recordKey(localId));
    final ids = await _readIndex();
    if (ids.contains(localId)) {
      await _writeIndex([
        for (final i in ids)
          if (i != localId) i,
      ]);
    }
  });

  /// Deletes every batch of this wallet and the index: the wallet itself is
  /// being deleted. Unclaimed vouchers stay recoverable without their codes:
  /// the batch's creator takes them back with `cancelBatch`, signed by the
  /// wallet's keys. With an unreadable index the records cannot be found
  /// (the storage is never listed); the index goes all the same.
  Future<void> deleteAll() => _serial(() async {
    List<String> ids;
    try {
      ids = await _readIndex();
    } on FormatException {
      ids = const [];
    }
    for (final id in ids) {
      if (_id.hasMatch(id)) await _storage.delete(key: _recordKey(id));
    }
    await _storage.delete(key: _indexKey);
  });

  Future<List<String>> _readIndex() async {
    final raw = await _storage.read(key: _indexKey);
    if (raw == null) return const [];
    final json = jsonDecode(raw);
    final ids = json is Map ? json['ids'] : null;
    if (ids is! List || ids.any((i) => i is! String)) {
      // Never silently start a new, empty index over an unreadable one:
      // that would hide every saved batch.
      throw const FormatException('airdrop code index is unreadable');
    }
    return List<String>.unmodifiable(ids.cast<String>());
  }

  Future<void> _writeIndex(List<String> ids) =>
      _storage.write(key: _indexKey, value: jsonEncode({'v': 1, 'ids': ids}));

  static void _checkLocalId(String localId) {
    if (!_id.hasMatch(localId)) {
      throw ArgumentError.value(localId, 'localId', 'not a batch id');
    }
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final prev = _tails[walletId] ?? Future<void>.value();
    final result = prev.then((_) => task());
    _tails[walletId] = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
