/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../wallet/impl/beam_wallet.dart';
import '../../wallet/wallet.dart';

/// The names of the wallets a Campfire backup (.swb) cannot hold: BEAM
/// wallets imported from their wallet.db have no recovery phrase, and
/// `SWB.createStackWalletJSON` leaves them out.
List<String> beamWalletsNotInBackup(Iterable<Wallet> wallets) => [
  for (final w in wallets)
    if (w is BeamWallet && w.isImportedFromFile) w.info.name,
];

/// What the backup screens tell the user about [names] once a backup is
/// saved; null when every wallet is in it.
String? beamBackupOmissionNotice(List<String> names) {
  if (names.isEmpty) return null;
  final list = names.map((n) => '"$n"').join(', ');
  return names.length == 1
      ? 'Not in this backup: $list. This BEAM wallet was imported from a '
            "wallet.db file and has no recovery phrase, so a backup can't "
            'restore it. Keep its wallet.db file and password safe.'
      : 'Not in this backup: $list. These BEAM wallets were imported from '
            "wallet.db files and have no recovery phrase, so a backup can't "
            'restore them. Keep each wallet.db file and its password safe.';
}
