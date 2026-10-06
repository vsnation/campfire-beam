/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BEAM Receive, phone and desktop (Campfire's ReceiveView / DesktopReceive
// show it for a BEAM wallet).
//
// Spec (USER_PSYCHOLOGY §6):
//   Job:     give someone a way to pay you.
//   Primary: "Copy address" (QR beside it for in-person payments).
//   Taps:    1 from the wallet (Receive); the address is already there.
//
// What would make an impatient person close it (§1.7), and the answer:
// - Waiting for an address: the cached one shows at once; a new wallet
//   sees "Getting your address…" and, after 3 s, why it takes a moment.
// - Not knowing if a payment will arrive: one line says the regular
//   address needs both wallets online; the offline types say what they do.
// - Private types that "don't work": they are visibly disabled with the
//   reason and the one step that enables them, never silently missing.
// - Jargon: none on screen (no SBBS, voucher, Lelantus, token).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../notifications/show_flush_bar.dart';
import '../../../pages/receive_view/addresses/wallet_addresses_view.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../custom_buttons/blue_text_button.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';
import '../stickers/beam_sticker.dart';
import 'beam_address_list.dart';
import 'beam_more_ways.dart';
import 'beam_receive_backend.dart';
import 'beam_receive_model.dart';
import 'beam_receive_text.dart';
import 'beam_receive_widgets.dart';

class BeamReceivePanel extends ConsumerStatefulWidget {
  const BeamReceivePanel({
    super.key,
    required this.walletId,
    required this.desktop,
    this.clipboard = const ClipboardWrapper(),
  });

  final String walletId;

  /// Desktop: a column inside Campfire's Send/Receive tab (its parent
  /// scrolls). Phone: the body of the Receive page, scrolling itself.
  final bool desktop;
  final ClipboardInterface clipboard;

  @override
  ConsumerState<BeamReceivePanel> createState() => _BeamReceivePanelState();
}

class _BeamReceivePanelState extends ConsumerState<BeamReceivePanel> {
  late final BeamReceiveModel _model;

  @override
  void initState() {
    super.initState();
    _model = BeamReceiveModel(
      ref.read(pBeamReceiveBackend(widget.walletId))!,
    );
    unawaited(_model.start());
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  Future<void> _newAddress() async {
    try {
      await _model.newRegularAddress();
      if (!mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.success,
          message: BeamReceiveText.newAddressReady,
          context: context,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.warning,
          message: BeamReceiveText.error(e),
          context: context,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  void _openAddresses() {
    if (!widget.desktop) {
      unawaited(
        Navigator.of(context).pushNamed(
          WalletAddressesView.routeName,
          arguments: widget.walletId,
        ),
      );
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        builder: (context) => DesktopDialog(
          maxWidth: 640,
          maxHeight: math.min(760, MediaQuery.of(context).size.height - 64),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Text(
                      'Your addresses',
                      style: STextStyles.desktopH3(context),
                    ),
                  ),
                  const DesktopDialogCloseButton(),
                ],
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                  child: BeamAddressList(
                    walletId: widget.walletId,
                    desktop: true,
                    clipboard: widget.clipboard,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _model,
    builder: (context, _) {
      final address = _model.address;
      final desktop = widget.desktop;
      final column = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _AddressCard(model: _model, desktop: desktop),
          const SizedBox(height: 12),
          PrimaryButton(
            key: BeamReceiveKeys.copy,
            label: BeamReceiveText.copy,
            buttonHeight: desktop ? ButtonHeight.l : null,
            enabled: address != null,
            onPressed: address == null
                ? null
                : () => beamCopy(context, widget.clipboard, address),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SecondaryButton(
                  key: BeamReceiveKeys.share,
                  label: BeamReceiveText.share,
                  buttonHeight: desktop ? ButtonHeight.l : null,
                  enabled: address != null,
                  onPressed: address == null
                      ? null
                      : () => _model.backend.share(address),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SecondaryButton(
                  key: BeamReceiveKeys.newAddress,
                  label: _model.makingRegular
                      ? BeamReceiveText.making
                      : BeamReceiveText.newAddress,
                  buttonHeight: desktop ? ButtonHeight.l : null,
                  enabled: _model.connected && !_model.makingRegular,
                  onPressed: _model.connected && !_model.makingRegular
                      ? _newAddress
                      : null,
                ),
              ),
            ],
          ),
          if (_model.names.isNotEmpty) ...[
            const SizedBox(height: 16),
            _NameCard(
              names: _model.names,
              clipboard: widget.clipboard,
              desktop: desktop,
            ),
          ],
          const SizedBox(height: 16),
          BeamMoreWaysToReceive(
            model: _model,
            clipboard: widget.clipboard,
            desktop: desktop,
          ),
          const SizedBox(height: 16),
          Center(
            child: CustomTextButton(
              key: BeamReceiveKeys.allAddresses,
              text: BeamReceiveText.allAddresses,
              onTap: _openAddresses,
            ),
          ),
        ],
      );
      if (desktop) return column;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: column,
      );
    },
  );
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.model, required this.desktop});

  final BeamReceiveModel model;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final address = model.address;
    return BeamCard(
      desktop: desktop,
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, box) {
          final qr = math.min(box.maxWidth, desktop ? 220.0 : 200.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      BeamReceiveText.yourAddress,
                      style: desktop
                          ? STextStyles.desktopTextExtraSmall(
                              context,
                            ).copyWith(color: colors.textDark3)
                          : STextStyles.itemSubtitle(context),
                    ),
                  ),
                  // The Beam girl, small: decoration only, never pushing
                  // the QR code or the copy button down.
                  BeamStickerImage(
                    BeamMoments.receive,
                    size: desktop ? 52 : 40,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (address != null) ...[
                Center(
                  child: BeamReceiveQr(
                    key: BeamReceiveKeys.qr,
                    address: address,
                    size: qr,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  address,
                  key: BeamReceiveKeys.address,
                  textAlign: TextAlign.center,
                  style: desktop
                      ? STextStyles.desktopTextExtraExtraSmall(
                          context,
                        ).copyWith(color: colors.textDark)
                      : STextStyles.itemSubtitle12(context),
                ),
                const SizedBox(height: 10),
                const BeamNote(
                  BeamReceiveText.regularExplainer,
                  key: BeamReceiveKeys.explainer,
                ),
                if (model.offline) ...[
                  const SizedBox(height: 6),
                  const BeamNote(BeamReceiveText.offlineWarning, warning: true),
                ],
              ] else if (model.problem != null)
                _Problem(model: model, size: qr)
              else
                _Waiting(slow: model.slow, size: qr),
            ],
          );
        },
      ),
    );
  }
}

class _Waiting extends StatelessWidget {
  const _Waiting({required this.slow, required this.size});

  final bool slow;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: size),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: colors.accentColorDark,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              BeamReceiveText.gettingAddress,
              style: STextStyles.w500_14(context),
            ),
            if (slow) ...[
              const SizedBox(height: 6),
              Text(
                BeamReceiveText.gettingAddressSlow,
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle12(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Problem extends StatelessWidget {
  const _Problem({required this.model, required this.size});

  final BeamReceiveModel model;
  final double size;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(minHeight: size),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          BeamReceiveText.cantGetAddress,
          textAlign: TextAlign.center,
          style: STextStyles.w600_14(context),
        ),
        const SizedBox(height: 6),
        Text(
          model.problem!,
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle12(context),
        ),
        const SizedBox(height: 12),
        Center(
          child: SecondaryButton(
            key: BeamReceiveKeys.tryAgain,
            width: 160,
            label: BeamReceiveText.tryAgain,
            buttonHeight: ButtonHeight.m,
            onPressed: () => unawaited(model.reload()),
          ),
        ),
      ],
    ),
  );
}

/// "Your name: alice.beam": the BANS names this wallet owns, which people
/// can pay instead of an address.
class _NameCard extends StatelessWidget {
  const _NameCard({
    required this.names,
    required this.clipboard,
    required this.desktop,
  });

  final List<String> names;
  final ClipboardInterface clipboard;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return BeamCard(
      key: BeamReceiveKeys.nameCard,
      desktop: desktop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final name in names)
            Row(
              children: [
                Text(
                  '${BeamReceiveText.yourName}: ',
                  style: STextStyles.itemSubtitle(context),
                ),
                Expanded(
                  child: Text(
                    name,
                    overflow: TextOverflow.ellipsis,
                    style: STextStyles.w600_14(context),
                  ),
                ),
                IconButton(
                  key: BeamReceiveKeys.nameCopy(name),
                  tooltip: 'Copy $name',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => beamCopy(
                    context,
                    clipboard,
                    name,
                    message: BeamReceiveText.nameCopied,
                  ),
                  icon: SvgPicture.asset(
                    Assets.svg.copy,
                    width: 14,
                    height: 14,
                    colorFilter: ColorFilter.mode(
                      colors.infoItemIcons,
                      BlendMode.srcIn,
                    ),
                  ),
                ),
              ],
            ),
          Text(
            BeamReceiveText.nameExplainer,
            style: STextStyles.itemSubtitle12(context),
          ),
        ],
      ),
    );
  }
}
