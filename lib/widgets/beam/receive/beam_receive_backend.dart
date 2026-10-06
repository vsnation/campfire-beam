/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tuple/tuple.dart';

import '../../../db/isar/main_db.dart';
import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../pages/settings_views/wallet_settings_view/wallet_network_settings_view/wallet_network_settings_view.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../route_generator.dart';
import '../../../services/event_bus/events/global/node_connection_status_changed_event.dart';
import '../../../services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/api/beam_api.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/desktop_dialog_close_button.dart';
import 'beam_private_receive.dart';

/// What the BEAM receive screens need from the rest of the app, in one
/// place, so the screens never reach into globals and tests can hand them a
/// wallet whose core is a `FakeTransport`.
class BeamReceiveBackend {
  const BeamReceiveBackend({
    required this.walletId,
    required this.api,
    required this.cachedAddress,
    required this.privateReceive,
    required this.privateNodeWanted,
    required this.whenLive,
    required this.coreProblem,
    required this.myNames,
    required this.share,
    required this.forgetAddress,
    required this.log,
    this.openNodeSettings,
  });

  /// The production backend of [wallet].
  ///
  /// [myNames], [share] and [openNodeSettings] replace the app's own (BANS
  /// through the bundled shader, the system share sheet, Campfire's network
  /// settings), for tests.
  factory BeamReceiveBackend.forWallet(
    BeamWallet wallet, {
    Future<List<String>> Function()? myNames,
    Future<void> Function(String text)? share,
    void Function(BuildContext context, {required bool desktop})?
    openNodeSettings,
    Future<void> Function(String address)? forgetAddress,
  }) => BeamReceiveBackend(
    walletId: wallet.walletId,
    // Through the per-wallet services so every call follows the wallet's
    // current core connection across public <-> private node handovers.
    api: () => BeamWalletServices.of(wallet).api,
    cachedAddress: () => wallet.info.cachedReceivingAddress,
    privateReceive: (wanted) => BeamPrivateReceive.evaluate(
      status: wallet.privateNodeStatus,
      coreOpen: wallet.isOpen,
      // A restored wallet scanning for its coins runs with body requests
      // on (BeamWallet opens and re-opens its sessions with them while
      // isScanningForCoins), and the core can then find these payments.
      bodyRequests: wallet.isScanningForCoins,
      nodePossible: wallet.environment.createPrivateNode != null,
      nodeWanted: wanted,
    ),
    privateNodeWanted: () => wallet.environment.privateNodeSetting.read(),
    whenLive: () => wallet.whenLive,
    coreProblem: () => wallet.coreProblem?.message,
    myNames: myNames ?? () => _bansNames(wallet),
    share:
        share ??
        (text) async {
          await SharePlus.instance.share(ShareParams(text: text));
        },
    forgetAddress:
        forgetAddress ?? (address) => beamForgetAddress(wallet, address),
    log: wallet.environment.log,
    openNodeSettings:
        openNodeSettings ??
        (context, {required desktop}) =>
            openBeamNodeSettings(context, wallet, desktop: desktop),
  );

  final String walletId;

  /// The wallet's core API. Calls fail with `BeamConnectionException`
  /// while the core is not connected.
  final BeamApi Function() api;

  /// Campfire's cached receiving address, "" when there is none. Shown at
  /// once, before the core answers (R11).
  final String Function() cachedAddress;

  /// Whether offline / max-privacy / public addresses may be offered, given
  /// the "Use a private node" setting.
  final BeamPrivateReceive Function(bool privateNodeWanted) privateReceive;

  /// The "Use a private node" setting.
  final Future<bool> Function() privateNodeWanted;

  /// Completes once the wallet has applied live data from its core, so an
  /// address the wallet makes on its own first open is seen before this
  /// screen considers making one.
  final Future<void> Function() whenLive;

  /// Why the core is not usable, when it is not, in the user's words.
  final String? Function() coreProblem;

  /// The BANS names this wallet owns that can be paid now, as shown
  /// ("alice.beam"). May throw; the screens then show no name.
  final Future<List<String>> Function() myNames;

  final Future<void> Function(String text) share;

  /// Drops [address] from Campfire's cache once the core deleted it, so the
  /// cached receiving address never points at a deleted one.
  final Future<void> Function(String address) forgetAddress;

  /// Operational log; never given a secret.
  final void Function(String message) log;

  /// Opens the node settings, where the private node is turned on.
  final void Function(BuildContext context, {required bool desktop})?
  openNodeSettings;
}

/// The app's [BeamReceiveBackend] for a wallet id; null for a wallet that
/// is not BEAM.
final pBeamReceiveBackend = Provider.family<BeamReceiveBackend?, String>((
  ref,
  walletId,
) {
  final wallet = ref.watch(pWallets).getWallet(walletId);
  return wallet is BeamWallet ? BeamReceiveBackend.forWallet(wallet) : null;
});

Future<List<String>> _bansNames(BeamWallet wallet) =>
    beamPayableNames(BeamWalletServices.of(wallet).bans);

/// The names [bans]' wallet owns that can be paid right now (active, for
/// sale, or in the renewal hold), as people type them: "alice.beam".
Future<List<String>> beamPayableNames(BeamBansService bans) async {
  final mine = await bans.myNames();
  return [
    for (final d in mine.names)
      if (d.statusAt(mine.tipHeight).canReceivePayments)
        BansName.tryParse(d.name)?.display ?? '${d.name}.beam',
  ];
}

/// Marks [address] as no longer receiving in Campfire's cache, and moves
/// the cached receiving address off it, after the core deleted it.
Future<void> beamForgetAddress(BeamWallet wallet, String address) async {
  final db = MainDB.instance;
  final stored = await db.getAddress(wallet.walletId, address);
  if (stored != null && stored.subType != AddressSubType.unknown) {
    await db.updateOrPutAddresses([
      stored.copyWith(subType: AddressSubType.unknown),
    ]);
  }
  final current = await wallet.getCurrentReceivingAddress();
  final next = current?.value ?? '';
  if (wallet.info.cachedReceivingAddress != next) {
    await wallet.info.updateReceivingAddress(newAddress: next, isar: db.isar);
  }
}

/// Campfire's network settings for [wallet], where the BEAM node panel
/// lives: a page on phones, a dialog on desktop (as the wallet's network
/// button opens it).
void openBeamNodeSettings(
  BuildContext context,
  BeamWallet wallet, {
  required bool desktop,
}) {
  final sync = wallet.canSpend
      ? WalletSyncStatus.synced
      : WalletSyncStatus.syncing;
  final node = wallet.isOpen
      ? NodeConnectionStatus.connected
      : NodeConnectionStatus.disconnected;
  if (!desktop) {
    Navigator.of(context).pushNamed(
      WalletNetworkSettingsView.routeName,
      arguments: Tuple3(wallet.walletId, sync, node),
    );
    return;
  }
  showDialog<void>(
    context: context,
    builder: (context) => Navigator(
      initialRoute: WalletNetworkSettingsView.routeName,
      onGenerateRoute: RouteGenerator.generateRoute,
      onGenerateInitialRoutes: (_, _) => [
        FadePageRoute<void>(
          DesktopDialog(
            maxHeight: null,
            maxWidth: 580,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Network', style: STextStyles.desktopH3(context)),
                      DesktopDialogCloseButton(
                        onPressedOverride: Navigator.of(
                          context,
                          rootNavigator: true,
                        ).pop,
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
                    child: SingleChildScrollView(
                      child: WalletNetworkSettingsView(
                        walletId: wallet.walletId,
                        initialSyncStatus: sync,
                        initialNodeStatus: node,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const RouteSettings(name: WalletNetworkSettingsView.routeName),
        ),
      ],
    ),
  );
}
