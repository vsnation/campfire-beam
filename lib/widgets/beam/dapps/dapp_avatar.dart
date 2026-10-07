/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';

/// A dApp's picture: its own icon file when one is given and readable,
/// else the bundled copy of a checked dApp's icon ([iconAsset]), otherwise
/// its first letter on a plain tile.
///
/// The approval sheet passes neither on purpose: a dApp's own picture could
/// imitate Campfire's, and the sheet is where that would matter.
class DappAvatar extends StatelessWidget {
  const DappAvatar({
    super.key,
    required this.name,
    this.iconFile,
    this.iconAsset,
    this.size = 40,
  });

  final String name;
  final String? iconFile;

  /// An app asset (`assets/beam/dapps/<guid>.svg|png`): the store's picture
  /// of a bundled dApp that is not installed yet.
  final String? iconAsset;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final radius = BorderRadius.circular(
      Constants.size.circularBorderRadius * (size / 40),
    );
    final fallback = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.textFieldDefaultBG,
        borderRadius: radius,
      ),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase(),
        style: STextStyles.w600_18(context)
            .copyWith(color: colors.textDark3, fontSize: size * 0.45),
      ),
    );
    final path = iconFile;
    final asset = iconAsset;
    final Widget image;
    if (path != null && File(path).existsSync()) {
      image = path.toLowerCase().endsWith('.svg')
          ? SvgPicture(
              DappSvgLoader.file(path),
              width: size,
              height: size,
              placeholderBuilder: (_) => fallback,
              errorBuilder: (_, _, _) => fallback,
            )
          : Image.file(
              File(path),
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            );
    } else if (asset != null) {
      image = asset.toLowerCase().endsWith('.svg')
          ? SvgPicture(
              DappSvgLoader.asset(asset),
              width: size,
              height: size,
              placeholderBuilder: (_) => fallback,
              errorBuilder: (_, _, _) => fallback,
            )
          : Image.asset(
              asset,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            );
    } else {
      return fallback;
    }
    // Exactly size x size whatever the picture's own proportions, so rows
    // line up.
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(dimension: size, child: image),
    );
  }
}

/// Loads a dApp's SVG icon (an installed package's file, or the bundled copy
/// in the app's assets) through [dappSvgInlineStyles], so icons coloured by
/// a `<style>` sheet draw as they do in a browser.
@immutable
class DappSvgLoader extends SvgLoader<String> {
  const DappSvgLoader.file(String this.file) : asset = null;
  const DappSvgLoader.asset(String this.asset) : file = null;

  final String? file;
  final String? asset;

  @override
  Future<String?> prepareMessage(BuildContext? context) async {
    final f = file;
    if (f != null) {
      return utf8.decode(await File(f).readAsBytes(), allowMalformed: true);
    }
    final bundle = context == null
        ? rootBundle
        : DefaultAssetBundle.of(context);
    return bundle.loadString(asset!, cache: false);
  }

  @override
  String provideSvg(String? message) => dappSvgInlineStyles(message ?? '');

  @override
  int get hashCode => Object.hash(file, asset);

  @override
  bool operator ==(Object other) =>
      other is DappSvgLoader && other.file == file && other.asset == asset;
}

final _styleSheet = RegExp(
  r'<style\b[^>]*>([\s\S]*?)</style\s*>',
  caseSensitive: false,
);
final _cssComment = RegExp(r'/\*[\s\S]*?\*/');
final _cssRule = RegExp(r'([^{}]+)\{([^{}]*)\}');
final _classSelector = RegExp(r'^\.([A-Za-z_][\w-]*)$');
final _startTag = RegExp(r'<([A-Za-z][\w:.-]*)(\s[^<>]*?)?(/?)>');
final _classAttr = RegExp(r"""\sclass\s*=\s*(["'])([^"']*)\1""");
final _styleAttr = RegExp(r"""\sstyle\s*=\s*(["'])([^"']*)\1""");

/// [svg] with the simple class rules of its `<style>` sheets (`.a, .b {
/// fill: #fff; }`) moved onto the elements that carry those classes, as
/// `style` attributes, and the sheets removed.
///
/// flutter_svg does not read `<style>` sheets: an icon coloured only by
/// classes (BANS's: a dark disc with a teal and pink emblem) draws every
/// shape in the default black. It does read `style` attributes. Later
/// rules win over earlier ones and an element's own `style` over both, as
/// in CSS. Anything that is not a plain class selector is dropped, which
/// is what flutter_svg did with the whole sheet before.
String dappSvgInlineStyles(String svg) {
  if (!_styleSheet.hasMatch(svg)) return svg;
  final rules = <(String, String)>[];
  for (final sheet in _styleSheet.allMatches(svg)) {
    final css = sheet
        .group(1)!
        .replaceAll('<![CDATA[', '')
        .replaceAll(']]>', '')
        .replaceAll(_cssComment, '');
    for (final rule in _cssRule.allMatches(css)) {
      final declarations = rule
          .group(2)!
          .split(';')
          .map((d) => d.trim())
          .where((d) => d.contains(':'))
          .join(';')
          .replaceAll('"', "'");
      if (declarations.isEmpty) continue;
      for (final selector in rule.group(1)!.split(',')) {
        final c = _classSelector.firstMatch(selector.trim());
        if (c != null) rules.add((c.group(1)!, declarations));
      }
    }
  }
  return svg.replaceAll(_styleSheet, '').replaceAllMapped(_startTag, (m) {
    final attrs = m.group(2) ?? '';
    final cls = _classAttr.firstMatch(attrs);
    if (cls == null) return m.group(0)!;
    final names = cls.group(2)!.split(RegExp(r'\s+')).toSet();
    final declarations = [
      for (final (name, d) in rules)
        if (names.contains(name)) d,
    ];
    if (declarations.isEmpty) return m.group(0)!;
    var rest = attrs;
    final own = _styleAttr.firstMatch(rest);
    if (own != null) {
      declarations.add(own.group(2)!.trim());
      rest = rest.replaceRange(own.start, own.end, '');
    }
    return '<${m.group(1)}$rest style="${declarations.join(';')}"'
        '${m.group(3)}>';
  });
}
