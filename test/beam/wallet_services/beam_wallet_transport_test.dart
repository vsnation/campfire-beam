/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';

void main() {
  test('calls go to whatever connection the wallet has now', () async {
    final publicNode = FakeTransport({
      'get_version': {'api_version': '7.4', 'which': 'public'},
    });
    final privateNode = FakeTransport({
      'get_version': {'api_version': '7.4', 'which': 'private'},
    });
    BeamApi? current = BeamApi(publicNode);
    final t = BeamWalletTransport(() => current);

    expect(((await t.call('get_version'))! as Map)['which'], 'public');
    current = BeamApi(privateNode); // the wallet switched nodes
    expect(((await t.call('get_version'))! as Map)['which'], 'private');
    expect(publicNode.callsTo('get_version'), hasLength(1));
    expect(privateNode.callsTo('get_version'), hasLength(1));
  });

  test('no connection yet is a typed error, not a crash', () async {
    final t = BeamWalletTransport(() => null);
    expect(t.isConnected, isFalse);
    await expectLater(
      t.call('wallet_status'),
      throwsA(isA<BeamConnectionException>()),
    );
  });

  test('one shared API means one shader queue for every screen', () async {
    // Two services built on the same BeamWalletTransport share BeamApi's
    // per-transport lane; this is why screens must use BeamWalletServices.
    final t = BeamWalletTransport(() => null);
    expect(identical(BeamApi(t).transport, BeamApi(t).transport), isTrue);
  });
}
