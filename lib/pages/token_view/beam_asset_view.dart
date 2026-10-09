/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec — one asset (Campfire's token page for BEAM):
//   Job:  how much of this asset do I have, what is it worth, what happened
//         to it — and move it.
//   CTA:  Send / Receive, Campfire's two token buttons (R4: kept as a pair,
//         the same weight they have on every Campfire token page).
//   Taps: open wallet → Assets → asset: 2; Send: 3.
//
// Exit-intent:
//   * "Is this the real FOMO?" → unverified assets say so under the balance,
//     copycats in red with the verified asset's number.
//   * "What is it worth?" → the DEX estimate, labelled as one; "No price"
//     when no pool prices it (never "0").
//   * "Where did my payment go?" → this asset's history, in Campfire's rows.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/isar/models/beam/beam_asset_contract.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import 'beam_asset_navigation.dart';
import 'beam_asset_receive_view.dart';
import 'sub_widgets/beam_asset_icon.dart';
import 'sub_widgets/beam_asset_summary.dart';
import 'sub_widgets/beam_asset_transactions_list.dart';

class BeamAssetView extends ConsumerWidget {
  const BeamAssetView({super.key, required this.walletId});

  static const String routeName = "/beamAsset";

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final assetWallet = ref.watch(pCurrentBeamAssetWallet);
    if (assetWallet == null) return const SizedBox.shrink();
    final asset = assetWallet.asset;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          leading: const AppBarBackButton(),
          centerTitle: true,
          title: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              BeamAssetIcon(asset: asset, size: 24, surface: colors.background),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  // A copy of a verified asset must not title itself like
                  // the real one: unverified assets carry their number.
                  asset.verified || asset.isPoolShare
                      ? asset.name
                      : '${asset.name} ${asset.idLabel}',
                  style: STextStyles.navBarTitle(context),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: BeamAssetSummary(
                  walletId: walletId,
                  asset: asset,
                  onReceive: () => unawaited(
                    showBeamAssetReceive(
                      context: context,
                      walletId: walletId,
                      asset: asset,
                    ),
                  ),
                  onSend: () => unawaited(openBeamAssetSend(context, walletId)),
                ),
              ),
              const SizedBox(height: 20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  "Transactions",
                  style: STextStyles.itemSubtitle(context)
                      .copyWith(color: colors.textDark3),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: BeamAssetTransactionsList(
                    walletId: walletId,
                    assetWallet: assetWallet,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
