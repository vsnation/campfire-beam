/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:isar_community/isar.dart';

import '../../isar/models/wallet_info.dart';

/// The assets a user chose to hide from a wallet's asset list (spam
/// airdrops, dust). Kept per wallet in `WalletInfo.otherData` like the
/// other BEAM wallet data; nothing secret, so it travels with backups.
abstract final class BeamHiddenAssets {
  /// `WalletInfo.otherData` key: a JSON list of asset ids.
  static const String otherDataKey = 'beamHiddenAssetIdsKey';

  static Set<int> read(WalletInfo info) => parse(info.otherData[otherDataKey]);

  /// Ids in [json]; anything that is not a positive int is ignored.
  static Set<int> parse(Object? json) {
    if (json is! List) return {};
    return {
      for (final e in json)
        if (e is int && e > 0) e,
    };
  }

  /// Hides or shows [assetId] in [info]'s asset list.
  static Future<void> setHidden({
    required WalletInfo info,
    required Isar isar,
    required int assetId,
    required bool hidden,
  }) async {
    if (assetId <= 0) return; // BEAM itself is the wallet, never hidden.
    final latest = await isar.walletInfo.get(info.id) ?? info;
    final ids = read(latest);
    final changed = hidden ? ids.add(assetId) : ids.remove(assetId);
    if (!changed) return;
    await latest.updateOtherData(
      newEntries: {otherDataKey: (ids.toList()..sort())},
      isar: isar,
    );
  }
}
