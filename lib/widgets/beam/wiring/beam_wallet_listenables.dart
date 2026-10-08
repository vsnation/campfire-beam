/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The one place a BEAM wallet is turned into what the BEAM screens take:
// listenables for sync and balances, asset names, the DEX and Names deps,
// and the contract services (airdrop with the app's secure voucher store).
// One instance per wallet, so the screens' caches (pools, the last list of
// names, names on their way) survive closing and reopening a screen (R11).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/beam/node/beam_node_sync_view.dart';
import '../../../pages/receive_view/receive_view.dart';
import '../../../pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/assets/beam_asset_directory.dart';
import '../../../wallets/beam/contracts/airdrop/beam_airdrop_service.dart';
import '../../../wallets/beam/contracts/airdrop/secure_voucher_code_store.dart';
import '../../../wallets/beam/contracts/burn/beam_burn_service.dart';
import '../../../wallets/beam/contracts/dex/beam_ratio.dart';
import '../../../wallets/beam/contracts/minter/beam_minter_service.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../../wallets/beam/models/beam_wallet_status.dart';
import '../../../wallets/beam/price/beam_fiat_price.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_balance_mapper.dart';
import '../../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../../wallets/isar/models/wallet_info.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/supporting/beam_wallet_info_extension.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import '../airdrop/beam_asset_names.dart';
import '../airdrop/beam_layout.dart';
import '../dex/dex_auth_gate.dart';
import '../dex/dex_deps.dart';
import '../names/names_deps.dart';
import '../receive/beam_receive_panel.dart';
import 'beam_features.dart';

/// What the BEAM screens of one wallet share, built from the wallet itself.
///
/// Get it with [BeamWalletWiring.of]. It owns no wallet state: sync comes
/// from `BeamWallet.syncAssessments`, balances from the per-asset totals
/// Campfire caches after every `wallet_status`, so a screen shows what is
/// known at once and never waits for the core (R11).
class BeamWalletWiring {
  BeamWalletWiring._(this.wallet)
    : services = BeamWalletServices.of(
        wallet,
        voucherStore: SecureVoucherCodeStore(
          wallet.secureStorageInterface,
          wallet.walletId,
        ),
      ),
      _sync = ValueNotifier<BeamSyncAssessment>(wallet.syncAssessment),
      _balances = ValueNotifier<Map<int, BeamAssetTotals>>(
        beamAssetTotalsOf(wallet.info),
      ) {
    _syncSub = wallet.syncAssessments.listen((a) => _sync.value = a);
    _infoSub = wallet.mainDB.isar.walletInfo
        .watchObject(wallet.info.id)
        .listen(_onInfo);
    assetDirectory.addListener(_onNames);
    unawaited(wallet.whenLive.then((_) => _loadMetadata()));
    unawaited(_loadMetadata());
  }

  static final Map<String, BeamWalletWiring> _byWallet = {};

  /// Forces the DEX and Names layout in tests (null: the platform's).
  @visibleForTesting
  static bool? debugDesktopLayout;

  /// [wallet]'s wiring, created on first use. Creating it also gives the
  /// wallet's contract services the app's secure voucher store, whatever
  /// created those services first (the wallet home does, without one).
  static BeamWalletWiring of(BeamWallet wallet) {
    final known = _byWallet[wallet.walletId];
    if (known != null && identical(known.wallet, wallet)) return known;
    known?._dispose();
    return _byWallet[wallet.walletId] = BeamWalletWiring._(wallet);
  }

  /// Drops [walletId]'s wiring and its services. Also done by itself when
  /// the wallet's record is deleted.
  static Future<void> forget(String walletId) async {
    _byWallet.remove(walletId)?._dispose();
    await BeamWalletServices.forget(walletId);
  }

  final BeamWallet wallet;
  final BeamWalletServices services;

  final ValueNotifier<BeamSyncAssessment> _sync;
  final ValueNotifier<Map<int, BeamAssetTotals>> _balances;
  StreamSubscription<BeamSyncAssessment>? _syncSub;
  StreamSubscription<WalletInfo?>? _infoSub;
  bool _disposed = false;

  /// The honest sync verdict, as it changes. Only `BeamSynced` may spend.
  ValueListenable<BeamSyncAssessment> get sync => _sync;

  /// Per asset id, the wallet's totals from its last `wallet_status`.
  ValueListenable<Map<int, BeamAssetTotals>> get balances => _balances;

  // ------------------------------------------------------------- metadata

  /// On-chain names of every asset: the explorer's list of all of them in
  /// one read (cached in the wallet's info, refreshed daily), the core's
  /// `get_asset_info` for what it lacks. Assets the wallet does not hold,
  /// which the DEX lists, are named too.
  late final BeamAssetDirectory assetDirectory = BeamAssetDirectory(
    readTable: wallet.environment.readAssetTable,
    readOne: (id) async => (await services.api.getAssetInfo(id)).metadata,
    cache: WalletInfoAssetDirectoryCache(
      info: () => wallet.info,
      isar: () => wallet.mainDB.isar,
    ),
  );

  /// On-chain metadata of an unverified asset, once known; null before that
  /// (the asset shows by its id).
  BeamAssetMetadata? metadataOf(int assetId) =>
      assetDirectory.metadataOf(assetId);

  /// Names and tickers for the airdrop and minter screens.
  late final BeamAssetNames assetNames = BeamAssetNames(
    loadMetadata: (id) async =>
        assetDirectory.metadataOf(id) ??
        (await services.api.getAssetInfo(id)).metadata,
  );

  /// Names for what the wallet holds, and (once the DEX has loaded them)
  /// for every asset in a pool.
  Future<void> _loadMetadata() async {
    if (_disposed) return;
    await assetDirectory.ensure(_namedIds());
  }

  Iterable<int> _namedIds() sync* {
    yield* _balances.value.keys;
    final pools = _dexBuilt ? dex.pools.all : null;
    if (pools == null) return;
    final lp = {for (final p in pools) p.lpToken};
    for (final p in pools) {
      // LP tokens are named after their pool, not their metadata.
      if (!lp.contains(p.aid1)) yield p.aid1;
      if (!lp.contains(p.aid2)) yield p.aid2;
    }
  }

  void _onNames() {
    if (_disposed) return;
    // The Names screens rebuild on balances: a new map makes them re-read
    // names. The DEX screens follow the directory itself.
    _balances.value = Map.of(_balances.value);
  }

  void _onInfo(WalletInfo? info) {
    if (_disposed) return;
    if (info == null) {
      // The wallet was deleted: nothing of it may stay in memory.
      if (identical(_byWallet[wallet.walletId], this)) {
        unawaited(forget(wallet.walletId));
      } else {
        _dispose();
      }
      return;
    }
    final next = beamAssetTotalsOf(info);
    if (!_sameTotals(next, _balances.value)) {
      _balances.value = next;
      unawaited(_loadMetadata());
    }
  }

  // ---------------------------------------------------------------- deps

  /// Where "Try another node" and "Add BEAM" open from: the screen that
  /// opened the last BEAM feature (it stays under the feature's page).
  BuildContext? _host;

  /// Remembers [context] as the place sync and funding actions open from,
  /// and follows the user's fiat price from the app's providers above it.
  void attach(BuildContext context) {
    _host = context;
    _followFiat(context);
  }

  bool _dexBuilt = false;

  /// The DEX screens' deps, one per wallet: the pool list is loaded once.
  /// Every asset in a pool gets its name once the pools are in.
  late final BeamDexDeps dex = () {
    final deps = BeamDexDeps(
      dex: services.dex,
      sync: sync,
      balances: balances,
      authenticate: campfireDexAuthGate,
      metadataOf: metadataOf,
      assetNames: assetDirectory,
      fiat: _fiat,
      onSyncAction: onSyncAction,
      onSplitCoins: (context, assetId) =>
          unawaited(openBeamSplit(context, wallet, assetId: assetId)),
      isDesktop: debugDesktopLayout,
    );
    _dexBuilt = true;
    deps.pools.addListener(() => unawaited(_loadMetadata()));
    return deps;
  }();

  // ----------------------------------------------------------------- fiat

  final ValueNotifier<BeamDexFiat?> _fiat = ValueNotifier<BeamDexFiat?>(null);
  ProviderContainer? _fiatContainer;
  ProviderSubscription<BeamFiatPrice>? _fiatSub;

  /// The BEAM price in the user's currency, as the DEX shows it; null
  /// inside while price lookups are off.
  ValueListenable<BeamDexFiat?> get fiat => _fiat;

  /// Follows Campfire's price for this wallet in the app's provider
  /// container (the one [context] is under). Once per container.
  void _followFiat(BuildContext context) {
    final ProviderContainer container;
    try {
      container = ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      return; // Not under a ProviderScope: values stay in BEAM.
    }
    if (identical(container, _fiatContainer)) return;
    _fiatSub?.close();
    _fiatSub = null;
    _fiatContainer = container;
    try {
      _fiatSub = container.listen<BeamFiatPrice>(
        pBeamFiatPrice(wallet.walletId),
        (_, next) => _fiat.value = beamDexFiatOf(next),
        fireImmediately: true,
        onError: (_, __) => _fiat.value = null,
      );
    } catch (_) {
      // Prices not readable here (no settings yet): values stay in BEAM.
      _fiat.value = null;
    }
  }

  /// The Names screens' deps, one per wallet: they remember the last list
  /// of names and the names on their way.
  late final BeamNamesDeps names = BeamNamesDeps(
    bans: services.bans,
    sync: sync,
    balances: balances,
    metadataOf: metadataOf,
    onSyncAction: onSyncAction,
    onAddFunds: onAddFunds,
    inboxMonitor: services.bansInbox,
    isDesktop: debugDesktopLayout,
  );

  /// Airdrops, with the secure voucher store attached.
  BeamAirdropService get airdrop => services.airdrop;

  BeamMinterService get minter => services.minter;

  BeamBurnService get burn => services.burn;

  // ------------------------------------------------------------- actions

  /// A sync banner's button: the node panel for node trouble, a reconnect
  /// for connection trouble, nothing while the wallet only has to wait.
  void onSyncAction(BeamSyncAction action) {
    switch (action) {
      case BeamSyncAction.tryAnotherNode:
      case BeamSyncAction.usePublicNode:
      case BeamSyncAction.fixDeviceClock:
        final context = _host;
        if (context != null && context.mounted) {
          unawaited(showBeamNodePanel(context, wallet.walletId));
        } else {
          unawaited(wallet.refresh());
        }
      case BeamSyncAction.checkInternet:
      case BeamSyncAction.reconnect:
        unawaited(wallet.refresh());
      case BeamSyncAction.none:
      case BeamSyncAction.wait:
        break;
    }
  }

  /// "Add BEAM": the wallet's receive screen (a page on a phone, a dialog
  /// on desktop), so an empty balance is never a dead end.
  void onAddFunds() {
    final context = _host;
    if (context == null || !context.mounted) return;
    unawaited(showBeamReceive(context, wallet.walletId));
  }

  /// Stops following the wallet. The listenables are not disposed: a
  /// screen still open on them keeps its last values instead of failing.
  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_syncSub?.cancel());
    unawaited(_infoSub?.cancel());
    _syncSub = null;
    _infoSub = null;
    _host = null;
    _fiatSub?.close();
    _fiatSub = null;
    _fiatContainer = null;
    assetDirectory.removeListener(_onNames);
  }
}

/// [price] as the DEX screens take it: null while lookups are off, a null
/// [BeamDexFiat.perBeam] while there is no price.
BeamDexFiat? beamDexFiatOf(BeamFiatPrice price) {
  if (!price.lookupsOn) return null;
  final p = price.price;
  return BeamDexFiat(
    perBeam: p == null ? null : BeamRatio.parseDecimal(p.toString()),
    currency: price.currency,
    locale: price.locale,
  );
}

/// [info]'s cached per-asset totals in the shape the DEX and Names screens
/// read. The cache keeps one figure per pot, so it is reported as the
/// regular part and the max-privacy part as zero; the screens only read
/// `available`, which is exact.
Map<int, BeamAssetTotals> beamAssetTotalsOf(WalletInfo info) => {
  for (final e in info.beamAssetTotals.entries) e.key: _totals(e.value),
};

BeamAssetTotals _totals(BeamCachedAssetTotals c) => BeamAssetTotals(
  assetId: c.assetId,
  available: c.available,
  availableRegular: c.available,
  availableMp: BigInt.zero,
  receiving: c.receiving,
  receivingRegular: c.receiving,
  receivingMp: BigInt.zero,
  sending: c.sending,
  sendingRegular: c.sending,
  sendingMp: BigInt.zero,
  maturing: c.maturing,
  maturingRegular: c.maturing,
  maturingMp: BigInt.zero,
  change: c.change,
  // The core's "locked" is maturing + change, not a pot of its own.
  locked: c.maturing + c.change,
);

bool _sameTotals(Map<int, BeamAssetTotals> a, Map<int, BeamAssetTotals> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null ||
        o.available != e.value.available ||
        o.receiving != e.value.receiving ||
        o.sending != e.value.sending ||
        o.maturing != e.value.maturing ||
        o.change != e.value.change) {
      return false;
    }
  }
  return true;
}

/// The node and sync panel of [walletId]: a page on a phone, a dialog on
/// desktop. Follows [BeamLayoutScope], so a phone layout can be shown on a
/// desktop host (tests).
Future<void> showBeamNodePanel(BuildContext context, String walletId) {
  if (BeamLayoutScope.isDesktop(context)) {
    return showDialog<void>(
      context: context,
      builder: (_) => DesktopBeamNodeSyncDialog(walletId: walletId),
    );
  }
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => BeamNodeSyncView(walletId: walletId),
    ),
  );
}

/// The wallet's own receive screen: Campfire's Receive page on a phone, the
/// same BEAM receive panel the desktop Receive tab shows in a dialog.
Future<void> showBeamReceive(BuildContext context, String walletId) {
  if (!BeamLayoutScope.isDesktop(context)) {
    return Navigator.of(context)
        .pushNamed(ReceiveView.routeName, arguments: walletId);
  }
  return showDialog<void>(
    context: context,
    builder: (context) => DesktopDialog(
      maxWidth: 580,
      maxHeight: MediaQuery.of(context).size.height - 64,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 32),
                child: Text(
                  'Receive BEAM',
                  style: STextStyles.desktopH3(context),
                ),
              ),
              const DesktopDialogCloseButton(),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
              child: BeamReceivePanel(walletId: walletId, desktop: true),
            ),
          ),
        ],
      ),
    ),
  );
}
