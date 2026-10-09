/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — claim what was sent to my names:
//   1. Job: show exactly what claiming does (what arrives, the network fee,
//      who pays it) and do it after the user confirms with their PIN.
//   2. Primary CTA: "Claim 2.5 BEAM" (the outcome).
//   3. Taps from app open: Claim on the home (1), the CTA (2), PIN (3).
//
// Exit-intent check:
//   * A fee that changes after confirming: the sheet shows the fee of the
//     transaction the core actually built before the button turns on,
//     not a constant.
//   * A claim that silently costs more than it returns: said in plain words
//     before confirming, not forbidden.
//   * Silence after confirming: the sheet shows sending, then done or what
//     went wrong and that the payments are still safe.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../rounded_container.dart';
import '../airdrop/beam_blocks.dart';
import '../airdrop/beam_layout.dart';
import '../stickers/beam_sticker.dart';
import 'beam_home_controller.dart';
import 'beam_home_text.dart';

/// Asks for the user's PIN (mobile) or password (desktop). True only when
/// the user confirmed.
typedef BeamAuthGate = Future<bool> Function(BuildContext context);

enum _Phase { preparing, ready, prepareFailed, sending, done, failed }

/// The claim confirmation, as the content of a bottom sheet (mobile) or a
/// dialog (desktop).
class BeamClaimSheet extends StatefulWidget {
  const BeamClaimSheet({
    super.key,
    required this.controller,
    required this.summary,
    required this.beamAvailable,
    required this.authenticate,
    this.isDesktop = false,
  });

  /// The home's controller: sync state, and the wallet to claim with.
  final BeamHomeController controller;

  /// What the home showed when the user tapped Claim.
  final BansPendingSummary summary;

  /// Spendable BEAM in the wallet, in groth, for the fee advice.
  final BigInt beamAvailable;

  final BeamAuthGate authenticate;
  final bool isDesktop;

  @override
  State<BeamClaimSheet> createState() => _BeamClaimSheetState();
}

class _BeamClaimSheetState extends State<BeamClaimSheet> {
  late final BansClaimAdvice _advice = widget.summary.advise(
    beamAvailable: widget.beamAvailable,
  );
  late final VoidCallback _releaseNodeSwitch;

  _Phase _phase = _Phase.preparing;
  BansPrepared? _prepared;
  String? _error;
  String? _notConfirmed;
  bool _outcomeUnknown = false;
  bool _executed = false;

  BeamHomeController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    // No node handover while this sheet is open (R11).
    _releaseNodeSwitch = _c.source.holdNodeSwitch('claim name payments');
    _c.addListener(_onHome);
    _prepareIfAllowed();
  }

  @override
  void dispose() {
    _c.removeListener(_onHome);
    _releaseNodeSwitch();
    super.dispose();
  }

  void _onHome() {
    if (!mounted) return;
    setState(() {});
    _prepareIfAllowed();
  }

  bool get _allowed => _c.canSpend && _advice.canClaim;

  void _prepareIfAllowed() {
    if (_prepared != null || !_allowed) return;
    if (_phase != _Phase.preparing || _preparing) return;
    unawaited(_prepare());
  }

  bool _preparing = false;

  Future<void> _prepare() async {
    _preparing = true;
    try {
      final p = await _c.source.prepareClaimAll();
      if (!mounted) return;
      setState(() {
        _prepared = p;
        _phase = _Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.prepareFailed;
        _error = _prepareProblem(e);
      });
    } finally {
      _preparing = false;
    }
  }

  void _retryPrepare() {
    setState(() {
      _phase = _Phase.preparing;
      _prepared = null;
      _error = null;
    });
    _prepareIfAllowed();
  }

  Future<void> _confirm() async {
    final prepared = _prepared;
    if (prepared == null || _executed || !_allowed) return;
    setState(() => _notConfirmed = null);
    final ok = await widget.authenticate(context);
    if (!mounted) return;
    if (!ok) {
      setState(() => _notConfirmed = 'Not confirmed, so nothing was claimed.');
      return;
    }
    if (_executed) return;
    _executed = true;
    setState(() => _phase = _Phase.sending);
    try {
      await _c.source.executeClaim(prepared);
      if (!mounted) return;
      setState(() => _phase = _Phase.done);
    } catch (e) {
      if (!mounted) return;
      final unknown = e is BeamConnectionException || e is TimeoutException;
      setState(() {
        _phase = _Phase.failed;
        _outcomeUnknown = unknown;
        _error = unknown
            ? "The connection dropped while claiming, so it's not certain "
                  'the claim went out. Check your transaction history '
                  'before claiming again.'
            : '${_sendProblem(e)} Your payments are still waiting for you; '
                  'nothing was taken.';
      });
    } finally {
      // The inbox changed (or may have): read it again now.
      unawaited(_c.refreshNamesNow());
    }
  }

  static String _prepareProblem(Object e) => switch (e) {
    BansException(:final message) => message,
    BeamConnectionException() || TimeoutException() =>
      'The wallet did not answer in time. Check your connection, then try '
          'again. Your payments stay safe meanwhile.',
    BeamRpcException(:final message) =>
      'The wallet could not prepare the claim ("$message"). Try again in a '
          'moment. Your payments stay safe meanwhile.',
    _ =>
      'The claim could not be prepared. Try again in a moment. Your '
          'payments stay safe meanwhile.',
  };

  static String _sendProblem(Object e) => switch (e) {
    BansException(:final message) => message,
    BeamRpcException(:final message) =>
      'The wallet refused the claim ("$message").',
    _ => 'The claim was not sent.',
  };

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final text = BeamHomeText.claim(
      summary: widget.summary,
      advice: _advice,
      canSpend: _c.canSpend,
      built: _prepared?.summary,
    );
    final desktop = widget.isDesktop;
    final title = desktop
        ? STextStyles.desktopH3(context)
        : STextStyles.pageTitleH2(context);
    final label = desktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
        : STextStyles.itemSubtitle(context);
    final value = desktop
        ? STextStyles.desktopTextExtraExtraSmall600(context)
              .copyWith(color: c.textDark)
        : STextStyles.itemSubtitle12(context);
    final note =
        (desktop
                ? STextStyles.desktopTextExtraExtraSmall(context)
                : STextStyles.w500_12(context))
            .copyWith(color: c.textDark3);

    switch (_phase) {
      case _Phase.done:
        return _Result(
          isDesktop: desktop,
          title: 'Claim sent',
          message:
              'Your balance changes by ${text.balanceChange} once the '
              'network confirms it, usually within a few minutes.',
          primary: 'Done',
          onPrimary: _close,
          sticker: BeamAnimatedStickerView(
            BeamMoments.claimDone,
            key: const Key('beamClaimDoneSticker'),
            size: desktop ? 160 : 140,
          ),
        );
      case _Phase.failed:
        return _Result(
          isDesktop: desktop,
          title: _outcomeUnknown
              ? 'Not sure the claim went out'
              : 'The claim was not sent',
          message: _error ?? '',
          isProblem: true,
          primary: 'Close',
          onPrimary: _close,
          sticker: BeamStickerImage(
            BeamMoments.somethingWentWrong,
            size: desktop ? 140 : 120,
          ),
        );
      case _Phase.sending:
        return _Result(
          isDesktop: desktop,
          title: 'Claiming…',
          message:
              'Sending the claim to the BEAM network. This takes a few '
              'seconds.',
          busy: true,
        );
      case _Phase.preparing:
      case _Phase.ready:
      case _Phase.prepareFailed:
        break;
    }

    Widget row(String name, List<String> values, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(name, style: label)),
          const SizedBox(width: 12),
          Flexible(
            flex: 2,
            child: Column(
              key: key,
              // Aligned like the one-line values in the other rows.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final v in values) SelectableText(v, style: value),
              ],
            ),
          ),
        ],
      ),
    );

    final cancel = SecondaryButton(
      label: 'Cancel',
      buttonHeight: desktop ? ButtonHeight.l : null,
      onPressed: _close,
    );
    final Widget primary = _phase == _Phase.prepareFailed
        ? PrimaryButton(
            label: 'Try again',
            buttonHeight: desktop ? ButtonHeight.l : null,
            onPressed: _retryPrepare,
          )
        : PrimaryButton(
            key: const Key('beamClaimConfirm'),
            label: text.cta,
            enabled: _phase == _Phase.ready && text.blocker == null,
            buttonHeight: desktop ? ButtonHeight.l : null,
            onPressed: _phase == _Phase.ready && text.blocker == null
                ? _confirm
                : null,
          );

    final blocker = text.blocker;
    final preparing = _phase == _Phase.preparing && blocker == null;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        desktop ? 32 : 16,
        desktop ? 0 : 16,
        desktop ? 32 : 16,
        desktop ? 32 : 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text.headline, style: title),
          const SizedBox(height: 16),
          RoundedContainer(
            color: desktop ? c.textFieldDefaultBG : c.popupBG,
            borderColor: desktop ? null : c.textFieldDefaultBG,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                row(
                  'You receive',
                  text.receive,
                  key: const Key('beamClaimReceive'),
                ),
                if (text.from != null) row('Sent to', [text.from!]),
                row(_prepared == null ? 'Network fee (about)' : 'Network fee', [
                  text.fee,
                ], key: const Key('beamClaimFee')),
              ],
            ),
          ),
          const SizedBox(height: 8),
          BeamLayoutScope(
            desktop: desktop,
            child: BeamTotalRow(
              label: 'Your balance changes by',
              value: text.balanceChange,
              valueKey: const Key('beamClaimBalanceChange'),
              confirm: false,
            ),
          ),
          if (text.feeNote != null) ...[
            const SizedBox(height: 8),
            Text(text.feeNote!, style: note),
          ],
          if (text.warning != null) ...[
            const SizedBox(height: 12),
            RoundedContainer(
              key: const Key('beamClaimWarning'),
              color: c.warningBackground,
              child: Text(
                text.warning!,
                style: note.copyWith(color: c.warningForeground),
              ),
            ),
          ],
          if (text.batches != null) ...[
            const SizedBox(height: 12),
            Text(text.batches!, style: note),
          ],
          if (blocker != null) ...[
            const SizedBox(height: 12),
            Text(
              blocker,
              key: const Key('beamClaimBlocker'),
              style: note.copyWith(color: c.textError),
            ),
          ],
          if (_phase == _Phase.prepareFailed && _error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: note.copyWith(color: c.textError)),
          ],
          if (_notConfirmed != null) ...[
            const SizedBox(height: 12),
            Text(_notConfirmed!, style: note),
          ],
          if (preparing) ...[
            const SizedBox(height: 12),
            Text(
              'Checking the exact fee with the wallet…',
              key: const Key('beamClaimPreparing'),
              style: note,
            ),
          ],
          SizedBox(height: desktop ? 32 : 24),
          if (desktop)
            Row(
              children: [
                Expanded(child: cancel),
                const SizedBox(width: 16),
                Expanded(child: primary),
              ],
            )
          else ...[
            // One dominant button, full width, so a long amount still
            // fits a 375 px phone; Cancel under it.
            primary,
            const SizedBox(height: 12),
            cancel,
          ],
        ],
      ),
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.isDesktop,
    required this.title,
    required this.message,
    this.primary,
    this.onPrimary,
    this.isProblem = false,
    this.busy = false,
    this.sticker,
  });

  final bool isDesktop;
  final String title;
  final String message;
  final String? primary;
  final VoidCallback? onPrimary;
  final bool isProblem;
  final bool busy;

  /// The Beam girl, above the words (never on the confirm step).
  final Widget? sticker;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 32 : 16,
        isDesktop ? 0 : 16,
        isDesktop ? 32 : 16,
        isDesktop ? 32 : 16,
      ),
      child: Column(
        key: Key('beamClaimResult-$title'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (sticker != null) ...[
            Center(child: sticker),
            const SizedBox(height: 12),
          ],
          Text(
            title,
            style:
                (isDesktop
                        ? STextStyles.desktopH3(context)
                        : STextStyles.pageTitleH2(context))
                    .copyWith(color: isProblem ? c.textError : null),
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style:
                (isDesktop
                        ? STextStyles.desktopTextExtraExtraSmall(context)
                        : STextStyles.w500_14(context))
                    .copyWith(color: c.textDark3),
          ),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: c.textFieldDefaultBG,
              valueColor: AlwaysStoppedAnimation(c.accentColorGreen),
            ),
          ],
          if (primary != null) ...[
            SizedBox(height: isDesktop ? 32 : 24),
            PrimaryButton(
              label: primary,
              buttonHeight: isDesktop ? ButtonHeight.l : null,
              onPressed: onPrimary,
            ),
          ],
        ],
      ),
    );
  }
}
