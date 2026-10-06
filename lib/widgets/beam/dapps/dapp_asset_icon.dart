/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../assets/beam_asset_logo.dart';

/// An asset's icon in the approval sheet: the same [BeamAssetLogo] every
/// BEAM screen draws (BEAM's logo, a verified asset's bundled icon, or the
/// desktop wallet's generic icon for the asset's id).
///
/// The icon never vouches for an asset on its own: the sheet always writes
/// the symbol next to it, and for an unverified asset its `#id`, an
/// "Unverified asset" tag and, for a look-alike, a warning.
class DappAssetIcon extends StatelessWidget {
  const DappAssetIcon({super.key, required this.asset, this.size = 32});

  final BeamAssetDisplay asset;
  final double size;

  @override
  Widget build(BuildContext context) => BeamAssetLogo(asset, size: size);
}
