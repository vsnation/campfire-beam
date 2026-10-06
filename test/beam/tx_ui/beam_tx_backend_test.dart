/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The app backend's cache side, on a real Isar: the details screen follows
// a record as the wallet re-stores it, and a deleted transaction leaves
// Campfire's cache (the wallet's sync only adds and updates records).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_backend.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_view.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'tx_ui_harness.dart';

void main() {
  late Directory dir;
  late Isar isar;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('cfb_txui_isar');
    isar = await openTestMainDb(dir);
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await dir.delete(recursive: true);
  });

  test('watch follows a record; forget removes only that one', () async {
    final pending = simpleTxJson(seed: 90, status: BeamTxStatus.inProgress);
    final other = simpleTxJson(seed: 91, status: BeamTxStatus.completed);
    await isar.writeTxn(
      () => isar.transactionV2s.putAll([mapped(pending), mapped(other)]),
    );

    final seen = <BeamTxStatus?>[];
    final sub = beamWatchTransaction(
      isar,
      walletId: kWalletId,
      txid: pending['txId']! as String,
    ).listen((tx) => seen.add(tx == null ? null : BeamTxView.of(tx)!.status));
    await pumpEventQueue();
    expect(seen, [BeamTxStatus.inProgress]);

    // The wallet's refresh stores the cancelled record (same txid).
    final cancelled = mapped({
      ...pending,
      'status': BeamTxStatus.canceled.code,
    });
    await isar.writeTxn(() async {
      await isar.transactionV2s
          .where()
          .txidWalletIdEqualTo(cancelled.txid, kWalletId)
          .deleteAll();
      await isar.transactionV2s.put(cancelled);
    });
    await pumpEventQueue();
    expect(seen.last, BeamTxStatus.canceled);

    final gone = await beamForgetTransaction(
      isar,
      walletId: kWalletId,
      txid: cancelled.txid,
    );
    await pumpEventQueue();
    expect(gone, 1);
    expect(seen.last, isNull);
    final left = await isar.transactionV2s
        .where()
        .walletIdEqualTo(kWalletId)
        .findAll();
    expect(left.map((t) => t.txid), [other['txId']]);
    await sub.cancel();
  });
}
