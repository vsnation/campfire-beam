/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The short menu behind "Airdrops" and "Tokens": each groups three screens
// that are one job each (claim a code / my airdrops / create codes; create a
// token / my tokens / burn). A bottom sheet on a phone, a dialog on desktop,
// in the look of Campfire's "More features" dialog.
//
// Spec (USER_PSYCHOLOGY §6):
//   1. Job: pick which of the three things to do.
//   2. Primary CTA: the first row, the most common task ("Claim a code",
//      "Create a token"); the other two rows sit under it. No other buttons.
//   3. Taps from app open: wallet → More → Airdrops → Claim a code (3) on a
//      phone; wallet → Airdrops → Claim a code (3) on desktop.
//
// Exit-intent (§1.7) — what would make an impatient person close it:
// * Jargon in the row names ("batch", "voucher", "minter"): rows say what
//   the user gets ("Claim a code", "See who claimed your codes").
// * Not knowing which row is theirs: every row has one plain line under it.
// * No way out: the sheet closes on a swipe or a tap outside; the dialog has
//   Campfire's close button.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import '../airdrop/beam_layout.dart';

/// One row of a [showBeamFeatureMenu].
class BeamFeatureMenuOption {
  const BeamFeatureMenuOption({
    required this.key,
    required this.icon,
    required this.title,
    required this.detail,
    required this.onSelected,
  });

  /// Finds the row in tests and click paths.
  final Key key;

  /// An `Assets.svg` path.
  final String icon;
  final String title;
  final String detail;

  /// Runs after the menu has closed, with the context that opened it.
  final void Function(BuildContext context) onSelected;
}

/// Shows [options] under [title]: a bottom sheet on a phone, a dialog on
/// desktop. The chosen option runs after the menu has closed.
Future<void> showBeamFeatureMenu(
  BuildContext context, {
  required String title,
  required List<BeamFeatureMenuOption> options,
}) async {
  final desktop = BeamLayoutScope.isDesktop(context);
  final BeamFeatureMenuOption? chosen;
  if (desktop) {
    chosen = await showDialog<BeamFeatureMenuOption>(
      context: context,
      builder: (_) => _DesktopMenu(title: title, options: options),
    );
  } else {
    chosen = await showModalBottomSheet<BeamFeatureMenuOption>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _MobileMenu(title: title, options: options),
    );
  }
  if (chosen != null && context.mounted) chosen.onSelected(context);
}

class _MobileMenu extends StatelessWidget {
  const _MobileMenu({required this.title, required this.options});

  final String title;
  final List<BeamFeatureMenuOption> options;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      key: const Key('beamFeatureMenu'),
      decoration: BoxDecoration(
        color: colors.popupBG,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  decoration: BoxDecoration(
                    color: colors.textFieldDefaultBG,
                    borderRadius: BorderRadius.circular(
                      Constants.size.circularBorderRadius,
                    ),
                  ),
                  width: 60,
                  height: 4,
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(title, style: STextStyles.pageTitleH2(context)),
              ),
              const SizedBox(height: 16),
              for (final o in options) ...[
                RoundedWhiteContainer(
                  key: o.key,
                  borderColor: colors.textFieldDefaultBG,
                  padding: const EdgeInsets.all(12),
                  onPressed: () => Navigator.of(context).pop(o),
                  child: Row(
                    children: [
                      _Icon(asset: o.icon, size: 40, iconSize: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              o.title,
                              style: STextStyles.titleBold12(context),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              o.detail,
                              style: STextStyles.itemSubtitle(context),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopMenu extends StatelessWidget {
  const _DesktopMenu({required this.title, required this.options});

  final String title;
  final List<BeamFeatureMenuOption> options;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return DesktopDialog(
      key: const Key('beamFeatureMenu'),
      maxHeight: MediaQuery.sizeOf(context).height - 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(title, style: STextStyles.desktopH3(context)),
              ),
              const DesktopDialogCloseButton(),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final o in options)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 32,
                      ),
                      child: RoundedContainer(
                        key: o.key,
                        color: Colors.transparent,
                        borderColor: colors.textFieldDefaultBG,
                        onPressed: () => Navigator.of(context).pop(o),
                        child: Row(
                          children: [
                            _Icon(asset: o.icon, size: 46, iconSize: 24),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    o.title,
                                    style: STextStyles.w600_20(context),
                                  ),
                                  Text(
                                    o.detail,
                                    style:
                                        STextStyles.desktopTextExtraExtraSmall(
                                          context,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Icon extends StatelessWidget {
  const _Icon({
    required this.asset,
    required this.size,
    required this.iconSize,
  });

  final String asset;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      padding: EdgeInsets.zero,
      color: colors.settingsIconBack,
      width: size,
      height: size,
      radiusMultiplier: size,
      child: Center(
        child: SvgPicture.asset(
          asset,
          width: iconSize,
          height: iconSize,
          colorFilter: ColorFilter.mode(
            colors.settingsIconIcon,
            BlendMode.srcIn,
          ),
        ),
      ),
    );
  }
}
