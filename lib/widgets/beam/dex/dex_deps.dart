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
import 'package:flutter/widgets.dart';

import '../../../utilities/util.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/dex/beam_dex_service.dart';
import '../../../wallets/beam/contracts/dex/beam_pool.dart';
import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../../wallets/beam/models/beam_wallet_status.dart';
import '../../../wallets/beam/price/beam_asset_pricer.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';

/// Asks the user to prove it is them before money moves (Campfire's PIN on
/// mobile, the wallet password on desktop).
///
/// Returns true when the user passed, false when the PIN or password was
/// wrong, and null when they backed out.
typedef BeamDexAuthGate = Future<bool?> Function(
  BuildContext context, {
  required String reason,
});

/// The user's fiat price of BEAM, for "≈ $1.20" hints.
@immutable
class BeamDexFiat {
  const BeamDexFiat({required this.perBeam, required this.currency});

  /// Fiat units per whole BEAM.
  final BeamRatio perBeam;

  /// ISO code, e.g. "USD".
  final String currency;
}

/// Everything the DEX screens need, handed in by whoever opens them.
///
/// The screens own no wallet state: balances, sync and prices come from
/// listenables the wallet already keeps, so the DEX never waits for the
/// core to show what is known (R11).
class BeamDexDeps {
  BeamDexDeps({
    required this.dex,
    required this.sync,
    required this.balances,
    required this.authenticate,
    this.metadataOf = _noMetadata,
    this.fiat,
    this.onSyncAction,
    this.isDesktop,
    BeamDexPoolStore? pools,
  }) : pools = pools ?? BeamDexPoolStore(dex);

  /// The AMM service for this wallet.
  final BeamDexService dex;

  /// The honest sync verdict. Only [BeamSynced] may spend.
  final ValueListenable<BeamSyncAssessment> sync;

  /// Per asset id, the wallet's totals from `wallet_status`.
  final ValueListenable<Map<int, BeamAssetTotals>> balances;

  /// On-chain metadata of an asset the wallet knows, for unverified names.
  final BeamAssetMetadata? Function(int assetId) metadataOf;

  /// Campfire's PIN / password gate. In the app this is
  /// `campfireDexAuthGate` (`dex_auth_gate.dart`), kept out of this file so
  /// the DEX screens do not import the lock screen and the rest of the app
  /// with it.
  final BeamDexAuthGate authenticate;

  /// The BEAM price in the user's currency, when known.
  final ValueListenable<BeamDexFiat?>? fiat;

  /// Runs the sync banner's action ("Try another node", …).
  final void Function(BeamSyncAction action)? onSyncAction;

  /// Forces the desktop or mobile layout; null follows the platform.
  final bool? isDesktop;

  /// Pools, shared by every DEX screen of this wallet.
  final BeamDexPoolStore pools;

  static BeamAssetMetadata? _noMetadata(int assetId) => null;

  bool get desktop => isDesktop ?? Util.isDesktop;

  bool get canSpend => sync.value.canSpend;

  BeamAssetDisplay display(int assetId) =>
      BeamAssetCatalog.display(assetId, metadataOf(assetId));

  /// What the wallet can spend of [assetId] right now.
  BigInt available(int assetId) =>
      balances.value[assetId]?.available ?? BigInt.zero;

  /// The pool whose LP token is [assetId], if it is one.
  BeamPool? poolOfLpToken(int assetId) {
    for (final p in pools.all ?? const <BeamPool>[]) {
      if (p.lpToken == assetId) return p;
    }
    return null;
  }

  /// "BEAM/FOMO", in pool order.
  String pairLabel(BeamPool pool) =>
      '${display(pool.aid1).symbol}/${display(pool.aid2).symbol}';

  /// How an asset is named in a sentence. LP tokens are named after their
  /// pool, because their own metadata is a meaningless "Asset #175".
  String assetName(int assetId) {
    final pool = poolOfLpToken(assetId);
    if (pool != null) return '${pairLabel(pool)} pool tokens';
    return display(assetId).symbol;
  }
}

/// The DEX pools, loaded once and refreshed on demand, so every screen
/// opens with the last known pools instead of a spinner.
class BeamDexPoolStore extends ChangeNotifier {
  BeamDexPoolStore(this.dex);

  final BeamDexService dex;

  List<BeamPool>? _all;
  Object? _error;
  Future<void>? _inFlight;
  BeamAssetPricer? _pricer;

  /// Every pool, empty ones included; null until the first load.
  List<BeamPool>? get all => _all;

  /// Pools holding liquidity.
  List<BeamPool> get live =>
      (_all ?? const <BeamPool>[]).where((p) => !p.isEmpty).toList();

  /// The last load's failure, cleared by a successful load.
  Object? get error => _error;

  bool get isLoading => _inFlight != null;

  /// Values assets in BEAM from the deepest BEAM pool.
  BeamAssetPricer? get pricer =>
      _pricer ??= _all == null ? null : BeamAssetPricer(_all!);

  /// Every asset id that is some pool's LP token.
  Set<int> get lpTokens => {for (final p in _all ?? <BeamPool>[]) p.lpToken};

  /// Loads the pools unless they are already here.
  Future<void> ensureLoaded() => _all != null ? Future.value() : refresh();

  /// Reloads the pools. Concurrent callers share one call. Listeners are
  /// told once it finishes, never in the middle of a build.
  Future<void> refresh() => _inFlight ??= _load().whenComplete(() {
    _inFlight = null;
    notifyListeners();
  });

  Future<void> _load() async {
    try {
      _all = await dex.listPools(includeEmpty: true);
      _pricer = null;
      _error = null;
    } catch (e) {
      _error = e;
    }
  }
}
