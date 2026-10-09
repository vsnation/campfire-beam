/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../background.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import '../stickers/beam_sticker.dart';
import 'dex_deps.dart';

/// What the DEX screens need to know to lay themselves out: a dialog on
/// desktop, a page on a phone. [BeamDexDeps] and the Uniswap swap's deps
/// both provide it, so both DEXes share these widgets.
abstract interface class DexLayout {
  bool get desktop;
}

/// Font features for addresses: no contextual alternates (Inter would draw
/// "0x" and digit-x-digit as "×").
const List<FontFeature> kAddressFontFeatures = [FontFeature.disable('calt')];

/// How loud a [DexNotice] is.
enum DexNoticeKind { info, warning, error, success }

/// A notice card: what happened, in plain words, and the one thing to do
/// next. Used for empty states, errors and warnings (USER_PSYCHOLOGY §1.4).
class DexNotice extends StatelessWidget {
  const DexNotice({
    super.key,
    required this.title,
    this.detail,
    this.kind = DexNoticeKind.info,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
    this.sticker,
  });

  final String title;
  final String? detail;
  final DexNoticeKind kind;

  /// A small Beam girl sticker shown in place of the icon (empty states
  /// and failures only; never on a confirmation).
  final BeamSticker? sticker;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  static ButtonHeight get _buttonHeight =>
      Util.isDesktop ? ButtonHeight.m : ButtonHeight.xl;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final (Color bg, Color fg, IconData icon) = switch (kind) {
      DexNoticeKind.info => (
        colors.snackBarBackInfo,
        colors.snackBarTextInfo,
        Icons.info_outline_rounded,
      ),
      DexNoticeKind.warning => (
        colors.warningBackground,
        colors.warningForeground,
        Icons.warning_amber_rounded,
      ),
      DexNoticeKind.error => (
        colors.snackBarBackError,
        colors.snackBarTextError,
        Icons.error_outline_rounded,
      ),
      DexNoticeKind.success => (
        colors.snackBarBackSuccess,
        colors.snackBarTextSuccess,
        Icons.check_circle_outline_rounded,
      ),
    };
    return RoundedContainer(
      color: bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sticker != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: BeamStickerImage(sticker!, size: 56),
                )
              else
                Icon(icon, size: 20, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: STextStyles.smallMed14(context)
                          .copyWith(color: fg),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        detail!,
                        style: STextStyles.smallMed12(context)
                            .copyWith(color: fg),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 12),
            SecondaryButton(
              label: actionLabel,
              buttonHeight: _buttonHeight,
              onPressed: onAction,
            ),
          ],
          if (secondaryLabel != null) ...[
            SizedBox(height: actionLabel != null ? 8 : 12),
            SecondaryButton(
              label: secondaryLabel,
              buttonHeight: _buttonHeight,
              onPressed: onSecondary,
            ),
          ],
        ],
      ),
    );
  }
}

/// The wallet's honest sync state as a plain banner, shown only when
/// spending is off. Nothing at all when the wallet is up to date.
class DexSyncBanner extends StatelessWidget {
  const DexSyncBanner({super.key, required this.deps});

  final BeamDexDeps deps;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BeamSyncAssessment>(
      valueListenable: deps.sync,
      builder: (context, sync, _) {
        if (sync.canSpend) return const SizedBox.shrink();
        final m = BeamSyncMessages.describe(sync);
        final act = deps.onSyncAction;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DexNotice(
            key: const Key('dex-sync-banner'),
            kind: DexNoticeKind.warning,
            title: m.title,
            detail: m.detail,
            actionLabel: act == null ? null : m.actionLabel,
            onAction: act == null ? null : () => act(sync.action),
          ),
        );
      },
    );
  }
}

/// What an amount is worth, under its field: "≈ 1.20 USD", "under 0.01
/// USD", "≈ 0.5 BEAM", "No price" ([BeamDexDeps.worth]). Nothing when
/// [text] is null.
class DexWorth extends StatelessWidget {
  const DexWorth(this.text, {super.key, this.textKey});

  final String? text;

  /// On the text itself, so tests read it like any other value.
  final Key? textKey;

  @override
  Widget build(BuildContext context) {
    final t = text;
    if (t == null) return const SizedBox.shrink();
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Text(
        t,
        key: textKey,
        style: STextStyles.label(context).copyWith(color: colors.textSubtitle1),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// One "label · value" line of a details card.
class DexDetailRow extends StatelessWidget {
  const DexDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.valueColor,
    this.note,
    this.noteKey,
    this.trailing,
    this.onTap,
    this.address = false,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final Color? valueColor;

  /// [value] is (or holds) an address: drawn without Inter's contextual
  /// alternates, which turn "0x1" into "0×1" and any digit-x-digit in an
  /// address into a multiplication sign.
  final bool address;

  /// A quieter line under the value, e.g. what it is worth.
  final String? note;
  final Key? noteKey;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final valueText = Text(
      value,
      key: valueKey,
      textAlign: TextAlign.right,
      style: STextStyles.itemSubtitle12(context).copyWith(
        color: valueColor ?? colors.textDark,
        fontFeatures: address ? kAddressFontFeatures : null,
      ),
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: STextStyles.smallMed12(context)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 5,
            child: note == null
                ? valueText
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      valueText,
                      Text(
                        note!,
                        key: noteKey,
                        textAlign: TextAlign.right,
                        style: STextStyles.label(context)
                            .copyWith(color: colors.textSubtitle1),
                      ),
                    ],
                  ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing!],
        ],
      ),
    );
    if (onTap == null) return row;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: row,
      ),
    );
  }
}

/// A row of equally wide choice chips (25 % / 50 % …, fee tiers, Add /
/// Withdraw). The selected one uses Campfire's primary button colours.
class DexChoiceChips<T> extends StatelessWidget {
  const DexChoiceChips({
    super.key,
    required this.values,
    required this.labelOf,
    required this.selected,
    required this.onSelected,
    this.keyOf,
  });

  final List<T> values;
  final String Function(T) labelOf;
  final T? selected;
  final ValueChanged<T> onSelected;
  final Key Function(T)? keyOf;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Row(
      children: [
        for (var i = 0; i < values.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: RoundedContainer(
              key: keyOf?.call(values[i]),
              padding: const EdgeInsets.symmetric(vertical: 10),
              color: values[i] == selected
                  ? colors.buttonBackPrimary
                  : colors.buttonBackSecondary,
              onPressed: () => onSelected(values[i]),
              child: Center(
                child: Text(
                  labelOf(values[i]),
                  style: STextStyles.smallMed12(context).copyWith(
                    color: values[i] == selected
                        ? colors.buttonTextPrimary
                        : colors.buttonTextSecondary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A DEX screen in Campfire's two shapes: a full page with an app bar on
/// mobile (like the send flow), a dialog body on desktop. The [bottom]
/// (the primary button and its reason) is pinned, so the main action is
/// on screen without scrolling at any height (USER_PSYCHOLOGY §1.3).
class DexPage extends StatelessWidget {
  const DexPage({
    super.key,
    required this.deps,
    required this.title,
    required this.body,
    this.bottom,
    this.onClose,
    this.actions,
  });

  final DexLayout deps;
  final String title;
  final Widget body;
  final Widget? bottom;
  final VoidCallback? onClose;

  /// App bar actions on mobile; the desktop dialog has only its close
  /// button.
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    if (deps.desktop) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(title, style: STextStyles.desktopH3(context)),
                ),
                DesktopDialogCloseButton(onPressedOverride: onClose),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: body,
            ),
          ),
          if (bottom != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
              child: bottom,
            )
          else
            const SizedBox(height: 32),
        ],
      );
    }
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: AppBarBackButton(
            onPressed: onClose ?? () => Navigator.of(context).pop(),
          ),
          title: Text(title, style: STextStyles.navBarTitle(context)),
          actions: actions,
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: body,
                ),
              ),
              if (bottom != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: bottom,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens a DEX screen: pushed as a page on mobile, in a dialog on desktop.
Future<T?> showDexPage<T>(
  BuildContext context,
  DexLayout deps,
  WidgetBuilder builder,
) {
  if (deps.desktop) {
    return showDialog<T>(
      context: context,
      // A click beside it must not drop a half-filled form; Escape closes
      // it, as desktop dialogs do (maybePop: a swap being sent stays).
      barrierDismissible: false,
      builder: (context) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(Navigator.of(context).maybePop()),
        },
        child: Focus(
          autofocus: true,
          child: DesktopDialog(
            maxWidth: 580,
            maxHeight: 760,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: builder(context),
            ),
          ),
        ),
      ),
    );
  }
  return Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: builder));
}

/// The primary button with the reason it is off, right above it, so a
/// disabled button is never a dead end.
class DexPrimaryAction extends StatelessWidget {
  const DexPrimaryAction({
    super.key,
    required this.deps,
    required this.label,
    required this.onPressed,
    this.reason,
    this.buttonKey,
    this.reasonActionLabel,
    this.onReasonAction,
  });

  final DexLayout deps;
  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// Why the button is off (or what is happening), in plain words.
  final String? reason;
  final Key? buttonKey;

  /// A quiet link under [reason] ("Split coins for next time").
  final String? reasonActionLabel;
  final VoidCallback? onReasonAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (reason != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              reason!,
              key: const Key('dex-cta-reason'),
              textAlign: TextAlign.center,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textSubtitle1),
            ),
          ),
        if (reason != null &&
            reasonActionLabel != null &&
            onReasonAction != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Center(
              child: CustomTextButton(
                key: const Key('dex-cta-reason-action'),
                text: reasonActionLabel!,
                onTap: onReasonAction,
              ),
            ),
          ),
        PrimaryButton(
          key: buttonKey,
          label: label,
          enabled: onPressed != null,
          onPressed: onPressed,
          buttonHeight: deps.desktop ? ButtonHeight.l : null,
        ),
      ],
    );
  }
}

/// A white card, the building block of every Campfire details screen.
class DexCard extends StatelessWidget {
  const DexCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: child,
    );
    if (onTap == null) return card;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: card,
      ),
    );
  }
}

/// Campfire's round flip button, as on the exchange form.
class DexFlipButton extends StatelessWidget {
  const DexFlipButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Semantics(
      label: 'Swap the two assets',
      button: true,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        // As on Campfire's exchange form: a tap target on a small rounded
        // tile (a button here would stretch to Material's 88 px minimum).
        child: GestureDetector(
          key: const Key('dex-flip'),
          onTap: onTap,
          child: RoundedContainer(
            padding: const EdgeInsets.all(6),
            color: colors.buttonBackSecondary,
            radiusMultiplier: 0.75,
            child: SvgPicture.asset(
              Assets.svg.swap,
              width: 20,
              height: 20,
              colorFilter: ColorFilter.mode(
                colors.accentColorDark,
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
