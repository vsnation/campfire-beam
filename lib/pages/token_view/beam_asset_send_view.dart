/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec: see sub_widgets/beam_asset_send_form.dart (the page is the form).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import 'sub_widgets/beam_asset_send_form.dart';

/// The phone's send page of the current asset wallet.
class BeamAssetSendView extends ConsumerWidget {
  const BeamAssetSendView({super.key, required this.walletId});

  static const String routeName = '/beamAssetSend';

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final assetWallet = ref.watch(pCurrentBeamAssetWallet);
    if (assetWallet == null) return const SizedBox.shrink();
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: const AppBarBackButton(),
          title: Text(
            'Send ${assetWallet.tokenSymbol}',
            style: STextStyles.navBarTitle(context),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: BeamAssetSendForm(
              walletId: walletId,
              assetWallet: assetWallet,
              onSent: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }
}
