/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../beam_decimal_input.dart';
import 'dex_asset_icon.dart';

/// An amount box with the asset on its right, in the look of Campfire's
/// exchange form (`ExchangeTextField`): grey field, asset button with its
/// icon, ticker and a chevron when it can be changed.
class DexAmountField extends StatelessWidget {
  const DexAmountField({
    super.key,
    required this.controller,
    required this.asset,
    this.focusNode,
    this.onChanged,
    this.onAssetTap,
    this.readOnly = false,
    this.hint = '0',
    this.fieldKey,
    this.assetButtonKey,
    this.error = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// Null shows "Choose".
  final BeamAssetDisplay? asset;
  final ValueChanged<String>? onChanged;

  /// Null makes the asset fixed (no chevron).
  final VoidCallback? onAssetTap;
  final bool readOnly;
  final String hint;
  final Key? fieldKey;
  final Key? assetButtonKey;

  /// Draws the field in Campfire's error colours.
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final radius = Constants.size.circularBorderRadius;
    final a = asset;
    return Container(
      decoration: BoxDecoration(
        color: error ? colors.textFieldErrorBG : colors.textFieldDefaultBG,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: TextField(
                key: fieldKey,
                controller: controller,
                focusNode: focusNode,
                readOnly: readOnly,
                onChanged: onChanged,
                enableSuggestions: false,
                autocorrect: false,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  // The DEX reads "." only; a phone set to a region that
                  // writes 0,5 has no "." key.
                  BeamDecimalKeyFormatter('.'),
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                style: STextStyles.smallMed14(context).copyWith(
                  color: error ? colors.textFieldErrorText : colors.textDark,
                  fontSize: 18,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
                  hintText: hint,
                  hintStyle: STextStyles.fieldLabel(context)
                      .copyWith(fontSize: 18),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
              ),
            ),
            MouseRegion(
              cursor: onAssetTap == null
                  ? MouseCursor.defer
                  : SystemMouseCursors.click,
              child: GestureDetector(
                key: assetButtonKey,
                onTap: onAssetTap,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 96),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: colors.buttonBackSecondary,
                    borderRadius: BorderRadius.horizontal(
                      right: Radius.circular(radius),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (a != null) ...[
                        DexAssetIcon(asset: a, size: 20),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 110),
                          child: DexAssetName(
                            asset: a,
                            showWarning: false,
                            style: STextStyles.smallMed14(context)
                                .copyWith(color: colors.textDark),
                          ),
                        ),
                      ] else
                        Text(
                          'Choose',
                          style: STextStyles.smallMed14(context)
                              .copyWith(color: colors.textDark),
                        ),
                      if (onAssetTap != null) ...[
                        const SizedBox(width: 6),
                        SvgPicture.asset(
                          Assets.svg.chevronDown,
                          width: 8,
                          height: 4,
                          colorFilter: ColorFilter.mode(
                            colors.textDark,
                            BlendMode.srcIn,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
