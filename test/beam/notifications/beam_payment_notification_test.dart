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

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/models/notification_model.dart';
import 'package:stackwallet/services/notifications_api.dart';
import 'package:stackwallet/services/notifications_service.dart';
import 'package:stackwallet/utilities/beam_app_identity.dart';
import 'package:stackwallet/utilities/prefs.dart';

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
}
