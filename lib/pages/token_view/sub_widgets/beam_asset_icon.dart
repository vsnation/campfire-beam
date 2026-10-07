/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/assets/beam_asset_registry.dart';
import '../../../widgets/beam/assets/beam_asset_logo.dart';

/// An asset's icon on the asset screens, drawn by [BeamAssetLogo] like on
/// every other BEAM screen: a verified asset's bundled icon, otherwise the
/// BEAM desktop wallet's generic icon for its id, and for a pool share the
/// pool's two icons. The picture comes from the catalogue, the id and the
/// pool the DEX named, never from anything the asset's creator wrote; the
/// name, `#id` and any copycat warning are written next to it.
class BeamAssetIcon extends StatelessWidget {
  const BeamAssetIcon({
    super.key,
    required this.asset,
    this.size = 32,
    this.surface,
  });

  final BeamAssetContract asset;
  final double size;

  /// What the icon sits on, for the gap in a pool share's pair (Campfire's
  /// card colour by default).
  final Color? surface;

  @override
  Widget build(BuildContext context) =>
      BeamAssetLogo(beamAssetLook(asset), size: size, surface: surface);
}

/// How [asset]'s cached row is drawn: the catalogue's look for its id, its
/// own name, and the pool it is a share of, if any.
BeamAssetDisplay beamAssetLook(BeamAssetContract asset) {
  final pool = BeamAssetRegistry.poolOf(asset);
  if (pool != null) {
    final look = BeamAssetCatalog.lpDisplay(pool);
    return BeamAssetDisplay(
      assetId: asset.assetId,
      name: asset.name,
      symbol: asset.symbol,
      verified: look.verified,
      icon: look.icon,
      color: look.color,
      pool: pool,
    );
  }
  final look = BeamAssetCatalog.display(asset.assetId, null);
  return BeamAssetDisplay(
    assetId: asset.assetId,
    name: asset.name,
    symbol: asset.symbol,
    verified: look.verified,
    icon: look.icon,
    color: look.color,
    impersonates: asset.impersonates,
  );
}
