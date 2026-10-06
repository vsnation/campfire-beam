/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_holdings.dart';
import '../../../wallets/beam/assets/beam_asset_text.dart';
import '../../../widgets/rounded_white_container.dart';
import 'beam_asset_icon.dart';
import 'beam_asset_layout.dart';

/// One row of the asset list, laid out like Campfire's token row
/// (`MyTokenSelectItem`): icon, name and balance; ticker (or what the asset
/// is) and its estimated value. A copycat of a verified asset carries the
/// warning in the row itself, where the user decides to tap it.
///
/// In [managing] mode the row shows or hides the asset instead of opening it.
class BeamAssetSelectItem extends ConsumerWidget {
  const BeamAssetSelectItem({
    super.key,
    required this.holding,
    required this.marketKnown,
    required this.onPressed,
    this.managing = false,
  });

  final BeamAssetHolding holding;
  final bool marketKnown;
  final bool managing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = BeamAssetLayout.isDesktop(context);
    final colors = Theme.of(context).extension<StackColors>()!;
    final asset = holding.contract;
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    // Rounded to what a person reads; the asset page shows every digit.
    final balanceText = BeamAssetText.rounded(
      holding.balance.total,
      asset,
      locale: locale,
    );
    // A pool share's row says "Pool share" underneath; its title is the
    // pair.
    final title = asset.isPoolShare
        ? asset.name.replaceFirst(RegExp(r' pool share$'), '')
        : asset.name;
    final value = holding.valueGroth;
    final valueText = value != null
        ? BeamAssetText.beamEstimate(value, locale: locale)
        : marketKnown
        ? BeamAssetText.noPrice
        : '';
    final badge = BeamAssetText.badge(asset);
    final subtitle = asset.isPoolShare
        ? 'Pool share ${asset.idLabel}'
        : badge.isEmpty
        ? asset.symbol
        : '${asset.symbol == asset.idLabel ? '' : '${asset.symbol} · '}'
              '$badge';
    final warning = BeamAssetText.impersonation(asset);

    final titleStyle = isDesktop
        ? STextStyles.desktopTextExtraSmall(context)
              .copyWith(color: colors.textDark)
        : STextStyles.titleBold12(context);
    final subStyle = isDesktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
        : STextStyles.itemSubtitle(context);

    return Opacity(
      opacity: managing && holding.hidden ? 0.5 : 1,
      child: RoundedWhiteContainer(
        padding: EdgeInsets.zero,
        child: MaterialButton(
          key: Key('beamAssetRow_${asset.assetId}'),
          padding: isDesktop
              ? const EdgeInsets.symmetric(horizontal: 28, vertical: 24)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              Constants.size.circularBorderRadius,
            ),
          ),
          onPressed: onPressed,
          child: Row(
            children: [
              BeamAssetIcon(asset: asset, size: isDesktop ? 32 : 28),
              SizedBox(width: isDesktop ? 12 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: Text(
                            title,
                            style: titleStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 6,
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                balanceText,
                                style: isDesktop
                                    ? titleStyle
                                    : STextStyles.itemSubtitle(context)
                                          .copyWith(color: colors.textDark),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            subtitle,
                            style: subStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (valueText.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(valueText, style: subStyle),
                        ],
                      ],
                    ),
                    if (warning != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        warning,
                        key: Key('beamAssetWarning_${asset.assetId}'),
                        style: subStyle.copyWith(color: colors.textError),
                      ),
                    ],
                  ],
                ),
              ),
              if (managing) ...[
                const SizedBox(width: 12),
                Semantics(
                  label: holding.hidden ? 'Hidden' : 'Shown',
                  child: SvgPicture.asset(
                    holding.hidden ? Assets.svg.eyeSlash : Assets.svg.eye,
                    width: 20,
                    height: 20,
                    colorFilter: ColorFilter.mode(
                      holding.hidden
                          ? colors.textSubtitle2
                          : colors.accentColorBlue,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
