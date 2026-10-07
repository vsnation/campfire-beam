/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// When the screens say a restored wallet is still being scanned.
//
// `restoreScanPending` (BeamWallet.isScanningForCoins) keeps the wallet
// asking public nodes for block bodies until a node holding its owner key
// has scanned the chain. Where the private node cannot run (a phone, low
// disk, turned off) that never happens, yet the scan the user waits for is
// over once the wallet is up to date: the screens follow that scan, never
// the flag alone, so a finished scan does not say "Scanning…" for ever.

import '../../../wallets/beam/wallet/beam_sync_tracker.dart';
import '../../../wallets/isar/models/wallet_info.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/supporting/beam_wallet_info_extension.dart';
import '../../../wallets/wallet/wallet.dart';

/// A restore scan is running: the wallet still looks for its coins
/// ([pending]) and is either not up to date yet or reports body requests
/// still outstanding. Up to date with nothing outstanding (or no progress
/// reported at all) means the scan is over.
bool beamScanRunning({
  required bool pending,
  required BeamScanProgress? scan,
  required bool canSpend,
}) {
  if (!pending) return false;
  if (!canSpend) return true;
  final f = scan?.fraction;
  return f != null && f < 1;
}

/// The scan of [wallet], from its live state.
bool beamWalletScanRunning(BeamWallet wallet) => beamScanRunning(
  pending: wallet.isScanningForCoins,
  scan: wallet.scanProgress,
  canSpend: wallet.canSpend,
);

/// Whether a wallet list says "Scanning…" for [info] instead of its cached
/// 0: a restored wallet that has found nothing yet and whose scan is not
/// known to be over. An open wallet answers from its live state; a closed
/// one goes on scanning when it is opened, so it still says so.
bool beamListShowsScanning(WalletInfo info, Wallet? wallet) {
  if (!info.beamScanFoundNothing) return false;
  if (wallet is! BeamWallet || !wallet.isOpen) return true;
  return beamWalletScanRunning(wallet);
}
