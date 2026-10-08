/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The fields of the BEAM Send screen, in Campfire's send-form style. The
// screen around it (beam_send_screen.dart) owns the "Send" button.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/address_utils.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/amount/amount_input_formatter.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/contracts/bans/bans_recipient.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../icon_widgets/addressbook_icon.dart';
import '../../icon_widgets/clipboard_icon.dart';
import '../../icon_widgets/qrcode_icon.dart';
import '../../icon_widgets/x_icon.dart';
import '../../rounded_container.dart';
import '../../textfield_icon_button.dart';
import '../beam_decimal_input.dart';
import 'beam_recipient_card.dart';
import 'beam_send_format.dart';
import 'beam_send_model.dart';
import 'beam_send_widgets.dart';

/// Returns an address (or name) picked elsewhere, or null.
typedef BeamPickRecipient = Future<String?> Function(BuildContext context);

class BeamSendForm extends StatefulWidget {
  const BeamSendForm({
    super.key,
    required this.model,
    required this.locale,
    required this.desktop,
    this.walletName,
    this.clipboard = const ClipboardWrapper(),
    this.onScanQr,
    this.onAddressBook,
    this.assetWorth,
    this.initialRecipient,
    this.initialAmount,
    this.onSplitCoins,
  });

  final BeamSendModel model;
  final String locale;
  final bool desktop;

  /// Shown in the balance header on a phone, as Campfire's send screen does.
  final String? walletName;
  final ClipboardInterface clipboard;
  final BeamPickRecipient? onScanQr;
  final BeamPickRecipient? onAddressBook;

  /// What an amount of an asset is worth ("≈ 0.02 USD"), shown in the asset
  /// picker; null when there is no price.
  final String? Function(int assetId, BigInt amount)? assetWorth;
  final String? initialRecipient;
  final BigInt? initialAmount;

  /// Opens Split coins for an asset whose coins are tied up in a payment
  /// that has not finished; null hides the link.
  final void Function(int assetId)? onSplitCoins;

  @override
  State<BeamSendForm> createState() => BeamSendFormState();
}

class BeamSendFormState extends State<BeamSendForm> {
  late final TextEditingController _to;
  late final TextEditingController _amount;
  late final TextEditingController _comment;
  final _toFocus = FocusNode();
  final _amountFocus = FocusNode();
  final _commentFocus = FocusNode();

  BeamSendModel get _m => widget.model;
  bool get _desktop => widget.desktop;

  @override
  void initState() {
    super.initState();
    _to = TextEditingController(text: widget.initialRecipient ?? '');
    _amount = TextEditingController(
      text: widget.initialAmount == null
          ? ''
          : BeamSendFormat.editable(widget.initialAmount!, widget.locale),
    );
    _comment = TextEditingController(text: _m.comment);
    for (final f in [_toFocus, _amountFocus, _commentFocus]) {
      f.addListener(_refresh);
    }
    if (_to.text.isNotEmpty) _m.setRecipient(_to.text);
    if (_amount.text.isNotEmpty) _m.setAmountText(_amount.text, widget.locale);
  }

  @override
  void dispose() {
    for (final f in [_toFocus, _amountFocus, _commentFocus]) {
      f.removeListener(_refresh);
      f.dispose();
    }
    _to.dispose();
    _amount.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Empties every field (after a payment went out).
  void clear() {
    _to.clear();
    _amount.clear();
    _comment.clear();
    _m.setRecipient('');
    _m.setAmountText('', widget.locale);
    _m.comment = '';
    _m.setAsset(0);
    setState(() {});
  }

  void _setRecipient(String text, {String? amount}) {
    _to.text = text;
    _to.selection = TextSelection.collapsed(offset: text.length);
    _m.setRecipient(text);
    if (amount != null) {
      final parsed = Amount.tryParseCanonicalAmount(
        amount,
        fractionDigits: BeamSendFormat.decimals,
        truncateOverprecision: true,
      );
      if (parsed != null) {
        _amount.text = BeamSendFormat.editable(parsed.raw, widget.locale);
        _m.setAmountText(_amount.text, widget.locale);
      }
    }
  }

  /// A pasted or scanned `beam:` payment link fills address and amount.
  void _applyText(String raw) {
    var content = raw.trim();
    if (content.contains('\n')) {
      content = content.substring(0, content.indexOf('\n')).trim();
    }
    PaymentUriData? uri;
    try {
      uri = AddressUtils.parsePaymentUri(content);
    } catch (_) {
      uri = null;
    }
    if (uri != null && uri.scheme?.toLowerCase() == 'beam') {
      _setRecipient(uri.address.trim(), amount: uri.amount);
    } else {
      _setRecipient(content);
    }
  }

  Future<void> _paste() async {
    final data = await widget.clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) return;
    _applyText(text);
  }

  Future<void> _pick(BeamPickRecipient pick) async {
    final picked = await pick(context);
    if (picked != null && picked.trim().isNotEmpty) _applyText(picked);
  }

  void _useMax() {
    final text = _m.useMax(widget.locale);
    _amount.text = text;
    _amount.selection = TextSelection.collapsed(offset: text.length);
  }

  @override
  Widget build(BuildContext context) {
    return BeamCloseKeyboardOnTapOutside(
      child: ListenableBuilder(
        listenable: _m,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_desktop) ...[
              _balanceHeader(context),
              const SizedBox(height: 16),
            ],
            if (_m.syncMessage != null) ...[
              BeamNotice(
                key: const Key('beamSendSyncNotice'),
                kind: BeamNoticeKind.warning,
                title: _m.syncMessage!.title,
                message:
                    _m.syncMessage!.detail ??
                    "Sending is paused until it's done.",
              ),
              const SizedBox(height: 16),
            ],
            BeamFieldLabel('Send to', desktop: _desktop),
            SizedBox(height: _desktop ? 10 : 8),
            _recipientField(context),
            ..._recipientBelow(context),
            if (_m.assetChoices.length > 1 || _m.assetId != 0) ...[
              SizedBox(height: _desktop ? 20 : 12),
              BeamFieldLabel('Asset', desktop: _desktop),
              SizedBox(height: _desktop ? 10 : 8),
              _assetSelector(context),
              ..._assetBelow(context),
            ],
            SizedBox(height: _desktop ? 20 : 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                BeamFieldLabel('Amount', desktop: _desktop),
                CustomTextButton(
                  key: const Key('beamSendAllButton'),
                  text: 'Send all ${BeamSendFormat.symbol(_m.asset)}',
                  onTap: _useMax,
                ),
              ],
            ),
            SizedBox(height: _desktop ? 10 : 8),
            _amountField(context),
            ..._amountBelow(context),
            SizedBox(height: _desktop ? 20 : 12),
            BeamFieldLabel('Network fee', desktop: _desktop),
            SizedBox(height: _desktop ? 10 : 8),
            _feeBox(context),
            SizedBox(height: _desktop ? 20 : 12),
            BeamFieldLabel('Comment (optional)', desktop: _desktop),
            SizedBox(height: _desktop ? 10 : 8),
            _commentField(context),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(_m.commentHint, style: STextStyles.label(context)),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- header

  Widget _balanceHeader(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final asset = _m.asset;
    return Container(
      decoration: BoxDecoration(
        color: c.popupBG,
        borderRadius: BorderRadius.circular(
          Constants.size.circularBorderRadius,
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          BeamAssetIcon(asset),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.walletName ?? 'BEAM wallet',
                  style: STextStyles.titleBold12(context)
                      .copyWith(fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                Text(
                  'Available balance',
                  style: STextStyles.label(context).copyWith(fontSize: 10),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: _useMax,
            child: Text(
              BeamSendFormat.amount(_m.available(), asset),
              key: const Key('beamSendAvailable'),
              style: STextStyles.titleBold12(context).copyWith(fontSize: 10),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ recipient

  TextStyle _fieldStyle(BuildContext context) => _desktop
      ? STextStyles.desktopTextExtraSmall(context).copyWith(
          color: Theme.of(context)
              .extension<StackColors>()!
              .textFieldActiveText,
          height: 1.8,
        )
      : STextStyles.field(context);

  EdgeInsets get _fieldPadding => _desktop
      ? const EdgeInsets.only(left: 16, top: 11, bottom: 12, right: 5)
      : const EdgeInsets.only(left: 16, top: 6, bottom: 8, right: 5);

  Widget _recipientField(BuildContext context) {
    final empty = _to.text.isEmpty;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
      child: TextField(
        key: const Key('beamSendRecipientField'),
        controller: _to,
        focusNode: _toFocus,
        autocorrect: false,
        enableSuggestions: false,
        minLines: 1,
        maxLines: _desktop ? 5 : 3,
        style: _fieldStyle(context),
        onChanged: (v) {
          _m.setRecipient(v);
          setState(() {});
        },
        decoration:
            beamInputDecoration(
              'Enter BEAM address or name',
              _toFocus,
              context,
              desktop: _desktop,
            ).copyWith(
              contentPadding: _fieldPadding,
              suffixIcon: Padding(
                padding: empty
                    ? const EdgeInsets.only(right: 8)
                    : EdgeInsets.zero,
                child: UnconstrainedBox(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      if (!empty)
                        TextFieldIconButton(
                          key: const Key('beamSendClearRecipient'),
                          semanticsLabel:
                              'Clear Button. Clears The Address Field Input.',
                          onTap: () {
                            _to.clear();
                            _m.setRecipient('');
                            setState(() {});
                          },
                          child: const XIcon(),
                        )
                      else
                        TextFieldIconButton(
                          key: const Key('beamSendPasteRecipient'),
                          semanticsLabel:
                              'Paste Button. Pastes From Clipboard To Address '
                              'Field Input.',
                          onTap: _paste,
                          child: const ClipboardIcon(),
                        ),
                      if (empty && widget.onAddressBook != null)
                        TextFieldIconButton(
                          semanticsLabel:
                              'Address Book Button. Opens Address Book For '
                              'Address Field.',
                          onTap: () => _pick(widget.onAddressBook!),
                          child: const AddressBookIcon(),
                        ),
                      if (empty && widget.onScanQr != null)
                        TextFieldIconButton(
                          semanticsLabel:
                              'Scan QR Button. Opens Camera For Scanning QR '
                              'Code.',
                          onTap: () => _pick(widget.onScanQr!),
                          child: const QrCodeIcon(),
                        ),
                    ],
                  ),
                ),
              ),
            ),
      ),
    );
  }

  List<Widget> _recipientBelow(BuildContext context) {
    final name = _m.nameState;
    if (name != null) {
      return [
        const SizedBox(height: 8),
        BeamNameCard(
          state: name,
          typedText: _m.recipientText,
          onRetry: _m.recheckName,
        ),
      ];
    }
    final issue = _m.recipientIssue;
    if (issue != null && !issue.quiet) {
      return [
        const SizedBox(height: 8),
        BeamNotice(
          key: const Key('beamRecipientIssue'),
          kind: BeamNoticeKind.error,
          message: issue.message,
        ),
      ];
    }
    final note = _m.addressNote;
    if (note != null) {
      return [
        const SizedBox(height: 8),
        BeamAddressNote(title: note.$1, note: note.$2),
      ];
    }
    if (_m.recipient is BeamRecipientName) {
      return const [];
    }
    return const [];
  }

  // ---------------------------------------------------------------- asset

  Widget _assetSelector(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final asset = _m.asset;
    return RoundedContainer(
      key: const Key('beamSendAssetSelector'),
      color: c.textFieldDefaultBG,
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: _desktop ? 16 : 12,
      ),
      onPressed: () => _chooseAsset(context),
      child: Row(
        children: [
          BeamAssetIcon(asset, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  BeamSendFormat.symbol(asset),
                  style: STextStyles.itemSubtitle12(context),
                ),
                BeamAssetBadge(asset),
              ],
            ),
          ),
          Text(
            BeamSendFormat.amount(_m.available(), asset),
            style: STextStyles.itemSubtitle(context),
          ),
          const SizedBox(width: 10),
          SvgPicture.asset(
            Assets.svg.chevronDown,
            width: 8,
            height: 4,
            colorFilter: ColorFilter.mode(c.textSubtitle2, BlendMode.srcIn),
          ),
        ],
      ),
    );
  }

  List<Widget> _assetBelow(BuildContext context) {
    final out = <Widget>[];
    final warn = beamImpersonationWarning(_m.asset);
    if (warn != null) {
      out
        ..add(const SizedBox(height: 8))
        ..add(BeamNotice(kind: BeamNoticeKind.warning, message: warn));
    }
    final issue = _m.assetIssue;
    if (issue != null) {
      out
        ..add(const SizedBox(height: 8))
        ..add(
          BeamNotice(
            key: const Key('beamAssetIssue'),
            kind: BeamNoticeKind.error,
            message: issue.message,
          ),
        );
    }
    return out;
  }

  Future<void> _chooseAsset(BuildContext context) async {
    // Each picker pops itself with its own context, whichever navigator
    // (root or nested) it was shown on.
    Widget list(BuildContext pickerContext) => _AssetList(
      model: _m,
      worth: widget.assetWorth,
      onPick: (id) => Navigator.of(pickerContext).pop(id),
    );
    final int? picked;
    if (_desktop) {
      picked = await showDialog<int>(
        context: context,
        builder: (dialogContext) => DesktopDialog(
          maxWidth: 480,
          maxHeight: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      'Choose what to send',
                      style: STextStyles.desktopH3(context),
                    ),
                  ),
                  const DesktopDialogCloseButton(),
                ],
              ),
              Flexible(child: list(dialogContext)),
            ],
          ),
        ),
      );
    } else {
      picked = await showModalBottomSheet<int>(
        context: context,
        backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) => SafeArea(child: list(sheetContext)),
      );
    }
    if (picked == null || !mounted) return;
    _m.setAsset(picked);
    if (_amount.text.isNotEmpty) {
      _m.setAmountText(_amount.text, widget.locale);
    }
  }

  // --------------------------------------------------------------- amount

  /// The app locale's decimal separator when it is "." or ",".
  String? get _localeSeparator {
    final sep = Util.getSymbolsFor(locale: widget.locale)?.DECIMAL_SEP ?? '.';
    return sep == '.' || sep == ',' ? sep : null;
  }

  Widget _amountField(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return TextField(
      key: const Key('beamSendAmountField'),
      controller: _amount,
      focusNode: _amountFocus,
      autocorrect: false,
      enableSuggestions: false,
      style: STextStyles.smallMed14(context).copyWith(color: c.textDark),
      keyboardType: _desktop
          ? null
          : const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.right,
      inputFormatters: [
        // The decimal key types the app locale's separator, whatever the
        // phone's region offers.
        if (_localeSeparator case final sep?) BeamDecimalKeyFormatter(sep),
        AmountInputFormatter(
          controller: _amount,
          decimals: BeamSendFormat.decimals,
          locale: widget.locale,
        ),
      ],
      onChanged: (v) => _m.setAmountText(v, widget.locale),
      decoration: InputDecoration(
        contentPadding: _desktop
            ? const EdgeInsets.only(top: 22, right: 12, bottom: 22)
            : const EdgeInsets.only(top: 12, right: 12),
        hintText: '0',
        hintStyle: _desktop
            ? STextStyles.desktopTextExtraSmall(context)
                  .copyWith(color: c.textFieldDefaultText)
            : STextStyles.fieldLabel(context).copyWith(fontSize: 14),
        prefixIcon: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              BeamSendFormat.symbol(_m.asset),
              style: STextStyles.smallMed14(context)
                  .copyWith(color: c.accentColorDark),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _amountBelow(BuildContext context) {
    final out = <Widget>[];
    final issue = _m.amountIssue;
    final waiting = issue?.waitingAssetId;
    final split = widget.onSplitCoins;
    if (issue != null && !issue.quiet && waiting != null) {
      // Not a mistake: the money is there, just busy for a minute.
      out
        ..add(const SizedBox(height: 8))
        ..add(
          BeamNotice(
            key: const Key('beamAmountIssue'),
            kind: BeamNoticeKind.warning,
            message: issue.message,
            action: split == null
                ? null
                : CustomTextButton(
                    key: const Key('beamSendSplitLink'),
                    text: 'Split coins for next time',
                    onTap: () => split(waiting),
                  ),
          ),
        );
    } else if (issue != null && !issue.quiet) {
      out
        ..add(const SizedBox(height: 8))
        ..add(
          BeamNotice(
            key: const Key('beamAmountIssue'),
            kind: BeamNoticeKind.error,
            message: issue.message,
          ),
        );
    } else if (_m.sendAll && _m.isAddress && _m.assetId == 0) {
      out
        ..add(const SizedBox(height: 4))
        ..add(
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              'The network fee comes out of this amount.',
              style: STextStyles.label(context),
            ),
          ),
        );
    }
    final warning = _m.warning;
    if (warning != null) {
      out
        ..add(const SizedBox(height: 8))
        ..add(
          BeamNotice(
            key: const Key('beamAmountWarning'),
            kind: BeamNoticeKind.warning,
            message: warning,
          ),
        );
    }
    return out;
  }

  // ------------------------------------------------------------------ fee

  Widget _feeBox(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    final fee = BeamSendFormat.beam(_m.feeEstimate);
    return RoundedContainer(
      key: const Key('beamSendFee'),
      color: c.textFieldDefaultBG,
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: _desktop ? 18 : 14,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _m.feeIsMinimum ? 'At least $fee' : fee,
              style: STextStyles.itemSubtitle12(context),
            ),
          ),
          Text(
            _m.feeIsMinimum
                ? 'Exact fee on the next screen'
                : 'Set by the network',
            style: STextStyles.label(context),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- comment

  Widget _commentField(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Constants.size.circularBorderRadius),
      child: TextField(
        key: const Key('beamSendCommentField'),
        controller: _comment,
        focusNode: _commentFocus,
        maxLength: 256,
        minLines: 1,
        maxLines: _desktop ? 3 : 1,
        style: _fieldStyle(context),
        onChanged: (v) {
          _m.comment = v;
          setState(() {});
        },
        decoration:
            beamInputDecoration(
              'Type something…',
              _commentFocus,
              context,
              desktop: _desktop,
            ).copyWith(
              counterText: '',
              contentPadding: _fieldPadding,
              suffixIcon: _comment.text.isEmpty
                  ? null
                  : UnconstrainedBox(
                      child: TextFieldIconButton(
                        onTap: () {
                          _comment.clear();
                          _m.comment = '';
                          setState(() {});
                        },
                        child: const XIcon(),
                      ),
                    ),
            ),
      ),
    );
  }
}

class _AssetList extends StatelessWidget {
  const _AssetList({required this.model, required this.onPick, this.worth});

  final BeamSendModel model;
  final void Function(int id) onPick;
  final String? Function(int assetId, BigInt amount)? worth;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<StackColors>()!;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      children: [
        for (final id in model.assetChoices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: RoundedContainer(
              key: Key('beamAssetChoice_$id'),
              color: id == model.assetId
                  ? c.textFieldActiveBG
                  : c.textFieldDefaultBG,
              onPressed: () => onPick(id),
              child: Row(
                children: [
                  BeamAssetIcon(model.assetOf(id), size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.assetOf(id).name,
                          style: STextStyles.itemSubtitle12(context),
                        ),
                        BeamAssetBadge(model.assetOf(id)),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        BeamSendFormat.amount(
                          model.available(id),
                          model.assetOf(id),
                        ),
                        style: STextStyles.itemSubtitle(context),
                      ),
                      if (worth?.call(id, model.available(id))
                          case final value?)
                        Text(
                          value,
                          key: Key('beamAssetChoiceWorth_$id'),
                          style: STextStyles.label(context),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
