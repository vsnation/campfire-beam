/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Builds the Uniswap swap for one Ethereum wallet: its RPC (the node
// chosen in its network settings), Campfire's Ethereum HTTP client (Tor
// when Tor is on, and never the clear net while Tor is on but down), its
// key (inside the wallet), its token list, prices, and Campfire's PIN /
// password gate. Also where it opens: a page on a phone, a dialog on
// desktop.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../db/isar/main_db.dart';
import '../../../pages_desktop_specific/eth/uniswap/desktop_uniswap_view.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/price_provider.dart';
import '../../../utilities/block_explorers.dart';
import '../../../utilities/logger.dart';
import '../../../utilities/stack_file_system.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/ethereum/eth_http_client.dart';
import '../../../wallets/ethereum/near_intents/near_intents_store.dart';
import '../../../wallets/ethereum/near_intents/one_click_client.dart';
import '../../../wallets/ethereum/uniswap/eth_rpc.dart';
import '../../../wallets/ethereum/uniswap/uniswap_discovery.dart';
import '../../../wallets/ethereum/uniswap/uniswap_models.dart';
import '../../../wallets/ethereum/uniswap/uniswap_service.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../widgets/beam/dex/dex_auth_gate.dart';
import '../../../widgets/desktop/desktop_dialog.dart';
import '../near_intents/near_intents_view.dart';
import 'uniswap_deps.dart';
import 'uniswap_swap_view.dart';

/// Pool searches, kept in one small JSON file next to Campfire's other
/// data. Pools are public chain data; nothing here is about the wallet.
class FileUniPoolStore implements UniPoolStore {
  FileUniPoolStore._();

  static final instance = FileUniPoolStore._();

  Map<String, Object?>? _data;
  Future<void>? _loading;
  Timer? _flush;

  Future<File> _file() async {
    final dir = await StackFileSystem.applicationRootDirectory();
    return File('${dir.path}${Platform.pathSeparator}uniswap_pools.json');
  }

  Future<void> _load() => _loading ??= () async {
    try {
      final f = await _file();
      _data = await f.exists()
          ? (jsonDecode(await f.readAsString()) as Map).cast<String, Object?>()
          : {};
    } catch (e) {
      Logging.instance.w('Uniswap pool cache unreadable, starting over: $e');
      _data = {};
    }
  }();

  @override
  Future<UniPoolScan?> read(String key) async {
    await _load();
    final j = _data![key];
    if (j is! Map) return null;
    try {
      return UniPoolScan.fromJson(j.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, UniPoolScan scan) async {
    await _load();
    _data![key] = scan.toJson();
    _flush?.cancel();
    _flush = Timer(const Duration(seconds: 2), () async {
      try {
        await (await _file()).writeAsString(jsonEncode(_data));
      } catch (e) {
        Logging.instance.w('Uniswap pool cache not saved: $e');
      }
    });
  }
}

/// One service per RPC URL for the app's lifetime, so pool rankings and
/// searches are shared between screens.
final Map<String, UniswapService> _services = {};

UniswapService uniswapServiceFor(EthereumWallet wallet) {
  final url = wallet.getCurrentNode().host;
  return _services.putIfAbsent(url, () {
    final rpc = EthRpc(
      url: url,
      clientFactory: createEthHttpClient,
      timeout: const Duration(seconds: 45),
    );
    return UniswapService(
      rpc: rpc,
      discovery: UniswapDiscovery(rpc: rpc, store: FileUniPoolStore.instance),
    );
  });
}

/// The swap's dependencies for [wallet].
Future<UniswapDeps> uniswapDepsFor(
  EthereumWallet wallet,
  WidgetRef ref, {
  bool? isDesktop,
}) async {
  final address = (await wallet.getCurrentReceivingAddress())!.value
      .toLowerCase();
  final eth = Ethereum(CryptoCurrencyNetwork.main);
  final beam = Beam(CryptoCurrencyNetwork.main);
  double? fiat(UniToken t) {
    if (!ref.read(prefsChangeNotifierProvider).externalCalls) return null;
    final prices = ref.read(priceAnd24hChangeNotifierProvider);
    final coin = t.isEthLike
        ? eth
        : t.address == kWbeamToken.address
        ? beam
        : null;
    if (coin == null) return null;
    final p = prices.getPrice(coin)?.value;
    return p == null || p.toDouble() <= 0 ? null : p.toDouble();
  }

  List<UniToken> tokens() => [
    for (final a in wallet.info.tokenContractAddresses)
      if (MainDB.instance.getEthContractSync(a) case final c?)
        UniToken(
          address: c.address.toLowerCase(),
          symbol: c.symbol,
          decimals: c.decimals,
          name: c.name,
        ),
  ];

  return UniswapDeps(
    service: uniswapServiceFor(wallet),
    signer: EthWalletSwapSigner(wallet, address),
    walletTokens: tokens,
    fiatPerToken: fiat,
    fiatCurrency: ref.read(prefsChangeNotifierProvider).currency,
    authenticate: (context, {required reason}) =>
        campfireDexAuthGate(context, reason: reason, coin: eth),
    explorerTx: (hash) =>
        getBlockExplorerTransactionUrlFor(coin: eth, txid: hash),
    isDesktop: isDesktop,
  );
}

/// NEAR Intents for [wallet], over the same deps.
NearIntentsDeps nearIntentsDepsFor(
  EthereumWallet wallet,
  UniswapDeps deps,
  WidgetRef ref,
) => NearIntentsDeps(
  uniswap: deps,
  client: OneClickClient(clientFactory: createEthHttpClient),
  store: _nearIntentsStore,
  walletId: wallet.walletId,
  onBuyWbeam: (context, eth) {
    // Keep enough ETH for the swap's own network fee.
    final keep = BigInt.from(10).pow(18) * BigInt.from(5) ~/ BigInt.from(10000);
    final spend = eth > keep * BigInt.two ? eth - keep : eth ~/ BigInt.two;
    unawaited(openUniswapSwap(context, ref, wallet, initialAmount: spend));
  },
);

final _nearIntentsStore = FileNearIntentsStore(() async {
  final dir = await StackFileSystem.applicationRootDirectory();
  return File('${dir.path}${Platform.pathSeparator}near_intents_swaps.json');
});

/// Opens the Uniswap swap for [wallet]: a page on a phone, a wide dialog
/// on desktop. [initialAmount] of ETH to start with.
Future<void> openUniswapSwap(
  BuildContext context,
  WidgetRef ref,
  EthereumWallet wallet, {
  BigInt? initialAmount,
}) async {
  final deps = await uniswapDepsFor(wallet, ref);
  if (!context.mounted) return;
  final intents = nearIntentsDepsFor(wallet, deps, ref);
  void payWithOtherCoin(BuildContext c) =>
      unawaited(NearIntentsView.show(c, intents));
  if (deps.desktop) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => DesktopDialog(
        maxWidth: 1180,
        maxHeight: 820,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const Key('uni-desktop-close'),
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            Expanded(
              child: DesktopUniswapView(
                deps: deps,
                showHeader: false,
                initialAmount: initialAmount,
                onPayWithOtherCoin: () => payWithOtherCoin(context),
              ),
            ),
          ],
        ),
      ),
    );
  } else {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (c) => UniswapSwapView(
          deps: deps,
          initialAmount: initialAmount,
          onPayWithOtherCoin: () => payWithOtherCoin(c),
        ),
      ),
    );
  }
  deps.dispose();
}
