/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/isar/models/beam/beam_asset_contract.dart';
import '../../pages_desktop_specific/my_stack_view/wallet_view/beam_desktop_asset_view.dart';
import '../../route_generator.dart';
import '../../utilities/logger.dart';
import '../../wallets/beam/assets/beam_asset_providers.dart';
import '../../wallets/isar/providers/beam/current_beam_asset_wallet_provider.dart';
import '../../wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import 'beam_asset_send_view.dart';
import 'beam_asset_view.dart';
import 'sub_widgets/beam_asset_layout.dart';

/// Opens [asset]'s page: makes its [BeamAssetWallet] current (like
/// `MyTokenSelectItem` does for Ethereum tokens) and shows it at once from
/// the cache; nothing waits for the core (R11).
Future<void> openBeamAsset({
  required BuildContext context,
  required WidgetRef ref,
  required String walletId,
  required BeamAssetContract asset,
}) async {
  final parent = ref.read(pBeamWallet(walletId));
  if (parent == null) return;
  final old = ref.read(beamAssetWalletStateProvider);
  if (old != null) unawaited(old.exit());
  final wallet = BeamAssetWallet.load(parent: parent, asset: asset);
  ref.read(beamAssetWalletStateProvider.state).state = wallet;
  unawaited(() async {
    try {
      await wallet.init();
    } catch (e) {
      Logging.instance.w("BEAM: asset ${asset.assetId} init: $e");
    }
  }());
  final desktop = BeamAssetLayout.isDesktop(context);
  await Navigator.of(context).push(
    RouteGenerator.getRoute<void>(
      builder: (_) => desktop
          ? BeamDesktopAssetView(walletId: walletId)
          : BeamAssetView(walletId: walletId),
      settings: RouteSettings(
        name: desktop
            ? BeamDesktopAssetView.routeName
            : BeamAssetView.routeName,
      ),
    ),
  );
}

/// The send screen of the current asset wallet (phone; desktop has it as a
/// tab on the asset page).
Future<void> openBeamAssetSend(BuildContext context, String walletId) =>
    Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        builder: (_) => BeamAssetSendView(walletId: walletId),
        settings: const RouteSettings(name: BeamAssetSendView.routeName),
      ),
    );
