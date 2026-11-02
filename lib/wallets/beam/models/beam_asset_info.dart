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

  /// The places its metadata gives ([BeamAssetMetadata.decimals]); a
  /// verified asset's are pinned instead (`BeamAssetCatalog.decimalsOf`).
  int get decimals => assetId == beamAssetId ? beamDecimals : metadata.decimals;
}

/// Parsed asset metadata: `STD:SCH_VER=1;N=..;SN=..;UN=..;NTHUN=..;
/// NTH_RATIO=..;OPT_*=..`.
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

  /// How many smallest units make one whole unit, as the issuer wrote it.
  BigInt? get nthRatio => BigInt.tryParse(values['NTH_RATIO'] ?? '');

  /// `NTH_RATIO=1` up to `10^38` (a supply is at most 2^128-1).
  static final _powerOfTen = RegExp(r'^10{0,38}$');

  /// Decimal places for amounts of this asset, as BEAM's Asset Descriptor
  /// v1.0 defines them: `NTH_RATIO` is "the ratio of the smallest asset unit
  /// to regular unit", 100000000 (8 places) when omitted. CANDY (#31) sets
  /// 10: 1 place. Only a power of ten can be written as decimal places, so
  /// anything else (0, 21000000, text) counts as 8, as BEAM's own wallets
  /// show every asset; so do two different `NTH_RATIO`s in one metadata,
  /// which wallets keeping the first or the last would read apart. The web
  /// wallet reads them the same way (`pwa/src/lib/meta.js`).
  int get decimals {
    if (!isStdPrefixed) return BeamAssetInfo.beamDecimals;
    const key = 'NTH_RATIO=';
    final ratios = {
      for (final entry in raw.substring(4).split(';'))
        if (entry.startsWith(key)) entry.substring(key.length),
    };
    if (ratios.length != 1) return BeamAssetInfo.beamDecimals;
    final ratio = ratios.single;
    return _powerOfTen.hasMatch(ratio)
        ? ratio.length - 1
        : BeamAssetInfo.beamDecimals;
  }
}
