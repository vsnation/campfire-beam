/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — receive an asset:
//   Job:  give the sender the address this asset arrives at.
//   CTA:  "Copy address" (the QR is right above it for in-person sends).
//   Taps: open wallet → Assets → asset → Receive: 3.
//
// Exit-intent:
//   * "Do I need a special FOMO address?" → the first line says FOMO
//     arrives at the same BEAM address.
//   * "No address shown" → it says why (the wallet is still connecting)
//     instead of an empty box.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/isar/models/beam/beam_asset_contract.dart';
import '../../notifications/show_flush_bar.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/clipboard_interface.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/beam/assets/beam_asset_text.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/desktop_dialog.dart';
import '../../widgets/desktop/desktop_dialog_close_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/qr.dart';
import '../../widgets/rounded_white_container.dart';
import '../receive_view/receive_view.dart';
import 'sub_widgets/beam_asset_layout.dart';

/// Opens the receive screen for [asset] (or for assets in general): a page
/// on a phone, a dialog on desktop.
Future<void> showBeamAssetReceive({
  required BuildContext context,
  required String walletId,
  BeamAssetContract? asset,
}) async {
  if (BeamAssetLayout.isDesktop(context)) {
    await showDialog<void>(
      context: context,
      builder: (context) => DesktopDialog(
        maxWidth: 480,
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
                    'Receive ${asset?.symbol ?? 'assets'}',
                    style: STextStyles.desktopH3(context),
                  ),
                ),
                const DesktopDialogCloseButton(),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: BeamAssetReceivePanel(walletId: walletId, asset: asset),
            ),
          ],
        ),
      ),
    );
    return;
  }
  await Navigator.of(context).push(
    RouteGenerator.getRoute<void>(
      builder: (_) => BeamAssetReceiveView(walletId: walletId, asset: asset),
      settings: const RouteSettings(name: BeamAssetReceiveView.routeName),
    ),
  );
}

class BeamAssetReceiveView extends StatelessWidget {
  const BeamAssetReceiveView({super.key, required this.walletId, this.asset});

  static const String routeName = '/beamAssetReceive';

  final String walletId;
  final BeamAssetContract? asset;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: const AppBarBackButton(),
          title: Text(
            'Receive ${asset?.symbol ?? 'assets'}',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: RoundedWhiteContainer(
              padding: const EdgeInsets.all(16),
              child: BeamAssetReceivePanel(walletId: walletId, asset: asset),
            ),
          ),
        ),
      ),
    );
  }
}

/// The address an asset arrives at (the wallet's own BEAM address), its QR
/// and a copy button.
class BeamAssetReceivePanel extends ConsumerWidget {
  const BeamAssetReceivePanel({
    super.key,
    required this.walletId,
    this.asset,
    this.clipboard = const ClipboardWrapper(),
  });

  final String walletId;
  final BeamAssetContract? asset;
  final ClipboardInterface clipboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final address = ref.watch(pWalletReceivingAddress(walletId));
    final what = asset?.symbol ?? 'Every asset';
    final isDesktop = BeamAssetLayout.isDesktop(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          BeamAssetText.receiveLine(what),
          style: isDesktop
              ? STextStyles.desktopTextExtraExtraSmall(context)
              : STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 16),
        if (address.isEmpty)
          Text(
            'Your address appears as soon as the wallet has connected to the '
            'BEAM network.',
            style: STextStyles.itemSubtitle(context),
          )
        else ...[
          Center(
            child: QR(data: address, size: isDesktop ? 180 : 200),
          ),
          const SizedBox(height: 16),
          SelectableText(
            address,
            key: const Key('beamAssetReceiveAddress'),
            textAlign: TextAlign.center,
            style: STextStyles.itemSubtitle12(context)
                .copyWith(color: colors.textDark),
          ),
          const SizedBox(height: 16),
          PrimaryButton(
            key: const Key('beamAssetReceiveCopy'),
            label: 'Copy address',
            onPressed: () async {
              await clipboard.setData(ClipboardData(text: address));
              if (context.mounted) {
                unawaited(
                  showFloatingFlushBar(
                    type: FlushBarType.info,
                    message: 'Address copied',
                    context: context,
                  ),
                );
              }
            },
          ),
        ],
        if (!isDesktop) ...[
          const SizedBox(height: 12),
          Center(
            child: CustomTextButton(
              text: 'Other address types',
              onTap: () =>
                  Navigator.of(context)
                      .pushNamed(ReceiveView.routeName, arguments: walletId),
            ),
          ),
        ],
      ],
    );
  }
}
