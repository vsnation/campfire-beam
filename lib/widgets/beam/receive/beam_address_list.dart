/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The wallet's own BEAM addresses (Campfire's "Wallet addresses").
//
// Spec:
//   Job:     see which addresses can still be paid, and tidy them up.
//   Primary: none while there are addresses (copy, label and delete are
//            per address); "Get my address" when there are none.
//   Taps:    2 from the wallet (Receive → list).
//
// Exit risks: a wall of dead addresses (expired ones are folded
// behind a count); deleting by accident (a confirmation says what deleting
// means); an empty or failed list (each says what to do, with a button).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../../../pages/receive_view/addresses/address_tag.dart';
import '../../stack_dialog.dart';
import '../../stack_text_field.dart';
import 'beam_receive_backend.dart';
import 'beam_receive_model.dart';
import 'beam_receive_text.dart';
import 'beam_receive_widgets.dart';

abstract final class BeamAddressListKeys {
  static const expiredHeader = ValueKey('beamAddresses.expired');
  static const empty = ValueKey('beamAddresses.empty');
  static const error = ValueKey('beamAddresses.error');
  static const labelField = ValueKey('beamAddresses.labelField');
  static const saveLabel = ValueKey('beamAddresses.saveLabel');
  static const confirmDelete = ValueKey('beamAddresses.confirmDelete');
  static ValueKey<String> tile(String address) =>
      ValueKey('beamAddresses.tile.$address');
  static ValueKey<String> copy(String address) =>
      ValueKey('beamAddresses.copy.$address');
  static ValueKey<String> edit(String address) =>
      ValueKey('beamAddresses.edit.$address');
  static ValueKey<String> delete(String address) =>
      ValueKey('beamAddresses.delete.$address');
}

class BeamAddressList extends ConsumerStatefulWidget {
  const BeamAddressList({
    super.key,
    required this.walletId,
    required this.desktop,
    this.clipboard = const ClipboardWrapper(),
  });

  final String walletId;
  final bool desktop;
  final ClipboardInterface clipboard;

  @override
  ConsumerState<BeamAddressList> createState() => _BeamAddressListState();
}

class _BeamAddressListState extends ConsumerState<BeamAddressList> {
  late final BeamReceiveModel _model;
  bool _showExpired = false;

  @override
  void initState() {
    super.initState();
    _model = BeamReceiveModel(
      ref.read(pBeamReceiveBackend(widget.walletId))!,
    );
    unawaited(_model.start(ensureAddress: false));
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  void _flush(String message, {bool ok = true}) {
    if (!mounted) return;
    unawaited(
      showFloatingFlushBar(
        type: ok ? FlushBarType.success : FlushBarType.warning,
        message: message,
        context: context,
        duration: ok
            ? const Duration(milliseconds: 1500)
            : const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _edit(BeamAddress a) async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => _EditLabelDialog(
        initial: a.comment,
        desktop: widget.desktop,
      ),
    );
    if (label == null || label.trim() == a.comment) return;
    try {
      await _model.rename(a, label);
      _flush(BeamReceiveText.labelSaved);
    } catch (e) {
      _flush(BeamReceiveText.error(e), ok: false);
    }
  }

  Future<void> _delete(BeamAddress a) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => StackDialog(
        width: widget.desktop ? 460 : null,
        title: BeamReceiveText.deleteTitle,
        message: BeamReceiveText.deleteMessage,
        leftButton: SecondaryButton(
          label: BeamReceiveText.cancel,
          buttonHeight: widget.desktop ? ButtonHeight.l : null,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        rightButton: PrimaryButton(
          key: BeamAddressListKeys.confirmDelete,
          label: BeamReceiveText.delete,
          buttonHeight: widget.desktop ? ButtonHeight.l : null,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ),
    );
    if (sure != true) return;
    try {
      await _model.delete(a);
      _flush(BeamReceiveText.deleted);
    } catch (e) {
      _flush(BeamReceiveText.error(e), ok: false);
    }
  }

  Future<void> _makeFirst() async {
    try {
      await _model.makeFirstAddress();
    } catch (e) {
      _flush(BeamReceiveText.error(e), ok: false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, _) {
      final own = _model.ownAddresses;
      if (own == null) {
        final error = _model.listError;
        return error == null
            ? _Message(
                title: 'Getting your addresses…',
                busy: true,
                body: _model.slow ? BeamReceiveText.gettingAddressSlow : null,
              )
            : _Message(
                key: BeamAddressListKeys.error,
                title: BeamReceiveText.cantShowAddresses,
                body: BeamReceiveText.error(error),
                action: BeamReceiveText.tryAgain,
                onAction: () => unawaited(_model.reload()),
                desktop: widget.desktop,
              );
      }
      final active = _model.active;
      final expired = _model.expired;
      if (active.isEmpty && expired.isEmpty) {
        return _Message(
          key: BeamAddressListKeys.empty,
          title: BeamReceiveText.noAddresses,
          body: BeamReceiveText.noAddressesHint,
          action: BeamReceiveText.getMyAddress,
          primary: true,
          onAction: _model.makingRegular ? null : _makeFirst,
          desktop: widget.desktop,
        );
      }
      final shown = _model.receiveAddress?.address;
      Widget tile(BeamAddress a) => _AddressTile(
        address: a,
        desktop: widget.desktop,
        onReceive: a.address == shown,
        onCopy: () => beamCopy(context, widget.clipboard, a.address),
        onEdit: () => _edit(a),
        onDelete: () => _delete(a),
      );
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          const _Section(text: BeamReceiveText.active),
          if (active.isEmpty)
            _Message(
              key: BeamAddressListKeys.empty,
              title: 'No active address',
              body: BeamReceiveText.noAddressesHint,
              action: BeamReceiveText.getMyAddress,
              primary: true,
              onAction: _model.makingRegular ? null : _makeFirst,
              desktop: widget.desktop,
              compact: true,
            ),
          for (final a in active) ...[tile(a), const SizedBox(height: 10)],
          if (expired.isNotEmpty) ...[
            const SizedBox(height: 6),
            BeamCard(
              key: BeamAddressListKeys.expiredHeader,
              desktop: widget.desktop,
              onPressed: () => setState(() => _showExpired = !_showExpired),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      BeamReceiveText.expiredCount(expired.length),
                      style: STextStyles.w600_14(context),
                    ),
                  ),
                  SvgPicture.asset(
                    _showExpired
                        ? Assets.svg.chevronUp
                        : Assets.svg.chevronDown,
                    width: 12,
                    height: 6,
                    colorFilter: ColorFilter.mode(
                      Theme.of(
                        context,
                      ).extension<StackColors>()!.textSubtitle1,
                      BlendMode.srcIn,
                    ),
                  ),
                ],
              ),
            ),
            if (_showExpired)
              for (final a in expired) ...[
                const SizedBox(height: 10),
                tile(a),
              ],
          ],
        ],
      );
    },
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text,
      style: STextStyles.itemSubtitle(context).copyWith(
        color: Theme.of(context).extension<StackColors>()!.textSubtitle1,
      ),
    ),
  );
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({
    required this.address,
    required this.desktop,
    required this.onReceive,
    required this.onCopy,
    required this.onEdit,
    required this.onDelete,
  });

  final BeamAddress address;
  final bool desktop;
  final bool onReceive;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final a = address;
    final hasLabel = a.comment.trim().isNotEmpty;
    return BeamCard(
      key: BeamAddressListKeys.tile(a.address),
      desktop: desktop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                BeamReceiveText.typeLabel(a.type),
                style: STextStyles.w600_12(context).copyWith(
                  color: a.expired
                      ? colors.textSubtitle1
                      : colors.accentColorDark,
                ),
              ),
              if (onReceive) ...[
                const Spacer(),
                const AddressTag(tag: BeamReceiveText.onReceive),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasLabel ? a.comment : BeamReceiveText.noLabel,
            style: hasLabel
                ? STextStyles.w500_14(context)
                : STextStyles.w500_14(
                    context,
                  ).copyWith(color: colors.textSubtitle2),
          ),
          const SizedBox(height: 4),
          Text(
            BeamReceiveText.short(a.address),
            style: STextStyles.itemSubtitle12(
              context,
            ).copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 2),
          Text(
            BeamReceiveText.lifetime(a),
            style: STextStyles.itemSubtitle12(
              context,
            ).copyWith(color: colors.textSubtitle1),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 20,
            runSpacing: 4,
            children: [
              CustomTextButton(
                key: BeamAddressListKeys.copy(a.address),
                text: 'Copy',
                onTap: onCopy,
              ),
              CustomTextButton(
                key: BeamAddressListKeys.edit(a.address),
                text: BeamReceiveText.editLabel,
                onTap: onEdit,
              ),
              CustomTextButton(
                key: BeamAddressListKeys.delete(a.address),
                text: BeamReceiveText.delete,
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Loading, empty and error states: what is happening, and the one thing
/// to do about it.
class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.title,
    this.body,
    this.action,
    this.onAction,
    this.busy = false,
    this.primary = false,
    this.desktop = false,
    this.compact = false,
  });

  final String title;
  final String? body;
  final String? action;
  final VoidCallback? onAction;
  final bool busy;
  final bool primary;
  final bool desktop;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final button = action == null
        ? null
        : primary
        ? PrimaryButton(
            label: action,
            buttonHeight: desktop ? ButtonHeight.l : null,
            enabled: onAction != null,
            onPressed: onAction,
          )
        : SecondaryButton(
            label: action,
            buttonHeight: desktop ? ButtonHeight.l : null,
            enabled: onAction != null,
            onPressed: onAction,
          );
    final content = BeamCard(
      desktop: desktop,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) ...[
            Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: colors.accentColorDark,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            title,
            textAlign: TextAlign.center,
            style: STextStyles.w600_14(context),
          ),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body!,
              textAlign: TextAlign.center,
              style: STextStyles.itemSubtitle12(context),
            ),
          ],
          if (button != null) ...[const SizedBox(height: 16), button],
        ],
      ),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: content,
      );
    }
    return Align(alignment: Alignment.topCenter, child: content);
  }
}

class _EditLabelDialog extends StatefulWidget {
  const _EditLabelDialog({required this.initial, required this.desktop});

  final String initial;
  final bool desktop;

  @override
  State<_EditLabelDialog> createState() => _EditLabelDialogState();
}

class _EditLabelDialogState extends State<_EditLabelDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  final _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StackDialogBase(
    width: widget.desktop ? 460 : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          BeamReceiveText.editLabel,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: TextField(
            key: BeamAddressListKeys.labelField,
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            maxLength: 64,
            style: STextStyles.field(context),
            decoration: standardInputDecoration(
              BeamReceiveText.labelHint,
              _focus,
              context,
            ).copyWith(counterText: ''),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: SecondaryButton(
                label: BeamReceiveText.cancel,
                buttonHeight: widget.desktop ? ButtonHeight.l : null,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: PrimaryButton(
                key: BeamAddressListKeys.saveLabel,
                label: BeamReceiveText.saveLabel,
                buttonHeight: widget.desktop ? ButtonHeight.l : null,
                onPressed: () => Navigator.of(context).pop(_controller.text),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
