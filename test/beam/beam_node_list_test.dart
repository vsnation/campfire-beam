/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The owner: "Nodes should have list of all available nodes by
// {}-nodes.mainnet.beam.mw". Settings > Nodes lists every public BEAM node,
// in their order, the default first, then the user's own.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/db/hive/db.dart';
import 'package:stackwallet/models/node_model.dart';
import 'package:stackwallet/services/node_service.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';

import '../hive/hive_ce_test_utils.dart';

void main() {
  final beam = Beam(CryptoCurrencyNetwork.main);
  var registered = false;

  setUp(() async {
    await setUpHiveCeTest();
    if (!registered) {
      registered = true;
      DB.instance.hive.registerAdapter(NodeModelAdapter());
    }
    await DB.instance.hive.openBox<NodeModel>(DB.boxNameNodeModels);
  });

  tearDown(() async {
    await tearDownHiveCeTest();
  });

  test('every public node, in order, the default first; own nodes after; '
      'a user change to a public node is kept', () async {
    final service = NodeService(secureStorageInterface: FakeSecureStorage());
    await service.updateDefaults();
    expect(service.getNodesFor(beam).map((n) => n.host), [
      for (final n in Beam.mainnetNodes) n.host,
    ]);
    expect(service.getNodesFor(beam).first.name, 'eu-nodes');

    final own = NodeModel(
      host: 'my-node.example',
      port: 8100,
      name: 'Mine',
      id: 'mine',
      useSSL: false,
      enabled: true,
      coinName: beam.identifier,
      isFailover: true,
      isDown: false,
      torEnabled: false,
      clearnetEnabled: true,
      isPrimary: false,
    );
    await service.save(own, null, false);
    final alt = beam.alternateNodes.first;
    await DB.instance.put<NodeModel>(
      boxName: DB.boxNameNodeModels,
      key: alt.id,
      value: alt.copyWith(enabled: false, loginName: null, trusted: null),
    );
    await service.updateDefaults();
    final hosts = service.getNodesFor(beam).map((n) => n.host).toList();
    expect(hosts.last, 'my-node.example');
    expect(hosts, hasLength(Beam.mainnetNodes.length + 1));
    expect(service.getNodeById(id: alt.id)!.enabled, isFalse);
  });

  test('ids a test build used are removed', () async {
    final stale = beam.alternateNodes.first;
    await DB.instance.put<NodeModel>(
      boxName: DB.boxNameNodeModels,
      key: 'beam_public_eu-node01.mainnet.beam.mw',
      value: NodeModel(
        host: stale.host,
        port: stale.port,
        name: stale.name,
        id: 'beam_public_eu-node01.mainnet.beam.mw',
        useSSL: false,
        enabled: true,
        coinName: beam.identifier,
        isFailover: true,
        isDown: false,
        torEnabled: false,
        clearnetEnabled: true,
        isPrimary: false,
      ),
    );
    final service = NodeService(secureStorageInterface: FakeSecureStorage());
    await service.updateDefaults();
    expect(
      service.getNodeById(id: 'beam_public_eu-node01.mainnet.beam.mw'),
      isNull,
    );
    expect(
      service.getNodesFor(beam).where((n) => n.host == stale.host),
      hasLength(1),
    );
  });
}
