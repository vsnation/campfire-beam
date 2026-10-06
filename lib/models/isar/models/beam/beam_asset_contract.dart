/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:isar_community/isar.dart';

import '../contract.dart';

part 'beam_asset_contract.g.dart';

/// How Campfire shows one BEAM Confidential Asset, cached so the asset list
/// renders at unlock without asking the core (R11). The BEAM analogue of
/// [EthContract] / [SolContract]: global, not per wallet.
///
/// [address] is `beamAsset:<id>`, the same tag `BeamTxMapper` writes into
/// `TransactionV2.contractAddress` for the asset's transactions, so an asset
/// wallet finds its history with one indexed comparison.
///
/// Name and ticker are the catalogue's for verified assets and the cleaned
/// on-chain metadata otherwise (`BeamAssetCatalog.display`). Every BEAM
/// asset has 8 decimals.
@collection
class BeamAssetContract extends Contract {
  BeamAssetContract({
    required this.address,
    required this.assetId,
    required this.name,
    required this.symbol,
    required this.decimals,
    required this.verified,
    required this.metadataKnown,
    this.iconAsset,
    this.color,
    this.impersonates,
    this.poolAssetA,
    this.poolAssetB,
    this.poolKind,
  });

  Id id = Isar.autoIncrement;

  /// `beamAsset:<assetId>`.
  @override
  @Index(unique: true, replace: true)
  late final String address;

  late final int assetId;

  @override
  late final String name;

  @override
  late final String symbol;

  /// Always 8 (`BeamAssetInfo.decimalsFor`).
  @override
  late final int decimals;

  /// In `BeamAssetCatalog.verified`. Unverified assets are always shown with
  /// their `#id`, never with an icon or colour of their own.
  late final bool verified;

  /// The on-chain metadata has been read (or the asset is verified). False
  /// means [name] is the "Asset #id" placeholder and is worth re-reading.
  late final bool metadataKnown;

  /// Bundled asset path of a verified asset's icon.
  late final String? iconAsset;

  /// ARGB colour of a verified asset.
  late final int? color;

  /// The verified asset id this unverified asset copies the name or ticker
  /// of ("Not the verified FOMO (#174)").
  late final int? impersonates;

  /// For a DEX liquidity (LP) token: the pool's two assets and its kind, as
  /// the DEX contract reports them (`pools_view`, `lp-token`). Null for
  /// every other asset. Only the DEX's own pool list sets these; an asset's
  /// self-declared name never does.
  late final int? poolAssetA;
  late final int? poolAssetB;
  late final int? poolKind;

  /// The `address` of asset [assetId].
  static String addressFor(int assetId) => 'beamAsset:$assetId';

  /// The asset id in a `beamAsset:<id>` address, or null for any other
  /// address (an Ethereum or Solana token, for example).
  static int? assetIdOf(String address) {
    const prefix = 'beamAsset:';
    if (!address.startsWith(prefix)) return null;
    final id = int.tryParse(address.substring(prefix.length));
    return id == null || id < 0 ? null : id;
  }

  BeamAssetContract copyWith({
    String? name,
    String? symbol,
    bool? verified,
    bool? metadataKnown,
    String? iconAsset,
    int? color,
    int? impersonates,
    int? poolAssetA,
    int? poolAssetB,
    int? poolKind,
  }) => BeamAssetContract(
    address: address,
    assetId: assetId,
    name: name ?? this.name,
    symbol: symbol ?? this.symbol,
    decimals: decimals,
    verified: verified ?? this.verified,
    metadataKnown: metadataKnown ?? this.metadataKnown,
    iconAsset: iconAsset ?? this.iconAsset,
    color: color ?? this.color,
    impersonates: impersonates ?? this.impersonates,
    poolAssetA: poolAssetA ?? this.poolAssetA,
    poolAssetB: poolAssetB ?? this.poolAssetB,
    poolKind: poolKind ?? this.poolKind,
  )..id = id;
}

/// Read-only conveniences (kept out of the collection class so the Isar
/// generator only sees stored fields).
extension BeamAssetContractX on BeamAssetContract {
  /// A DEX liquidity token ("Pool share").
  bool get isPoolShare => poolAssetA != null && poolAssetB != null;

  /// "#174".
  String get idLabel => '#$assetId';

  /// True when two cached rows would show the same thing.
  bool sameAs(BeamAssetContract other) =>
      other.address == address &&
      other.assetId == assetId &&
      other.name == name &&
      other.symbol == symbol &&
      other.decimals == decimals &&
      other.verified == verified &&
      other.metadataKnown == metadataKnown &&
      other.iconAsset == iconAsset &&
      other.color == color &&
      other.impersonates == impersonates &&
      other.poolAssetA == poolAssetA &&
      other.poolAssetB == poolAssetB &&
      other.poolKind == poolKind;
}
