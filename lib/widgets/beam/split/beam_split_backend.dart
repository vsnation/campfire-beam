/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/foundation.dart';

import '../../../wallets/beam/contracts/dex/beam_lp_tokens.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/utxo/beam_coin_split.dart';
import '../../../wallets/beam/utxo/beam_coins.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../airdrop/beam_asset_names.dart';
import '../wiring/beam_wallet_listenables.dart';

/// Everything the Split coins screens need from one wallet. The screens
/// talk to nothing else, so the same widgets run on a real wallet in the
/// app and on scripted answers in tests.
///
/// Nothing here moves coins except [confirm], and the screens call it only
/// from Campfire's PIN / password gate.
abstract interface class BeamSplitBackend {
  /// The honest sync verdict. Only one that can spend lets a split through.
  ValueListenable<BeamSyncAssessment> get sync;

  /// Fires when the wallet's balances change: the coins may have too.
  Listenable? get coinsChanged;

  /// Names, tickers and icons of assets.
  BeamAssetNames get names;

  /// The wallet's coins per asset (all of them, read from the core).
  Future<Map<int, BeamCoinSummary>> coins();

  /// A DEX pool share (LP token): never offered for a split.
  bool isPoolShare(int assetId);

  /// Why a split cannot start right now — another payment, swap or approval
  /// is open, or a restore is still looking for coins — and what happens
  /// next. Null when it can. Sync is [sync]'s to say.
  String? get blocked;

  /// Checks [plan] against the coins now and holds the wallet's node switch
  /// for the review screen. Never signs or sends.
  Future<BeamPreparedSplit> prepare(BeamSplitPlan plan);

  /// Splits [split] (`tx_split`) and returns the transaction id.
  Future<String> confirm(BeamPreparedSplit split);
}

/// [BeamSplitBackend] over a real [BeamWallet].
class BeamWalletSplitBackend implements BeamSplitBackend {
  BeamWalletSplitBackend(this.wallet) : _wiring = BeamWalletWiring.of(wallet);

  final BeamWallet wallet;
  final BeamWalletWiring _wiring;

  @override
  ValueListenable<BeamSyncAssessment> get sync => _wiring.sync;

  @override
  Listenable get coinsChanged => _wiring.balances;

  @override
  BeamAssetNames get names => _wiring.assetNames;

  @override
  Future<Map<int, BeamCoinSummary>> coins() => wallet.loadCoins();

  @override
  bool isPoolShare(int assetId) =>
      beamIsPoolShare(assetId, metadataName: _wiring.metadataOf(assetId)?.name);

  @override
  String? get blocked => wallet.splitBlocked?.message;

  @override
  Future<BeamPreparedSplit> prepare(BeamSplitPlan plan) =>
      wallet.prepareSplit(plan);

  @override
  Future<String> confirm(BeamPreparedSplit split) => wallet.confirmSplit(split);
}

/// What the Split coins route takes: the wallet, and which asset's coins
/// (BEAM unless said).
class BeamSplitArgs {
  const BeamSplitArgs(this.wallet, {this.assetId = 0});

  final BeamWallet wallet;
  final int assetId;
}

/// A DEX liquidity token: known from the DEX's pools, or by the name the
/// AMM contract gives every LP token it mints ("Amm Liquidity Token
/// 0-174-2"), for one the DEX has not been read for yet.
bool beamIsPoolShare(int assetId, {String? metadataName}) =>
    assetId != 0 &&
    (BeamLpTokens.of(assetId) != null ||
        (metadataName?.startsWith('Amm Liquidity Token') ?? false));
