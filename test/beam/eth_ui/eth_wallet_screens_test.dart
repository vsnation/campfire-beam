/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Ethereum screens of the BEAM build, desktop 1280 × 800 and a
// 375 × 667 phone: an Ethereum wallet with its WBEAM / USDT / USDC (WBEAM
// drawn as BEAM and priced as BEAM), the Ethereum wallets of My Campfire,
// the Ethereum RPC list with the index note, the add-RPC form, and "Test
// connection" on an RPC of another chain.
//
// No network: the wallet is never synced with anything real (Campfire's
// test binding answers every HTTP request with 400), the Ethereum index is
// a fake, and the RPC test is replaced by a fixed answer. The balances and
// prices are made up for the layout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/manage_nodes_views/add_edit_node_view.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/manage_nodes_views/coin_nodes_view.dart';
import 'package:stackwallet/pages/bridge/bridge_wiring.dart';
import 'package:stackwallet/pages/token_view/my_tokens_view.dart';
import 'package:stackwallet/pages/token_view/sub_widgets/token_summary.dart';
import 'package:stackwallet/pages/wallets_view/wallets_overview.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/desktop_wallet_view.dart';
import 'package:stackwallet/providers/global/node_service_provider.dart';
import 'package:stackwallet/providers/global/price_provider.dart';
import 'package:stackwallet/providers/global/secure_store_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/default_eth_tokens.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/utilities/test_eth_node_connection.dart';
import 'package:stackwallet/utilities/util.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/providers/all_wallets_info_provider.dart';
import 'package:stackwallet/wallets/wallet/impl/ethereum_wallet.dart';
import 'package:stackwallet/widgets/beam/wbeam_icon.dart';
import 'package:stackwallet/widgets/ethereum/eth_index_note.dart';

import '../wiring_ui/wiring_harness.dart';
import 'eth_ui_harness.dart';

final _eth = Ethereum(CryptoCurrencyNetwork.main);

BigInt _units(num amount, int decimals) =>
    BigInt.parse((amount * 100).round().toString()) *
    BigInt.from(10).pow(decimals - 2);

/// An Ethereum wallet holding 0.25 ETH, 1,250 WBEAM, 40 USDT and 15.5 USDC.
Future<EthereumWallet> _ethWithTokens(WidgetTester tester) async {
  final wallet = await openEthWallet(tester, name: 'Ethereum');
  await seedTokens(tester, wallet, {
    DefaultTokens.wbeam: _units(1250, 8),
    DefaultTokens.usdt: _units(40, 6),
    DefaultTokens.usdc: _units(15.5, 6),
  }, ethWei: _units(0.25, 18));
  return wallet;
}

Widget _phone(Widget child) => Builder(
  builder: (context) => Scaffold(
    backgroundColor: Theme.of(context).extension<StackColors>()!.background,
    body: child,
  ),
);

class _FixedEthTest {
  _FixedEthTest(this.result);

  final EthNodeTestResult result;
  final List<String> seen = [];

  Future<EthNodeTestResult> call(String url) async {
    seen.add(url);
    return result;
  }
}

const _name = Key('addCustomNodeNodeNameFieldKey');
const _host = Key('addCustomNodeNodeAddressFieldKey');

void main() {
  final db = WiringDb();
  setUpAll(() async {
    await db.open();
    await openNodeHive();
  });
  tearDownAll(() async {
    await closeNodeHive();
    await db.close();
  });

  for (final desktop in [true, false]) {
    final where = desktop ? 'desktop' : 'phone';
    group(where, () {
      setUp(() => Util.debugIsDesktop = desktop);
      tearDown(() => Util.debugIsDesktop = null);

      testWidgets('an Ethereum wallet: WBEAM first, drawn and priced as BEAM '
          '($where)', (tester) async {
        final wallet = await _ethWithTokens(tester);
        await pumpWiring(
          tester,
          desktop
              ? DesktopWalletView(walletId: wallet.walletId)
              : MyTokensView(walletId: wallet.walletId),
          desktop: desktop,
          prefs: PricesOnPrefs(),
          overrides: [
            pAllWalletsInfo.overrideWithValue([wallet.info]),
            priceAnd24hChangeNotifierProvider.overrideWithValue(LayoutPrices()),
            nodeServiceChangeNotifierProvider.overrideWithValue(
              testNodeService(),
            ),
          ],
        );
        await drainWork(tester);
        await settle(tester);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/eth_wallet_tokens_$where.png'),
        );
        expect(find.text('Wrapped BEAM'), findsOneWidget);
        expect(find.byKey(const ValueKey('wbeam-icon')), findsOneWidget);
        final names = [
          for (final t in ['Wrapped BEAM', 'Tether', 'USD Coin'])
            tester.getTopLeft(find.text(t)).dy,
        ];
        expect(
          names,
          orderedEquals([...names]..sort()),
          reason: 'WBEAM on top',
        );
        // WBEAM at BEAM's price (0.0287 USD, two decimals in this list);
        // Campfire has no price for the dollar tokens.
        expect(find.text('0.03 USD'), findsOneWidget);
        await drainWork(tester);
        await finish(tester);
      });

      testWidgets('Ethereum RPCs: Stack Wallet first, then the public ones, '
          'and where the rest of the data comes from ($where)', (tester) async {
        await pumpWiring(
          tester,
          CoinNodesView(coin: _eth),
          desktop: desktop,
          frame: false,
          overrides: [
            nodeServiceChangeNotifierProvider.overrideWithValue(
              testNodeService(),
            ),
            secureStoreProvider.overrideWithValue(FakeSecureStorage()),
          ],
        );
        for (final name in [
          'Stack Wallet',
          'PublicNode',
          'dRPC',
          'MEV Blocker',
          'Blast',
        ]) {
          expect(find.text(name), findsOneWidget, reason: name);
        }
        expect(find.byType(EthIndexNote), findsOneWidget);
        expect(
          find.text(
            'Payment history, fee estimates and token details come from Stack '
            "Wallet's Ethereum index (eth2.stackwallet.com), through Tor when "
            'Tor is on.',
          ),
          findsOneWidget,
        );
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/eth_nodes_$where.png'),
        );
        await finish(tester);
      });

      Future<_FixedEthTest> pumpAddRpc(
        WidgetTester tester,
        EthNodeTestResult result,
      ) async {
        final fake = _FixedEthTest(result);
        await pumpWiring(
          tester,
          _phone(
            desktop
                ? Center(
                    child: AddEditNodeView(
                      viewType: AddEditNodeViewType.add,
                      coin: _eth,
                      nodeId: null,
                      routeOnSuccessOrDelete: '/',
                    ),
                  )
                : AddEditNodeView(
                    viewType: AddEditNodeViewType.add,
                    coin: _eth,
                    nodeId: null,
                    routeOnSuccessOrDelete: '/',
                  ),
          ),
          desktop: desktop,
          frame: false,
          overrides: [
            nodeServiceChangeNotifierProvider.overrideWithValue(
              testNodeService(),
            ),
            secureStoreProvider.overrideWithValue(FakeSecureStorage()),
            testEthNodeConnectionProvider.overrideWithValue(fake.call),
          ],
        );
        return fake;
      }

      testWidgets('add an RPC: one URL, no port, SSL or login ($where)', (
        tester,
      ) async {
        await pumpAddRpc(
          tester,
          const EthNodeTestResult(EthNodeTestStatus.mainnet),
        );
        expect(find.text('RPC URL'), findsOneWidget);
        expect(
          find.byKey(const Key('addCustomNodeNodePortFieldKey')),
          findsNothing,
        );
        expect(find.text('Use SSL'), findsNothing);
        expect(find.text('Login (optional)'), findsNothing);
        expect(find.text('Use as failover'), findsNothing);
        expect(find.text('Only TOR traffic'), findsNothing);

        await tester.enterText(find.byKey(_name), 'My RPC');
        await tester.enterText(
          find.byKey(_host),
          'https://eth-mainnet.example.org/v2/my-key',
        );
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byKey(_host)).controller!.text,
          'https://eth-mainnet.example.org/v2/my-key',
          reason: 'the path stays',
        );
        expect(
          find.byKey(const Key('addCustomNodeEthUrlProblem')),
          findsNothing,
        );
        await settle(tester);
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/eth_add_rpc_$where.png'),
        );

        // http:// to a public host is explained, and cannot be tested.
        await tester.enterText(find.byKey(_host), 'http://eth.drpc.org');
        await tester.pump();
        expect(
          find.byKey(const Key('addCustomNodeEthUrlProblem')),
          findsOneWidget,
        );
        await finish(tester);
      });

      testWidgets('Test connection on another chain says so ($where)', (
        tester,
      ) async {
        final fake = await pumpAddRpc(
          tester,
          EthNodeTestResult(
            EthNodeTestStatus.wrongChain,
            chainId: BigInt.from(56),
          ),
        );
        await tester.enterText(find.byKey(_name), 'Some RPC');
        await tester.enterText(find.byKey(_host), 'https://bsc-rpc.example');
        await tester.pump();
        await tester.tap(find.text('Test connection'));
        await tester.pump();
        // The toast slides in over 1 s and stays 1.5 s.
        await tester.pump(const Duration(milliseconds: 1100));
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/eth_rpc_not_mainnet_$where.png'),
        );
        expect(fake.seen, ['https://bsc-rpc.example']);
        expect(
          find.text(
            'This RPC is not Ethereum mainnet (chain id 56). Pick another.',
          ),
          findsOneWidget,
        );
        // Save refuses it too, with the same words, and saves nothing.
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        await finish(tester);
      });
    });
  }

  testWidgets('a token the bridge carries offers Bridge on its page; one it '
      'does not, none (phone)', (tester) async {
    Util.debugIsDesktop = false;
    BridgeSides.debugAvailable = true;
    addTearDown(() {
      Util.debugIsDesktop = null;
      BridgeSides.debugAvailable = null;
    });
    final wallet = await _ethWithTokens(tester);
    for (final (token, bridged) in [
      (DefaultTokens.wbeam, true),
      (DefaultTokens.usdt, true),
      (DefaultTokens.usdc, false),
    ]) {
      await pumpWiring(
        tester,
        _phone(
          Center(
            child: TokenWalletOptions(
              walletId: wallet.walletId,
              tokenContract: token,
            ),
          ),
        ),
        desktop: false,
        prefs: PricesOnPrefs(),
      );
      await tester.pump();
      expect(
        find.byKey(const Key('tokenBridgeButton')),
        bridged ? findsOneWidget : findsNothing,
        reason: token.symbol,
      );
      expect(find.text('Send'), findsOneWidget);
    }
  });

  testWidgets('My Campfire › Ethereum: the wallet with its tokens, WBEAM as '
      'BEAM (desktop)', (tester) async {
    Util.debugIsDesktop = true;
    addTearDown(() => Util.debugIsDesktop = null);
    final wallet = await _ethWithTokens(tester);
    await pumpWiring(
      tester,
      _phone(
        Padding(
          padding: const EdgeInsets.all(32),
          child: Builder(
            builder: (context) => WalletsOverview(
              coin: _eth,
              navigatorState: Navigator.of(context),
              overrideSimpleWalletCardPopPreviousValueWith: false,
            ),
          ),
        ),
      ),
      desktop: true,
      prefs: PricesOnPrefs(),
      overrides: [
        pAllWalletsInfo.overrideWithValue([wallet.info]),
        priceAnd24hChangeNotifierProvider.overrideWithValue(LayoutPrices()),
        nodeServiceChangeNotifierProvider.overrideWithValue(testNodeService()),
      ],
    );
    await drainWork(tester);
    await settle(tester);
    expect(find.byType(WbeamIcon), findsOneWidget);
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/my_campfire_ethereum_wallets_desktop.png'),
    );
    await drainWork(tester);
    await finish(tester);
  });

  testWidgets('My Campfire: a BEAM wallet and an Ethereum wallet with its '
      'tokens, in one list (desktop)', (tester) async {
    Util.debugIsDesktop = true;
    addTearDown(() => Util.debugIsDesktop = null);
    final beam = await openBeamWallet(tester, db);
    final eth = await _ethWithTokens(tester);
    await pumpWiring(
      tester,
      const MyStackView(),
      desktop: true,
      prefs: PricesOnPrefs(),
      overrides: [
        pAllWalletsInfo.overrideWithValue([beam.info, eth.info]),
        priceAnd24hChangeNotifierProvider.overrideWithValue(LayoutPrices()),
        nodeServiceChangeNotifierProvider.overrideWithValue(testNodeService()),
      ],
    );
    await drainWork(tester);
    await settle(tester);
    // Each wallet with its balance, BEAM first; Ethereum's tokens below it.
    expect(find.text('Everyday BEAM'), findsWidgets);
    expect(find.textContaining('1,250.00000000 WBEAM'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Everyday BEAM').last).dy,
      lessThan(tester.getTopLeft(find.textContaining('WBEAM').first).dy),
    );
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/my_campfire_beam_and_ethereum_desktop.png'),
    );
    await drainWork(tester);
    await finish(tester);
  });
}
