/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the Ethereum screens: a real EthereumWallet registered
// in Campfire's Wallets next to the BEAM one (wiring_harness.dart), the
// node list from Campfire's own NodeService over a test Hive, and no prices
// (the real service reads Hive and the network).
//
// No network: the wallet is never refreshed, and the Ethereum index
// (`EthereumAPI.client`) is a fake that answers from a table.

import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/balance.dart';
import 'package:stackwallet/models/isar/models/ethereum/eth_contract.dart';
import 'package:stackwallet/models/node_model.dart';
import 'package:stackwallet/networking/http.dart';
import 'package:stackwallet/services/ethereum/ethereum_api.dart';
import 'package:stackwallet/services/node_service.dart';
import 'package:stackwallet/services/price_service.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/ethereum/wbeam.dart';
import 'package:stackwallet/wallets/isar/models/token_wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/ethereum_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../../hive/hive_ce_test_utils.dart';
import '../wallet/beam_wallet_test_support.dart';
import '../wiring_ui/wiring_harness.dart' show TestPrefs;

/// Whether this build lists Ethereum (configure_campfire.sh).
bool get buildHasEthereum => AppConfig.coins.whereType<Ethereum>().isNotEmpty;

/// Prices off: nothing is fetched, nothing is shown.
class NoPrices extends PriceService {
  NoPrices() : super('USD');

  @override
  Future<void> updatePrice() async {}
}

/// Campfire's NodeService over a fresh test Hive, with every built-in node
/// saved the way the app saves them at start. Call [closeNodeHive] after.
Future<void> openNodeHive() async {
  await setUpHiveCeTest();
  if (!DB.instance.hive.isAdapterRegistered(NodeModelAdapter().typeId)) {
    DB.instance.hive.registerAdapter(NodeModelAdapter());
  }
  await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
  await NodeService(secureStorageInterface: FakeSecureStorage())
      .updateDefaults();
}

Future<void> closeNodeHive() => tearDownHiveCeTest();

/// A NodeService reading the test Hive; a new one per pump (a provider
/// container disposes its notifier).
NodeService testNodeService() =>
    NodeService(secureStorageInterface: FakeSecureStorage());

/// The Ethereum index (`EthereumAPI.client`) answering from [routes]: the
/// first route whose key the URL contains gives the body. Anything else is
/// a 404. Records every URL.
class FakeEthIndex extends HTTP {
  FakeEthIndex(this.routes);

  final Map<String, Object> routes;
  final List<Uri> seen = [];

  @override
  Future<Response> get({
    required Uri url,
    Map<String, String>? headers,
    required ({InternetAddress host, int port})? proxyInfo,
    Duration? connectionTimeout,
  }) async {
    seen.add(url);
    for (final e in routes.entries) {
      if (url.toString().contains(e.key)) {
        return Response(utf8.encode(jsonEncode(e.value)), 200);
      }
    }
    return Response(const [], 404);
  }
}

/// A real Ethereum wallet, created from a fresh phrase, registered in
/// Campfire's Wallets. Never refreshed: no network.
Future<EthereumWallet> openEthWallet(
  WidgetTester tester, {
  String name = 'Ethereum',
  List<String> tokenAddresses = const [],
}) async {
  late EthereumWallet wallet;
  await tester.runAsync(() async {
    final eth = Ethereum(CryptoCurrencyNetwork.main);
    wallet = await Wallet.create(
      walletInfo: WalletInfo.createNew(coin: eth, name: name),
      mainDB: MainDB.instance,
      secureStorageInterface: FakeSecureStorage(),
      nodeService: FakeNodeService(eth.defaultNode(isPrimary: true)),
      prefs: FakePrefs(),
      mnemonic: bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as EthereumWallet;
    wallet.shouldAutoSync = false;
    await wallet.init();
    if (tokenAddresses.isNotEmpty) {
      await wallet.info.updateContractAddresses(
        newContractAddresses: tokenAddresses.toSet(),
        isar: MainDB.instance.isar,
      );
    }
    Wallets.sharedInstance.addWallet(wallet);
  });
  addTearDown(() async {
    // A refresh a screen started (the wallet view refreshes on open) may
    // still be writing to Isar; left half-done it would hold the write lock
    // and the next test's wallet would wait for ever.
    for (var i = 0; i < 100 && wallet.refreshMutex.isLocked; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    wallet.shouldAutoSync = false;
    await tester.runAsync(wallet.exit);
  });
  return wallet;
}

/// Made-up prices, for the layout of fiat values only: BEAM 0.0287 USD,
/// ETH 2,500 USD; WBEAM as BEAM (`pricesFromCoins`, as the app does); no
/// price for the dollar tokens (Campfire fetches none for ERC-20 tokens).
class LayoutPrices extends PriceService {
  LayoutPrices() : super('USD');

  static final coins = {
    Beam(CryptoCurrencyNetwork.main): (
      value: Decimal.parse('0.0287'),
      change24h: -1.2,
    ),
    Ethereum(CryptoCurrencyNetwork.main): (
      value: Decimal.parse('2500'),
      change24h: 0.8,
    ),
  };

  @override
  ({Decimal value, double change24h})? getPrice(CryptoCurrency coin) =>
      coins[coin];

  @override
  ({Decimal value, double change24h})? getTokenPrice(String contract) =>
      pricesFromCoins(coins, [contract])[contract.toLowerCase()];

  @override
  Future<void> updatePrice() async {}
}

/// Prices shown (Campfire's "external calls" on).
class PricesOnPrefs extends TestPrefs {
  @override
  bool get externalCalls => true;
}

/// Saves [tokens] and the wallet's cached balance of each ([raw] units,
/// the token's decimals), and makes the fake index answer the same
/// balances, so a screen that refreshes them shows the same numbers.
Future<FakeEthIndex> seedTokens(
  WidgetTester tester,
  EthereumWallet wallet,
  Map<EthContract, BigInt> tokens, {
  BigInt? ethWei,
}) async {
  final index = FakeEthIndex({
    for (final e in tokens.entries)
      e.key.address: {
        'data': [
          {'balance': e.value.toString(), 'decimals': e.key.decimals},
        ],
      },
  });
  EthereumAPI.client = index;
  addTearDown(() => EthereumAPI.client = const HTTP());
  await tester.runAsync(() async {
    final isar = MainDB.instance.isar;
    await MainDB.instance.putEthContracts(tokens.keys.toList());
    for (final e in tokens.entries) {
      final info = TokenWalletInfo(
        walletId: wallet.walletId,
        tokenAddress: e.key.address,
        tokenFractionDigits: e.key.decimals,
      );
      await isar.writeTxn(() => isar.tokenWalletInfo.put(info));
      final amount = Amount(rawValue: e.value, fractionDigits: e.key.decimals);
      final zero = Amount.zeroWith(fractionDigits: e.key.decimals);
      await info.updateCachedBalance(
        Balance(
          total: amount,
          spendable: amount,
          blockedTotal: zero,
          pendingSpendable: zero,
        ),
        isar: isar,
      );
    }
    if (ethWei != null) {
      final eth = Amount(rawValue: ethWei, fractionDigits: 18);
      final zero = Amount.zeroWith(fractionDigits: 18);
      await wallet.info.updateBalance(
        newBalance: Balance(
          total: eth,
          spendable: eth,
          blockedTotal: zero,
          pendingSpendable: zero,
        ),
        isar: isar,
      );
    }
    await wallet.info.updateContractAddresses(
      newContractAddresses: {for (final t in tokens.keys) t.address},
      isar: isar,
    );
  });
  return index;
}

/// Lets work a screen started (wallet refresh, token balance fetches, Isar
/// writes) finish: real I/O completes during `runAsync`, its continuations
/// run on the next frame. An Isar write left half-done holds the database's
/// write lock and the next test's wallet would wait on it for ever (as the
/// side-menu tests' `drain`).
Future<void> drainWork(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
