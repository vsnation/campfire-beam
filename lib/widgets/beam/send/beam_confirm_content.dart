/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM body of Campfire's "Confirm transaction" screen
// (ConfirmTransactionView keeps the PIN / password gate and the sending).
//
// Spec:
//   1. Job: show exactly what will happen — who receives it, how much, in
//      which asset, the network fee and the total — before anything is
//      signed.
//   2. Primary CTA: "Send 1.5 BEAM" / "Send to alice.beam", then PIN.
//   3. Taps from app open: wallet → Send → "Send" → this button (3), PIN.
//
// Exit-intent: "is this the right person?" → full address on copy,
// owner key of a name; "what does it cost?" → fee decoded from the built
// payment and a total; "can people see this?" → a name payment says the
// amount is public.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_send_rules.dart';
import '../../background.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../desktop/primary_button.dart';
import '../../rounded_container.dart';
import '../../rounded_white_container.dart';
import 'beam_send_format.dart';
import 'beam_send_review.dart';
import 'beam_send_widgets.dart';

/// Campfire's back arrow, with the layout passed in.
class BeamBackButton extends StatelessWidget {
  const BeamBackButton({super.key, required this.desktop, this.onPressed});

  final bool desktop;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: desktop
          ? const EdgeInsets.symmetric(vertical: 20, horizontal: 24)
          : const EdgeInsets.all(10),
      child: AppBarIconButton(
        semanticsLabel: 'Back Button. Takes Back To Previous Page.',
        size: desktop ? 40 : 32,
        color: desktop ? c.textFieldDefaultBG : c.background,
        icon: SvgPicture.asset(
          Assets.svg.arrowLeft,
          width: 24,
          height: 24,
          colorFilter: ColorFilter.mode(c.topNavIconPrimary, BlendMode.srcIn),
        ),
        onPressed: onPressed ?? () => Navigator.of(context).pop(),
      ),
    );
  }
}

class BeamConfirmContent extends StatefulWidget {
  const BeamConfirmContent({
    super.key,
    required this.review,
    required this.desktop,
    required this.onSend,
    this.clipboard = const ClipboardWrapper(),
  });

  final BeamSendReview review;
  final bool desktop;

  /// Campfire's gate, then the send (ConfirmTransactionView).
  final VoidCallback onSend;
  final ClipboardInterface clipboard;

  @override
  State<BeamConfirmContent> createState() => _BeamConfirmContentState();
}

class _BeamConfirmContentState extends State<BeamConfirmContent> {
  late BeamSyncAssessment _sync;
  StreamSubscription<BeamSyncAssessment>? _sub;

  BeamSendReview get r => widget.review;
  bool get _desktop => widget.desktop;

  @override
  void initState() {
    super.initState();
    _sync = r.backend.syncAssessment;
    _sub = r.backend.syncAssessments.listen((a) {
      if (mounted) setState(() => _sync = a);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _copy(String text, String what) async {
    await widget.clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.info,
          message: '$what copied',
          iconAsset: Assets.svg.copy,
          context: context,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = _details(context);
    final bottom = _bottom(context);
    if (_desktop) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const BeamBackButton(desktop: true),
              Expanded(
                child: Text(
                  'Confirm ${BeamSendFormat.symbol(r.asset)} transaction',
                  style: STextStyles.desktopH3(context),
                ),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: details,
            ),
          ),
          const SizedBox(height: 23),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: bottom,
          ),
          const SizedBox(height: 32),
        ],
      );
    }
    final c = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: c.background,
        appBar: AppBar(
          backgroundColor: c.background,
          leading: const BeamBackButton(desktop: false),
          title: Text(
            'Confirm transaction',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: details,
                ),
              ),
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

  // ---------------------------------------------------------------- body

  Widget _details(BuildContext context) {
    final rows = <Widget>[
      _recipient(context),
      _row(
        context,
        label: 'Amount',
        value: BeamSendFormat.amount(r.amount, r.asset),
        valueKey: const Key('beamConfirmAmount'),
      ),
      _assetRow(context),
      _row(
        context,
        label: 'Network fee',
        value: BeamSendFormat.beam(r.fee),
        valueKey: const Key('beamConfirmFee'),
        note: r.isName
            ? 'Read from the payment your wallet built. Paying a name costs '
                  'more than paying an address.'
            : null,
      ),
      if (r.comment.isNotEmpty)
        _row(
          context,
          label: 'Comment',
          value: r.comment,
          note: r.isName ? 'Only you see this.' : 'The receiver sees this too.',
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_desktop) ...[
          Text(
            'Send ${BeamSendFormat.symbol(r.asset)}',
            style: STextStyles.pageTitleH1(context),
          ),
          const SizedBox(height: 12),
        ],
        for (final w in rows) ...[w, const SizedBox(height: 12)],
      ],
    );
  }

  Widget _box({required Widget child}) => _desktop
      ? RoundedContainer(
          color: Colors.transparent,
          borderColor: Theme.of(context)
              .extension<StackColors>()!
              .textFieldDefaultBG,
          padding: const EdgeInsets.all(16),
          child: child,
        )
      : RoundedWhiteContainer(padding: const EdgeInsets.all(12), child: child);

  TextStyle _labelStyle(BuildContext context) => _desktop
      ? STextStyles.desktopTextExtraExtraSmall(context)
      : STextStyles.smallMed12(context);

  TextStyle _valueStyle(BuildContext context) => _desktop
      ? STextStyles.desktopTextExtraExtraSmall(
          context,
        ).copyWith(color: Theme.of(context).extension<StackColors>()!.textDark)
      : STextStyles.itemSubtitle12(context);

  Widget _row(
    BuildContext context, {
    required String label,
    required String value,
    Key? valueKey,
    String? note,
  }) {
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: _labelStyle(context)),
              const SizedBox(width: 12),
              Flexible(
                child: SelectableText(
                  value,
                  key: valueKey,
                  style: _valueStyle(context),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 4),
            Text(note, style: STextStyles.label(context)),
          ],
        ],
      ),
    );
  }

  Widget _assetRow(BuildContext context) {
    final warn = beamImpersonationWarning(r.asset);
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Asset', style: _labelStyle(context)),
              const Spacer(),
              BeamAssetIcon(r.asset, size: 18),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    BeamSendFormat.symbol(r.asset),
                    key: const Key('beamConfirmAsset'),
                    style: _valueStyle(context),
                  ),
                  BeamAssetBadge(r.asset),
                ],
              ),
            ],
          ),
          if (warn != null) ...[
            const SizedBox(height: 8),
            BeamNotice(kind: BeamNoticeKind.warning, message: warn),
          ],
        ],
      ),
    );
  }

  Widget _recipient(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    if (r.isName) {
      return _box(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Send to', style: _labelStyle(context)),
            const SizedBox(height: 4),
            Text(
              r.destination,
              key: const Key('beamConfirmRecipient'),
              style: _desktop
                  ? STextStyles.desktopTextSmall(context)
                  : STextStyles.titleBold12(context).copyWith(fontSize: 16),
            ),
            const SizedBox(height: 4),
            SelectableText(
              'Owner key ${r.ownerFingerprint}',
              key: const Key('beamConfirmOwner'),
              style: STextStyles.label(context),
            ),
            const SizedBox(height: 8),
            Text(
              'Anonymous name payment: the amount is visible on the '
              'blockchain, the recipient is not. The name is checked once '
              'more right before sending, and nothing is sent if its owner '
              'changed.',
              style: STextStyles.label(context).copyWith(color: c.textDark3),
            ),
            if (r.nameOnHold) ...[
              const SizedBox(height: 8),
              const BeamNotice(
                kind: BeamNoticeKind.warning,
                message:
                    'This name has lapsed. Payments still reach its owner '
                    'for now, but it may pass to someone else if they '
                    "don't renew it.",
              ),
            ],
            if (r.nameListed && !r.nameOnHold) ...[
              const SizedBox(height: 8),
              const BeamNotice(
                kind: BeamNoticeKind.warning,
                message:
                    'This name is listed for sale. It may change owner '
                    'before your payment arrives.',
              ),
            ],
          ],
        ),
      );
    }
    final type = r.addressType;
    final regular =
        type == BeamAddressType.regular || type == BeamAddressType.regularNew;
    final how = type == null || type == BeamAddressType.unknown
        ? null
        : BeamSendMode.forType(type).explanation;
    return _box(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Send to', style: _labelStyle(context)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  BeamSendFormat.shortAddress(r.destination, keep: 10),
                  key: const Key('beamConfirmRecipient'),
                  style: _valueStyle(context),
                ),
              ),
              IconButton(
                key: const Key('beamConfirmCopyAddress'),
                tooltip: 'Copy the full address',
                onPressed: () => _copy(r.destination, 'Address'),
                icon: SvgPicture.asset(
                  Assets.svg.copy,
                  width: 16,
                  height: 16,
                  colorFilter: ColorFilter.mode(
                    c.infoItemIcons,
                    BlendMode.srcIn,
                  ),
                ),
              ),
            ],
          ),
          if (how != null)
            Text(
              regular
                  ? "Regular BEAM address. The receiver's wallet must be "
                        'online to accept this payment.'
                  : how,
              key: const Key('beamConfirmAddressType'),
              style: STextStyles.label(context),
            ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- bottom

  Widget _bottom(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final syncMessage = _sync.canSpend
        ? null
        : BeamSyncMessages.describe(_sync);
    final totalStyle = _desktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
              .copyWith(color: c.textConfirmTotalAmount)
        : STextStyles.titleBold12(context)
              .copyWith(color: c.textConfirmTotalAmount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RoundedContainer(
          padding: _desktop
              ? const EdgeInsets.symmetric(horizontal: 16, vertical: 18)
              : const EdgeInsets.all(12),
          color: c.snackBarBackSuccess,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _desktop ? 'Total amount to send' : 'Total',
                style: totalStyle,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: SelectableText(
                  r.totalText,
                  key: const Key('beamConfirmTotal'),
                  style: totalStyle,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
        if (syncMessage != null) ...[
          const SizedBox(height: 12),
          BeamNotice(
            kind: BeamNoticeKind.warning,
            title: syncMessage.title,
            message: syncMessage.detail ?? "Sending is paused until it's done.",
          ),
        ],
        SizedBox(height: _desktop ? 28 : 16),
        PrimaryButton(
          key: const Key('beamConfirmSendButton'),
          label: r.sendLabel,
          buttonHeight: _desktop ? ButtonHeight.l : null,
          enabled: _sync.canSpend,
          onPressed: _sync.canSpend ? widget.onSend : null,
        ),
      ],
    );
  }
}
