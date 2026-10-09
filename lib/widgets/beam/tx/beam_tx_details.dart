/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — BEAM transaction details:
//   Job:  show exactly what happened to one payment, and offer the one
//         thing that can still be done about it.
//   CTA:  while a payment can still be stopped: "Cancel payment" (pinned,
//         visible at 375 px). Otherwise none dominant; proof and removal
//         are secondary.
//   Taps: open wallet → entry (1) → Cancel payment → confirm (3).
//
// Exit-intent, and what this screen does about each:
//   * "Is my money gone?" → the status says it in words; failed and
//     cancelled payments say "Nothing was sent".
//   * "What is this hex?" → the only ID shown is the one the explorer uses,
//     with an info button; addresses are shortened, full value on copy.
//   * "I pressed cancel and nothing happened" → confirmation, then a toast;
//     a refusal says why ("Too late to cancel…"), never an error code.
//   * "Did deleting this lose money?" → the confirmation says nothing
//     changes on the blockchain.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/amount/amount_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/format.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../background.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/secondary_button.dart';
import '../../icon_widgets/copy_icon.dart';
import '../../rounded_white_container.dart';
import '../stickers/beam_sticker.dart';
import 'beam_transaction_card.dart';
import 'beam_tx_backend.dart';
import 'beam_tx_dialogs.dart';
import 'beam_tx_icon.dart';
import 'beam_tx_text.dart';
import 'beam_tx_view.dart';

/// The details of one BEAM transaction, in Campfire's details layout
/// (`TransactionV2DetailsView`), with BEAM's status, actions and proofs.
class BeamTxDetails extends ConsumerStatefulWidget {
  const BeamTxDetails({
    super.key,
    required this.transaction,
    required this.walletId,
    required this.coin,
  });

  final TransactionV2 transaction;
  final String walletId;
  final CryptoCurrency coin;

  @override
  ConsumerState<BeamTxDetails> createState() => _BeamTxDetailsState();
}

enum _Busy { none, cancel, delete, proof }

class _BeamTxDetailsState extends ConsumerState<BeamTxDetails> {
  late BeamTxView _view;
  StreamSubscription<TransactionV2?>? _sub;
  _Busy _busy = _Busy.none;

  BeamTxBackend get _backend => ref.read(pBeamTxBackend(widget.walletId));
  bool get _isDesktop => ref.read(pBeamTxIsDesktop);

  @override
  void initState() {
    super.initState();
    _follow();
  }

  /// Shows [BeamTxDetails.transaction] and follows its record: after a
  /// cancel, the wallet's refresh turns it "Cancelled" here too, and the
  /// actions change with it.
  void _follow() {
    _view = BeamTxView.of(widget.transaction)!;
    _sub = _backend.watch(widget.transaction.txid).listen((tx) {
      final next = tx == null ? null : BeamTxView.of(tx);
      if (next != null && mounted) setState(() => _view = next);
    });
  }

  @override
  void didUpdateWidget(covariant BeamTxDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transaction.txid != widget.transaction.txid) {
      unawaited(_sub?.cancel());
      _follow();
    }
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _toast(String message, {FlushBarType type = FlushBarType.success}) {
    unawaited(
      showFloatingFlushBar(type: type, message: message, context: context),
    );
  }

  // ---------------------------------------------------------------- actions

  Future<void> _cancel() async {
    if (_busy != _Busy.none) return;
    final ok = await showBeamConfirm(
      context,
      title: BeamTxText.cancelTitle,
      message: BeamTxText.cancelMessage,
      confirm: BeamTxText.cancelConfirm,
      keep: BeamTxText.cancelKeep,
      isDesktop: _isDesktop,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = _Busy.cancel);
    final backend = _backend;
    String? problem;
    try {
      final api = backend.api();
      if (api == null) {
        problem = BeamTxText.notConnected;
      } else if (!await api.txCancel(_view.txid)) {
        problem = BeamTxText.cancelTooLate;
      }
    } on BeamRpcException {
      // canCancel was true when the button was shown, so the only thing
      // the core can be saying is that the payment has moved on.
      problem = BeamTxText.cancelTooLate;
    } catch (_) {
      problem = BeamTxText.notConnected;
    }
    // Whatever the core said, the record may have moved on: re-read it.
    unawaited(backend.refresh());
    if (!mounted) return;
    setState(() => _busy = _Busy.none);
    if (problem != null) {
      await showBeamNotice(context, title: problem, isDesktop: _isDesktop);
    } else {
      _toast(BeamTxText.cancelDone);
    }
  }

  Future<void> _delete() async {
    if (_busy != _Busy.none) return;
    final ok = await showBeamConfirm(
      context,
      title: BeamTxText.deleteTitle,
      message: BeamTxText.deleteMessage,
      confirm: BeamTxText.deleteConfirm,
      keep: BeamTxText.deleteKeep,
      isDesktop: _isDesktop,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _busy = _Busy.delete);
    final backend = _backend;
    String? problem;
    try {
      final api = backend.api();
      if (api == null) {
        problem = BeamTxText.notConnected;
      } else if (!await api.txDelete(_view.txid)) {
        problem = BeamTxText.deleteRefused;
      }
    } on BeamRpcException {
      problem = BeamTxText.deleteRefused;
    } catch (_) {
      problem = BeamTxText.notConnected;
    }
    if (!mounted) return;
    if (problem != null) {
      setState(() => _busy = _Busy.none);
      await showBeamNotice(context, title: problem, isDesktop: _isDesktop);
      return;
    }
    // Stop following the record before it is removed. Not awaited: an
    // Isar watcher can take a while to wind down and nothing depends on it.
    unawaited(_sub?.cancel());
    _sub = null;
    await backend.forget(_view.txid);
    unawaited(backend.refresh());
    if (!mounted) return;
    _toast(BeamTxText.deleteDone);
    Navigator.of(context).pop();
  }

  Future<void> _exportProof() async {
    if (_busy != _Busy.none) return;
    setState(() => _busy = _Busy.proof);
    String? proof;
    String? problem;
    try {
      final api = _backend.api();
      if (api == null) {
        problem = BeamTxText.notConnected;
      } else {
        proof = await api.exportPaymentProof(_view.txid);
      }
    } on BeamRpcException {
      problem = BeamTxText.proofNone;
    } catch (_) {
      problem = BeamTxText.notConnected;
    }
    if (!mounted) return;
    setState(() => _busy = _Busy.none);
    if (proof == null) {
      await showBeamNotice(
        context,
        title: 'No payment proof',
        message: problem,
        isDesktop: _isDesktop,
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) =>
          BeamProofExportDialog(walletId: widget.walletId, proof: proof!),
    );
  }

  Future<void> _checkProof(AmountFormatter formatter) => showDialog<void>(
    context: context,
    builder: (_) =>
        BeamProofCheckDialog(walletId: widget.walletId, formatter: formatter),
  );

  // ----------------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) {
    final isDesktop = ref.watch(pBeamTxIsDesktop);
    final formatter = ref.watch(pAmountFormatter(widget.coin));
    final v = _view;
    final confirmations = v.confirmationsAt(
      ref.watch(pWalletChainHeight(widget.walletId)),
    );
    final funds = watchBeamContractFunds(ref, v);
    final text = BeamTxEntryText.of(
      v,
      formatter: formatter,
      signed: true,
      contractFunds: funds,
      fiat: ref.watch(pBeamTxFiat(widget.walletId)),
    );
    final colors = Theme.of(context).extension<StackColors>()!;

    final rows = <Widget>[
      _Header(view: v, text: text, isDesktop: isDesktop),
      _Row(
        label: 'Status',
        isDesktop: isDesktop,
        vertical: true,
        value: Text(
          BeamTxText.status(v),
          key: const Key('beamTxStatus'),
          style: _detail(
            context,
            isDesktop,
          ).copyWith(color: beamToneColor(context, BeamTxText.tone(v))),
        ),
        below: BeamTxText.technical(v) == null || !v.isFailed
            ? null
            : CustomTextButton(
                text: 'Copy technical details',
                onTap: () => copyWithToast(context, BeamTxText.technical(v)!),
              ),
      ),
      if (!v.isContract)
        _Row(
          label: 'Asset',
          isDesktop: isDesktop,
          value: Text(
            BeamTxText.assetName(
              v.assetId,
              cached: _backend.assetRow(v.assetId),
            ),
            key: const Key('beamTxAsset'),
            style: _detail(context, isDesktop),
          ),
        ),
      if (v.isContract)
        _Row(
          label: 'With',
          isDesktop: isDesktop,
          vertical: true,
          copy: v.contractIds.isEmpty ? null : v.contractIds.first,
          copyLabel: 'Copy contract ID',
          value: Text(
            [
              BeamTxText.contractParty(v.contractKind),
              if (v.appName != null)
                'App: ${BeamTxText.short(v.appName!, head: 24, tail: 0)} '
                    '(the name it gave itself)',
            ].join('\n'),
            style: _detail(context, isDesktop),
          ),
        )
      else if (v.counterparty != null)
        _Row(
          label: v.isIncoming
              ? 'From'
              : v.isToSelf
              ? 'Sent to (this wallet)'
              : 'Sent to',
          isDesktop: isDesktop,
          vertical: true,
          copy: v.counterparty,
          value: Text(
            BeamTxText.short(v.counterparty!, head: 10, tail: 8),
            key: const Key('beamTxCounterparty'),
            style: _detail(context, isDesktop),
          ),
        ),
      if (v.comment != null)
        _Row(
          label: 'Comment',
          isDesktop: isDesktop,
          vertical: true,
          value: SelectableText(v.comment!, style: _detail(context, isDesktop)),
        ),
      _Row(
        label: 'Date',
        isDesktop: isDesktop,
        value: Text(
          Format.extractDateFrom(v.timestamp),
          style: _detail(context, isDesktop),
        ),
      ),
      _Row(
        label: 'Network fee',
        isDesktop: isDesktop,
        value: Text(
          BeamTxText.fee(v, formatter),
          style: _detail(context, isDesktop),
        ),
      ),
      if (v.isCompleted) ...[
        _Row(
          label: 'Block height',
          isDesktop: isDesktop,
          value: Text('${v.height ?? '—'}', style: _detail(context, isDesktop)),
        ),
        _Row(
          label: 'Confirmations',
          isDesktop: isDesktop,
          value: Text(
            '${confirmations ?? '—'}',
            style: _detail(context, isDesktop),
          ),
        ),
      ] else if (v.isInFlight)
        _Row(
          label: 'Block height',
          isDesktop: isDesktop,
          value: Text('Not in a block yet', style: _detail(context, isDesktop)),
        ),
      _KernelRow(view: v, isDesktop: isDesktop, walletId: widget.walletId),
      if (v.canExportProof)
        _Row(
          label: 'Payment proof',
          isDesktop: isDesktop,
          vertical: true,
          value: Text(
            'Shows the receiver, or anyone you choose, that you paid.',
            style: _detail(context, isDesktop),
          ),
          below: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SecondaryButton(
              key: const Key('beamTxGetProof'),
              label: _busy == _Busy.proof
                  ? 'Getting proof…'
                  : 'Get payment proof',
              enabled: _busy == _Busy.none,
              onPressed: _exportProof,
            ),
          ),
        ),
      if (v.canCheckProof)
        _Row(
          label: 'Payment proof',
          isDesktop: isDesktop,
          vertical: true,
          value: Text(
            'Did someone send you a proof that they paid? Check it here.',
            style: _detail(context, isDesktop),
          ),
          below: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: CustomTextButton(
              key: const Key('beamTxCheckProof'),
              text: 'Check a payment proof',
              onTap: () => _checkProof(formatter),
            ),
          ),
        ),
      // Removing a record is housekeeping, never the main thing here: a
      // quiet link, with the confirmation doing the explaining.
      if (v.canDelete)
        _Row(
          label: 'This record',
          isDesktop: isDesktop,
          vertical: true,
          value: Text(
            'Only in this wallet. Removing it changes nothing on the '
            'blockchain.',
            style: _detail(context, isDesktop),
          ),
          below: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _RemoveLink(
              busy: _busy == _Busy.delete,
              enabled: _busy == _Busy.none,
              onTap: _delete,
            ),
          ),
        ),
    ];

    final cancel = !v.canCancel
        ? null
        : SizedBox(
            width: double.infinity,
            child: TextButton(
              key: const Key('beamTxCancel'),
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.all<Color>(
                  colors.textError,
                ),
                minimumSize: WidgetStateProperty.all(const Size(46, 48)),
                shape: WidgetStateProperty.all(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(1000),
                  ),
                ),
              ),
              onPressed: _busy == _Busy.none ? _cancel : null,
              child: Text(
                _busy == _Busy.cancel ? 'Cancelling…' : 'Cancel payment',
                style: STextStyles.button(context),
              ),
            ),
          );

    if (isDesktop) {
      return Padding(
        padding: const EdgeInsets.only(left: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Transaction details',
                  style: STextStyles.desktopH3(context),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 32, bottom: 32),
                child: RoundedWhiteContainer(
                  borderColor: colors.backgroundAppBar,
                  padding: EdgeInsets.zero,
                  child: SingleChildScrollView(
                    primary: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          if (i > 0) const _Divider(),
                          rows[i],
                        ],
                        if (cancel != null) ...[
                          const _Divider(),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: cancel,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            'Transaction details',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < rows.length; i++) ...[
                            if (i > 0) const SizedBox(height: 12),
                            rows[i],
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                if (cancel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: cancel,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

TextStyle _label(BuildContext context, bool isDesktop) => isDesktop
    ? STextStyles.desktopTextExtraExtraSmall(context)
    : STextStyles.itemSubtitle(context);

TextStyle _detail(BuildContext context, bool isDesktop) => isDesktop
    ? STextStyles.desktopTextExtraExtraSmall(context)
          .copyWith(color: Theme.of(context).extension<StackColors>()!.textDark)
    : STextStyles.itemSubtitle12(context);

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    height: 1,
    color: Theme.of(context).extension<StackColors>()!.backgroundAppBar,
  );
}

/// One labelled detail, like Campfire's: label and value side by side, or
/// stacked ([vertical]); on desktop a copy button sits on the right, on a
/// phone a "Copy" link sits next to the label.
class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    required this.isDesktop,
    this.vertical = false,
    this.copy,
    this.copyLabel = 'Copy',
    this.below,
  });

  final String label;
  final Widget value;
  final bool isDesktop;
  final bool vertical;
  final String? copy;
  final String copyLabel;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final labelText = Text(label, style: _label(context, isDesktop));
    final Widget body;
    if (vertical || copy != null || below != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (copy != null && !isDesktop)
            Row(
              children: [
                Expanded(child: labelText),
                _CopyLink(data: copy!, label: copyLabel),
              ],
            )
          else
            labelText,
          SizedBox(height: isDesktop ? 2 : 8),
          value,
          ?below,
        ],
      );
    } else {
      body = Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          labelText,
          const SizedBox(width: 12),
          Flexible(child: value),
        ],
      );
    }
    return RoundedWhiteContainer(
      padding: EdgeInsets.all(isDesktop ? 16 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          if (isDesktop && copy != null) const SizedBox(width: 12),
          if (isDesktop && copy != null) _CopyIconButton(data: copy!),
        ],
      ),
    );
  }
}

/// Campfire's phone "Copy" link (`SimpleCopyButton`), with its own label.
class _CopyLink extends StatelessWidget {
  const _CopyLink({required this.data, required this.label});

  final String data;
  final String label;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => copyWithToast(context, data),
      child: Row(
        children: [
          SvgPicture.asset(
            Assets.svg.copy,
            width: 10,
            height: 10,
            colorFilter: ColorFilter.mode(
              Theme.of(context).extension<StackColors>()!.infoItemIcons,
              BlendMode.srcIn,
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: STextStyles.link2(context)),
        ],
      ),
    );
  }
}

/// Campfire's desktop copy button (`IconCopyButton`).
class _CopyIconButton extends StatelessWidget {
  const _CopyIconButton({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return SizedBox(
      height: 26,
      width: 26,
      child: RawMaterialButton(
        fillColor: colors.buttonBackSecondary,
        elevation: 0,
        hoverElevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        onPressed: () => copyWithToast(context, data),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: CopyIcon(width: 16, height: 16, color: colors.textDark),
        ),
      ),
    );
  }
}

/// "Remove record" as a red text link with Campfire's trash icon.
class _RemoveLink extends StatelessWidget {
  const _RemoveLink({
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = enabled ? colors.accentColorRed : colors.textSubtitle2;
    return GestureDetector(
      key: const Key('beamTxDelete'),
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SvgPicture.asset(
              Assets.svg.trash,
              width: 14,
              height: 14,
              colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
            ),
            const SizedBox(width: 6),
            Text(
              busy ? 'Removing…' : 'Remove record',
              style: STextStyles.link2(context).copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// Amount header, like `_TxDetailsAmountHeader`.
class _Header extends StatelessWidget {
  const _Header({
    required this.view,
    required this.text,
    required this.isDesktop,
  });

  final BeamTxView view;
  final BeamTxEntryText text;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    // A received payment gets a small Beam girl; never anything that could
    // compete with an action.
    final arrived = view.isCompleted && view.isIncoming && !view.isContract;
    const sticker = BeamStickerImage(BeamMoments.paymentArrived, size: 56);
    final amounts = Column(
      crossAxisAlignment: isDesktop
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        SelectableText(
          text.primary,
          key: const Key('beamTxAmount'),
          style: text.muted
              ? _detail(
                  context,
                  isDesktop,
                ).copyWith(color: colors.textSubtitle1)
              : _detail(context, isDesktop),
        ),
        if (text.secondary != null) const SizedBox(height: 2),
        if (text.secondary != null)
          SelectableText(text.secondary!, style: _label(context, isDesktop)),
      ],
    );
    if (isDesktop) {
      return Container(
        decoration: BoxDecoration(
          color: colors.backgroundAppBar,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Constants.size.circularBorderRadius),
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            BeamTxIcon(view: view),
            const SizedBox(width: 16),
            Expanded(
              child: SelectableText(
                text.title,
                style: STextStyles.desktopTextMedium(context),
              ),
            ),
            if (arrived) sticker,
            const SizedBox(width: 12),
            amounts,
          ],
        ),
      );
    }
    return RoundedWhiteContainer(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text.title, style: STextStyles.itemSubtitle(context)),
                const SizedBox(height: 4),
                amounts,
              ],
            ),
          ),
          if (arrived) sticker,
          if (arrived) const SizedBox(width: 8),
          BeamTxIcon(view: view),
        ],
      ),
    );
  }
}

/// The ID the explorer looks a transaction up by (the kernel), with copy,
/// an explorer link and an info button for the word "kernel".
class _KernelRow extends ConsumerWidget {
  const _KernelRow({
    required this.view,
    required this.isDesktop,
    required this.walletId,
  });

  final BeamTxView view;
  final bool isDesktop;
  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kernel = view.kernelId;
    final colors = Theme.of(context).extension<StackColors>()!;
    final info = GestureDetector(
      key: const Key('beamTxKernelInfo'),
      onTap: () => showBeamNotice(
        context,
        title: 'About this ID',
        message: BeamTxText.explorerInfo,
        isDesktop: isDesktop,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: SvgPicture.asset(
          Assets.svg.circleInfo,
          width: 14,
          height: 14,
          colorFilter: ColorFilter.mode(colors.infoItemIcons, BlendMode.srcIn),
        ),
      ),
    );
    return _Row(
      label: 'Transaction ID',
      isDesktop: isDesktop,
      vertical: true,
      copy: kernel,
      value: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              kernel ??
                  (view.isFailed || view.isCancelled
                      ? 'None: it never reached the network'
                      : 'Appears once the network has it'),
              key: const Key('beamTxKernel'),
              style: _detail(context, isDesktop),
            ),
          ),
          info,
        ],
      ),
      below: kernel == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: CustomTextButton(
                key: const Key('beamTxExplorer'),
                text: 'Open in block explorer',
                onTap: () => openBeamExplorer(
                  context,
                  backend: ref.read(pBeamTxBackend(walletId)),
                  kernelId: kernel,
                  isDesktop: isDesktop,
                ),
              ),
            ),
    );
  }
}
