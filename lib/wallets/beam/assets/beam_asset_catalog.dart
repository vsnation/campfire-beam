/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../models/beam_asset_info.dart';

/// A Confidential Asset Campfire vouches for: its name, ticker, colour and a
/// bundled icon are shown as genuine.
class BeamKnownAsset {
  const BeamKnownAsset({
    required this.id,
    required this.name,
    required this.symbol,
    required this.color,
    this.icon,
  });

  final int id;
  final String name;
  final String symbol;

  /// ARGB.
  final int color;

  /// Bundled asset path. Icons ship with the app: loading them from the
  /// issuer's URL would tell that server the user's IP and what they hold.
  final String? icon;
}

/// How one asset is presented.
class BeamAssetDisplay {
  const BeamAssetDisplay({
    required this.assetId,
    required this.name,
    required this.symbol,
    required this.verified,
    this.icon,
    this.color,
    this.impersonates,
  });

  final int assetId;
  final String name;
  final String symbol;

  /// In [BeamAssetCatalog.verified]. Anything else is shown with its asset
  /// id, because anyone can mint an asset and call it anything.
  final bool verified;
  final String? icon;
  final int? color;

  /// The verified asset whose ticker or name this unverified asset copies,
  /// e.g. someone's own "FOMO". The UI says "Not the verified FOMO (#174)".
  final int? impersonates;

  /// Always shown next to unverified assets.
  String get idLabel => '#$assetId';
}

abstract final class BeamAssetCatalog {
  static const _icons = 'assets/beam/icons';

  /// Assets LightWallet showed as known, with names checked against their
  /// on-chain metadata (explorer `/assets`, 2026-10-06). CHAD and GIGA each
  /// exist twice: 186/187 are the first MemeClash pair, 190/191 the current
  /// (v9) one.
  static const Map<int, BeamKnownAsset> verified = {
    0: BeamKnownAsset(
      id: 0,
      name: 'BEAM',
      symbol: 'BEAM',
      color: 0xFF25C2A0,
    ),
    4: BeamKnownAsset(
      id: 4,
      name: 'Gothic Crown',
      symbol: 'CROWN',
      color: 0xFFFFD700,
      icon: '$_icons/4.png',
    ),
    6: BeamKnownAsset(
      id: 6,
      name: 'Rangers Fan Token',
      symbol: 'RFC',
      color: 0xFF0066CC,
    ),
    7: BeamKnownAsset(
      id: 7,
      name: 'BeamX',
      symbol: 'BEAMX',
      color: 0xFFDA70D6,
      icon: '$_icons/7.png',
    ),
    9: BeamKnownAsset(
      id: 9,
      name: 'Tico',
      symbol: 'TICO',
      color: 0xFFE91E63,
      icon: '$_icons/9.png',
    ),
    47: BeamKnownAsset(
      id: 47,
      name: 'Nephrite',
      symbol: 'NPH',
      color: 0xFF3498DB,
      icon: '$_icons/47.svg',
    ),
    174: BeamKnownAsset(
      id: 174,
      name: 'FOMO',
      symbol: 'FOMO',
      color: 0xFF60A5FA,
      icon: '$_icons/174.png',
    ),
    186: BeamKnownAsset(
      id: 186,
      name: 'Giga',
      symbol: 'GIGA',
      color: 0xFFA855F7,
      icon: '$_icons/186.png',
    ),
    187: BeamKnownAsset(
      id: 187,
      name: 'Chad',
      symbol: 'CHAD',
      color: 0xFF25C2A0,
      icon: '$_icons/187.png',
    ),
    190: BeamKnownAsset(
      id: 190,
      name: 'Chad',
      symbol: 'CHAD',
      color: 0xFF25C2A0,
      icon: '$_icons/187.png',
    ),
    191: BeamKnownAsset(
      id: 191,
      name: 'GigaChad',
      symbol: 'GIGA',
      color: 0xFFA855F7,
      icon: '$_icons/186.png',
    ),
  };

  /// Control, zero-width and text-direction characters (U+202A-U+202E,
  /// U+2066-U+2069 can make one ticker render as another).
  static final _invisible = RegExp(
    r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F'
    r'\u202A-\u202E\u2066-\u2069\uFEFF]',
  );

  static const _maxName = 32;
  static const _maxSymbol = 8;

  /// How to show [assetId]. Unverified assets take their name and ticker
  /// from on-chain [metadata], cleaned of anything that is not printable,
  /// cut to a sane length, and never get an icon or colour of their own.
  static BeamAssetDisplay display(int assetId, BeamAssetMetadata? metadata) {
    final known = verified[assetId];
    if (known != null) {
      return BeamAssetDisplay(
        assetId: assetId,
        name: known.name,
        symbol: known.symbol,
        verified: true,
        icon: known.icon,
        color: known.color,
      );
    }
    final name = _clean(metadata?.name, _maxName);
    final symbol = _clean(
      metadata?.unitName ?? metadata?.shortName,
      _maxSymbol,
    );
    return BeamAssetDisplay(
      assetId: assetId,
      name: name ?? 'Asset #$assetId',
      symbol: symbol ?? '#$assetId',
      verified: false,
      impersonates: _copied(name, symbol),
    );
  }

  static int? _copied(String? name, String? symbol) {
    String norm(String s) =>
        s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final n = name == null ? null : norm(name);
    final s = symbol == null ? null : norm(symbol);
    for (final k in verified.values) {
      final ks = norm(k.symbol);
      final kn = norm(k.name);
      if ((s != null && s.isNotEmpty && (s == ks || s == kn)) ||
          (n != null && n.isNotEmpty && (n == ks || n == kn))) {
        return k.id;
      }
    }
    return null;
  }

  /// Printable ASCII and common letters only, trimmed, at most [max] chars;
  /// null when nothing usable is left. On-chain names are attacker text.
  static String? _clean(String? raw, int max) {
    if (raw == null) return null;
    final kept = raw
        .replaceAll(_invisible, '')
        .trim();
    if (kept.isEmpty) return null;
    return kept.length > max ? '${kept.substring(0, max - 1)}…' : kept;
  }
}
