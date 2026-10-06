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
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';

/// A dApp's picture: its own icon file when one is given and readable,
/// otherwise its first letter on a plain tile.
///
/// The approval sheet passes no [iconFile] on purpose: a dApp's own picture
/// could imitate Campfire's, and the sheet is where that would matter.
class DappAvatar extends StatelessWidget {
  const DappAvatar({
    super.key,
    required this.name,
    this.iconFile,
    this.size = 40,
  });

  final String name;
  final String? iconFile;
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
    if (path == null || !File(path).existsSync()) return fallback;
    final lower = path.toLowerCase();
    final Widget image = lower.endsWith('.svg')
        ? SvgPicture.file(
            File(path),
            width: size,
            height: size,
            placeholderBuilder: (_) => fallback,
          )
        : Image.file(
            File(path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
          );
    return ClipRRect(borderRadius: radius, child: image);
  }
}
