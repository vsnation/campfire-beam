/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../assets/beam_asset_logo.dart';

/// An asset's round icon: [BeamAssetLogo], the same icon every BEAM screen
/// shows (BEAM's logo, a verified asset's own icon, or the BEAM desktop
/// wallet's generic icon for the asset's id; an LP token's pair).
class DexAssetIcon extends StatelessWidget {
  const DexAssetIcon({super.key, required this.asset, this.size = 24});

  final BeamAssetDisplay asset;
  final double size;

  @override
  Widget build(BuildContext context) => BeamAssetLogo(asset, size: size);
}

/// Two overlapping icons for a pool's pair ([BeamPairIcons]): both coins
/// [size] across, a gap of the card's colour where they overlap, and a box
/// of fixed size whatever the icons are, so rows never shift while the
/// pictures load.
class DexPairIcon extends StatelessWidget {
  const DexPairIcon({
    super.key,
    required this.first,
    required this.second,
    this.size = 28,
  });

  final BeamAssetDisplay first;
  final BeamAssetDisplay second;
  final double size;

  @override
  Widget build(BuildContext context) =>
      BeamPairIcons(first: first, second: second, size: size);
}

/// The asset's ticker, with "#id" for anything unverified and a warning
/// when it copies a verified asset's name.
class DexAssetName extends StatelessWidget {
  const DexAssetName({
    super.key,
    required this.asset,
    this.style,
    this.showWarning = true,
  });

  final BeamAssetDisplay asset;
  final TextStyle? style;
  final bool showWarning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final base = style ?? STextStyles.smallMed14(context);
    final symbol = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: asset.symbol),
          if (!asset.verified && asset.symbol != asset.idLabel)
            TextSpan(
              text: ' ${asset.idLabel}',
              style: base.copyWith(color: colors.textSubtitle1),
            ),
        ],
      ),
      style: base,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final copied = asset.impersonates;
    if (!showWarning || copied == null) return symbol;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        symbol,
        DexImpersonationWarning(asset: asset),
      ],
    );
  }
}

/// "Not the verified FOMO (#174)".
class DexImpersonationWarning extends StatelessWidget {
  const DexImpersonationWarning({super.key, required this.asset});

  final BeamAssetDisplay asset;

  @override
  Widget build(BuildContext context) {
    final copied = asset.impersonates;
    if (copied == null) return const SizedBox.shrink();
    final real = BeamAssetCatalog.verified[copied]!;
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.warning_amber_rounded,
          size: 14,
          color: colors.accentColorRed,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            'Not the verified ${real.symbol} (#${real.id})',
            style: STextStyles.label(context)
                .copyWith(color: colors.accentColorRed),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
