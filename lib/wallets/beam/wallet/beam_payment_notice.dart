/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../services/wallets.dart';
import '../../../utilities/amount/amount.dart';
import '../../../widgets/crypto_notifications.dart';
import '../../crypto_currency/crypto_currency.dart';
import '../../wallet/impl/beam_wallet.dart';
import '../../wallet/wallet.dart';
import '../assets/beam_asset_registry.dart';

/// An incoming payment that completed while its wallet was open.
class BeamPaymentReceived {
  const BeamPaymentReceived({
    required this.walletId,
    required this.walletName,
    required this.txId,
    required this.value,
    required this.assetId,
    required this.at,
  });

  final String walletId;
  final String walletName;
  final String txId;

  /// Groth (every BEAM asset has 8 decimals).
  final BigInt value;

  /// 0 for BEAM.
  final int assetId;
  final DateTime at;

  /// "Received 0.5 BEAM", "Received 12 FOMO", "Received 3 of token #779".
  /// Only a verified asset is named by its ticker: anyone can mint a token
  /// called "BEAM".
  String get title {
    final amount = Amount(rawValue: value, fractionDigits: 8).decimal;
    if (assetId == 0) return 'Received $amount BEAM';
    final contract = BeamAssetRegistry.build(assetId);
    return contract.verified
        ? 'Received $amount ${contract.symbol}'
        : 'Received $amount of token #$assetId';
  }
}

/// Posts [payment] to Campfire's notifications (the list in the menu and the
/// system banner).
void announceBeamPayment(BeamPaymentReceived payment) {
  CryptoNotificationsEventBus.instance.fire(
    CryptoNotificationEvent(
      title: payment.title,
      walletId: payment.walletId,
      walletName: payment.walletName,
      date: payment.at,
      shouldWatchForUpdates: false,
      coin: Beam(CryptoCurrencyNetwork.main),
      txid: payment.txId,
    ),
  );
}

/// Completes when no BEAM wallet has a money flow open: a send being
/// confirmed, a swap, a claim or a dApp approval (whatever holds the
/// wallet's node switch, [BeamWallet.isBusy]). The system's notification
/// permission question waits for this, so it never lands on top of one
/// (`NotificationApi.permissionDialogMayShow`). [wallets]: Campfire's open
/// wallets by default.
Future<void> beamNoMoneyFlowOpen({Iterable<Wallet>? wallets}) async {
  while (true) {
    final busy = [
      for (final w in wallets ?? Wallets.sharedInstance.wallets)
        if (w is BeamWallet && w.isBusy) w,
    ];
    if (busy.isEmpty) return;
    await Future.wait(busy.map((w) => w.whenNotBusy()));
  }
}
