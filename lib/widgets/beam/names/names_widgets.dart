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

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../background.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import 'names_deps.dart';
import 'names_format.dart';

/// A name expiring within this many days is flagged for renewal.
const int kNamesRenewSoonDays = 30;

/// How loud a [NamesNotice] is.
enum NamesNoticeKind { info, warning, error, success }

/// A notice card: what happened, in plain words, and the one thing to do
/// next. Used for empty states, errors and warnings (no dead ends).
class NamesNotice extends StatelessWidget {
  const NamesNotice({
    super.key,
    required this.title,
    this.detail,
    this.kind = NamesNoticeKind.info,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  final String title;
  final String? detail;
  final NamesNoticeKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final (Color bg, Color fg, IconData icon) = switch (kind) {
      NamesNoticeKind.info => (
        colors.snackBarBackInfo,
        colors.snackBarTextInfo,
        Icons.info_outline_rounded,
      ),
      NamesNoticeKind.warning => (
        colors.warningBackground,
        colors.warningForeground,
        Icons.warning_amber_rounded,
      ),
      NamesNoticeKind.error => (
        colors.snackBarBackError,
        colors.snackBarTextError,
        Icons.error_outline_rounded,
      ),
      NamesNoticeKind.success => (
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
              key: actionKey,
              label: actionLabel,
              buttonHeight: Util.isDesktop ? ButtonHeight.m : ButtonHeight.xl,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

/// The wallet's honest sync state as a plain banner, shown only when
/// signing is off. Nothing at all when the wallet is up to date.
class NamesSyncBanner extends StatelessWidget {
  const NamesSyncBanner({super.key, required this.deps});

  final BeamNamesDeps deps;

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
          child: NamesNotice(
            key: const Key('names-sync-banner'),
            kind: NamesNoticeKind.warning,
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

/// One "label · value" line of a details card.
class NamesDetailRow extends StatelessWidget {
  const NamesDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
    this.valueColor,
    this.sub,
    this.onTap,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final Color? valueColor;

  /// A smaller line under the value (USD next to BEAM, "on tap" detail).
  final String? sub;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.infoItemLabel),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  key: valueKey,
                  textAlign: TextAlign.right,
                  style: STextStyles.itemSubtitle12(context)
                      .copyWith(color: valueColor ?? colors.textDark),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub!,
                    textAlign: TextAlign.right,
                    style: STextStyles.smallMed12(context)
                        .copyWith(color: colors.textSubtitle1),
                  ),
                ],
              ],
            ),
          ),
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

/// Campfire's confirm-screen "Total amount" box.
class NamesTotalBox extends StatelessWidget {
  const NamesTotalBox({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final style = STextStyles.titleBold12(context)
        .copyWith(color: colors.textConfirmTotalAmount);
    return RoundedContainer(
      color: colors.snackBarBackSuccess,
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Text(
              value,
              key: valueKey,
              textAlign: TextAlign.right,
              style: style,
            ),
          ),
        ],
      ),
    );
  }
}

/// A white card, the building block of every Campfire details screen.
class NamesCard extends StatelessWidget {
  const NamesCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(12),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final card = RoundedWhiteContainer(padding: padding, child: child);
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

/// A small grey heading above a group of cards.
class NamesSectionLabel extends StatelessWidget {
  const NamesSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        text,
        style: STextStyles.smallMed12(context)
            .copyWith(color: colors.textSubtitle1),
      ),
    );
  }
}

/// Years, as a − value + stepper (1 by default, up to [max]).
class NamesYearsStepper extends StatelessWidget {
  const NamesYearsStepper({
    super.key,
    required this.value,
    required this.max,
    required this.onChanged,
    this.min = 1,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    Widget step(String label, Key key, int? to) {
      final enabled = to != null;
      return Semantics(
        button: true,
        label: label == '−' ? 'One year less' : 'One year more',
        excludeSemantics: true,
        child: RoundedContainer(
          key: key,
          width: 44,
          height: 40,
          padding: EdgeInsets.zero,
          color: enabled
              ? colors.buttonBackSecondary
              : colors.buttonBackSecondary.withValues(alpha: 0.4),
          onPressed: enabled ? () => onChanged(to) : null,
          child: Center(
            child: Text(
              label,
              style: STextStyles.w600_18(context)
                  .copyWith(color: colors.buttonTextSecondary),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        step(
          '−',
          const Key('names-years-minus'),
          value > min ? value - 1 : null,
        ),
        Expanded(
          child: Text(
            NamesFormat.years(value),
            key: const Key('names-years-value'),
            textAlign: TextAlign.center,
            style: STextStyles.w600_14(context),
          ),
        ),
        step(
          '+',
          const Key('names-years-plus'),
          value < max ? value + 1 : null,
        ),
      ],
    );
  }
}

/// How urgent a name's status line is.
enum NameTone { good, soon, bad, neutral }

/// A name's status in words, from its record and the wallet's last block.
@immutable
class NameStatusText {
  const NameStatusText(this.text, this.tone, {this.saleLine});

  final String text;
  final NameTone tone;

  /// `For sale at 500 BEAM`, for a listed name.
  final String? saleLine;

  /// Days left before the name stops being active, or null when it is not.
  static int? daysLeft(BansDomain d, int tipHeight) {
    final s = d.statusAt(tipHeight);
    if (s != BansNameStatus.active && s != BansNameStatus.forSale) {
      return null;
    }
    return NamesFormat.daysBetween(tipHeight, d.expireHeight);
  }

  /// Whether the owner should renew [d] now.
  static bool needsRenewal(BansDomain d, int tipHeight) {
    final s = d.statusAt(tipHeight);
    if (s == BansNameStatus.onHold) return true;
    final left = daysLeft(d, tipHeight);
    return left != null && left <= kNamesRenewSoonDays;
  }

  static NameStatusText of(
    BansDomain d,
    BansClock clock,
    String Function(BansAmount) price,
  ) {
    final tip = clock.tipHeight;
    final sale = d.salePrice == null
        ? null
        : 'For sale at ${price(d.salePrice!)}';
    switch (d.statusAt(tip)) {
      case BansNameStatus.availableAgain:
        return const NameStatusText(
          'Expired · anyone can register it now',
          NameTone.neutral,
        );
      case BansNameStatus.onHold:
        final by = clock.dateOf(BansTimeline.holdEndHeight(d.expireHeight));
        return NameStatusText(
          'Expired · renew by ${NamesFormat.date(by)} to keep it',
          NameTone.bad,
          saleLine: sale,
        );
      case BansNameStatus.active:
      case BansNameStatus.forSale:
      case BansNameStatus.available:
        final left = NamesFormat.daysBetween(tip, d.expireHeight);
        if (left <= kNamesRenewSoonDays) {
          return NameStatusText(
            'Expires ${NamesFormat.inDays(left)}',
            NameTone.soon,
            saleLine: sale,
          );
        }
        return NameStatusText(
          'Active until ${NamesFormat.date(clock.dateOf(d.expireHeight))}',
          NameTone.good,
          saleLine: sale,
        );
    }
  }

  Color color(StackColors c) => switch (tone) {
    NameTone.good => c.accentColorGreen,
    NameTone.soon => c.accentColorYellow,
    NameTone.bad => c.accentColorRed,
    NameTone.neutral => c.textSubtitle1,
  };
}

/// A Names screen in Campfire's two shapes: a full page with an app bar on
/// mobile (like the send flow), a dialog body on desktop. The [bottom]
/// (the primary button and its reason) is pinned, so the main action is on
/// screen without scrolling at any height.
class NamesPage extends StatelessWidget {
  const NamesPage({
    super.key,
    required this.deps,
    required this.title,
    required this.body,
    this.bottom,
    this.onClose,
  });

  final BeamNamesDeps deps;
  final String title;
  final Widget body;
  final Widget? bottom;
  final VoidCallback? onClose;

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
          titleSpacing: 0,
          title: Text(
            title,
            style: STextStyles.navBarTitle(context),
            overflow: TextOverflow.ellipsis,
          ),
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

/// Opens a Names screen: pushed as a page on mobile, in a dialog on
/// desktop.
Future<T?> showNamesPage<T>(
  BuildContext context,
  BeamNamesDeps deps,
  WidgetBuilder builder,
) {
  if (deps.desktop) {
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: 780,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: builder(context),
        ),
      ),
    );
  }
  return Navigator.of(context).push<T>(MaterialPageRoute<T>(builder: builder));
}

/// The primary button with the reason it is off (or what is happening)
/// right above it, so a disabled button is never a dead end.
class NamesPrimaryAction extends StatelessWidget {
  const NamesPrimaryAction({
    super.key,
    required this.deps,
    required this.label,
    required this.onPressed,
    this.reason,
    this.buttonKey,
  });

  final BeamNamesDeps deps;
  final String label;

  /// Null disables the button.
  final VoidCallback? onPressed;
  final String? reason;
  final Key? buttonKey;

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
              key: const Key('names-cta-reason'),
              textAlign: TextAlign.center,
              style: STextStyles.smallMed12(context)
                  .copyWith(color: colors.textSubtitle1),
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

/// A full-width secondary action (Transfer, Sell, ...).
class NamesSecondaryAction extends StatelessWidget {
  const NamesSecondaryAction({
    super.key,
    required this.deps,
    required this.label,
    required this.onPressed,
  });

  final BeamNamesDeps deps;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SecondaryButton(
    label: label,
    enabled: onPressed != null,
    onPressed: onPressed,
    buttonHeight: deps.desktop ? ButtonHeight.m : null,
  );
}

/// Plain words for a failure: what happened and what to do, never blaming
/// the user (no dead ends).
String namesErrorText(Object e) => switch (e) {
  BansException() => e.message,
  BeamConnectionException() =>
    "Your wallet isn't connected to the BEAM network right now. It "
        'reconnects on its own; try again in a moment.',
  TimeoutException() =>
    'The BEAM network took too long to answer. Try again in a moment.',
  BeamRpcException(:final message) =>
    "Your wallet couldn't do that right now ($message). Try again; if it "
        'keeps happening, report it.',
  _ =>
    'Something went wrong on our side. Try again; if it keeps '
        'happening, report it.',
};
