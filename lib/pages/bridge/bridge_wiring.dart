/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Builds the bridge for the app's real wallets: one controller per pair
// of the user's BEAM and Ethereum wallets (created once, resumed once,
// kept for the app's lifetime so crossings are followed after their screen
// closes), one crossing file next to Campfire's other data, Campfire's PIN
// / password gate, Etherscan links, and where the bridge opens: a page on
// a phone, the side menu's Bridge page on desktop.
//
// The two halves of a crossing come from [BridgeSides]: the BEAM wallet's
// pipe service and the Ethereum wallet's.
//
// Polling pauses while the app is in the background on a phone and
// resumes when it is back, as the ShopinBit ticket view does
// (`shopinbit_ticket_detail.dart`); desktop keeps polling.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_config.dart';
import '../../db/hive/db.dart';
import '../../models/add_wallet_list_entity/sub_classes/coin_entity.dart';
import '../../providers/global/wallets_provider.dart';
import '../../utilities/block_explorers.dart';
import '../../utilities/logger.dart';
import '../../utilities/stack_file_system.dart';
import '../../utilities/prefs.dart';
import '../../utilities/util.dart';
import '../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../wallets/bridge/bridge_routes.dart';
import '../../wallets/bridge/bridge_sides.dart';
import '../../wallets/bridge/bridge_store.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/ethereum/bridge/bridge_price_feed.dart';
import '../../wallets/ethereum/bridge/eth_pipe_service.dart';
import '../../wallets/ethereum/eth_http_client.dart';
import '../../wallets/ethereum/uniswap/eth_rpc.dart';
import '../../wallets/wallet/impl/beam_wallet.dart';
import '../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../wallets/wallet/wallet.dart';
import '../../wallets/wallet/wallet_mixin_interfaces/view_only_option_interface.dart';
import '../../widgets/beam/dex/dex_auth_gate.dart';
import '../../widgets/beam/sidebar/beam_sidebar.dart';
import '../../widgets/beam/wiring/beam_wallet_listenables.dart';
import '../add_wallet_views/create_or_restore_wallet_view/create_or_restore_wallet_view.dart';
import '../eth/uniswap/uniswap_deps.dart';
import 'bridge_deps.dart';
import 'bridge_move_view.dart';

/// The two halves of a crossing for real wallets: the BEAM wallet's
/// `BeamPipeService` (one per wallet, on the wallet's `BeamApi` lane) and
/// an `EthPipeService` over the Ethereum wallet's RPC and key. Tests put
/// fakes here; nothing else in the bridge names either class.
abstract final class BridgeSides {
  static BeamPipeSide Function(BeamWallet wallet)? beam = _beamSide;
  static Future<EthPipeSide> Function(EthereumWallet wallet)? ethereum =
      _ethSide;

  /// Forces [bridgeAvailable] in tests (null: decided as in the app).
  @visibleForTesting
  static bool? debugAvailable;

  static bool get wired => beam != null && ethereum != null;
}

BeamPipeSide _beamSide(BeamWallet wallet) =>
    BeamWalletServices.of(wallet).bridge;

/// One price feed for every wallet: CoinGecko asked at most every two
/// minutes, through Tor when Tor is on, never while price lookups are off.
final BridgePriceFeed _priceFeed = BridgePriceFeed(
  clientFactory: createEthHttpClient,
  lookupsAllowed: () => Prefs.instance.externalCalls,
);

/// The wallet's own RPC (the node in its network settings) and its key,
/// as the Uniswap swap uses them (`uniswap_wiring.dart`).
Future<EthPipeSide> _ethSide(EthereumWallet wallet) async {
  final address = (await wallet.getCurrentReceivingAddress())!.value
      .toLowerCase();
  return EthPipeService(
    rpc: EthRpc(
      url: wallet.getCurrentNode().host,
      clientFactory: createEthHttpClient,
      timeout: const Duration(seconds: 45),
    ),
    signer: EthWalletSwapSigner(wallet, address),
    priceFeed: _priceFeed,
  );
}

/// The bridge is in this build (it ships BEAM, as the Ethereum features
/// require) and both halves are wired.
bool get bridgeAvailable =>
    BridgeSides.debugAvailable ??
    (AppConfig.coins.whereType<Beam>().isNotEmpty && BridgeSides.wired);

// ------------------------------------------------------------------ memory

/// The wallet pair last used, between runs. Not a secret: two wallet ids,
/// already in Campfire's own database.
abstract final class BridgePairMemory {
  static const key = 'bridgeWalletPair';

  static (String?, String?) read() {
    try {
      final v = DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: key);
      if (v is! String || !v.contains('/')) return (null, null);
      final i = v.indexOf('/');
      return (v.substring(0, i), v.substring(i + 1));
    } catch (_) {
      return (null, null);
    }
  }

  static Future<void> write(String beamId, String ethId) async {
    try {
      await DB.instance.put<dynamic>(
        boxName: DB.boxNamePrefs,
        key: key,
        value: '$beamId/$ethId',
      );
    } catch (e) {
      Logging.instance.w('Bridge: could not remember the wallets: $e');
    }
  }
}

/// What the side menu's Bridge page opens with, once (set by a wallet's
/// Bridge button on desktop).
abstract final class BridgeOpenIntent {
  static String? walletId;
  static BridgeDirection? direction;
  static BridgeRoute? route;

  static (String?, BridgeDirection?, BridgeRoute?) take() {
    final r = (walletId, direction, route);
    walletId = null;
    direction = null;
    route = null;
    return r;
  }
}

// ------------------------------------------------------------- controllers

final BridgeStore _store = FileBridgeStore(() async {
  final dir = await StackFileSystem.applicationRootDirectory();
  return File('${dir.path}${Platform.pathSeparator}bridge_crossings.json');
});

final Map<String, Future<BridgeController>> _controllers = {};

/// The controller of [beam] and [eth], created and resumed once.
Future<BridgeController> bridgeControllerFor(
  BeamWallet beam,
  EthereumWallet eth,
) {
  final key = '${beam.walletId}/${eth.walletId}';
  return _controllers.putIfAbsent(key, () async {
    try {
      final beamSide = BridgeSides.beam;
      final ethSide = BridgeSides.ethereum;
      if (beamSide == null || ethSide == null) {
        throw StateError('The bridge is not wired in this build');
      }
      final c = BridgeController(
        beam: beamSide(beam),
        eth: await ethSide(eth),
        store: _store,
        beamWalletId: beam.walletId,
        ethWalletId: eth.walletId,
      );
      _BridgeLifecycle.follow(c);
      await c.resumeAll();
      return c;
    } catch (e) {
      // Not cached: the next open tries again.
      unawaited(_controllers.remove(key));
      rethrow;
    }
  });
}

/// Pauses every bridge controller while a phone app is in the background.
abstract final class _BridgeLifecycle {
  static AppLifecycleListener? _listener;
  static final List<BridgeController> _all = [];

  static void follow(BridgeController c) {
    _all.add(c);
    if (Util.isDesktop || _listener != null) return;
    _listener = AppLifecycleListener(
      onStateChange: (s) {
        for (final c in _all) {
          s == AppLifecycleState.resumed ? c.resume() : c.pause();
        }
      },
    );
  }
}

/// Follows the chosen BEAM wallet's honest sync state: may it send now?
class _BeamSyncFollower extends ChangeNotifier
    implements ValueListenable<bool> {
  ValueListenable<Object?>? _source;
  bool Function()? _read;

  void follow(BeamWallet? wallet) {
    _source?.removeListener(notifyListeners);
    if (wallet == null) {
      _source = null;
      _read = null;
    } else {
      final sync = BeamWalletWiring.of(wallet).sync;
      _source = sync;
      _read = () => sync.value.canSpend;
      sync.addListener(notifyListeners);
    }
    notifyListeners();
  }

  @override
  bool get value => _read?.call() ?? true;

  @override
  void dispose() {
    _source?.removeListener(notifyListeners);
    super.dispose();
  }
}

// -------------------------------------------------------------------- deps

/// The bridge's dependencies for the app's [wallets]. [walletId] (a BEAM
/// or Ethereum wallet) is the one to use on its side; the other side is
/// the pair last used, else the first wallet of its kind.
Future<BridgeDeps> bridgeDepsFor(
  BuildContext context, {
  required Iterable<Wallet> wallets,
  String? walletId,
  bool? isDesktop,
}) async {
  final all = wallets;
  final beams = [
    for (final w in all)
      if (w is BeamWallet) w,
  ];
  final eths = [
    for (final w in all)
      if (w is EthereumWallet && !_viewOnly(w)) w,
  ];
  final addresses = await Future.wait([
    for (final w in eths)
      w.getCurrentReceivingAddress().then<String?>(
        (a) => a?.value.toLowerCase(),
        onError: (Object _) => null,
      ),
  ]);
  var (beamId, ethId) = BridgePairMemory.read();
  if (beams.any((w) => w.walletId == walletId)) beamId = walletId;
  if (eths.any((w) => w.walletId == walletId)) ethId = walletId;
  if (!beams.any((w) => w.walletId == beamId)) beamId = null;
  if (!eths.any((w) => w.walletId == ethId)) ethId = null;

  final eth = Ethereum(CryptoCurrencyNetwork.main);
  final beamCoin = Beam(CryptoCurrencyNetwork.main);
  final sync = _BeamSyncFollower();
  BeamWallet? beamOf(String? id) {
    for (final w in beams) {
      if (w.walletId == id) return w;
    }
    return null;
  }

  late final BridgeDeps deps;
  deps = BridgeDeps(
    beamWallets: [
      for (final w in beams)
        BridgeWalletOption(id: w.walletId, name: w.info.name),
    ],
    ethWallets: [
      for (var i = 0; i < eths.length; i++)
        BridgeWalletOption(
          id: eths[i].walletId,
          name: eths[i].info.name,
          address: addresses[i],
        ),
    ],
    beamWalletId: beamId,
    ethWalletId: ethId,
    controllerFor: (b, e) => bridgeControllerFor(
      beams.firstWhere((w) => w.walletId == b),
      eths.firstWhere((w) => w.walletId == e),
    ),
    authenticate: (context, {required reason}) =>
        campfireDexAuthGate(context, reason: reason, coin: beamCoin),
    ethExplorerTx: (hash) =>
        getBlockExplorerTransactionUrlFor(coin: eth, txid: hash),
    ethExplorerAddress: (a) => Uri.parse('https://etherscan.io/address/$a'),
    onAddEthereumWallet: () => _addWallet(context, eth),
    onAddBeamWallet: () => _addWallet(context, beamCoin),
    onGetBeam: () {
      final w = beamOf(deps.beamWalletId);
      if (w != null) unawaited(showBeamReceive(context, w.walletId));
    },
    beamCanSpend: sync,
    onDispose: sync.dispose,
    onChoose: (b, e) {
      sync.follow(beamOf(b));
      unawaited(BridgePairMemory.write(b, e));
    },
    isDesktop: isDesktop,
  );
  sync.follow(beamOf(deps.beamWalletId));
  return deps;
}

bool _viewOnly(Wallet w) => w is ViewOnlyOptionInterface && w.isViewOnly;

void _addWallet(BuildContext context, CryptoCurrency coin) => unawaited(
  Navigator.of(
    context,
    rootNavigator: Util.isDesktop,
  ).pushNamed(CreateOrRestoreWalletView.routeName, arguments: CoinEntity(coin)),
);

// -------------------------------------------------------------------- open

/// Opens the bridge from [from]'s wallet screen: a page on a phone (moving
/// out of that wallet first), the side menu's Bridge page on desktop.
Future<void> openBridge(
  BuildContext context,
  Wallet from, {
  BridgeRoute? route,
}) async {
  final direction = from is EthereumWallet
      ? BridgeDirection.toBeam
      : BridgeDirection.toEthereum;
  if (BeamSidebar.enabled && Util.isDesktop) {
    BridgeOpenIntent.walletId = from.walletId;
    BridgeOpenIntent.direction = direction;
    BridgeOpenIntent.route = route;
    selectBeamSidebarDestination(
      ProviderScope.containerOf(context, listen: false),
      BeamSidebarDestination.bridge,
    );
    return;
  }
  final wallets = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(pWallets).wallets;
  final deps = await bridgeDepsFor(
    context,
    wallets: wallets,
    walletId: from.walletId,
  );
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => BridgeMoveView(
        deps: deps,
        initialRoute: route,
        initialDirection: direction,
      ),
    ),
  );
  deps.dispose();
}
