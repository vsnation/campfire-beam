/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// R11 on the home itself: a real BeamWallet (fake core on FakeTransport,
// real Isar) whose core takes 1.5 s to come up. The home is pumped before
// the core answers: the cached balance is on screen at once, with no
// spinner, and the live balance replaces it in the same place.

import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'package:stackwallet/themes/coin_icon_provider.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_source.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart';

import '../wallet/beam_wallet_test_support.dart';
import 'home_ui_support.dart';

const _height = 4100000;
const _myAddr =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

void main() {
  testWidgets('the home shows the cached balance before the core answers, '
      'with no spinner, and swaps in the live one in place', (tester) async {
    late Directory tmp;
    late BeamWallet wallet;
    late FakeBeamHost host;
    var status = statusJson(height: _height, available: g(0.05));

    await tester.runAsync(() async {
      // The widget-test binding answers every HTTP request with 400; Isar
      // fetches its core library once, so let that one request through.
      await HttpOverrides.runWithHttpOverrides(
        () => Isar.initializeIsarCore(download: true),
        _RealHttp(),
      );
      tmp = await Directory.systemTemp.createTemp('beam_home_cached_');
      await openTestMainDb(
        Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
      );
      final root = Directory(p.join(tmp.path, 'root'))
        ..createSync(recursive: true);
      host = FakeBeamHost(
        replies: () => {
          'ev_subunsub': true,
          'wallet_status': (Map<String, Object?> _) => status,
          'addr_list': (Map<String, Object?> _) => [ownAddressJson(_myAddr)],
          'tx_list': (Map<String, Object?> _) => <Object?>[],
        },
      );
      BeamWalletEnvironment.instance = BeamWalletEnvironment(
        beamRoot: () async => root.path,
        createHost: (_) => host,
        createExplorer: () => FakeExplorer(_height),
        explorerPollInterval: const Duration(milliseconds: 200),
        statusPollInterval: const Duration(hours: 1),
        eventDebounce: const Duration(milliseconds: 20),
        privateNodeStartDelay: Duration.zero,
        privateNodeReadyHold: Duration.zero,
        log: (_) {},
      );
      wallet = await Wallet.create(
        walletInfo: WalletInfo.createNew(
          coin: Beam(CryptoCurrencyNetwork.main),
          name: 'beam home test',
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
      // A previous session leaves 0.05 BEAM in Campfire's cache.
      await wallet.open();
      await wallet.whenLive.timeout(const Duration(seconds: 5));
      await wallet.exit();

      // This time the core needs 1.5 s, and knows a newer balance.
      host.openDelay = const Duration(milliseconds: 1500);
      status = statusJson(height: _height + 1, available: g(0.07));
      await wallet.init();
      await wallet.open();
    });

    // Fonts first, so a font arriving later cannot move the text.
    await loadFonts(tester);
    // Campfire's WalletInfo watcher (`_wiProvider`) is disposed twice when
    // its container is: by its own onDispose and again by
    // ChangeNotifierProvider, which debug builds assert on. The app never
    // disposes its container, and neither does this test.
    final container = ProviderContainer(
      overrides: [
        pBeamHomeSource.overrideWithProvider(
          (_) => Provider((_) => BeamWalletHomeSource(wallet)),
        ),
        pBeamHomeFormat.overrideWithProvider(
          (_) => Provider((_) => beamFormat(usdPerBeam: null)),
        ),
        coinIconProvider.overrideWithProvider(
          (_) => Provider((_) => beamIconPath()),
        ),
      ],
    );
    try {
      final colors = StackColors.fromStackColorTheme(campfireLightTheme());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: appThemeData(colors),
            home: Material(
              child: Column(
                children: [
                  SizedBox(
                    width: 343,
                    height: 196,
                    child: BeamWalletSummaryInfo(
                      walletId: wallet.walletId,
                      initialSyncStatus: WalletSyncStatus.synced,
                    ),
                  ),
                  BeamHomeExtras(walletId: wallet.walletId),
                ],
              ),
            ),
          ),
        ),
      );

      // First frame: the core is not up, the cached balance is on screen.
      expect(wallet.isOpen, isFalse);
      final spendable = find.byKey(const Key('beamHomeSpendable'));
      expect(
        find.descendant(of: spendable, matching: find.textContaining('0.05')),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      final before = tester.getTopLeft(spendable);

      // The core comes up; Isar's watcher brings the live balance.
      await tester.runAsync(
        () => wallet.whenLive.timeout(const Duration(seconds: 6)),
      );
      expect(wallet.openTimings!.liveData!.inMilliseconds, greaterThan(1400));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.descendant(of: spendable, matching: find.textContaining('0.07')),
        findsOneWidget,
      );
      expect(tester.getTopLeft(spendable), before);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    } finally {
      // Unmount the home first, under the same scope, so the home's
      // controller is disposed on the next frame (riverpod disposes it from
      // the scope's own build), then the scope.
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox(),
        ),
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await wallet.exit();
        // Not closed: Isar.close() waits on watcher callbacks that belong
        // to the widget test's fake clock and never come. The test process
        // ends right after this test; the files are deleted.
        await tmp.delete(recursive: true);
      });
      // Anything the wallet's shutdown scheduled on the test clock.
      await tester.pump(const Duration(seconds: 5));
    }
  });
}

class _RealHttp extends HttpOverrides {}
