/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../contracts/dex/dex_constants.dart';
import '../models/beam_transaction.dart';

/// DEX transactions (swaps, liquidity) the open BEAM wallets have sent and
/// the chain has not settled yet.
///
/// DEX calls are BEAM "dependent" (HFT) transactions: each variant is valid
/// in exactly one block, and the core builds a new variant when one misses
/// its block. A core without patch 0006 forgets after a restart which
/// variant it already sent, and can build another on top of it: on
/// 2026-10-07 one swap ran twice that way after the app was quit while it
/// was "In progress". So nothing that stops wallet-api (quitting, a node
/// switch) should do it while this is not empty.
///
/// Other contract calls (claims, minting, names) are not dependent: a
/// restart re-sends the same transaction, so they are not tracked here.
class BeamSwapsInFlight {
  BeamSwapsInFlight();

  /// The one the app uses; tests make their own.
  static BeamSwapsInFlight instance = BeamSwapsInFlight();

  final Map<String, Set<String>> _byWallet = {};
  final _changes = StreamController<void>.broadcast(sync: true);

  /// Fires after every change of [count].
  Stream<void> get changes => _changes.stream;

  /// Unsettled DEX transactions over all open wallets.
  int get count => _byWallet.values.fold(0, (n, s) => n + s.length);

  bool get isEmpty => count == 0;

  /// The unsettled DEX transaction ids of one wallet.
  Set<String> of(String walletId) =>
      Set.unmodifiable(_byWallet[walletId] ?? const <String>{});

  /// Replaces [walletId]'s set with what [history] (a full `tx_list`) says.
  /// Returns the new set.
  Set<String> update(String walletId, Iterable<BeamTransaction> history) {
    final ids = {
      for (final t in history)
        if (isUnsettledDexTx(t)) t.txId,
    };
    final before = _byWallet[walletId] ?? const <String>{};
    if (ids.isEmpty) {
      _byWallet.remove(walletId);
    } else {
      _byWallet[walletId] = ids;
    }
    if (before.length != ids.length || !before.containsAll(ids)) {
      _changes.add(null);
    }
    return ids;
  }

  /// The wallet's core is closed: nothing of it can be interrupted any more.
  void forget(String walletId) {
    if (_byWallet.remove(walletId) != null) _changes.add(null);
  }

  /// A contract call to the DEX the core has not finished with.
  static bool isUnsettledDexTx(BeamTransaction t) {
    if (!t.isContract) return false;
    switch (t.status) {
      case BeamTxStatus.pending:
      case BeamTxStatus.inProgress:
      case BeamTxStatus.registering:
      case BeamTxStatus.confirming:
        break;
      case BeamTxStatus.canceled:
      case BeamTxStatus.completed:
      case BeamTxStatus.failed:
      case BeamTxStatus.unknown:
        return false;
    }
    return t.invokeData.any(
      (i) => i.contractId.toLowerCase() == kDexContractId.toLowerCase(),
    );
  }
}
