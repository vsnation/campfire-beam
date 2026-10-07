/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's own Send entry points — SendView (phone route) and
// DesktopSend (desktop wallet tab) — open the BEAM send screen for a BEAM
// wallet, wired to the real BeamWallet (fake host on FakeTransport, real
// Isar) through pWallets, and a payment to an address is prepared by that
// wallet without anything being sent.

import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/pages/send_view/send_view.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/wallet_view/sub_widgets/desktop_send.dart';
import 'package:stackwallet/providers/global/wallets_provider.dart';
import 'package:stackwallet/services/wallets.dart';
import 'package:stackwallet/themes/coin_image_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/themes/theme_providers.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_review.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_screen.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_widgets.dart';

import '../core/fixtures.dart';
import '../wallet/beam_wallet_test_support.dart';
import 'send_ui_support.dart';

const _myAddr =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

Map<String, Object?> _replies() => {
  'ev_subunsub': true,
  'wallet_status': (Map<String, Object?> _) =>
      statusJson(height: kTip, available: g(0.05)),
  'addr_list': (Map<String, Object?> _) => [ownAddressJson(_myAddr)],
  'tx_list': (Map<String, Object?> _) => <Object?>[],
  'validate_address': (Map<String, Object?> _) => {
    'is_valid': true,
    'is_mine': false,
    'type': 'regular',
  },
  'calc_change': fixtureEnvelope('calc_change'),
};

void main() {
  late Directory tmp;
  late Isar isar;
  late FakeBeamHost host;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_send_view_test_');
    // The widget-test binding blocks HTTP; the Isar core is fetched once.
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      isar = await openTestMainDbShared(
        Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
      );
    } finally {
      HttpOverrides.global = saved;
    }
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  Future<BeamWallet> openWallet(WidgetTester tester) async {
    late BeamWallet wallet;
    await tester.runAsync(() async {
      final root = (await Directory(
        p.join(tmp.path, 'root-${DateTime.now().microsecondsSinceEpoch}'),
      ).create(recursive: true)).path;
      host = FakeBeamHost(replies: _replies);
      BeamWalletEnvironment.instance = BeamWalletEnvironment(
        beamRoot: () async => root,
        createHost: (_) => host,
        createExplorer: () => FakeExplorer(kTip),
        privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
        explorerPollInterval: const Duration(hours: 1),
        statusPollInterval: const Duration(hours: 1),
        eventDebounce: const Duration(milliseconds: 20),
        privateNodeStartDelay: Duration.zero,
        privateNodeReadyHold: Duration.zero,
        log: (_) {},
      );
      wallet = await Wallet.create(
        walletInfo: WalletInfo.createNew(
          coin: Beam(CryptoCurrencyNetwork.main),
          name: 'Everyday BEAM',
        ),
        mainDB: MainDB.instance,
        secureStorageInterface: FakeSecureStorage(),
        nodeService: FakeNodeService(
          beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
        ),
        prefs: FakePrefs(),
        mnemonic: bip39.generateMnemonic(),
        mnemonicPassphrase: '',
      ) as BeamWallet;
      await wallet.init();
      await wallet.open();
      await wallet.whenCanSend.timeout(const Duration(seconds: 5));
      await wallet.whenLive.timeout(const Duration(seconds: 5));
      Wallets.sharedInstance.addWallet(wallet);
    });
    addTearDown(() => tester.runAsync(wallet.exit));
    return wallet;
  }

  Future<void> pumpEntry(
    WidgetTester tester,
    Widget entry, {
    required bool desktop,
  }) async {
    await loadCampfireFonts(tester);
    final colors = StackColors.fromStackColorTheme(campfireLight);
    // Not disposed at the end: Campfire's wallet-info Watcher is disposed
    // twice when its container is (the app never disposes it).
    final container = ProviderContainer(
      overrides: [
        pWallets.overrideWithValue(Wallets.sharedInstance),
        themeProvider.overrideWithProvider(
          StateProvider<StackTheme>((ref) => campfireLight),
        ),
        coinImageSecondaryProvider.overrideWithProvider(
          (coin) => Provider<String>((_) => 'none.png'),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: campfireThemeData(colors),
          home: BeamSendLayout(
            desktop: desktop,
            child: desktop
                ? Scaffold(body: SingleChildScrollView(child: entry))
                : entry,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('SendView of a BEAM wallet is the BEAM send screen on the real '
      'wallet', (tester) async {
    await setScreen(tester, desktop: false);
    final wallet = await openWallet(tester);
    await pumpEntry(
      tester,
      SendView(walletId: wallet.walletId, coin: wallet.cryptoCurrency),
      desktop: false,
    );
    expect(find.byType(BeamSendScreen), findsOneWidget);
    expect(find.text('Send BEAM'), findsOneWidget);
    expect(find.text('Everyday BEAM'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('beamSendAvailable'))).data,
      '0.05 BEAM',
    );
    expect(find.text('Enter BEAM address or name'), findsOneWidget);
    // Campfire's generic form (and its fee sheet) is not shown for BEAM.
    expect(find.text('Transaction fee (estimated)'), findsNothing);

    // A payment to an address is prepared by the wallet itself.
    await tester.enterText(
      find.byKey(const Key('beamSendRecipientField')),
      vectorAddress('regular'),
    );
    await tester.enterText(
      find.byKey(const Key('beamSendAmountField')),
      '0.01',
    );
    await tester.pump(const Duration(milliseconds: 400));
    final page = tester.state<BeamSendPageState>(find.byType(BeamSendPage));
    expect(page.model.canReview, isTrue);
    late final BeamSendReview review;
    await tester.runAsync(() async {
      review = await page.model.prepare(wallet.cryptoCurrency);
    });
    final t = host.lastTransport!;
    expect(t.callsTo('validate_address'), hasLength(1));
    expect(t.callsTo('tx_send'), isEmpty);
    review.dispose();
    await tester.runAsync(() async {
      // Release the wallet's own send hold (prepareSend took it).
      await wallet.exit();
    });
  });

  testWidgets('DesktopSend of a BEAM wallet is the BEAM send tab', (
    tester,
  ) async {
    await setScreen(tester, desktop: true);
    final wallet = await openWallet(tester);
    await pumpEntry(
      tester,
      DesktopSend(walletId: wallet.walletId),
      desktop: true,
    );
    expect(find.byType(BeamSendScreen), findsOneWidget);
    expect(find.text('Send to'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Preview send'), findsNothing);
  });
}
