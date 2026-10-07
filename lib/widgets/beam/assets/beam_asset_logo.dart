/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';

/// An asset's round icon, the same on every BEAM screen.
///
/// The icon comes from [BeamAssetCatalog.display]: BEAM's logo, a verified
/// asset's bundled icon, or the BEAM desktop wallet's generic icon for the
/// asset's id. A DEX liquidity token ([BeamAssetDisplay.pool]) shows its
/// pool's two icons in the same space ([BeamPairLogo]). Every screen draws
/// assets through this one widget so a token never looks different in the
/// send form, the DEX and the history.
///
/// Every icon is the same coin: exactly [size] across, clipped to a circle.
/// A logo that is not a filled circle itself (NPH's bare triangle) sits on
/// a neutral disc with a hairline edge ([BeamAssetCatalog.frameInset]). The
/// box is [size] square from the first frame: while a picture loads, the
/// neutral disc holds its place, so nothing moves or flashes when it
/// arrives, and a reused row never shows the previous asset's picture.
///
/// Decorative for screen readers: the symbol (and `#id` for an unverified
/// asset) is always written next to it.
class BeamAssetLogo extends StatelessWidget {
  const BeamAssetLogo(this.asset, {super.key, this.size = 32, this.surface});

  /// For an asset id the network does not know: the desktop wallet's
  /// "missing asset" icon.
  const BeamAssetLogo.missing({super.key, this.size = 32, this.surface})
    : asset = null;

  final BeamAssetDisplay? asset;
  final double size;

  /// The colour the logo sits on, for the gap between a pair's two icons;
  /// Campfire's card colour by default.
  final Color? surface;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final pool = a?.pool;
    if (pool != null) {
      return BeamPairLogo(
        first: BeamAssetCatalog.display(pool.aid1, null),
        second: BeamAssetCatalog.display(pool.aid2, null),
        size: size,
        surface: surface,
      );
    }
    final path = a == null
        ? BeamAssetCatalog.missingIcon
        : a.icon ?? BeamAssetCatalog.genericIcon(a.assetId);
    final fallback = a == null
        ? BeamAssetCatalog.missingIcon
        : BeamAssetCatalog.genericIcon(a.assetId);
    return BeamAssetCoin(path: path, fallback: fallback, size: size);
  }
}

/// One icon as a coin: [size] square, clipped to a circle, on a neutral disc
/// while it loads (and for good when it is not round itself).
class BeamAssetCoin extends StatelessWidget {
  const BeamAssetCoin({
    super.key,
    required this.path,
    required this.fallback,
    required this.size,
  });

  /// Bundled asset path of the picture.
  final String path;

  /// Bundled SVG shown when a raster [path] cannot be read.
  final String fallback;
  final double size;

  /// The neutral disc's fill and edge when there is no Campfire theme.
  static const _discFallback = Color(0xFFEEEFF1);
  static const _edgeFallback = Color(0xFFE0E3E3);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>();
    final discColor = colors?.textSubtitle5 ?? _discFallback;
    final edgeColor = colors?.textSubtitle4 ?? _edgeFallback;
    final inset = BeamAssetCatalog.frameInset(path);
    final framed = inset != null;
    final inner = framed ? size * (1 - 2 * inset) : size;

    final disc = SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: discColor),
      ),
    );
    // While loading: the disc for a round logo (which then covers it), the
    // framed logo's own disc behind for the others.
    Widget loading(BuildContext _) =>
        framed ? SizedBox.square(dimension: inner) : disc;

    Widget svg(String p) => SvgPicture.asset(
      p,
      width: inner,
      height: inner,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      placeholderBuilder: loading,
    );

    final Widget picture = path.endsWith('.svg')
        ? svg(path)
        : Image.asset(
            path,
            width: inner,
            height: inner,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            excludeFromSemantics: true,
            frameBuilder: (context, child, frame, sync) =>
                sync || frame != null ? child : loading(context),
            // A bundled raster that fails to load falls back to the
            // generic icon rather than an empty hole.
            errorBuilder: (_, _, _) => svg(fallback),
          );

    final Widget coin = framed
        ? DecoratedBox(
            decoration: BoxDecoration(shape: BoxShape.circle, color: discColor),
            position: DecorationPosition.background,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: edgeColor,
                  width: size >= 24 ? 1 : 0.75,
                ),
              ),
              position: DecorationPosition.foreground,
              child: ClipOval(child: Center(child: picture)),
            ),
          )
        : ClipOval(child: picture);

    return SizedBox.square(
      dimension: size,
      // Keyed by the picture: a row reused for another asset starts from
      // the disc, never from the last asset's picture.
      child: KeyedSubtree(key: ValueKey(path), child: coin),
    );
  }
}

/// A DEX pool's two icons in one [size] square, as an LP token's logo: the
/// first asset top left, the second bottom right with a gap of [surface]
/// colour where they overlap. Both coins are the same size.
class BeamPairLogo extends StatelessWidget {
  const BeamPairLogo({
    super.key,
    required this.first,
    required this.second,
    required this.size,
    this.surface,
  });

  final BeamAssetDisplay first;
  final BeamAssetDisplay second;
  final double size;
  final Color? surface;

  /// Each coin's share of [size].
  static const double coinShare = 0.66;

  @override
  Widget build(BuildContext context) {
    final coin = size * coinShare;
    final ring = math.max(1.0, size * 0.05);
    final gap =
        surface ??
        Theme.of(context).extension<StackColors>()?.popupBG ??
        Colors.white;
    return SizedBox.square(
      dimension: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: BeamAssetLogo(first, size: coin, surface: gap),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: _Ringed(
              ring: ring,
              color: gap,
              child: BeamAssetLogo(second, size: coin, surface: gap),
            ),
          ),
        ],
      ),
    );
  }
}

/// [child] on a disc of [color], [ring] wider all round: the gap between
/// two overlapping coins.
class _Ringed extends StatelessWidget {
  const _Ringed({required this.ring, required this.color, required this.child});

  final double ring;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    child: Padding(padding: EdgeInsets.all(ring), child: child),
  );
}

/// Two full-size coins side by side, the second overlapping the first with
/// a gap of [surface] colour: a pool's pair in a list or a header. The box
/// is fixed, [size] × 1.6 wide and [size] high, whatever the icons are; the
/// gap's thin ring around the second coin may paint just past it, in the
/// colour of what is behind.
class BeamPairIcons extends StatelessWidget {
  const BeamPairIcons({
    super.key,
    required this.first,
    required this.second,
    this.size = 28,
    this.surface,
  });

  final BeamAssetDisplay first;
  final BeamAssetDisplay second;
  final double size;
  final Color? surface;

  /// The ring around the second coin.
  static double ringFor(double size) => math.max(1.5, size * 0.06);

  @override
  Widget build(BuildContext context) {
    final ring = ringFor(size);
    final gap =
        surface ??
        Theme.of(context).extension<StackColors>()?.popupBG ??
        Colors.white;
    return SizedBox(
      width: size * 1.6,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: BeamAssetLogo(first, size: size, surface: gap),
          ),
          Positioned(
            left: size * 0.6 - ring,
            top: -ring,
            child: _Ringed(
              ring: ring,
              color: gap,
              child: BeamAssetLogo(second, size: size, surface: gap),
            ),
          ),
        ],
      ),
    );
  }
}
