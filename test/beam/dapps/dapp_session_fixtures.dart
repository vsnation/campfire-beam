/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'dapp_test_zip.dart';

/// A consent UI the test drives: every request is held until [answer].
class ScriptedPolicy implements DappConsentPolicy {
  final shown = <DappConsentRequest>[];
  final _answers = <Completer<bool>>[];
  int showing = 0;
  int maxShowing = 0;

  /// When set, every request is answered at once with this.
  bool? autoAnswer;

  @override
  Future<bool> approve(DappConsentRequest request) {
    shown.add(request);
    showing++;
    maxShowing = max(maxShowing, showing);
    final c = Completer<bool>();
    _answers.add(c);
    if (autoAnswer != null) c.complete(autoAnswer);
    return c.future.whenComplete(() => showing--);
  }

  void answer(int index, bool ok) => _answers[index].complete(ok);

  /// Waits until [n] requests have been shown.
  Future<void> waitShown(int n) async {
    for (var i = 0; i < 200 && shown.length < n; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (shown.length < n) {
      throw StateError('only ${shown.length} of $n requests shown');
    }
  }
}

const testOrigin = 'http://127.0.0.1:40000';

DappIdentity testIdentity({
  String guid = testGuid,
  String name = 'Test dApp',
}) => DappIdentity(
  guid: guid,
  name: name,
  origin: testOrigin,
  startUrl: '$testOrigin/app/index.html',
  version: '1.2.3',
);

DappSession testSession(
  FakeTransport transport,
  DappConsentPolicy policy, {
  DappApiVersion version = DappApiVersion.v7_4,
  DappConsentQueue? queue,
  DappIdentity? identity,
  void Function(DappActivity)? onActivity,
}) => DappSession(
  identity: identity ?? testIdentity(),
  apiVersion: version,
  transport: transport,
  consent: queue ?? DappConsentQueue(policy),
  onActivity: onActivity,
);

String rq(Object id, String method, [Map<String, Object?>? params]) =>
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });

Map<String, Object?> decode(String response) =>
    (jsonDecode(response) as Map).cast<String, Object?>();

int? errorCode(String response) =>
    ((decode(response)['error'] as Map?)?['code']) as int?;

Object? errorData(String response) =>
    (decode(response)['error'] as Map?)?['data'];

Object? resultOf(String response) => decode(response)['result'];

String txId(int n) => n.toRadixString(16).padLeft(32, '0');
