/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../../models/isar/models/transaction_note.dart';
import '../../../utilities/amount/amount.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_send_rules.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../../wallets/models/tx_data.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/supporting/beam_wallet_info_extension.dart';

/// A hold on the private node's wallet-api restart, taken while a payment
/// is on screen (`BeamWallet.holdNodeSwitch`).
abstract interface class BeamSendHold {
  void release();
}

/// Everything the BEAM send screens need from one wallet. The screens talk
/// to nothing else, so the same widgets run on a real wallet in the app and
/// on recorded core answers in tests.
///
/// Nothing here sends money except [confirmSend] and [executePay], and the
/// screens call those only from Campfire's PIN / password gate.
abstract interface class BeamSendBackend {
  /// The honest sync verdict. Only a verdict that [BeamSyncAssessment.
  /// canSpend] lets a payment through.
  BeamSyncAssessment get syncAssessment;

  Stream<BeamSyncAssessment> get syncAssessments;

  /// Spendable now, per asset id (asset 0 is BEAM), in units of 10^-8.
  Map<int, BigInt> spendable();

  /// How [assetId] is shown (verified name and icon, or `#id`).
  BeamAssetDisplay asset(int assetId);

  /// Reads on-chain names of unverified assets the wallet holds, so they
  /// can be shown by name (always with their id). Best effort.
  Future<void> loadAssetNames(Iterable<int> assetIds);

  /// Looks a name up on the wallet's own node (`view_name`).
  Future<BansResolution> resolveName(BansName name);

  /// The fee the core would charge for a regular payment of [amount] BEAM.
  Future<BigInt> estimateAddressFee(BigInt amount);

  /// Validates and prices a payment to an address. Never broadcasts.
  Future<TxData> prepareSend(TxData txData);

  /// Sends what [prepareSend] priced. Returns the transaction id.
  Future<String> confirmSend(TxData txData);

  /// Builds an anonymous payment to a name, decoded and checked; nothing
  /// is signed or sent.
  Future<BansPrepared> preparePay(
    BansName name,
    int assetId,
    BigInt amount, {
    required String expectedOwnerKey,
  });

  /// Signs and sends [prepared] after resolving the name once more. Returns
  /// the transaction id. Throws `BansOwnerChanged` when the name moved.
  Future<String> executePay(BansPrepared prepared);

  /// Keeps the private node from restarting wallet-api while a payment is
  /// on screen.
  BeamSendHold holdNodeSwitch(String reason, {Duration? maxHold});

  /// Saves Campfire's local note for [txId] (shown in history).
  Future<void> saveNote(String txId, String note);

  /// Asks the wallet to read balances and history again.
  void refresh();
}

/// Throws the plain sync message unless [backend] may spend now.
void beamCheckCanSpend(BeamSendBackend backend) {
  final a = backend.syncAssessment;
  if (a.canSpend) return;
  final m = BeamSyncMessages.describe(a);
  throw BeamWalletException(
    BeamWalletProblem.notSynced,
    m.detail == null ? m.title : '${m.title}. ${m.detail}',
  );
}

/// [BeamSendBackend] over a real [BeamWallet] and its shared services.
class BeamWalletSendBackend implements BeamSendBackend {
  BeamWalletSendBackend(this.wallet, {BeamBansService? bans})
    : _bans = bans ?? BeamWalletServices.of(wallet).bans;

  final BeamWallet wallet;
  final BeamBansService _bans;
  final Map<int, BeamAssetMetadata?> _metadata = {};

  @override
  BeamSyncAssessment get syncAssessment => wallet.syncAssessment;

  @override
  Stream<BeamSyncAssessment> get syncAssessments => wallet.syncAssessments;

  @override
  Map<int, BigInt> spendable() {
    final info = wallet.info;
    final out = <int, BigInt>{
      for (final e in info.beamAssetTotals.entries) e.key: e.value.available,
    };
    out[0] = info.cachedBalance.spendable.raw;
    return out;
  }

  @override
  BeamAssetDisplay asset(int assetId) =>
      BeamAssetCatalog.display(assetId, _metadata[assetId]);

  @override
  Future<void> loadAssetNames(Iterable<int> assetIds) async {
    final api = wallet.coreApi;
    if (api == null) return;
    for (final id in assetIds) {
      if (id <= 0 ||
          BeamAssetCatalog.verified.containsKey(id) ||
          _metadata.containsKey(id)) {
        continue;
      }
      try {
        _metadata[id] = (await api.getAssetInfo(id)).metadata;
      } catch (_) {
        // Shown as "#id" until the core answers.
      }
    }
  }

  @override
  Future<BansResolution> resolveName(BansName name) => _bans.resolve(name);

  @override
  Future<BigInt> estimateAddressFee(BigInt amount) async {
    final fee = await wallet.estimateFeeFor(
      Amount(rawValue: amount, fractionDigits: 8),
      BigInt.one,
    );
    return fee.raw < kBeamDefaultFee ? kBeamDefaultFee : fee.raw;
  }

  @override
  Future<TxData> prepareSend(TxData txData) =>
      wallet.prepareSend(txData: txData);

  @override
  Future<String> confirmSend(TxData txData) async {
    final sent = await wallet.confirmSend(txData: txData);
    return sent.txid!;
  }

  @override
  Future<BansPrepared> preparePay(
    BansName name,
    int assetId,
    BigInt amount, {
    required String expectedOwnerKey,
  }) => _bans.preparePay(
    name,
    assetId,
    amount,
    expectedOwnerKey: expectedOwnerKey,
  );

  @override
  Future<String> executePay(BansPrepared prepared) async {
    beamCheckCanSpend(this);
    final lease = wallet.holdNodeSwitch('name payment');
    try {
      return await _bans.execute(prepared);
    } finally {
      lease.release();
    }
  }

  @override
  BeamSendHold holdNodeSwitch(String reason, {Duration? maxHold}) =>
      _WalletHold(wallet.holdNodeSwitch(reason, maxHold: maxHold).release);

  @override
  Future<void> saveNote(String txId, String note) =>
      wallet.mainDB.putTransactionNote(
        TransactionNote(walletId: wallet.walletId, txid: txId, value: note),
      );

  @override
  void refresh() => unawaited(wallet.refresh());
}

class _WalletHold implements BeamSendHold {
  _WalletHold(this._release);

  final void Function() _release;

  @override
  void release() => _release();
}
