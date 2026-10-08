/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-NOTIFY-PERM: when Campfire for BEAM asks for notification permission.
// Seen in the DMG test: the system asked at first launch, before anything
// had happened. Here the real NotificationApi drives the real notification
// plugin, whose platform channel is recorded:
//   * opening Campfire asks nothing;
//   * the first payment that arrives asks, once;
//   * the payment's entry in Campfire's own list never waits for the
//     answer, and the question never lands on top of an open send, swap,
//     claim or dApp approval;
//   * nothing is asked where notifications are already allowed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/models/notification_model.dart';
import 'package:stackwallet/services/notifications_api.dart';
import 'package:stackwallet/services/notifications_service.dart';
import 'package:stackwallet/utilities/beam_app_identity.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_payment_notice.dart';

import '../../hive/hive_ce_test_utils.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

/// The plugin's side of the platform channel: records every call, answers
/// the permission check with [allowed], and holds the permission question
/// open until [answer] completes (the user has not tapped yet).
class _Platform {
  _Platform({this.allowed = false});

  bool allowed;
  final calls = <MethodCall>[];
  final answer = Completer<bool>();

  List<String> get names => [for (final c in calls) c.method];

  int count(String method) => names.where((n) => n == method).length;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'checkPermissions':
        return {'isEnabled': allowed};
      case 'areNotificationsEnabled':
        return allowed;
      case 'requestPermissions':
      case 'requestNotificationsPermission':
        return answer.future;
      case 'initialize':
        return true;
      default:
        return null;
    }
  }
}

List<String> _listTitles() => [
  for (final n in DB.instance.values<NotificationModel>(
    boxName: DB.boxNameNotifications,
  ))
    n.title,
];

Future<void> _payment(String title) => NotificationApi.showNotification(
  title: title,
  body: 'Everyday BEAM',
  walletId: 'w1',
  iconAssetName: 'beam.svg',
  date: DateTime(2026, 10, 8, 9),
  shouldWatchForUpdates: false,
  coinName: 'beam',
  txid: 'ab' * 16,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Platform platform;

  void onPlatform(TargetPlatform target, _Platform p) {
    platform = p;
    debugDefaultTargetPlatformOverride = target;
    FlutterLocalNotificationsPlatform.instance = switch (target) {
      TargetPlatform.android => AndroidFlutterLocalNotificationsPlugin(),
      TargetPlatform.iOS => IOSFlutterLocalNotificationsPlugin(),
      _ => MacOSFlutterLocalNotificationsPlugin(),
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, p.handle);
  }

  setUp(() async {
    await setUpHiveCeTest();
    if (!DB.instance.hive.isAdapterRegistered(
      NotificationModelAdapter().typeId,
    )) {
      DB.instance.hive.registerAdapter(NotificationModelAdapter());
    }
    await DB.instance.hive.openBox<dynamic>(DB.boxNamePrefs);
    await DB.instance.hive.openBox<NotificationModel>(DB.boxNameNotifications);
    await Prefs.instance.init();
    NotificationApi.prefs = Prefs.instance;
    NotificationApi.notificationsService = NotificationsService.instance;
    NotificationApi.debugReset();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    NotificationApi.debugReset();
    await tearDownHiveCeTest();
  });

  test('the BEAM build waits for open money flows before asking', () {
    expect(BeamAppIdentity.isActive, isTrue, reason: 'the BEAM build');
    expect(NotificationApi.permissionDialogMayShow, beamNoMoneyFlowOpen);
  });

  for (final target in [TargetPlatform.macOS, TargetPlatform.iOS]) {
    group(target.name, () {
      test('opening Campfire asks nothing', () async {
        onPlatform(target, _Platform());
        await NotificationApi.init();
        expect(platform.names, ['initialize']);
        final settings = platform.calls.single.arguments as Map;
        expect(settings['requestAlertPermission'], isFalse);
        expect(settings['requestBadgePermission'], isFalse);
        expect(settings['requestSoundPermission'], isFalse);
      });

      test('the first payment asks, once; its entry in the list never '
          'waits for the answer', () async {
        onPlatform(target, _Platform());
        await NotificationApi.init();

        // The user has not answered (answer is still open): the payment is
        // in Campfire's list all the same.
        await _payment('Received 0.5 BEAM');
        await pumpEventQueue();
        expect(_listTitles(), ['Received 0.5 BEAM']);
        expect(platform.count('requestPermissions'), 1);
        expect(platform.count('show'), 0, reason: 'waits for the answer');

        // A second payment: listed, not asked again.
        await _payment('Received 12 FOMO');
        await pumpEventQueue();
        expect(_listTitles(), ['Received 0.5 BEAM', 'Received 12 FOMO']);
        expect(platform.count('requestPermissions'), 1);

        // "Allow": both banners show.
        platform.answer.complete(true);
        await pumpEventQueue();
        expect(platform.count('show'), 2);
      });

      test('never on top of an open send, swap, claim or approval', () async {
        onPlatform(target, _Platform());
        final moneyFlow = Completer<void>();
        NotificationApi.permissionDialogMayShow = () => moneyFlow.future;
        await NotificationApi.init();

        await _payment('Received 0.5 BEAM');
        await pumpEventQueue();
        expect(_listTitles(), ['Received 0.5 BEAM']);
        expect(platform.count('requestPermissions'), 0);

        moneyFlow.complete(); // the confirm screen closed
        await pumpEventQueue();
        expect(platform.count('requestPermissions'), 1);
        platform.answer.complete(false); // "Don't Allow"
        await pumpEventQueue();
        expect(_listTitles(), ['Received 0.5 BEAM']);
      });

      test('already allowed: nothing is asked, the banner shows at once, '
          'even during a money flow', () async {
        onPlatform(target, _Platform(allowed: true));
        final never = Completer<void>();
        NotificationApi.permissionDialogMayShow = () => never.future;
        await NotificationApi.init();
        await _payment('Received 0.5 BEAM');
        await pumpEventQueue();
        expect(platform.count('requestPermissions'), 0);
        expect(platform.count('show'), 1);
      });
    });
  }

  group('android', () {
    test('opening asks nothing; the first payment asks, once', () async {
      onPlatform(TargetPlatform.android, _Platform());
      await NotificationApi.init();
      expect(platform.names, ['initialize']);

      await _payment('Received 0.5 BEAM');
      await _payment('Received 12 FOMO');
      await pumpEventQueue();
      expect(_listTitles(), hasLength(2));
      expect(platform.count('requestNotificationsPermission'), 1);
      platform.answer.complete(true);
      await pumpEventQueue();
      expect(platform.count('show'), 2);
    });
  });
}
