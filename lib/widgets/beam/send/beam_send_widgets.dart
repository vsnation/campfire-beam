/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../rounded_container.dart';
import '../assets/beam_asset_logo.dart';

/// Which layout the BEAM send screens use below this widget. The app never
/// sets it (Campfire's own platform check decides); golden tests use it to
/// draw the phone layout on a desktop test host.
class BeamSendLayout extends InheritedWidget {
  const BeamSendLayout({
    super.key,
    required this.desktop,
    required super.child,
  });

  final bool desktop;

  static bool isDesktop(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BeamSendLayout>()?.desktop ??
      Util.isDesktop;

  @override
  bool updateShouldNotify(BeamSendLayout oldWidget) =>
      oldWidget.desktop != desktop;
}

/// Campfire's `standardInputDecoration`, with the layout passed in rather
/// than read from the platform.
InputDecoration beamInputDecoration(
  String? label,
  FocusNode focus,
  BuildContext context, {
  required bool desktop,
}) {
  final colors = Theme.of(context).extension<StackColors>()!;
  final hint = desktop
      ? STextStyles.desktopTextExtraSmall(context)
            .copyWith(color: colors.textFieldDefaultText)
      : STextStyles.fieldLabel(context);
  return InputDecoration(
    labelText: label,
    fillColor: focus.hasFocus
        ? colors.textFieldActiveBG
        : colors.textFieldDefaultBG,
    labelStyle: hint,
    hintStyle: hint,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
  );
}

/// A field label as Campfire's send screens draw it.
class BeamFieldLabel extends StatelessWidget {
  const BeamFieldLabel(this.text, {super.key, required this.desktop});

  final String text;
  final bool desktop;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: desktop
        ? STextStyles.desktopTextExtraSmall(context).copyWith(
            color: Theme.of(context)
                .extension<StackColors>()!
                .textFieldActiveSearchIconRight,
          )
        : STextStyles.smallMed12(context),
    textAlign: TextAlign.left,
  );
}

enum BeamNoticeKind { info, warning, error, success }

/// A short message box in Campfire's colours: info on the card colour,
/// warnings on Campfire's warning colours, errors in its error red.
class BeamNotice extends StatelessWidget {
  const BeamNotice({
    super.key,
    required this.kind,
    required this.message,
    this.title,
    this.action,
  });

  final BeamNoticeKind kind;
  final String? title;
  final String message;

  /// A text button under the message ("Try again").
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final (Color bg, Color fg, String icon) = switch (kind) {
      BeamNoticeKind.info => (c.textFieldDefaultBG, c.textDark3, ''),
      BeamNoticeKind.warning => (
        c.warningBackground,
        c.warningForeground,
        Assets.svg.alertCircle,
      ),
      BeamNoticeKind.error => (
        c.textFieldErrorBG,
        c.textError,
        Assets.svg.circleAlert,
      ),
      BeamNoticeKind.success => (
        c.textFieldSuccessBG,
        c.accentColorGreen,
        Assets.svg.checkCircle,
      ),
    };
    return RoundedContainer(
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: SvgPicture.asset(
                icon,
                width: 16,
                height: 16,
                colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: STextStyles.label(context)
                        .copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  message,
                  style: STextStyles.label(context).copyWith(color: fg),
                ),
                if (action != null) ...[const SizedBox(height: 4), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A BEAM asset's icon, drawn as the BEAM desktop wallet draws it (one
/// widget for every BEAM screen): BEAM's logo, a verified asset's bundled
/// icon, or the generic icon for its id — never an icon an issuer chose.
class BeamAssetIcon extends StatelessWidget {
  const BeamAssetIcon(this.asset, {super.key, this.size = 22});

  final BeamAssetDisplay asset;
  final double size;

  @override
  Widget build(BuildContext context) => BeamAssetLogo(asset, size: size);
}

/// "Verified" or "Not verified · #321", next to an asset's name.
class BeamAssetBadge extends StatelessWidget {
  const BeamAssetBadge(this.asset, {super.key});

  final BeamAssetDisplay asset;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final text = asset.verified
        ? (asset.assetId == 0 ? '' : 'Verified')
        : 'Not verified · ${asset.idLabel}';
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(
      text,
      style: STextStyles.label(context).copyWith(
        fontSize: 10,
        color: asset.verified ? c.accentColorGreen : c.textSubtitle1,
      ),
    );
  }
}

/// The one-line warning for an unverified asset that copies a verified
/// one's name ("Not the verified FOMO (#174)").
String? beamImpersonationWarning(BeamAssetDisplay asset) {
  final copied = asset.impersonates;
  if (copied == null) return null;
  final real = BeamAssetCatalog.verified[copied];
  if (real == null) return null;
  return 'Not the verified ${real.symbol} (#${real.id}). Anyone can create '
      'an asset with any name; this one is ${asset.idLabel}.';
}

/// A grey placeholder bar for content that is loading.
class BeamSkeletonLine extends StatelessWidget {
  const BeamSkeletonLine({super.key, required this.width, this.height = 12});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Theme.of(context).extension<StackColors>()!.textFieldDefaultBG,
      borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
    ),
  );
}
