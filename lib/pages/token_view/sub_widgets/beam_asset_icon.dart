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
import '../../../widgets/beam/assets/beam_asset_logo.dart';

/// An asset's icon on the asset screens, drawn by [BeamAssetLogo] like on
/// every other BEAM screen: a verified asset's bundled icon, otherwise the
/// BEAM desktop wallet's generic icon for its id (pool shares included).
/// The picture comes from the catalogue and the id only, never from a
/// cached row or anything the asset's creator wrote; the name, `#id` and
/// any copycat warning are written next to it.
class BeamAssetIcon extends StatelessWidget {
  const BeamAssetIcon({super.key, required this.asset, this.size = 32});

  final BeamAssetContract asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final look = BeamAssetCatalog.display(asset.assetId, null);
    return BeamAssetLogo(
      BeamAssetDisplay(
        assetId: asset.assetId,
        name: asset.name,
        symbol: asset.symbol,
        verified: look.verified,
        icon: look.icon,
        color: look.color,
        impersonates: asset.impersonates,
      ),
      size: size,
    );
  }
}
