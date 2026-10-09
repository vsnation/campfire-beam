/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the Buy BEAM screens need from the app, in one object, so they can
// be tested with fakes: the buy controller, the BEAM wallet the BEAM
// arrives in (its name, and a way to make it a new address), the user's
// own address on the coin's chain when Campfire has one, and where to send
// the user next (WBEAM on Ethereum, the delivered transaction,
// buybeam.my's support).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../utilities/util.dart';
import '../../../wallets/beam/buy/buybeam_client.dart';
import '../../../wallets/beam/buy/buybeam_controller.dart';
import '../../../widgets/beam/dex/dex_widgets.dart';

class BuyBeamDeps implements DexLayout {
  BuyBeamDeps({
    required this.controller,
    required this.walletId,
    required this.walletName,
    required this.newBeamAddress,
    this.refundAddressFor,
    this.receivedInWallet,
    this.onWantWbeam,
    this.onOpenTransaction,
    this.onOpenSupport,
    this.torOn,
    this.isDesktop,
  });

  final BuyBeamController controller;

  /// The BEAM wallet the BEAM arrives in.
  final String walletId;
  final String walletName;

  /// A new address of that wallet, one per buy (throws when the wallet
  /// cannot make one yet).
  final Future<String> Function() newBeamAddress;

  /// The user's own address on [BuyBeamAsset.blockchain], when Campfire
  /// has a wallet there (the Ethereum wallet for coins on Ethereum).
  final Future<String?> Function(BuyBeamAsset asset)? refundAddressFor;

  /// Opens WBEAM on Ethereum instead (the Ethereum wallet's swap); null
  /// hides the link. [ref] belongs to the screen asking, which stays open
  /// under what this opens.
  final void Function(BuildContext context, WidgetRef ref)? onWantWbeam;

  /// Whether this wallet has the BEAM transaction [txId], received and
  /// confirmed (buybeam.my having sent it is not the same: a regular
  /// address receives only while Campfire is open and accepts it).
  final Future<bool> Function(String txId)? receivedInWallet;

  /// Shows the BEAM transaction [txId] in this wallet (or the wallet's
  /// history while Campfire has not seen it yet).
  final Future<void> Function(BuildContext context, String? txId)?
  onOpenTransaction;

  /// Opens buybeam.my, where its support is.
  final VoidCallback? onOpenSupport;

  /// Whether Tor is on (the "no answer" message says what helps).
  final bool Function()? torOn;

  final bool? isDesktop;

  @override
  bool get desktop => isDesktop ?? Util.isDesktop;

  bool get tor => torOn?.call() ?? false;
}

/// Thrown by [BuyBeamDeps.newBeamAddress] while the BEAM wallet is not
/// running yet.
class BuyBeamWalletNotReady implements Exception {
  const BuyBeamWalletNotReady();
}
