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

import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import '../../stack_text_field.dart';
import '../beam_decimal_input.dart';
import 'beam_layout.dart';

/// Small building blocks for the BEAM contract screens, made of Campfire's
/// own containers and text styles so the screens look native.

/// A field caption above an input or a card.
class BeamLabel extends StatelessWidget {
  const BeamLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style:
            (desktop
                    ? STextStyles.w500_14(context)
                    : STextStyles.w500_12(context))
                .copyWith(
                  color: Theme.of(context)
                      .extension<StackColors>()!
                      .infoItemLabel,
                ),
      ),
    );
  }
}

/// One label / value line of a summary, as in Campfire's confirm screens.
class BeamDetailRow extends StatelessWidget {
  const BeamDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.valueKey,
  });

  final String label;
  final String value;

  /// A second, quieter line under [value].
  final String? detail;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final desktop = BeamLayoutScope.isDesktop(context);
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                label,
                style:
                    (desktop
                            ? STextStyles.desktopTextExtraExtraSmall(context)
                            : STextStyles.smallMed12(context))
                        .copyWith(color: colors.infoItemLabel),
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              // The amount keeps its own width (up to 55%), so a short
              // label never wraps beside a short value.
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.55),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    key: valueKey,
                    textAlign: TextAlign.right,
                    style: desktop
                        ? STextStyles.desktopTextExtraExtraSmall(context)
                              .copyWith(color: colors.textDark)
                        : STextStyles.itemSubtitle12(context),
                  ),
                  if (detail != null)
                    Text(
                      detail!,
                      textAlign: TextAlign.right,
                      style: STextStyles.label(context),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A white card holding [BeamDetailRow]s.
class BeamDetailCard extends StatelessWidget {
  const BeamDetailCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => RoundedWhiteContainer(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// The green "Total" line of Campfire's confirm screen.
class BeamTotalRow extends StatelessWidget {
  const BeamTotalRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.confirm = true,
  });

  final String label;
  final String value;
  final Key? valueKey;

  /// False on a form, before anything is confirmed: a plain card, not the
  /// confirm screen's green (which reads as "done").
  final bool confirm;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    final style =
        (desktop
                ? STextStyles.desktopTextExtraExtraSmall(context)
                : STextStyles.titleBold12(context))
            .copyWith(
              color: confirm ? colors.textConfirmTotalAmount : colors.textDark,
            );
    return RoundedContainer(
      color: confirm ? colors.snackBarBackSuccess : colors.popupBG,
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, box) {
          // One line when label and value both fit; otherwise the value
          // goes under the label, so neither wraps a lone word onto a line
          // of its own ("Your balance changes" / "by").
          final scaler = MediaQuery.textScalerOf(context);
          // Measured in the font the Text will draw with (the inherited
          // family), not the platform default.
          final drawn = DefaultTextStyle.of(context).style.merge(style);
          final need =
              _width(label, drawn, scaler) + 12 + _width(value, drawn, scaler);
          final fits = need <= box.maxWidth;
          if (!fits) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: style),
                const SizedBox(height: 4),
                Text(value, key: valueKey, style: style),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: style)),
              const SizedBox(width: 12),
              Text(
                value,
                key: valueKey,
                textAlign: TextAlign.right,
                style: style,
              ),
            ],
          );
        },
      ),
    );
  }

  static double _width(String text, TextStyle style, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }
}

enum BeamNoticeKind { info, warning, danger, success }

/// A coloured box with an icon and plain-language text: warnings, errors
/// and "what happens next". Every error names the next step
/// (no dead ends).
class BeamNotice extends StatelessWidget {
  const BeamNotice({
    super.key,
    required this.kind,
    required this.message,
    this.title,
    this.actionLabel,
    this.onAction,
  });

  final BeamNoticeKind kind;
  final String? title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final (Color bg, Color fg, IconData icon) = switch (kind) {
      BeamNoticeKind.info => (
        c.snackBarBackInfo,
        c.snackBarTextInfo,
        Icons.info_outline_rounded,
      ),
      BeamNoticeKind.warning => (
        c.warningBackground,
        c.warningForeground,
        Icons.warning_amber_rounded,
      ),
      BeamNoticeKind.danger => (
        c.snackBarBackError,
        c.snackBarTextError,
        Icons.error_outline_rounded,
      ),
      BeamNoticeKind.success => (
        c.snackBarBackSuccess,
        c.snackBarTextSuccess,
        Icons.check_circle_outline_rounded,
      ),
    };
    final desktop = BeamLayoutScope.isDesktop(context);
    final body = desktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
        : STextStyles.smallMed12(context);
    return RoundedContainer(
      color: bg,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      title!,
                      style: body.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Text(message, style: body.copyWith(color: fg)),
                if (actionLabel != null && onAction != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: GestureDetector(
                      onTap: onAction,
                      behavior: HitTestBehavior.opaque,
                      child: Text(
                        actionLabel!,
                        style: body.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A Campfire text field (rounded, theme-filled) with a caption and a
/// plain-language problem line under it.
class BeamTextField extends StatefulWidget {
  const BeamTextField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.error,
    this.helper,
    this.suffix,
    this.keyboardType,
    this.inputFormatters,
    this.maxLines = 1,
    this.enabled = true,
    this.onChanged,
    this.fieldKey,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.obscureText = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;

  /// A password: hidden as typed (and never offered to the keyboard's
  /// suggestions, like every field here).
  final bool obscureText;
  final ValueChanged<String>? onSubmitted;

  /// Shown in the error colour; wins over [helper].
  final String? error;
  final String? helper;
  final Widget? suffix;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int maxLines;
  final bool enabled;
  final ValueChanged<String>? onChanged;
  final Key? fieldKey;
  final TextCapitalization textCapitalization;
  final TextStyle? style;

  @override
  State<BeamTextField> createState() => _BeamTextFieldState();
}

class _BeamTextFieldState extends State<BeamTextField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_refocus);
  }

  void _refocus() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_refocus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    final under = widget.error ?? widget.helper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) BeamLabel(widget.label!),
        ClipRRect(
          borderRadius: BorderRadius.circular(
            Constants.size.circularBorderRadius,
          ),
          child: BeamCloseKeyboardOnTapOutside(
            child: TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.obscureText,
              onSubmitted: widget.onSubmitted,
              maxLines: widget.obscureText ? 1 : widget.maxLines,
              minLines: 1,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: widget.keyboardType,
              // A decimal keyboard's key types "." whatever the phone's
              // region (BeamUnits reads "." as the decimal point).
              inputFormatters: [
                if (widget.keyboardType?.decimal ?? false)
                  BeamDecimalKeyFormatter('.'),
                ...?widget.inputFormatters,
              ],
              textCapitalization: widget.textCapitalization,
              onChanged: widget.onChanged,
              style:
                  widget.style ??
                  (desktop
                      ? STextStyles.desktopTextExtraSmall(context)
                            .copyWith(color: colors.textFieldActiveText)
                      : STextStyles.field(context)),
              decoration:
                  standardInputDecoration(
                    null,
                    _focus,
                    context,
                    desktopMed: true,
                  ).copyWith(
                    hintText: widget.hint,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    suffixIcon: widget.suffix,
                    isDense: true,
                  ),
            ),
          ),
        ),
        if (under != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              under,
              style: STextStyles.label(context).copyWith(
                color: widget.error != null
                    ? colors.textError
                    : colors.textSubtitle1,
              ),
            ),
          ),
      ],
    );
  }
}

/// A short status word on a coloured pill.
class BeamPill extends StatelessWidget {
  const BeamPill({super.key, required this.text, required this.kind});

  final String text;
  final BeamNoticeKind kind;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final (Color bg, Color fg) = switch (kind) {
      BeamNoticeKind.info => (c.snackBarBackInfo, c.snackBarTextInfo),
      BeamNoticeKind.warning => (c.warningBackground, c.warningForeground),
      BeamNoticeKind.danger => (c.snackBarBackError, c.snackBarTextError),
      BeamNoticeKind.success => (c.snackBarBackSuccess, c.snackBarTextSuccess),
    };
    return RoundedContainer(
      color: bg,
      radiusMultiplier: 4,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        text,
        style: STextStyles.label(context)
            .copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// A centred "nothing here yet" block that always names the next step.
class BeamEmptyState extends StatelessWidget {
  const BeamEmptyState({
    super.key,
    this.icon,
    this.art,
    required this.title,
    required this.message,
  }) : assert(icon != null || art != null);

  final IconData? icon;

  /// Shown instead of [icon], e.g. a Beam girl sticker.
  final Widget? art;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 8),
      child: Column(
        children: [
          art ?? Icon(icon, size: 48, color: c.textSubtitle2),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: desktop
                ? STextStyles.desktopH3(context)
                : STextStyles.pageTitleH2(context),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: desktop
                ? STextStyles.desktopTextExtraSmall(context)
                      .copyWith(color: c.textSubtitle1)
                : STextStyles.itemSubtitle(context),
          ),
        ],
      ),
    );
  }
}

/// A progress line with text, for loads that can take more than a second
/// (no dead ends).
class BeamWorking extends StatelessWidget {
  const BeamWorking(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: c.accentColorBlue,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: STextStyles.itemSubtitle(context))),
        ],
      ),
    );
  }
}
