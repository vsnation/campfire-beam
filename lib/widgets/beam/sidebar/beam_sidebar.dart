/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's desktop side menu as the BEAM build's main navigation (owner,
// 2026-10-06: "Left side bar menu can provide really nice navigation").
//
// What lives here:
// * which BEAM features the menu lists, in which order, with which icon;
// * which BEAM wallet those pages act on (the wallet context), and the
//   memory of the last one used;
// * the hook that lets the wallet screen open a feature in the menu.
//
// The menu itself is `beam_sidebar_menu.dart`; the pages it opens are under
// lib/pages_desktop_specific/beam/sidebar/.
//
// Click budget (USER_PSYCHOLOGY §1.2), from opening the app on desktop:
//   Swap, Assets, Names, dApps: 1 click (the menu).
//   Claim a code, My airdrops, Create codes, Create a token, My tokens,
//   Burn: 2 (Airdrops / Tokens → the task).
//   Node & sync: 1 (the node chip under the logo).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app_config.dart';
import '../../../db/hive/db.dart';
import '../../../pages_desktop_specific/desktop_menu.dart';
import '../../../providers/desktop/current_desktop_menu_item.dart';
import '../../../providers/global/active_wallet_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../services/event_bus/events/wallet_added_event.dart';
import '../../../services/event_bus/global_event_bus.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/logger.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/isar/providers/all_wallets_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../airdrop/beam_layout.dart';
import '../wiring/beam_features.dart';

/// Whether the desktop menu is the BEAM one.
abstract final class BeamSidebar {
  /// Forces the answer in tests (null: decided by the build's coins).
  @visibleForTesting
  static bool? debugEnabled;

  /// This build ships BEAM: the desktop menu lists the BEAM features and
  /// the node chip. Every other build keeps Campfire's own menu.
  static bool get enabled =>
      debugEnabled ?? AppConfig.coins.whereType<Beam>().isNotEmpty;

  /// The BEAM coin of this build (main net unless the build says else).
  static CryptoCurrency get coin =>
      AppConfig.coins.whereType<Beam>().firstOrNull ??
      Beam(CryptoCurrencyNetwork.main);
}

/// The BEAM pages of the desktop menu, in menu order.
enum BeamSidebarDestination {
  swap(BeamFeature.swap, DesktopMenuItemId.beamSwap),
  assets(BeamFeature.assets, DesktopMenuItemId.beamAssets),
  names(BeamFeature.names, DesktopMenuItemId.beamNames),
  dapps(BeamFeature.dapps, DesktopMenuItemId.beamDapps),
  airdrops(BeamFeature.airdrops, DesktopMenuItemId.beamAirdrops),
  tokens(BeamFeature.tokens, DesktopMenuItemId.beamTokens);

  const BeamSidebarDestination(this.feature, this.menuId);

  /// The same feature the phone's bar and the wallet screen open.
  final BeamFeature feature;
  final DesktopMenuItemId menuId;

  /// "Swap", "Assets"… (the feature's own word, everywhere).
  String get label => feature.label;

  /// One line under the page title.
  String get description => feature.description;

  /// Campfire's own solid desktop icons, so the BEAM items have the weight
  /// and size of My Campfire, Notifications and the rest.
  String get icon => switch (this) {
    swap => Assets.svg.exchangeDesktop,
    assets => Assets.svg.tokens,
    names => Assets.svg.robotHead,
    dapps => Assets.svg.boxAuto,
    airdrops => Assets.svg.envelope,
    tokens => Assets.svg.circlePlusFilled,
  };

  /// Finds the menu key in tests and click paths (`beamSidebar_swap`).
  ValueKey<String> get menuKey => ValueKey('beamSidebar_$name');

  static BeamSidebarDestination? ofMenuId(DesktopMenuItemId id) {
    for (final d in values) {
      if (d.menuId == id) return d;
    }
    return null;
  }

  static BeamSidebarDestination? ofFeature(BeamFeature feature) {
    for (final d in values) {
      if (d.feature == feature) return d;
    }
    return null;
  }
}

// ------------------------------------------------------------ wallet context

/// Where the id of the last BEAM wallet the sidebar acted on is kept between
/// runs. Not a secret: a wallet id, already in Campfire's own database.
abstract class BeamSidebarWalletMemory {
  String? read();
  Future<void> write(String walletId);
}

/// [BeamSidebarWalletMemory] in Campfire's preferences box.
class HiveBeamSidebarWalletMemory implements BeamSidebarWalletMemory {
  const HiveBeamSidebarWalletMemory();

  static const String key = 'beamSidebarWalletId';

  @override
  String? read() {
    try {
      final v = DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: key);
      return v is String ? v : null;
    } catch (_) {
      // The box is not open (yet): nothing remembered, nothing breaks.
      return null;
    }
  }

  @override
  Future<void> write(String walletId) async {
    try {
      await DB.instance.put<dynamic>(
        boxName: DB.boxNamePrefs,
        key: key,
        value: walletId,
      );
    } catch (e) {
      Logging.instance.w('BEAM sidebar: could not remember the wallet: $e');
    }
  }
}

/// Tests replace it with one in memory.
final pBeamSidebarWalletMemory = Provider<BeamSidebarWalletMemory>(
  (_) => const HiveBeamSidebarWalletMemory(),
);

/// Ticks when Campfire loads a wallet (`Wallets.addWallet`, which can land
/// after the wallet's record is already in the database).
final _pWalletsChanged = StreamProvider<WalletsChangedEvent>(
  (_) => GlobalEventBus.instance.on<WalletsChangedEvent>(),
);

/// The BEAM wallets Campfire has loaded, in the order My Campfire lists
/// them. Rebuilt when a wallet is added or deleted.
final pBeamSidebarWallets = Provider<List<BeamWallet>>((ref) {
  ref.watch(_pWalletsChanged);
  final infos = ref.watch(pAllWalletsInfo);
  final loaded = {
    for (final w in ref.watch(pWallets).wallets)
      if (w is BeamWallet) w.walletId: w,
  };
  return [
    for (final info in infos)
      if (loaded[info.walletId] case final BeamWallet w) w,
  ];
});

/// The wallet the user last chose for the BEAM pages: picked in a page's
/// wallet chip, or opened in My Campfire. Starts from the remembered one.
class BeamSidebarWalletChoice extends StateNotifier<String?> {
  BeamSidebarWalletChoice(this._memory) : super(_memory.read());

  final BeamSidebarWalletMemory _memory;

  void choose(String walletId) {
    if (state == walletId) return;
    state = walletId;
    unawaited(_memory.write(walletId));
  }
}

final pBeamSidebarWalletChoice =
    StateNotifierProvider<BeamSidebarWalletChoice, String?>((ref) {
      final choice = BeamSidebarWalletChoice(
        ref.watch(pBeamSidebarWalletMemory),
      );
      // The wallet open in My Campfire is the one the user is working with.
      ref.listen<String?>(currentWalletIdProvider, (_, id) {
        if (id != null &&
            ref.read(pBeamSidebarWallets).any((w) => w.walletId == id)) {
          choice.choose(id);
        }
      }, fireImmediately: true);
      return choice;
    });

/// Which BEAM wallet the sidebar pages act on.
@immutable
class BeamSidebarWalletContext {
  const BeamSidebarWalletContext({required this.wallets, this.wallet});

  /// Every BEAM wallet, in My Campfire's order.
  final List<BeamWallet> wallets;

  /// The one in use; null with no wallet, or with several and none chosen.
  final BeamWallet? wallet;

  bool get hasWallets => wallets.isNotEmpty;

  /// Several wallets and none chosen yet: the page asks which.
  bool get needsPick => wallet == null && wallets.length > 1;

  /// More than one: the page header offers to switch.
  bool get canSwitch => wallets.length > 1;
}

/// The rule, without Flutter: the chosen wallet (the one open in My
/// Campfire, or picked here; remembered between runs); else the only one;
/// else the only one whose core is running; else none (the page asks).
T? resolveBeamSidebarWallet<T>({
  required List<T> wallets,
  required String Function(T) idOf,
  required bool Function(T) isOpen,
  required String? chosenId,
}) {
  if (wallets.isEmpty) return null;
  if (chosenId != null) {
    for (final w in wallets) {
      if (idOf(w) == chosenId) return w;
    }
  }
  if (wallets.length == 1) return wallets.single;
  final open = wallets.where(isOpen).toList();
  if (open.length == 1) return open.single;
  return null;
}

final pBeamSidebarWallet = Provider<BeamSidebarWalletContext>((ref) {
  final wallets = ref.watch(pBeamSidebarWallets);
  return BeamSidebarWalletContext(
    wallets: wallets,
    wallet: resolveBeamSidebarWallet<BeamWallet>(
      wallets: wallets,
      idOf: (w) => w.walletId,
      isOpen: (w) => w.isOpen,
      chosenId: ref.watch(pBeamSidebarWalletChoice),
    ),
  );
});

// ---------------------------------------------------------------- navigation

/// Shows [destination] in the menu's content area, for [walletId] when
/// given. Marks the menu item the way Campfire's own shortcuts do
/// (`DesktopWalletFeatures` → Swap).
void selectBeamSidebarDestination(
  ProviderContainer container,
  BeamSidebarDestination destination, {
  String? walletId,
}) {
  if (walletId != null) {
    container.read(pBeamSidebarWalletChoice.notifier).choose(walletId);
  }
  container.read(currentDesktopMenuItemProvider.state).state =
      destination.menuId;
  container.read(prevDesktopMenuItemProvider.state).state = destination.menuId;
}

/// For the wallet screen's feature row: opens [feature] of [wallet] in the
/// side menu's content area instead of a dialog or a page of its own, so a
/// BEAM feature has one home on desktop. Returns false where there is no
/// BEAM side menu (phones, other builds) or the feature has no menu item
/// (Node & sync), and the caller opens it as before.
bool openBeamFeatureInSidebar(
  BuildContext context,
  BeamWallet wallet,
  BeamFeature feature,
) {
  if (!BeamSidebar.enabled || !BeamLayoutScope.isDesktop(context)) {
    return false;
  }
  final destination = BeamSidebarDestination.ofFeature(feature);
  if (destination == null) return false;
  selectBeamSidebarDestination(
    ProviderScope.containerOf(context, listen: false),
    destination,
    walletId: wallet.walletId,
  );
  return true;
}
