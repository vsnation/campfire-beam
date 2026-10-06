/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:stackwallet/wallets/beam/contracts/airdrop/voucher_code_store.dart';

/// A [VoucherCodeStore] for tests. Round-trips every record through JSON,
/// as a real store would, and logs what happened in [log] so tests can
/// check the order of "saved" and "sent".
class MemoryCodeStore implements VoucherCodeStore {
  MemoryCodeStore([this.log]);

  final List<String>? log;
  final _rows = <String, String>{};

  /// When set, the next [put] throws it.
  Object? failNextPut;

  /// When true, [put] pretends to succeed but stores nothing.
  bool dropWrites = false;

  int deletes = 0;

  @override
  Future<void> put(AirdropSavedBatch batch) async {
    final f = failNextPut;
    if (f != null) {
      failNextPut = null;
      log?.add('put failed');
      throw f;
    }
    log?.add('put ${batch.txStatus.name}');
    if (dropWrites) return;
    _rows[batch.localId] = jsonEncode(batch.toJson());
  }

  @override
  Future<List<AirdropSavedBatch>> all() async => [
    for (final r in _rows.values)
      AirdropSavedBatch.fromJson(
        (jsonDecode(r) as Map).cast<String, Object?>(),
      ),
  ];

  @override
  Future<void> delete(String localId) async {
    deletes++;
    log?.add('delete');
    _rows.remove(localId);
  }
}
