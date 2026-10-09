/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';

import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../services/event_bus/events/global/blocks_remaining_event.dart';
import '../../../services/event_bus/events/global/node_connection_status_changed_event.dart';
import '../../../services/event_bus/events/global/refresh_percent_changed_event.dart';
import '../../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../../services/event_bus/global_event_bus.dart';
import '../../../wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/node/beam_private_node_coordinator.dart';
import '../../../wallets/beam/price/beam_asset_pricer.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_sync_tracker.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';

/// Everything the BEAM wallet home reads from or asks of the wallet.
///
/// [BeamWalletHomeSource] is the real one. Tests give the home widgets a
/// fake, so every state (stalled, scanning, names waiting…) can be shown
/// without a core.
abstract class BeamHomeSource {
  /// The honest sync verdict now. Synchronous: the home never
  /// waits for it.
  BeamSyncAssessment get syncAssessment;

  /// Verdicts as they change.
  Stream<BeamSyncAssessment> get syncAssessments;

  bool get canSpend;

  /// A restored wallet still looking for its coins.
  bool get isScanningForCoins;

  BeamScanProgress? get scanProgress;

  BeamPrivateNodeStatus? get privateNodeStatus;

  /// Why the core cannot be used, e.g. not installed.
  BeamWalletException? get coreProblem;

  /// The core is up for this wallet (contract reads can run).
  bool get isOpen;

  /// Fires when the wallet reports progress or a status change (Campfire's
  /// event bus), so the home re-reads the getters above.
  Stream<void> get walletEvents;

  /// Fires when this wallet's transaction history changes.
  Stream<void> get transactionsChanged;

  /// Money waiting for this wallet's BANS names.
  BansInboxMonitor get bansInbox;

  /// Asset prices from the DEX (cached by the wallet's services).
  Future<BeamAssetPricer> pricer();

  /// Builds (never sends) a claim of what waits for the user's names.
  Future<BansPrepared> prepareClaimAll();

  /// Signs and sends a claim built by [prepareClaimAll]; returns its tx id.
  Future<String> executeClaim(BansPrepared prepared);

  /// Keeps the private node from switching the wallet's connection while a
  /// money flow is open (R11). Call the returned function to let go.
  VoidCallback holdNodeSwitch(String reason);

  /// Reconnect / re-read ("Try again").
  Future<void> retry();
}

/// [BeamHomeSource] over a real [BeamWallet] and its shared services.
class BeamWalletHomeSource implements BeamHomeSource {
  BeamWalletHomeSource(this.wallet) : services = BeamWalletServices.of(wallet);

  final BeamWallet wallet;
  final BeamWalletServices services;

  @override
  BeamSyncAssessment get syncAssessment => wallet.syncAssessment;

  @override
  Stream<BeamSyncAssessment> get syncAssessments => wallet.syncAssessments;

  @override
  bool get canSpend => wallet.canSpend;

  @override
  bool get isScanningForCoins => wallet.isScanningForCoins;

  @override
  BeamScanProgress? get scanProgress => wallet.scanProgress;

  @override
  BeamPrivateNodeStatus? get privateNodeStatus => wallet.privateNodeStatus;

  @override
  BeamWalletException? get coreProblem => wallet.coreProblem;

  @override
  bool get isOpen => wallet.isOpen;

  @override
  Stream<void> get walletEvents {
    final id = wallet.walletId;
    return GlobalEventBus.instance
        .on<Object>()
        .where(
          (e) => switch (e) {
            RefreshPercentChangedEvent(:final walletId) ||
            BlocksRemainingEvent(:final walletId) ||
            WalletSyncStatusChangedEvent(:final walletId) ||
            NodeConnectionStatusChangedEvent(:final walletId) => walletId == id,
            _ => false,
          },
        )
        .map((_) {});
  }

  @override
  Stream<void> get transactionsChanged => wallet.mainDB.isar.transactionV2s
      .where()
      .walletIdEqualTo(wallet.walletId)
      .watchLazy();

  @override
  BansInboxMonitor get bansInbox => services.bansInbox;

  @override
  Future<BeamAssetPricer> pricer() => services.pricer();

  @override
  Future<BansPrepared> prepareClaimAll() => services.bans.prepareClaimAll();

  @override
  Future<String> executeClaim(BansPrepared prepared) =>
      services.bans.execute(prepared);

  @override
  VoidCallback holdNodeSwitch(String reason) => wallet
      .holdNodeSwitch(reason, maxHold: const Duration(minutes: 10))
      .release;

  @override
  Future<void> retry() => wallet.refresh();
}
