/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Seen in the DMG test: a payment arrived, Campfire's Notifications list
// stayed empty. The entry was added only after the system banner, and the
// banner fails on an ad-hoc signed build (or when the user said no). Here
// the banner always fails (no notification plugin in tests): the entry must
// still be in Campfire's list.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/models/notification_model.dart';
import 'package:stackwallet/services/notifications_api.dart';
import 'package:stackwallet/services/notifications_service.dart';
import 'package:stackwallet/themes/coin_icon_provider.dart';
import 'package:stackwallet/utilities/beam_app_identity.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_payment_notice.dart';
import 'package:stackwallet/widgets/crypto_notifications.dart';

import '../../hive/hive_ce_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await setUpHiveCeTest();
    if (!DB.instance.hive.isAdapterRegistered(
      NotificationModelAdapter().typeId,
    )) {
      DB.instance.hive.registerAdapter(NotificationModelAdapter());
    }
    await DB.instance.hive.openBox<dynamic>(DB.boxNamePrefs);
    await DB.instance.hive.openBox<NotificationModel>(DB.boxNameNotifications);
  });

  tearDown(() async {
    await tearDownHiveCeTest();
  });

  test('a payment notice is in Campfire\'s list even when the system banner '
      'fails', () async {
    expect(BeamAppIdentity.isActive, isTrue, reason: 'the BEAM build');
    await Prefs.instance.init();
    NotificationApi.prefs = Prefs.instance;
    NotificationApi.notificationsService = NotificationsService.instance;

    await NotificationApi.showNotification(
      title: 'Received 0.01 BEAM',
      body: 'Second test',
      walletId: 'w2',
      iconAssetName: 'beam.svg',
      date: DateTime(2026, 10, 7, 6, 40),
      shouldWatchForUpdates: false,
      coinName: 'beam',
      txid: 'ab' * 16,
    );

    final saved = DB.instance
        .values<NotificationModel>(boxName: DB.boxNameNotifications)
        .toList();
    expect(saved, hasLength(1));
    expect(saved.single.title, 'Received 0.01 BEAM');
    expect(saved.single.walletId, 'w2');
  });

  // Seen live: the payment was announced, and nothing listened. The
  // listener wrapped the first route, and the desktop login removes every
  // route (pushNamedAndRemoveUntil). main.dart now mounts it in
  // MaterialApp.builder, above the navigator, as here.
  testWidgets('a payment announced after a login that clears every route '
      'still reaches the list', (tester) async {
    await tester.runAsync(() async {
      await Prefs.instance.init();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            coinIconProvider.overrideWithProvider(
              (coin) => Provider<String>((_) => 'beam.svg'),
            ),
          ],
          child: MaterialApp(
            builder: (context, child) =>
                CryptoNotifications(child: child ?? const SizedBox.shrink()),
            onGenerateRoute: (settings) => MaterialPageRoute<void>(
              builder: (_) => const Text('home after login'),
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamedAndRemoveUntil('/home', (route) => false),
                child: const Text('log in'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('log in'));
      await tester.pumpAndSettle();
      expect(find.text('home after login'), findsOneWidget);

      announceBeamPayment(
        BeamPaymentReceived(
          walletId: 'w2',
          walletName: 'Second test',
          txId: 'cd' * 16,
          value: BigInt.from(1000000),
          assetId: 0,
          at: DateTime(2026, 10, 7, 7, 25),
        ),
      );
      for (
        var i = 0;
        i < 50 &&
            DB.instance
                .values<NotificationModel>(boxName: DB.boxNameNotifications)
                .isEmpty;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final saved = DB.instance
        .values<NotificationModel>(boxName: DB.boxNameNotifications)
        .toList();
    expect(saved.map((n) => n.title), ['Received 0.01 BEAM']);
  });
}
