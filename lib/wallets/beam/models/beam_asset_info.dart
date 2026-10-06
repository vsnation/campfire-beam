/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'beam_json.dart';

/// A Confidential Asset as `get_asset_info` / `assets_list` describe it.
///
/// Asset 0 (BEAM itself) never comes back from these calls.
@immutable
class BeamAssetInfo {
  const BeamAssetInfo({
    required this.assetId,
    required this.ownerId,
    required this.isOwned,
    required this.emission,
    required this.metadata,
    this.lockHeight,
    this.refreshHeight,
    this.coreSaysStd,
  });

  factory BeamAssetInfo.fromJson(Map<String, Object?> json) => BeamAssetInfo(
    assetId: BeamJson.integer(json, 'asset_id'),
    ownerId: BeamJson.string(json, 'ownerId'),
    isOwned: BeamJson.boolean(json, 'isOwned'),
    emission: BeamJson.amount(json, 'emission'),
    metadata: BeamAssetMetadata.parse(
      BeamJson.optString(json, 'metadata') ?? '',
    ),
    lockHeight: BeamJson.optHeight(json, 'lockHeight'),
    refreshHeight: BeamJson.optHeight(json, 'refreshHeight'),
    coreSaysStd: BeamJson.optBool(json, 'metadata_std'),
  );

  static const int beamAssetId = 0;
  static const int beamDecimals = 8;

  final int assetId;
  final String ownerId;

  /// This wallet holds the asset's owner key (it can mint and burn).
  final bool isOwned;

  /// Total supply in the smallest unit. Often above 2^53, sometimes above
  /// 2^64.
  final BigInt emission;
  final BeamAssetMetadata metadata;
  final int? lockHeight;
  final int? refreshHeight;

  /// The core's own `metadata_std` verdict (API 6.1+): the metadata follows
  /// the v6 standard with all required fields valid.
  final bool? coreSaysStd;

  /// See [decimalsFor].
  int get decimals => decimalsFor(assetId);

  /// Decimal places for amounts of [assetId]: always 8.
  ///
  /// Every Confidential Asset uses BEAM's groth scale (`Rules::Coin`,
  /// 10^8 smallest units per unit). The core has no ratio field at all —
  /// its standard metadata keys are N, SN, UN, NTHUN and OPT_*
  /// (`wallet/core/assets_utils.cpp`) — and the official desktop wallet reads
  /// only the smallest unit's *name* (`beam-ui ui/model/assets_manager.cpp`).
  /// A metadata `NTH_RATIO` is a label some issuers add; showing CROWN
  /// (`NTH_RATIO=1000`) with 3 decimals would make its balances 10^5 larger
  /// than in every other BEAM wallet.
  static int decimalsFor(int assetId) => beamDecimals;
}

/// Parsed asset metadata: `STD:SCH_VER=1;N=..;SN=..;UN=..;NTHUN=..;OPT_*=..`
/// (plus non-standard keys such as `NTH_RATIO`, kept as-is in [values]).
///
/// Mirrors `WalletAssetMeta::Parse` (`wallet/core/assets_utils.cpp`): only
/// text starting with `STD:` has fields; entries are split on `;` and each
/// on its first `=`, so values may contain `=` but never `;`.
@immutable
class BeamAssetMetadata {
  const BeamAssetMetadata._(this.raw, this.isStdPrefixed, this.values);

  factory BeamAssetMetadata.parse(String raw) {
    const mark = 'STD:';
    if (!raw.startsWith(mark)) {
      return BeamAssetMetadata._(raw, false, const {});
    }
    final values = <String, String>{};
    for (final entry in raw.substring(mark.length).split(';')) {
      final eq = entry.indexOf('=');
      if (eq < 0) continue;
      values[entry.substring(0, eq)] = entry.substring(eq + 1);
    }
    return BeamAssetMetadata._(raw, true, Map.unmodifiable(values));
  }

  final String raw;
  final bool isStdPrefixed;
  final Map<String, String> values;

  String? get name => values['N'];
  String? get shortName => values['SN'];
  String? get unitName => values['UN'];
  String? get nthUnitName => values['NTHUN'];
  int? get schemaVersion => int.tryParse(values['SCH_VER'] ?? '');
  String? get shortDescription => values['OPT_SHORT_DESC'];
  String? get longDescription => values['OPT_LONG_DESC'];
  String? get color => values['OPT_COLOR'];
  String? get siteUrl => values['OPT_SITE_URL'];
  String? get pdfUrl => values['OPT_PDF_URL'];
  String? get logoUrl => values['OPT_LOGO_URL'];
  String? get faviconUrl => values['OPT_FAVICON_URL'];

  /// The issuer's `NTH_RATIO` label, informational only: no BEAM wallet
  /// scales amounts by it (see [BeamAssetInfo.decimalsFor]).
  BigInt? get nthRatio => BigInt.tryParse(values['NTH_RATIO'] ?? '');
}
