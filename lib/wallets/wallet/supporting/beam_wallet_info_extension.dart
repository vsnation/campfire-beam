/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:isar_community/isar.dart';

import '../../../utilities/logger.dart';
import '../../beam/wallet/beam_balance_mapper.dart';
import '../../isar/models/wallet_info.dart';

/// BEAM data kept in `WalletInfo.otherData` (no schema change, mirrors
/// `epiccash_wallet_info_extension.dart`). Nothing secret goes here: it is
/// part of Stack backups.
extension BeamWalletInfoExtension on WalletInfo {
  ExtraBeamWalletInfo? get beamData {
    final data = otherData[WalletInfoKeys.beamData];
    if (data is! String) return null;
    try {
      return ExtraBeamWalletInfo.fromMap(
        Map<String, dynamic>.from(jsonDecode(data) as Map),
      );
    } catch (e, s) {
      Logging.instance.e(
        "ExtraBeamWalletInfo.fromMap failed: ",
        error: e,
        stackTrace: s,
      );
      return null;
    }
  }

  Future<void> updateExtraBeamWalletInfo({
    required ExtraBeamWalletInfo beamData,
    required Isar isar,
  }) async {
    await updateOtherData(
      newEntries: {WalletInfoKeys.beamData: jsonEncode(beamData.toMap())},
      isar: isar,
    );
  }

  /// Per-asset totals from the last `wallet_status` (asset 0 is BEAM).
  Map<int, BeamCachedAssetTotals> get beamAssetTotals =>
      BeamBalanceMapper.parseAssetTotals(
        otherData[WalletInfoKeys.beamAssetTotals],
      );
}

/// BEAM wallet state that must survive restarts.
class ExtraBeamWalletInfo {
  const ExtraBeamWalletInfo({
    this.restoreScanPending = false,
    this.restoreScanStartedAt,
  });

  ExtraBeamWalletInfo.fromMap(Map<String, dynamic> json)
    : restoreScanPending = json['restoreScanPending'] as bool? ?? false,
      restoreScanStartedAt = json['restoreScanStartedAt'] as int?;

  /// The wallet was restored from its phrase and has not yet been scanned
  /// by a node holding its owner key. While true the wallet asks public
  /// nodes for block bodies (`request_bodies`) to find its coins, and the
  /// UI says "Scanning for your coins…" instead of a bare 0.
  final bool restoreScanPending;

  /// Unix seconds when that scan began.
  final int? restoreScanStartedAt;

  Map<String, dynamic> toMap() => {
    'restoreScanPending': restoreScanPending,
    if (restoreScanStartedAt != null)
      'restoreScanStartedAt': restoreScanStartedAt,
  };

  ExtraBeamWalletInfo copyWith({
    bool? restoreScanPending,
    int? restoreScanStartedAt,
  }) => ExtraBeamWalletInfo(
    restoreScanPending: restoreScanPending ?? this.restoreScanPending,
    restoreScanStartedAt: restoreScanStartedAt ?? this.restoreScanStartedAt,
  );

  @override
  String toString() => toMap().toString();
}
