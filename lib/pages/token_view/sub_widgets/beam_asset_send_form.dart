/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — send an asset:
//   Job:  say who gets how much of this asset.
//   CTA:  "Review payment" (nothing is sent from here; the confirm screen
//         shows asset, amount, fee and destination first).
//   Taps: asset page → Send → paste → amount → Review: 3 from the asset.
//
// Exit-intent:
//   * "Why can't I send my FOMO?" → the BEAM fee is stated before the user
//     types anything, and a wallet without enough BEAM is told how much to
//     add, with one tap to receive BEAM — not a failure at the end.
//   * "Is the wallet ready?" → while not honestly synced the form says so
//     and the button stays off.
//   * "How much do I have?" → "Available" sits under the amount, "Send all"
//     fills it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../providers/global/barcode_scanner_provider.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/address_utils.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_unit.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_providers.dart';
import '../../../wallets/beam/assets/beam_asset_text.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_send_rules.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/models/tx_data.dart';
import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import '../../../widgets/custom_buttons/blue_text_button.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/icon_widgets/clipboard_icon.dart';
import '../../../widgets/icon_widgets/qrcode_icon.dart';
import '../../../widgets/icon_widgets/x_icon.dart';
import '../../../widgets/rounded_container.dart';
import '../../../widgets/stack_dialog.dart';
import '../../../widgets/stack_text_field.dart';
import '../../../widgets/textfield_icon_button.dart';
import '../../../utilities/show_loading.dart';
import '../beam_asset_confirm_view.dart';
import '../beam_asset_receive_view.dart';
import 'beam_asset_layout.dart';

/// The send form of one asset, built from Campfire's send-field widgets.
/// The same form is the phone's send page and the desktop asset page's
/// Send tab.
class BeamAssetSendForm extends ConsumerStatefulWidget {
  const BeamAssetSendForm({
    super.key,
    required this.walletId,
    required this.assetWallet,
    this.clipboard = const ClipboardWrapper(),
    this.initialAddress,
    this.initialAmount,
    this.onSent,
  });

  final String walletId;
  final BeamAssetWallet assetWallet;
  final ClipboardInterface clipboard;

  /// Pre-filled values (tests, deep links).
  final String? initialAddress;
  final String? initialAmount;

  /// Called once a payment went out (the phone's send page closes itself);
  /// without it the form clears for the next payment.
  final VoidCallback? onSent;

  @override
  ConsumerState<BeamAssetSendForm> createState() => _BeamAssetSendFormState();
}

class _BeamAssetSendFormState extends ConsumerState<BeamAssetSendForm> {
  static final _beam = Beam(CryptoCurrencyNetwork.main);

  late final TextEditingController _address;
  late final TextEditingController _amount;
  final _addressFocus = FocusNode();
  final _amountFocus = FocusNode();
  bool _busy = false;

  BeamAssetContract get _asset => widget.assetWallet.asset;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.initialAddress ?? '');
    _amount = TextEditingController(text: widget.initialAmount ?? '');
  }

  @override
  void dispose() {
    _address.dispose();
    _amount.dispose();
    _addressFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  String get _locale => ref.read(localeServiceChangeNotifierProvider).locale;

  Amount? _parsedAmount() => AmountUnit.normal.tryParse(
    _amount.text.trim(),
    locale: _locale,
    coin: _beam,
    tokenContract: _asset,
  );

  Future<void> _paste() async {
    final data = await widget.clipboard.getData(Clipboard.kTextPlain);
    var text = data?.text?.trim() ?? '';
    if (text.contains('\n')) text = text.substring(0, text.indexOf('\n'));
    if (text.isEmpty) return;
    setState(() => _address.text = text.trim());
  }

  Future<void> _scan() async {
    try {
      final result = await ref.read(pBarcodeScanner).scan(context: context);
      final raw = result.rawContent?.trim();
      if (raw == null || raw.isEmpty) return;
      final parsed = raw.contains(':')
          ? AddressUtils.parsePaymentUri(raw)
          : null;
      setState(() => _address.text = parsed?.address.trim() ?? raw);
    } catch (_) {
      // Camera unavailable or cancelled: the field stays as it was.
    }
  }

  void _sendAll(BigInt available) {
    _amount.text = AmountUnit.normal.formatEditable(
      amount: Amount(rawValue: available, fractionDigits: _asset.decimals),
      locale: _locale,
    );
    setState(() {});
  }

  Future<void> _review() async {
    final amount = _parsedAmount();
    if (amount == null || _busy) return;
    setState(() => _busy = true);
    final ({TxData? tx, Object? error})? outcome = await showLoading(
      context: context,
      rootNavigator: BeamAssetLayout.isDesktop(context),
      message: 'Checking the payment',
      whileFuture: () async {
        try {
          final tx = await widget.assetWallet.prepareSend(
            txData: TxData(
              recipients: [
                TxRecipient(
                  address: _address.text.trim(),
                  amount: amount,
                  isChange: false,
                  addressType: AddressType.mimbleWimble,
                ),
              ],
            ),
          );
          return (tx: tx, error: null);
        } catch (e) {
          return (tx: null, error: e);
        }
      }(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    final tx = outcome?.tx;
    if (tx == null) {
      await showDialog<void>(
        context: context,
        builder: (_) => StackOkDialog(
          title: 'Payment not ready',
          message: '${outcome?.error ?? 'Something went wrong. Try again.'}',
          desktopPopRootNavigator: BeamAssetLayout.isDesktop(context),
          maxWidth: BeamAssetLayout.isDesktop(context) ? 480 : null,
        ),
      );
      return;
    }
    final sent = await showBeamAssetConfirm(
      context: context,
      walletId: widget.walletId,
      assetWallet: widget.assetWallet,
      txData: tx,
    );
    if (sent == true && mounted) {
      final onSent = widget.onSent;
      if (onSent != null) return onSent();
      _address.clear();
      _amount.clear();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final isDesktop = BeamAssetLayout.isDesktop(context);
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    final totals = ref.watch(pBeamAssetTotals(widget.walletId));
    final available = totals[_asset.assetId]?.available ?? BigInt.zero;
    final beamAvailable = totals[0]?.available ?? BigInt.zero;
    final fee = kBeamDefaultFee;
    final amount = _parsedAmount();
    final tooMuch = amount != null && amount.raw > available;
    final noBeam = beamAvailable < fee;

    final labelStyle = isDesktop
        ? STextStyles.desktopTextExtraSmall(context)
              .copyWith(color: colors.textDark3)
        : STextStyles.smallMed12(context);
    final fieldStyle = isDesktop
        ? STextStyles.desktopTextExtraSmall(context)
              .copyWith(color: colors.textFieldActiveText, height: 1.8)
        : STextStyles.field(context);

    return StreamBuilder<BeamSyncAssessment>(
      stream: widget.assetWallet.parent.syncAssessments,
      initialData: widget.assetWallet.parent.syncAssessment,
      builder: (context, snap) {
        final sync = snap.data ?? widget.assetWallet.parent.syncAssessment;
        final canReview =
            !_busy &&
            sync.canSpend &&
            !noBeam &&
            _address.text.trim().isNotEmpty &&
            amount != null &&
            amount.raw > BigInt.zero &&
            !tooMuch;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!sync.canSpend) ...[
              _Notice(
                key: const Key('beamAssetSendSyncNotice'),
                text: () {
                  final m = BeamSyncMessages.describe(sync);
                  return m.detail == null
                      ? 'Sending is off: ${m.title}.'
                      : 'Sending is off: ${m.title}. ${m.detail}';
                }(),
              ),
              const SizedBox(height: 16),
            ],
            Text('Send to', style: labelStyle),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
              child: TextField(
                key: const Key('beamAssetSendAddress'),
                controller: _address,
                focusNode: _addressFocus,
                autocorrect: false,
                enableSuggestions: false,
                style: fieldStyle,
                onChanged: (_) => setState(() {}),
                minLines: 1,
                maxLines: 3,
                decoration:
                    standardInputDecoration(
                      null,
                      _addressFocus,
                      context,
                      desktopMed: isDesktop,
                    ).copyWith(
                      hintText: 'Paste the ${_asset.symbol} address',
                      contentPadding: const EdgeInsets.only(
                        left: 16,
                        top: 6,
                        bottom: 8,
                        right: 5,
                      ),
                      suffixIcon: Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: UnconstrainedBox(
                          child: Row(
                            children: [
                              if (_address.text.isNotEmpty)
                                TextFieldIconButton(
                                  semanticsLabel: 'Clear the address',
                                  onTap: () => setState(() => _address.clear()),
                                  child: const XIcon(),
                                )
                              else
                                TextFieldIconButton(
                                  key: const Key('beamAssetSendPaste'),
                                  semanticsLabel: 'Paste the address',
                                  onTap: _paste,
                                  child: const ClipboardIcon(),
                                ),
                              if (!isDesktop && _address.text.isEmpty)
                                TextFieldIconButton(
                                  semanticsLabel: 'Scan a QR code',
                                  onTap: _scan,
                                  child: const QrCodeIcon(),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text('Amount', style: labelStyle)),
                CustomTextButton(
                  key: const Key('beamAssetSendAll'),
                  text: 'Send all',
                  onTap: available > BigInt.zero
                      ? () => _sendAll(available)
                      : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(
                Constants.size.circularBorderRadius,
              ),
              child: TextField(
                key: const Key('beamAssetSendAmount'),
                controller: _amount,
                focusNode: _amountFocus,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.right,
                style: fieldStyle,
                onChanged: (_) => setState(() {}),
                decoration:
                    standardInputDecoration(
                      null,
                      _amountFocus,
                      context,
                      desktopMed: isDesktop,
                    ).copyWith(
                      hintText: '0',
                      contentPadding: const EdgeInsets.only(
                        top: 12,
                        bottom: 12,
                        left: 12,
                        right: 12,
                      ),
                      // The unit after the number, as in Campfire's send.
                      suffixIcon: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _asset.symbol,
                          style: STextStyles.smallMed14(context)
                              .copyWith(color: colors.accentColorDark),
                        ),
                      ),
                      suffixIconConstraints: const BoxConstraints(),
                    ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${tooMuch ? 'More than you have. ' : ''}Available: '
              '${BeamAssetText.amount(
                Amount(rawValue: available, fractionDigits: _asset.decimals),
                _asset,
                locale: locale,
              )}',
              key: const Key('beamAssetSendAvailable'),
              style: STextStyles.itemSubtitle(context)
                  .copyWith(color: tooMuch ? colors.textError : null),
            ),
            const SizedBox(height: 16),
            RoundedContainer(
              color: colors.textFieldDefaultBG,
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    BeamAssetText.feeLine(fee, locale: locale),
                    key: const Key('beamAssetSendFee'),
                    style: STextStyles.itemSubtitle12(context),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'BEAM available for the fee: '
                    '${BeamAssetText.beam(beamAvailable, locale: locale)}',
                    style: STextStyles.itemSubtitle(context),
                  ),
                ],
              ),
            ),
            if (noBeam) ...[
              const SizedBox(height: 12),
              _Notice(
                key: const Key('beamAssetSendNoBeam'),
                text: BeamAssetText.needBeamForFee(
                  _asset.symbol,
                  fee,
                  beamAvailable,
                  locale: locale,
                ),
                action: 'Receive BEAM',
                onAction: () => unawaited(
                  showBeamAssetReceive(
                    context: context,
                    walletId: widget.walletId,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            PrimaryButton(
              key: const Key('beamAssetSendReview'),
              label: 'Review payment',
              buttonHeight: isDesktop ? ButtonHeight.l : null,
              enabled: canReview,
              onPressed: canReview ? _review : null,
            ),
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({super.key, required this.text, this.action, this.onAction});

  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return RoundedContainer(
      color: colors.warningBackground,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: STextStyles.itemSubtitle12(context)
                .copyWith(color: colors.warningForeground),
          ),
          if (action != null) ...[
            const SizedBox(height: 8),
            CustomTextButton(text: action!, onTap: onAction),
          ],
        ],
      ),
    );
  }
}
