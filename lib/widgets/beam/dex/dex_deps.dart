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
import 'dex_format.dart';
import 'dex_widgets.dart' show DexLayout;

/// Asks the user to prove it is them before money moves (Campfire's PIN on
/// mobile, the wallet password on desktop).
///
/// Returns true when the user passed, false when the PIN or password was
/// wrong, and null when they backed out.
typedef BeamDexAuthGate = Future<bool?> Function(
  BuildContext context, {
  required String reason,
});

/// The user's fiat price of BEAM, for "≈ 1.20 USD" lines. The listenable
/// in [BeamDexDeps.fiat] holds null while price lookups are off in
/// Settings (values are then shown in BEAM).
@immutable
class BeamDexFiat {
  const BeamDexFiat({
    required this.perBeam,
    required this.currency,
    this.locale = 'en_US',
  });

  /// Fiat units per whole BEAM; null while there is no price (the screens
  /// say "No USD price", never "0.00 USD").
  final BeamRatio? perBeam;

  /// ISO code, e.g. "USD".
  final String currency;

  /// For the digits: "1,234.56" or "1.234,56".
  final String locale;

  /// [groth] of BEAM in this currency: "≈ 1.20 USD", or "under 0.01 USD";
  /// null without a price.
  String? approx(BigInt groth) {
    final p = perBeam;
    if (p == null) return null;
    return DexFormat.fiatApprox(groth, p, currency, locale: locale);
  }

  @override
  bool operator ==(Object other) =>
      other is BeamDexFiat &&
      other.perBeam == perBeam &&
      other.currency == currency &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(perBeam, currency, locale);
}

/// Everything the DEX screens need, handed in by whoever opens them.
///
/// The screens own no wallet state: balances, sync and prices come from
/// listenables the wallet already keeps, so the DEX never waits for the
/// core to show what is known (R11).
class BeamDexDeps implements DexLayout {
  BeamDexDeps({
    required this.dex,
    required this.sync,
    required this.balances,
    required this.authenticate,
    this.metadataOf = _noMetadata,
    this.assetNames,
    this.hiddenAssetIds = _noneHidden,
    this.fiat,
    this.onSyncAction,
    this.onSplitCoins,
    this.isDesktop,
    BeamDexPoolStore? pools,
  }) : pools = pools ?? BeamDexPoolStore(dex);

  /// The assets the user hid from the wallet's asset list
  /// (`BeamHiddenAssets.read`). Asset pickers leave them out.
  final Set<int> Function() hiddenAssetIds;

  static Set<int> _noneHidden() => const {};

  /// The AMM service for this wallet.
  final BeamDexService dex;

  /// The honest sync verdict. Only [BeamSynced] may spend.
  final ValueListenable<BeamSyncAssessment> sync;

  /// Per asset id, the wallet's totals from `wallet_status`.
  final ValueListenable<Map<int, BeamAssetTotals>> balances;

  /// On-chain metadata of any asset, for unverified names: every asset the
  /// DEX lists, not only the ones the wallet holds (`BeamAssetDirectory`).
  final BeamAssetMetadata? Function(int assetId) metadataOf;

  /// Fires when [metadataOf] knows more names (the explorer's list of every
  /// asset arrived), so open screens show them; null when names never
  /// change (tests).
  final Listenable? assetNames;

  /// Campfire's PIN / password gate. In the app this is
  /// `campfireDexAuthGate` (`dex_auth_gate.dart`), kept out of this file so
  /// the DEX screens do not import the lock screen and the rest of the app
  /// with it.
  final BeamDexAuthGate authenticate;

  /// The BEAM price in the user's currency; null inside while price
  /// lookups are off. Null itself: no fiat at all (values in BEAM).
  final ValueListenable<BeamDexFiat?>? fiat;

  /// Runs the sync banner's action ("Try another node", …).
  final void Function(BeamSyncAction action)? onSyncAction;

  /// Opens Split coins for an asset whose coins are tied up in a transaction
  /// that has not finished, from the DEX screen at the context; null hides
  /// the link.
  final void Function(BuildContext context, int assetId)? onSplitCoins;

  /// Forces the desktop or mobile layout; null follows the platform.
  final bool? isDesktop;

  /// Pools, shared by every DEX screen of this wallet.
  final BeamDexPoolStore pools;

  static BeamAssetMetadata? _noMetadata(int assetId) => null;

  /// Everything a DEX screen shows that can change while it is open: pools,
  /// balances, sync, asset names and the fiat price.
  late final Listenable changes = Listenable.merge([
    pools,
    balances,
    sync,
    assetNames,
    fiat,
  ]);

  @override
  bool get desktop => isDesktop ?? Util.isDesktop;

  bool get canSpend => sync.value.canSpend;

  /// How [assetId] is shown: its name from the catalogue or the chain, or
  /// for an LP token its pair, "BEAM/FOMO LP".
  BeamAssetDisplay display(int assetId) => BeamAssetCatalog.display(
    assetId,
    metadataOf(assetId),
    metadataOf: metadataOf,
  );

  /// What the wallet can spend of [assetId] right now.
  BigInt available(int assetId) =>
      balances.value[assetId]?.available ?? BigInt.zero;

  /// [assetId]'s change still on its way back from a transaction that has
  /// not finished: spendable again in about a minute.
  BigInt returning(int assetId) =>
      balances.value[assetId]?.change ?? BigInt.zero;

  /// The pool whose LP token is [assetId], if it is one.
  BeamPool? poolOfLpToken(int assetId) {
    for (final p in pools.all ?? const <BeamPool>[]) {
      if (p.lpToken == assetId) return p;
    }
    return null;
  }

  /// The ticker as the DEX writes it in a sentence: "FOMO" for a verified
  /// asset, "FOMO #999" for anything else, because anyone can mint an
  /// asset and call it FOMO; "BEAM/FOMO LP" for an LP token.
  String assetLabel(int assetId) => display(assetId).label;

  /// "BEAM/FOMO", in pool order ("BEAM/FOMO #999" for a copy), as the
  /// pool's LP token is named ([BeamAssetCatalog.pairName]).
  String pairLabel(BeamPool pool) =>
      BeamAssetCatalog.pairName(display(pool.aid1), display(pool.aid2));

  /// How an asset is named in a sentence. LP tokens are named after their
  /// pool ("BEAM/FOMO LP"), because their own metadata is a meaningless
  /// "Amm Liquidity Token 0-174-2".
  String assetName(int assetId) {
    final pool = poolOfLpToken(assetId);
    if (pool != null) return '${pairLabel(pool)} LP';
    return assetLabel(assetId);
  }

  // ---------------------------------------------------------------- value

  /// What [amount] of [assetId] is worth in groth, from the DEX pools by
  /// the same pricer the dashboard and Assets page use
  /// ([BeamAssetPricer]: a verified asset at its deepest pool's price, any
  /// other only from a pool holding 1,000 BEAM, at what that pool would
  /// pay). Null when no pool prices it, or the pools are not loaded.
  BigInt? valueInBeam(int assetId, BigInt amount) =>
      assetId == 0 ? amount : pools.pricer?.valueInGroth(assetId, amount);

  /// The line under an amount of [assetId]: "≈ 1.20 USD" or "under 0.01
  /// USD"; "≈ 0.5 BEAM" for another asset while there is no fiat price;
  /// "No price" when no pool prices the asset. Null when there is nothing
  /// to add: no amount, pools still loading, or BEAM itself with price
  /// lookups off.
  String? worth(int assetId, BigInt amount) {
    if (amount <= BigInt.zero) return null;
    if (assetId != 0 && pools.pricer == null) return null;
    final inBeam = valueInBeam(assetId, amount);
    if (inBeam == null) return 'No price';
    return worthOfBeam(inBeam, inBeam: assetId != 0);
  }

  /// [groth] of BEAM as a value line: "≈ 1.20 USD", "under 0.01 USD".
  /// Without a fiat price: "≈ 0.5 BEAM" when [inBeam] (the amount was in
  /// another asset, so its BEAM value says something), "No USD price" when
  /// lookups are on but CoinGecko gave none, null when lookups are off.
  String? worthOfBeam(BigInt groth, {bool inBeam = false}) {
    final f = fiat?.value;
    final money = f?.approx(groth);
    if (money != null) return money;
    if (inBeam) {
      return groth > BigInt.zero
          ? '≈ ${DexFormat.compact(groth)} BEAM'
          : 'under 0.00000001 BEAM';
    }
    return f == null ? null : 'No ${f.currency} price';
  }

  /// Both sides of [pool] valued in groth; null when a side has no price.
  BigInt? poolSize(BeamPool pool) {
    final v1 = valueInBeam(pool.aid1, pool.tok1);
    final v2 = valueInBeam(pool.aid2, pool.tok2);
    return v1 == null || v2 == null ? null : v1 + v2;
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
