/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../wallet/impl/beam_wallet.dart';
import '../../models/beam_asset_info.dart';
import '../../rpc/beam_transport.dart';
import '../../sync/beam_sync_messages.dart';
import '../../wallet/beam_wallet_services.dart';
import '../dapp_identity.dart';
import 'dapp_shared_transport.dart';
import 'dapp_wallet_link.dart';

/// [DappWalletLink] over an open [BeamWallet].
///
/// * Every dApp page talks through [BeamWalletServices.transport] (the
///   wallet's current core connection, which follows node handovers), via a
///   [DappSharedTransport] of its own.
/// * dApps are installed under the wallet's own folder
///   (`<beam>/wallets/<walletId>/dapps/…`), so they belong to this wallet.
/// * Approvals are refused while [BeamWallet.canSpend] is false, and hold
///   the node switch while on screen.
class BeamWalletDappLink implements DappWalletLink {
  BeamWalletDappLink(this.wallet, {BeamWalletServices? services})
    : services = services ?? BeamWalletServices.of(wallet);

  final BeamWallet wallet;
  final BeamWalletServices services;

  /// An approval left open longer than this stops holding the node switch.
  static const maxApprovalHold = Duration(minutes: 15);

  @override
  Future<String> dappsRoot() => wallet.environment.walletDir(wallet.walletId);

  @override
  BeamTransport dappTransport(DappIdentity dapp) =>
      DappSharedTransport(services.transport, api: services.api);

  @override
  Future<Map<int, BigInt>?> availableBalances() async {
    try {
      final s = await services.api.walletStatus();
      if (s.totals.isEmpty) {
        final beam = s.available;
        return beam == null ? null : {0: beam};
      }
      return {for (final t in s.totals) t.assetId: t.available};
    } catch (_) {
      return null;
    }
  }

  @override
  Future<BeamAssetMetadata?> assetMetadata(int assetId) async {
    try {
      return (await services.api.getAssetInfo(assetId)).metadata;
    } catch (_) {
      return null;
    }
  }

  @override
  String? get spendBlockedReason {
    if (wallet.canSpend) return null;
    final m = BeamSyncMessages.describe(wallet.syncAssessment);
    final detail = m.detail;
    if (detail == null) return m.title;
    final end = m.title.endsWith('.') ? '' : '.';
    return '${m.title}$end $detail';
  }

  @override
  void Function() holdForApproval(String reason) =>
      wallet.holdNodeSwitch(reason, maxHold: maxApprovalHold).release;
}
