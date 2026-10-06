/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';

/// "<dApp> asks for your approval" above the dApp page, shown before the
/// approval sheet for every request.
///
/// The sheet never opens by itself the moment a request arrives: the page
/// controls that moment, and could time it so the user's next tap lands on
/// Approve. With [autoOpenAfter] (the user just tapped the page, so the
/// request is probably theirs) the banner says the review is opening and
/// opens it after that visible delay; without it, it waits for "Review".
/// "Reject" works throughout.
class DappApprovalBanner extends StatefulWidget {
  const DappApprovalBanner({
    super.key,
    required this.dappName,
    required this.onAnswer,
    required this.isDesktop,
    this.autoOpenAfter,
  });

  /// How long the banner shows before it opens the review by itself, when
  /// the user just tapped the page.
  static const openDelay = Duration(milliseconds: 1200);

  static const reviewKey = Key("dappBannerReview");
  static const rejectKey = Key("dappBannerReject");

  final String dappName;

  /// Called once: true to open the review, false to reject.
  final ValueChanged<bool> onAnswer;
  final bool isDesktop;
  final Duration? autoOpenAfter;

  @override
  State<DappApprovalBanner> createState() => _DappApprovalBannerState();
}

class _DappApprovalBannerState extends State<DappApprovalBanner> {
  bool _answered = false;

  void _answer(bool review) {
    if (_answered || !mounted) return;
    _answered = true;
    widget.onAnswer(review);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = widget.isDesktop;
    final delay = widget.autoOpenAfter;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: RoundedContainer(
        color: colors.popupBG,
        borderColor: colors.textFieldDefaultBG,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "${widget.dappName} asks for your approval",
                        style: STextStyles.w600_14(context)
                            .copyWith(color: colors.textDark),
                      ),
                      if (delay != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          "Opening the review…",
                          style: STextStyles.w500_12(context)
                              .copyWith(color: colors.textSubtitle1),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SecondaryButton(
                  key: DappApprovalBanner.rejectKey,
                  label: "Reject",
                  width: 80,
                  buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
                  onPressed: () => _answer(false),
                ),
                const SizedBox(width: 8),
                PrimaryButton(
                  key: DappApprovalBanner.reviewKey,
                  label: "Review",
                  width: 84,
                  buttonHeight: desktop ? ButtonHeight.s : ButtonHeight.l,
                  onPressed: () => _answer(true),
                ),
              ],
            ),
            if (delay != null) ...[
              const SizedBox(height: 8),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: delay,
                onEnd: () => _answer(true),
                builder: (context, v, _) => LinearProgressIndicator(
                  value: v,
                  minHeight: 3,
                  color: colors.accentColorBlue,
                  backgroundColor: colors.textFieldDefaultBG,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
