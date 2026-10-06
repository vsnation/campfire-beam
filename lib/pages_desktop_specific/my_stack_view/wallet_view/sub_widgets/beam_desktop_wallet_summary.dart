/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop header's balance for a BEAM wallet, in the slot
// `DesktopWalletSummary` fills for other coins (as Firo and MWEB have their
// own). Spec and exit-intent notes:
// lib/widgets/beam/wallet_home/beam_home_widgets.dart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../pages/wallet_view/sub_widgets/wallet_refresh_button.dart';
import '../../../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../../widgets/beam/wallet_home/beam_home_text.dart';
import '../../../../widgets/beam/wallet_home/beam_home_widgets.dart';
import '../../../../widgets/beam/wallet_home/beam_wallet_home.dart';

class BeamDesktopWalletSummary extends ConsumerWidget {
  const BeamDesktopWalletSummary({
    super.key,
    required this.walletId,
    required this.initialSyncStatus,
  });

  final String walletId;
  final WalletSyncStatus initialSyncStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(pBeamHome(walletId));
    final totals = ref.watch(pBeamAssetTotals(walletId));
    home.setHeldAssets(totals.keys.toSet());
    final names = BeamHomeText.namePayments(home.namePayments);
    return BeamDesktopBalance(
      lines: beamBalanceLines(
        balance: ref.watch(pWalletBalance(walletId)),
        totals: totals,
        format: ref.watch(pBeamHomeFormat(walletId)),
        home: home,
      ),
      refreshButton: WalletRefreshButton(
        walletId: walletId,
        initialSyncStatus: initialSyncStatus,
      ),
      nodeChip: BeamNodeChip(
        label: BeamHomeText.nodeChip(home.privateNodeStatus),
        isPrivate: BeamHomeText.onPrivateNode(home.privateNodeStatus),
        onTap: () =>
            openBeamNetworkSettings(context, ref, walletId, isDesktop: true),
      ),
      namePayments: names == null
          ? null
          : BeamNamePaymentsLine(
              text: names,
              isDesktop: true,
              onClaim: () =>
                  showBeamClaimSheet(context, ref, walletId, isDesktop: true),
            ),
    );
  }
}

/// The honest sync banner under the desktop header row. Nothing (and no
/// space) when the wallet is up to date.
class BeamDesktopSyncBanner extends ConsumerWidget {
  const BeamDesktopSyncBanner({super.key, required this.walletId});

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => BeamSyncBanner(
    content: ref.watch(pBeamHome(walletId)).banner,
    isDesktop: true,
    padding: const EdgeInsets.only(top: 16),
    onAction: (a) =>
        runBeamHomeAction(context, ref, walletId, a, isDesktop: true),
  );
}
