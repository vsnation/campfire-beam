/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The card under the Send screen's recipient field.
//
// Spec (USER_PSYCHOLOGY §6):
//   1. Job: show, before anything is built, who a typed name pays — or why
//      it can't be paid — so a name is never resolved silently.
//   2. Primary CTA: none here (the screen's "Send"); "Try again" is a text
//      link on a failed lookup only.
//   3. Taps: 0 — it appears as the user types.
//
// Exit-intent (§1.7): "is this the right person?" → owner key fingerprint
// and expiry; "why can't I send?" → every not-payable state says what to do;
// "is it stuck?" → a skeleton with the name being looked up.

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:intl/intl.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_recipient.dart';
import '../../../wallets/beam/contracts/bans/bans_timeline.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../rounded_white_container.dart';
import 'beam_send_widgets.dart';

/// "18 May 2028". Dates from heights are estimates (one block a minute).
String beamDate(DateTime d) => DateFormat('d MMM y').format(d.toLocal());

/// The resolution card for a name in the recipient field.
class BeamNameCard extends StatelessWidget {
  const BeamNameCard({
    super.key,
    required this.state,
    required this.onRetry,
    required this.typedText,
  });

  final BansRecipientState state;
  final VoidCallback onRetry;

  /// What the user typed, to tell a mistyped address from a name.
  final String typedText;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const Key('beamNameCard'),
      child: switch (state) {
        BansRecipientResolving(:final name) => _Resolving(name),
        final BansRecipientPayable s => _Payable(s),
        BansRecipientNotPayable(:final name, :final status) => BeamNotice(
          kind: BeamNoticeKind.error,
          title: status == BansNameStatus.availableAgain
              ? '${name.display} has expired'
              : 'No one owns ${name.display}',
          message: status == BansNameStatus.availableAgain
              ? '${name.display} has expired; payments to it are refused. '
                    'Ask the person for their address or their new name.'
              : 'Check the spelling, or ask for their address.'
                    '${typedText.trim().length >= 26 ? ' If you pasted an '
                              "address, it isn't a BEAM address." : ''}',
        ),
        BansRecipientFailed(:final name, :final error) => BeamNotice(
          kind: BeamNoticeKind.error,
          title: "Couldn't check ${name.display}",
          message: _failure(error),
          action: CustomTextButton(text: 'Try again', onTap: onRetry),
        ),
      },
    );
  }

  static String _failure(Object e) {
    if (e is BansException) return e.message;
    if (e is BeamWalletException) return e.message;
    if (e is BeamConnectionException) return BeamWalletMessages.notOpen;
    return "The BEAM network didn't answer the lookup this time. Try "
        'again in a moment.';
  }
}

class _Resolving extends StatelessWidget {
  const _Resolving(this.name);

  final BansName name;

  @override
  Widget build(BuildContext context) {
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Looking up ${name.display}…',
            style: STextStyles.itemSubtitle12(context),
          ),
          const SizedBox(height: 10),
          const BeamSkeletonLine(width: 180),
          const SizedBox(height: 8),
          const BeamSkeletonLine(width: 240),
        ],
      ),
    );
  }
}

class _Payable extends StatelessWidget {
  const _Payable(this.s);

  final BansRecipientPayable s;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final r = s.resolution;
    final expires = r.expiresAt;
    final holdEnds = r.holdEndsAt;
    final listed = r.domain?.isListed ?? false;
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SvgPicture.asset(
                Assets.svg.checkCircle,
                width: 16,
                height: 16,
                colorFilter: ColorFilter.mode(
                  c.accentColorGreen,
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.name.display,
                  style: STextStyles.titleBold12(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'Registered name',
                style: STextStyles.label(context)
                    .copyWith(color: c.accentColorGreen),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            'Owner key ${BansKey.fingerprint(s.ownerKey)}'
            '${!s.onHold && expires != null ? ' · active until '
                      '${beamDate(expires)}' : ''}',
            key: const Key('beamNameCardOwner'),
            style: STextStyles.label(context),
          ),
          const SizedBox(height: 6),
          Text(
            'Anonymous name payment: the amount is visible on the '
            'blockchain, the recipient is not. They claim it from their '
            'wallet.',
            style: STextStyles.label(context).copyWith(color: c.textDark3),
          ),
          if (s.onHold) ...[
            const SizedBox(height: 8),
            BeamNotice(
              kind: BeamNoticeKind.warning,
              title: 'This name has lapsed',
              message:
                  'It expired${expires == null ? '' : ' on '
                            '${beamDate(expires)}'}. Payments still reach '
                  'its owner, who can renew it'
                  '${holdEnds == null ? '' : ' until ${beamDate(holdEnds)}'}'
                  '. If they don\'t, it can pass to someone else.',
            ),
          ],
          if (listed && !s.onHold) ...[
            const SizedBox(height: 8),
            const BeamNotice(
              kind: BeamNoticeKind.warning,
              message:
                  'This name is listed for sale. It may change owner before '
                  'your payment arrives.',
            ),
          ],
          if (s.maybeStale) ...[
            const SizedBox(height: 8),
            const BeamNotice(
              kind: BeamNoticeKind.warning,
              message:
                  'Your wallet was still catching up when this was checked, '
                  'so it may be out of date. It is checked again before '
                  'anything is sent.',
            ),
          ],
        ],
      ),
    );
  }
}

/// The note under an address in the recipient field: its type in plain
/// words, or why it can't be paid yet.
class BeamAddressNote extends StatelessWidget {
  const BeamAddressNote({super.key, required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => BeamNotice(
    key: const Key('beamAddressNote'),
    kind: BeamNoticeKind.info,
    title: title,
    message: note,
  );
}
