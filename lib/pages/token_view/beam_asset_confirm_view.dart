/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §6) — confirm an asset payment:
//   Job:  show exactly what will happen before it happens: which asset, how
//         much, the BEAM fee, where it goes, how it arrives.
//   CTA:  "Send 12.5 FOMO" (the outcome), behind Campfire's PIN / password.
//   Taps: … Review → Send: 1 more, plus the PIN.
//
// Exit-intent (§1.7):
//   * "Am I sending the right token?" → the asset row names it with its
//     number, and a copycat is flagged in red right here.
//   * "Will it take FOMO for the fee?" → the fee row says it is BEAM.
//   * "Did it go?" → success says so and the history shows it; a failure
//     says what happened and that nothing was sent when that is certain.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/isar/models/beam/beam_asset_contract.dart';
import '../../notifications/show_flush_bar.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_auth_send.dart';
import '../../providers/global/locale_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/show_loading.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/beam/assets/beam_asset_text.dart';
import '../../wallets/beam/models/beam_address.dart';
import '../../wallets/beam/wallet/beam_send_rules.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/rounded_white_container.dart';
import '../../widgets/stack_dialog.dart';
import '../pinpad_views/lock_screen_view.dart';
import 'sub_widgets/beam_asset_icon.dart';
import 'sub_widgets/beam_asset_layout.dart';

/// Proves it is the user before money moves: true only when they did.
typedef BeamAssetAuthorizer = Future<bool> Function(BuildContext context);

/// Shows the confirm screen (page on a phone, dialog on desktop). Completes
/// with true once the payment was sent.
Future<bool?> showBeamAssetConfirm({
  required BuildContext context,
  required String walletId,
  required BeamAssetWallet assetWallet,
  required TxData txData,
}) {
  if (BeamAssetLayout.isDesktop(context)) {
    return showDialog<bool>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Text(
                    'Confirm payment',
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: BeamAssetConfirmView(
                  walletId: walletId,
                  assetWallet: assetWallet,
                  txData: txData,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  return Navigator.of(context).push<bool>(
    RouteGenerator.getRoute<bool>(
      builder: (_) => BeamAssetConfirmView(
        walletId: walletId,
        assetWallet: assetWallet,
        txData: txData,
      ),
      settings: const RouteSettings(name: BeamAssetConfirmView.routeName),
    ),
  );
}

/// Campfire's own gate, as `ConfirmTransactionView` uses it: the wallet
/// password on desktop, the PIN screen (with biometrics when enabled) on a
/// phone.
Future<bool> campfireAuthorizeBeamAssetSend(BuildContext context) async {
  final bool? unlocked;
  if (BeamAssetLayout.isDesktop(context)) {
    unlocked = await showDialog<bool?>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 580,
        maxHeight: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [DesktopDialogCloseButton()],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 32, right: 32, bottom: 32),
              child: DesktopAuthSend(coin: Beam(CryptoCurrencyNetwork.main)),
            ),
          ],
        ),
      ),
    );
  } else {
    unlocked = await Navigator.push<bool>(
      context,
      RouteGenerator.getRoute<bool>(
        builder: (_) => const LockscreenView(
          showBackButton: true,
          popOnSuccess: true,
          routeOnSuccessArguments: true,
          routeOnSuccess: "",
          biometricsCancelButtonString: "CANCEL",
          biometricsLocalizedReason: "Authenticate to send transaction",
          biometricsAuthenticationTitle: "Confirm Transaction",
        ),
        settings: const RouteSettings(name: "/beamAssetSendLockscreen"),
      ),
    );
  }
  if (unlocked == false && context.mounted) {
    unawaited(
      showFloatingFlushBar(
        type: FlushBarType.warning,
        message: BeamAssetLayout.isDesktop(context)
            ? "Invalid passphrase"
            : "Invalid PIN",
        context: context,
      ),
    );
  }
  return unlocked == true;
}

class BeamAssetConfirmView extends ConsumerStatefulWidget {
  const BeamAssetConfirmView({
    super.key,
    required this.walletId,
    required this.assetWallet,
    required this.txData,
    this.authorize = campfireAuthorizeBeamAssetSend,
  });

  static const String routeName = '/beamAssetConfirm';

  final String walletId;
  final BeamAssetWallet assetWallet;
  final TxData txData;
  final BeamAssetAuthorizer authorize;

  @override
  ConsumerState<BeamAssetConfirmView> createState() =>
      _BeamAssetConfirmViewState();
}

class _BeamAssetConfirmViewState extends ConsumerState<BeamAssetConfirmView> {
  bool _sending = false;

  BeamAssetContract get _asset => widget.assetWallet.asset;

  Future<void> _send(String amountText) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      if (!await widget.authorize(context) || !mounted) return;
      final ({TxData? tx, Object? error})? outcome = await showLoading(
        context: context,
        rootNavigator: BeamAssetLayout.isDesktop(context),
        message: 'Sending $amountText',
        whileFuture: () async {
          try {
            return (
              tx: await widget.assetWallet.confirmSend(txData: widget.txData),
              error: null,
            );
          } catch (e) {
            return (tx: null, error: e);
          }
        }(),
      );
      if (!mounted) return;
      if (outcome?.tx == null) {
        await showDialog<void>(
          context: context,
          builder: (_) => StackOkDialog(
            title: 'Payment not sent',
            message: '${outcome?.error ?? 'Something went wrong. Try again.'}',
            desktopPopRootNavigator: BeamAssetLayout.isDesktop(context),
            maxWidth: BeamAssetLayout.isDesktop(context) ? 480 : null,
          ),
        );
        return;
      }
      final nav = Navigator.of(context);
      unawaited(
        showFloatingFlushBar(
          type: FlushBarType.success,
          message: 'Sent $amountText',
          context: context,
        ),
      );
      nav.pop(true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final isDesktop = BeamAssetLayout.isDesktop(context);
    final locale = ref.watch(
      localeServiceChangeNotifierProvider.select((s) => s.locale),
    );
    final recipient = widget.txData.recipients!.single;
    final fee = widget.txData.fee!;
    final amountText = BeamAssetText.exact(
      recipient.amount,
      _asset,
      locale: locale,
    );
    final type = BeamAssetWallet.preparedAddressType(widget.txData);
    final mode = type == null || type == BeamAddressType.unknown
        ? null
        : BeamSendMode.forType(type);
    final warning = BeamAssetText.impersonation(_asset);
    final assetLine = _asset.isPoolShare
        ? '${_asset.name} ${_asset.idLabel}'
        : _asset.verified
        ? '${_asset.name == _asset.symbol ? _asset.name : '${_asset.name} '
                    '(${_asset.symbol})'} · verified'
        : '${_asset.name} ${_asset.idLabel} · unverified';

    final labelStyle = isDesktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
        : STextStyles.smallMed12(context);
    final valueStyle = isDesktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
              .copyWith(color: colors.textDark)
        : STextStyles.itemSubtitle12(context);

    Widget row(String label, Widget value, {Key? key}) => Padding(
      key: key,
      padding: const EdgeInsets.only(bottom: 8),
      child: RoundedWhiteContainer(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: labelStyle),
            const SizedBox(height: 4),
            value,
          ],
        ),
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row(
          'You send',
          Row(
            children: [
              BeamAssetIcon(asset: _asset, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    amountText,
                    key: const Key('beamAssetConfirmAmount'),
                    style: STextStyles.pageTitleH2(context),
                  ),
                ),
              ),
            ],
          ),
        ),
        row(
          'Asset',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(assetLine, style: valueStyle),
              if (warning != null) ...[
                const SizedBox(height: 4),
                Text(
                  warning,
                  style: valueStyle.copyWith(color: colors.textError),
                ),
              ],
            ],
          ),
        ),
        row(
          'To',
          SelectableText(
            recipient.address,
            key: const Key('beamAssetConfirmAddress'),
            style: valueStyle,
          ),
        ),
        row(
          'Network fee',
          Text(
            '${BeamAssetText.beam(fee.raw, locale: locale)}, paid in BEAM',
            key: const Key('beamAssetConfirmFee'),
            style: valueStyle,
          ),
        ),
        if (mode != null)
          row('How it arrives', Text(mode.explanation, style: valueStyle)),
        SizedBox(height: isDesktop ? 20 : 8),
        PrimaryButton(
          key: const Key('beamAssetConfirmSend'),
          label: 'Send $amountText',
          buttonHeight: isDesktop ? ButtonHeight.l : null,
          enabled: !_sending,
          onPressed: _sending ? null : () => _send(amountText),
        ),
      ],
    );

    if (isDesktop) return SingleChildScrollView(child: content);

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: const AppBarBackButton(),
          title: Text(
            'Confirm payment',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: content,
          ),
        ),
      ),
    );
  }
}
