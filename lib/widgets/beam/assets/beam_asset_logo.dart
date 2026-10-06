/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../wallets/beam/assets/beam_asset_catalog.dart';

/// An asset's round icon, the same on every BEAM screen.
///
/// The icon comes from [BeamAssetCatalog.display]: BEAM's logo, a verified
/// asset's bundled icon, or the BEAM desktop wallet's generic icon for the
/// asset's id. Every screen draws assets through this one widget so a token
/// never looks different in the send form, the DEX and the history.
///
/// Decorative for screen readers: the symbol (and `#id` for an unverified
/// asset) is always written next to it.
class BeamAssetLogo extends StatelessWidget {
  const BeamAssetLogo(this.asset, {super.key, this.size = 32});

  /// For an asset id the network does not know: the desktop wallet's
  /// "missing asset" icon.
  const BeamAssetLogo.missing({super.key, this.size = 32}) : asset = null;

  final BeamAssetDisplay? asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final path = a == null
        ? BeamAssetCatalog.missingIcon
        : a.icon ?? BeamAssetCatalog.genericIcon(a.assetId);
    final generic = a == null
        ? BeamAssetCatalog.missingIcon
        : BeamAssetCatalog.genericIcon(a.assetId);
    Widget svg(String p) => SvgPicture.asset(
      p,
      width: size,
      height: size,
      excludeFromSemantics: true,
    );
    final Widget image = path.endsWith('.svg')
        ? svg(path)
        : ClipOval(
            child: Image.asset(
              path,
              width: size,
              height: size,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
              // A bundled raster that fails to load falls back to the
              // generic icon rather than an empty hole.
              errorBuilder: (_, _, _) => svg(generic),
            ),
          );
    return SizedBox.square(dimension: size, child: image);
  }
}
