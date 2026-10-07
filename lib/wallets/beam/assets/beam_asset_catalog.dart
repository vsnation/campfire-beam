/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/widgets.dart' show Characters;

import '../models/beam_asset_info.dart';
import 'beam_asset_lookalike.dart';

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
  /// e.g. someone's own "FOMO", "FОМО" (Cyrillic), "F0MO", "wFOMO" or
  /// "Pepe #174" ([BeamLookalike.copiedKey]). The UI says "Not the verified
  /// FOMO (#174)".
  final int? impersonates;

  /// Always shown next to unverified assets.
  String get idLabel => '#$assetId';
}

abstract final class BeamAssetCatalog {
  static const _icons = 'assets/beam/icons';
  static const _generic = '$_icons/generic';

  /// The BEAM desktop wallet's generic asset icons (`assets/beam/icons/generic`,
  /// Apache-2.0, see the NOTICE there), used the way it uses them
  /// (`AssetsManager::getIcon`): an asset with no icon of its own gets
  /// `asset-<id % 20>`, so one asset always looks the same, in this wallet
  /// and in the desktop one. The choice depends only on the asset id, never
  /// on anything the asset's creator wrote, so it cannot be used to copy a
  /// verified asset's look.
  static const genericIconCount = 20;

  static String genericIcon(int assetId) =>
      '$_generic/asset-${assetId % genericIconCount}.svg';

  /// Generic icons a verified asset already wears (RFC, #6, has no icon
  /// of its own and shows `asset-6`).
  static final Set<String> _verifiedIcons = {
    for (final k in verified.values)
      if (k.icon == null) genericIcon(k.id),
  };

  /// [genericIcon] for an asset Campfire does not vouch for, skipping any
  /// icon a verified asset wears: #26, #46… would otherwise look exactly
  /// like RFC (#6). Depends only on the id.
  static String unverifiedIcon(int assetId) {
    for (var i = 0; i < genericIconCount; i++) {
      final icon = genericIcon(assetId + i);
      if (!_verifiedIcons.contains(icon)) return icon;
    }
    return missingIcon;
  }

  /// For an asset id the network does not know.
  static const missingIcon = '$_generic/asset-err.svg';

  /// The desktop wallet's accent colours, in the same order as its icons.
  static const _genericColors = [
    0xFF72FDFF, 0xFF2ACF1D, 0xFFFFBB54, 0xFFD885FF, 0xFF008EFF, //
    0xFFFF746B, 0xFF91E300, 0xFFFFE75A, 0xFF9643FF, 0xFF395BFF, //
    0xFFFF3B3B, 0xFF73FF7C, 0xFFFFA86C, 0xFFFF3ABE, 0xFF00AEE1, //
    0xFFFF5200, 0xFF6464FF, 0xFFFF7A21, 0xFF63AFFF, 0xFFC81F68, //
  ];

  /// ARGB accent of [genericIcon]. The desktop wallet would take an
  /// unverified asset's `OPT_COLOR` instead; we don't, because its creator
  /// chooses it and could choose a verified asset's colour.
  static int genericColor(int assetId) =>
      _genericColors[assetId % _genericColors.length];

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
      icon: '$_icons/beam.svg',
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
    // The Beam Bridge's wrapped Ethereum assets. Each is owned on chain by
    // its bridge asset contract (acefc4bed7… ETH, d455975164… USDT,
    // 8a09b19c37… WBTC, 041710c647… DAI), as in the owner's bridge route
    // registry; names from their metadata (explorer `/assets`,
    // 2026-10-07). No bundled icons yet: the generic icon for the id.
    36: BeamKnownAsset(
      id: 36,
      name: 'Wrapped ETH',
      symbol: 'bETH',
      color: 0xFF627EEA,
    ),
    37: BeamKnownAsset(
      id: 37,
      name: 'Wrapped USDT',
      symbol: 'bUSDT',
      color: 0xFF26A17B,
    ),
    38: BeamKnownAsset(
      id: 38,
      name: 'Wrapped WBTC',
      symbol: 'bWBTC',
      color: 0xFFF09242,
    ),
    39: BeamKnownAsset(
      id: 39,
      name: 'Wrapped DAI',
      symbol: 'bDAI',
      color: 0xFFF5AC37,
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

  static const _maxName = 32;
  static const _maxSymbol = 8;

  /// How to show [assetId]. Unverified assets take their name and ticker
  /// from on-chain [metadata], cleaned of anything that is not printable,
  /// cut to a sane length, and never get an icon or colour of their own:
  /// they get the desktop wallet's generic icon for their id
  /// ([unverifiedIcon]). Verified assets without a bundled icon get one
  /// too.
  static BeamAssetDisplay display(int assetId, BeamAssetMetadata? metadata) {
    final known = verified[assetId];
    if (known != null) {
      return BeamAssetDisplay(
        assetId: assetId,
        name: known.name,
        symbol: known.symbol,
        verified: true,
        icon: known.icon ?? genericIcon(assetId),
        color: known.color,
      );
    }
    final rawName = metadata?.name;
    final rawSymbol = metadata?.unitName ?? metadata?.shortName;
    final name = _clean(rawName, _maxName);
    final symbol = _clean(rawSymbol, _maxSymbol);
    return BeamAssetDisplay(
      assetId: assetId,
      name: name ?? placeholderName(assetId),
      symbol: symbol ?? placeholderSymbol(assetId),
      verified: false,
      icon: unverifiedIcon(assetId),
      color: genericColor(assetId),
      // Judged on the raw text: cleaning drops a borrowed "#174".
      impersonates: impersonationOf(rawName, rawSymbol),
    );
  }

  /// "Asset #557": an unverified asset whose metadata gave no name.
  static String placeholderName(int assetId) => 'Asset #$assetId';

  /// "#557": an unverified asset whose metadata gave no ticker.
  static String placeholderSymbol(int assetId) => '#$assetId';

  /// The verified asset an unverified asset named [name] with ticker
  /// [symbol] copies, or null ([BeamLookalike.copiedKey]).
  static int? impersonationOf(String? name, String? symbol) =>
      BeamLookalike.copiedKey<int>(name, symbol, {
        for (final k in verified.values) k.id: (symbol: k.symbol, name: k.name),
      });

  /// A cached unverified row's name and ticker under today's rules: cleaned
  /// again and checked again for a copied verified asset. Rows cached by an
  /// older version keep whatever it let through (a borrowed "#174", a
  /// look-alike it did not flag) until this runs. Placeholders stay as
  /// they are.
  static ({String name, String symbol, int? impersonates}) relook(
    int assetId,
    String name,
    String symbol,
  ) {
    final keepName = name == placeholderName(assetId);
    final keepSymbol = symbol == placeholderSymbol(assetId);
    final cleanName = keepName ? name : _clean(name, _maxName);
    final cleanSymbol = keepSymbol ? symbol : _clean(symbol, _maxSymbol);
    return (
      name: cleanName ?? placeholderName(assetId),
      symbol: cleanSymbol ?? placeholderSymbol(assetId),
      impersonates: impersonationOf(
        keepName ? null : name,
        keepSymbol ? null : symbol,
      ),
    );
  }

  // ------------------------------------------------------------- cleaning

  /// What a name may be built from: letters, digits, punctuation and
  /// symbols of any script. Everything else is dropped: controls, format
  /// characters (zero-width, bidi overrides, U+061C, U+2060-U+206F, soft
  /// hyphen, tag characters), line and paragraph separators, private-use
  /// and unassigned code points.
  static final _printable = RegExp(r'^[\p{L}\p{N}\p{P}\p{S}]$', unicode: true);
  static final _space = RegExp(r'^[\p{Zs}\t]$', unicode: true);
  static final _mark = RegExp(r'^\p{M}$', unicode: true);

  /// Letters and marks that render as nothing (Hangul fillers, the braille
  /// blank, Khmer inherent vowels, the combining grapheme joiner, variation
  /// selectors), so a name cannot look empty or hide characters.
  static bool _blank(int r) =>
      r == 0x115F ||
      r == 0x1160 ||
      r == 0x3164 ||
      r == 0xFFA0 ||
      r == 0x2800 ||
      r == 0x17B4 ||
      r == 0x17B5 ||
      r == 0x034F ||
      (r >= 0x180B && r <= 0x180F) ||
      (r >= 0xFE00 && r <= 0xFE0F) ||
      (r >= 0xE0100 && r <= 0xE01EF);

  /// At most this many combining marks per character: enough for accented
  /// letters and Indic scripts, too few to paint over the line below.
  static const _maxMarksPerCharacter = 2;

  /// `#`, `＃`, `﹟`: kept out of names entirely, so "Pepe #174" can never
  /// sit next to Campfire's real "#999".
  static const _numberSigns = {'#', '\uFF03', '\uFE5F'};

  /// A raw metadata field longer than this is cut before cleaning.
  static const _maxRaw = 512;

  /// Printable characters only (an allow-list, [_printable]), any run of
  /// spaces as one, no borrowed "#174" (Campfire's id label is Campfire's),
  /// trimmed and cut to at most [max] characters as people see them
  /// (grapheme clusters, so a cut never splits one); null when nothing
  /// usable is left. On-chain names are attacker text.
  static String? _clean(String? raw, int max) {
    if (raw == null) return null;
    var text = raw.length > _maxRaw ? raw.substring(0, _maxRaw) : raw;
    text = text.replaceAll(BeamLookalike.idLabel, ' ');
    final out = StringBuffer();
    for (final cluster in Characters(text)) {
      var base = false;
      var marks = 0;
      for (final r in cluster.runes) {
        final c = String.fromCharCode(r);
        if (_blank(r)) continue;
        if (_mark.hasMatch(c)) {
          if (base && marks < _maxMarksPerCharacter) {
            out.write(c);
            marks++;
          }
        } else if (_space.hasMatch(c)) {
          out.write(' ');
          base = false;
        } else if (_printable.hasMatch(c) && !_numberSigns.contains(c)) {
          out.write(c);
          base = true;
        }
      }
    }
    final kept = out.toString().replaceAll(RegExp(' {2,}'), ' ').trim();
    if (kept.isEmpty) return null;
    final chars = Characters(kept);
    return chars.length > max ? '${chars.take(max - 1)}…' : kept;
  }
}
