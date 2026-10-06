/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/coin_icon_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';

/// The theme's BEAM coin icon file, or null when the theme has none.
/// Overridable in tests.
final pBeamDexBeamIconPath = Provider<String?>((ref) {
  try {
    return ref.watch(coinIconProvider(Beam(CryptoCurrencyNetwork.main)));
  } catch (_) {
    return null;
  }
});

/// An asset's round icon: the theme's BEAM logo, a bundled icon for
/// verified assets, and initials on a neutral disc for everything else.
/// Unverified assets never get an icon or a colour of their own, because
/// anyone can mint an asset that looks like another.
class DexAssetIcon extends ConsumerWidget {
  const DexAssetIcon({super.key, required this.asset, this.size = 24});

  final BeamAssetDisplay asset;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fallback = _Initials(asset: asset, size: size);
    if (asset.assetId == 0) {
      final path = ref.watch(pBeamDexBeamIconPath);
      if (path == null) return fallback;
      return SvgPicture.file(
        File(path),
        width: size,
        height: size,
        placeholderBuilder: (_) => fallback,
      );
    }
    final icon = asset.icon;
    if (!asset.verified || icon == null) return fallback;
    final Widget image = icon.endsWith('.svg')
        ? SvgPicture.asset(
            icon,
            width: size,
            height: size,
            placeholderBuilder: (_) => fallback,
          )
        : Image.asset(
            icon,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
    return ClipOval(
      child: Container(
        width: size,
        height: size,
        color: colors.textFieldDefaultBG,
        child: image,
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.asset, required this.size});

  final BeamAssetDisplay asset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final verifiedColor = asset.verified && asset.color != null
        ? Color(asset.color!)
        : null;
    final letters = asset.symbol.replaceAll('#', '');
    final text = letters.isEmpty
        ? '?'
        : letters.substring(0, letters.length < 2 ? letters.length : 2);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: verifiedColor ?? colors.textFieldDefaultBG,
        border: verifiedColor == null
            ? Border.all(color: colors.textSubtitle3)
            : null,
      ),
      child: Text(
        text,
        maxLines: 1,
        style: STextStyles.label700(context).copyWith(
          fontSize: size * 0.36,
          color: verifiedColor == null ? colors.textDark3 : colors.textWhite,
        ),
      ),
    );
  }
}

/// Two overlapping icons for a pool's pair.
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
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.6,
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            child: DexAssetIcon(asset: first, size: size),
          ),
          Positioned(
            left: size * 0.6,
            child: DexAssetIcon(asset: second, size: size),
          ),
        ],
      ),
    );
  }
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
