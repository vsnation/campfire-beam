/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM wallet home, as plain widgets: they take finished text and
// callbacks, read no providers, and are built from Campfire's own pieces
// (STextStyles, StackColors, RoundedContainer, CustomTextButton), so they
// look native in every Campfire theme. beam_wallet_home.dart connects them
// to the wallet.
//
// Spec (USER_PSYCHOLOGY §6) — the wallet home:
//   1. Job: show what the user has (spendable BEAM, what is arriving, what
//      waits for their names) and whether it is safe to send right now.
//   2. Primary CTA: Send (Campfire's bottom bar). "Claim" on the names line
//      is secondary and only there when something waits.
//   3. Taps from app open: 0 to see the balance; Send 1; Claim 1 (+ confirm
//      + PIN, because it moves money).
//
// Exit-intent check (§1.7) — what would make an impatient person close it:
//   * A spinner over the balance, or a balance that jumps when live data
//     lands: the balance renders from Campfire's cache at once and the lines
//     under it keep their slots (R11).
//   * A bare "0 BEAM" after a restore: the card says it is still scanning.
//   * A Send button that fails for no visible reason: it is dimmed, and a
//     tap says why and when it comes back.
//   * A sync bar that flashes on every open: non-urgent banners wait a few
//     seconds before showing.
//   Not fixable here: a BEAM core missing from the build (the banner says
//   so plainly and names the fix).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../rounded_container.dart';
import '../../wallet_navigation_bar/components/icons/send_nav_icon.dart';
import '../stickers/beam_sticker.dart';
import 'beam_home_text.dart';

StackColors _colors(BuildContext context) =>
    Theme.of(context).extension<StackColors>()!;

/// The lines of the balance area, already worded and formatted.
class BeamBalanceLines {
  const BeamBalanceLines({
    required this.spendable,
    this.title = 'Available balance',
    this.fiat,
    this.reserveFiat = false,
    this.arriving,
    this.scanning,
    this.portfolio,
    this.reservePortfolio = false,
  });

  final String title;

  /// "12.5 BEAM", Campfire's formatter.
  final String spendable;

  /// "0.11 USD", or null while no price is known.
  final String? fiat;

  /// Keep the fiat line's space even before a price arrives (prices on).
  final bool reserveFiat;

  /// "+ 0.5 BEAM arriving".
  final String? arriving;

  /// "Scanning for your coins… 43%" after a restore.
  final String? scanning;

  final BeamPortfolioText? portfolio;

  /// Keep two lines for the portfolio (the wallet holds other assets, which
  /// the cache already says), so pricing them later moves nothing.
  final bool reservePortfolio;
}

// ---------------------------------------------------------------- node chip

/// "Public node" / "Private node syncing 43%" / "Private node". Small and
/// secondary; tapping it opens the wallet's network settings.
class BeamNodeChip extends StatelessWidget {
  const BeamNodeChip({
    super.key,
    required this.label,
    required this.isPrivate,
    this.onCard = false,
    this.onTap,
  });

  final String label;
  final bool isPrivate;

  /// Drawn on the coloured coin card (mobile) rather than on white.
  final bool onCard;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final fg = onCard ? c.textFavoriteCard : c.textSubtitle1;
    final dot = isPrivate ? c.accentColorGreen : fg.withValues(alpha: 0.6);
    return Semantics(
      button: onTap != null,
      label: '$label. Opens network settings.',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: onCard
                ? c.textFavoriteCard.withValues(alpha: 0.12)
                : c.textFieldDefaultBG,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w500_10(context).copyWith(color: fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- mobile card

/// The content of Campfire's coin card for a BEAM wallet (mobile), in the
/// place of `WalletSummaryInfo`: spendable BEAM big, then fiat, what is
/// arriving, and the estimate with other assets.
class BeamBalanceCardContent extends StatelessWidget {
  const BeamBalanceCardContent({
    super.key,
    required this.lines,
    this.icon,
    this.refreshButton,
    this.nodeChip,
  });

  final BeamBalanceLines lines;
  final Widget? icon;
  final Widget? refreshButton;
  final Widget? nodeChip;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final small = STextStyles.w500_12(context)
        .copyWith(color: c.textFavoriteCard.withValues(alpha: 0.85));

    Widget line(String? text, TextStyle style, {Key? key}) => Text(
      text ?? '',
      key: key,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style.copyWith(height: 1.3),
    );

    final p = lines.portfolio;
    // The card has a fixed shape; on a phone narrower than 375 px the
    // lowest line is clipped rather than painted outside the card.
    return Row(
      children: [
        Expanded(
          child: ClipRect(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  lines.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.subtitle500(context)
                      .copyWith(color: c.textFavoriteCard),
                ),
                // On its own line: "Private node syncing 43%" does not fit
                // beside the title on a 375 px phone.
                if (nodeChip != null) ...[const SizedBox(height: 6), nodeChip!],
                const Spacer(),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SelectableText(
                    lines.spendable,
                    key: const Key('beamHomeSpendable'),
                    style: STextStyles.pageTitleH1(context)
                        .copyWith(fontSize: 24, color: c.textFavoriteCard),
                  ),
                ),
                if (lines.fiat != null || lines.reserveFiat)
                  line(
                    lines.fiat,
                    STextStyles.subtitle500(context)
                        .copyWith(color: c.textFavoriteCard),
                  ),
                if (lines.scanning != null)
                  line(lines.scanning, small, key: const Key('beamHomeScan')),
                if (lines.arriving != null)
                  line(
                    lines.arriving,
                    small,
                    key: const Key('beamHomeArriving'),
                  ),
                if (p != null || lines.reservePortfolio) ...[
                  line(p?.total, small),
                  line(p?.note, small),
                ],
              ],
            ),
          ),
        ),
        Column(
          children: [
            if (icon != null) SizedBox(width: 24, height: 24, child: icon),
            const Spacer(),
            ?refreshButton,
          ],
        ),
      ],
    );
  }
}

// ------------------------------------------------------------ desktop card

/// The desktop header's balance block for a BEAM wallet, next to the coin
/// icon (the slot `DesktopWalletSummary` fills for other coins).
class BeamDesktopBalance extends StatelessWidget {
  const BeamDesktopBalance({
    super.key,
    required this.lines,
    this.refreshButton,
    this.nodeChip,
    this.namePayments,
  });

  final BeamBalanceLines lines;
  final Widget? refreshButton;
  final Widget? nodeChip;

  /// The name payments line, directly under the balance.
  final Widget? namePayments;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final small = STextStyles.desktopTextExtraExtraSmall(context)
        .copyWith(color: c.textSubtitle1);
    Widget line(String? text, TextStyle style) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(text ?? '', maxLines: 1, style: style),
    );
    final p = lines.portfolio;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              lines.spendable,
              key: const Key('beamHomeSpendable'),
              style: STextStyles.desktopH3(context),
            ),
            if (lines.fiat != null || lines.reserveFiat)
              line(
                lines.fiat,
                STextStyles.desktopTextExtraSmall(context)
                    .copyWith(color: c.textSubtitle1),
              ),
            if (lines.scanning != null) line(lines.scanning, small),
            if (lines.arriving != null) line(lines.arriving, small),
            if (p != null || lines.reservePortfolio) ...[
              line(p?.total, small),
              line(p?.note, small),
            ],
            if (namePayments != null) ...[
              const SizedBox(height: 8),
              namePayments!,
            ],
          ],
        ),
        const SizedBox(width: 8),
        ?refreshButton,
        if (nodeChip != null) ...[const SizedBox(width: 8), nodeChip!],
      ],
    );
  }
}

// ------------------------------------------------------------ name payments

/// "Sent to your name alice.beam: 2.5 BEAM · Claim". Never part of the
/// spendable balance: the money is in the name vault until claimed.
class BeamNamePaymentsLine extends StatelessWidget {
  const BeamNamePaymentsLine({
    super.key,
    required this.text,
    required this.onClaim,
    this.isDesktop = false,
  });

  final BeamNamePaymentsText text;
  final VoidCallback onClaim;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    if (isDesktop) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${text.lead}: '),
                  TextSpan(
                    text: text.amounts,
                    style: STextStyles.desktopTextExtraExtraSmall600(context),
                  ),
                ],
              ),
              key: const Key('beamHomeNamePayments'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: STextStyles.desktopTextExtraExtraSmall(context)
                  .copyWith(color: c.textSubtitle1),
            ),
          ),
          const SizedBox(width: 4),
          CustomTextButton(
            key: const Key('beamHomeClaim'),
            text: 'Claim',
            textSize: 14,
            onTap: onClaim,
          ),
        ],
      );
    }
    return Semantics(
      button: true,
      label: '${text.line}. Claim.',
      excludeSemantics: true,
      child: RoundedContainer(
        key: const Key('beamHomeClaim'),
        color: c.popupBG,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        onPressed: onClaim,
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${text.lead}: ',
                      style: STextStyles.w500_12(context)
                          .copyWith(color: c.textDark3),
                    ),
                    TextSpan(
                      text: text.amounts,
                      style: STextStyles.w600_14(context)
                          .copyWith(color: c.textDark),
                    ),
                  ],
                ),
                key: const Key('beamHomeNamePayments'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text('Claim', style: STextStyles.link2(context)),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- sync banner

/// The honest sync banner (R5). Shows nothing when the wallet is up to date.
/// A non-[BeamBannerContent.urgent] banner waits [grace] before appearing,
/// so the usual second of "connecting" on open never flashes (R11).
class BeamSyncBanner extends StatefulWidget {
  const BeamSyncBanner({
    super.key,
    required this.content,
    required this.onAction,
    this.isDesktop = false,
    this.grace = const Duration(seconds: 3),
    this.padding = EdgeInsets.zero,
  });

  final BeamBannerContent? content;
  final void Function(BeamHomeAction action) onAction;
  final bool isDesktop;
  final Duration grace;

  /// Around the banner when it shows (nothing when it does not).
  final EdgeInsets padding;

  @override
  State<BeamSyncBanner> createState() => _BeamSyncBannerState();
}

class _BeamSyncBannerState extends State<BeamSyncBanner> {
  Timer? _timer;
  bool _graceOver = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(BeamSyncBanner old) {
    super.didUpdateWidget(old);
    final was = old.content;
    final now = widget.content;
    if (now == null) {
      _timer?.cancel();
      _timer = null;
      _graceOver = false;
    } else if (was == null) {
      _arm();
    }
  }

  void _arm() {
    final content = widget.content;
    if (content == null || content.urgent || _graceOver) return;
    _timer ??= Timer(widget.grace, () {
      _timer = null;
      if (mounted) setState(() => _graceOver = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final visible = content != null && (content.urgent || _graceOver);
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      alignment: Alignment.topCenter,
      child: visible
          ? Padding(
              padding: widget.padding,
              child: _BannerBody(
                content: content,
                isDesktop: widget.isDesktop,
                onAction: widget.onAction,
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}

class _BannerBody extends StatelessWidget {
  const _BannerBody({
    required this.content,
    required this.isDesktop,
    required this.onAction,
  });

  final BeamBannerContent content;
  final bool isDesktop;
  final void Function(BeamHomeAction action) onAction;

  /// The Beam girl, small and to the side: secondary to the words.
  static BeamSticker _sticker(BeamBannerMood mood) => switch (mood) {
    BeamBannerMood.syncing => BeamMoments.syncing,
    BeamBannerMood.behind => BeamMoments.behindOrOffline,
    BeamBannerMood.broken => BeamMoments.somethingWentWrong,
  };

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final calm = content.tone == BeamBannerTone.progress;
    final titleStyle = isDesktop
        ? STextStyles.desktopTextSmall(context)
        : STextStyles.w600_14(context).copyWith(color: c.textDark);
    final detailStyle = isDesktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
              .copyWith(color: c.textDark3)
        : STextStyles.w500_12(context).copyWith(color: c.textDark3);
    final label = content.actionLabel;
    final Widget? action =
        label != null && content.action != BeamHomeAction.none
        ? CustomTextButton(
            key: const Key('beamHomeSyncAction'),
            text: label,
            textSize: isDesktop ? 14 : 13,
            onTap: () => onAction(content.action),
          )
        : null;
    return Semantics(
      liveRegion: true,
      child: RoundedContainer(
        key: const Key('beamHomeSyncBanner'),
        color: calm ? c.popupBG : c.warningBackground,
        padding: EdgeInsets.all(isDesktop ? 16 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BeamStickerImage(
              _sticker(content.mood),
              key: Key('beamHomeSyncSticker-${content.mood.name}'),
              size: isDesktop ? 64 : 52,
            ),
            SizedBox(width: isDesktop ? 16 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Text(content.title, style: titleStyle)),
                      // Desktop has room beside the title; on a phone the
                      // button goes under the text so the title keeps the
                      // width.
                      if (action != null && isDesktop)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: action,
                        ),
                    ],
                  ),
                  if (content.detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(content.detail!, style: detailStyle),
                    ),
                  if (content.progress != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          key: const Key('beamHomeSyncProgress'),
                          value: content.progress,
                          minHeight: 3,
                          backgroundColor: c.textFieldDefaultBG,
                          valueColor: AlwaysStoppedAnimation(
                            c.accentColorGreen,
                          ),
                        ),
                      ),
                    ),
                  if (action != null && !isDesktop)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: action,
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

// ---------------------------------------------------------------- send nav

/// Campfire's Send icon, dimmed while sending is off.
class BeamSendNavIcon extends StatelessWidget {
  const BeamSendNavIcon({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) =>
      Opacity(opacity: enabled ? 1 : 0.35, child: const SendNavIcon());
}

/// The "Send" label, dimmed while sending is off.
class BeamSendNavLabel extends StatelessWidget {
  const BeamSendNavLabel({super.key, required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context) => Text(
    'Send',
    key: Key(enabled ? 'beamSendEnabled' : 'beamSendDisabled'),
    style: STextStyles.buttonSmall(context).copyWith(
      color: _colors(context).bottomNavText
          .withValues(alpha: enabled ? 1 : 0.35),
    ),
  );
}
