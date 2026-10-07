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

  /// A restored wallet whose scan is still pending and that has found
  /// nothing yet: any balance shown for it would be a bare 0, which must not
  /// look like a loss. (Whether the scan still runs is the live wallet's to
  /// say; see beam_scan_state.dart.)
  bool get beamScanFoundNothing => beamNothingFoundYet(
    scanning: beamData?.restoreScanPending ?? false,
    beamTotal: cachedBalance.total.raw,
    totals: beamAssetTotals,
  );

  /// Restored from its phrase and holding something. A restore finds coins,
  /// not past payments (BEAM keeps no history on the chain), so such a
  /// wallet can have a balance and an empty list of transactions.
  bool get beamRestoredWithFunds {
    final d = beamData;
    if (d == null ||
        !(d.restoreScanPending || d.restoreScanStartedAt != null)) {
      return false;
    }
    return !beamNothingFoundYet(
      scanning: true,
      beamTotal: cachedBalance.total.raw,
      totals: beamAssetTotals,
    );
  }
}

/// The rule behind [BeamWalletInfoExtension.beamScanFoundNothing], for the
/// screens that read the live scan state instead of the cached flag: a
/// restore scan runs and neither BEAM ([beamTotal], arriving included) nor
/// any asset in [totals] has turned up yet.
bool beamNothingFoundYet({
  required bool scanning,
  required BigInt beamTotal,
  required Map<int, BeamCachedAssetTotals> totals,
}) =>
    scanning &&
    beamTotal == BigInt.zero &&
    totals.values.every((t) => t.total == BigInt.zero);

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
