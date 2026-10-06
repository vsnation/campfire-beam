/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The panel's real source on a real BeamWallet (fake core, fake explorer,
// a fake private node, real Isar): it finds the wallet's coordinator by
// wallet directory, follows its status, measures the disk itself, and its
// buttons and switch reach the node. The switch's choice is stored for the
// next run.

import 'dart:async';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_model.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_source.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_preference.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../wallet/beam_wallet_test_support.dart';

const _height = 4100000;
const _addr =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

class _Node implements BeamPrivateNode {
  final _controller = StreamController<BeamNodeProgress>.broadcast();
  bool stopped = false;
  String? key;

  @override
  int? port = 40123;

  @override
  BeamNodeProgress progress = const BeamNodeProgress();

  @override
  Stream<BeamNodeProgress> get progressStream => _controller.stream;

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    key = ownerKey;
    progress = progress.copyWith(
      ownerAccounts: 1,
      phase: BeamNodePhase.fastSyncDownloading,
      percent: 43,
    );
    _controller.add(progress);
  }

  @override
  Future<void> stop() async {
    if (stopped) return;
    stopped = true;
    await _controller.close();
  }
}

void main() {
  late Directory tmp;
  late Isar isar;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_panel_source_');
    isar = await openTestMainDb(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
  });

  tearDownAll(() async {
    // Let the closed wallet's last background writes land before the
    // database goes away.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  test('finds the coordinator, follows it, and drives it', () async {
    final root = p.join(tmp.path, 'root');
    final host = FakeBeamHost(
      replies: () => {
        'ev_subunsub': true,
        'wallet_status': (Map<String, Object?> _) =>
            statusJson(height: _height, available: BigInt.from(5000000)),
        'addr_list': (Map<String, Object?> _) => [ownAddressJson(_addr)],
        'tx_list': (Map<String, Object?> _) => <Object?>[],
      },
    );
    final nodes = <_Node>[];
    final env = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => host,
      createExplorer: () => FakeExplorer(_height),
      createPrivateNode: (_, _) {
        final n = _Node();
        nodes.add(n);
        return n;
      },
      // The app's setting today: on for desktop, fixed.
      privateNodeSetting: const BeamFixedPrivateNodeSetting(true),
      explorerPollInterval: const Duration(milliseconds: 200),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
    );
    BeamWalletEnvironment.instance = env;

    final w = await Wallet.create(
      walletInfo: WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: 'panel source test',
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
    await w.init();
    addTearDown(w.exit);
    await w.open();
    await w.whenCanSend.timeout(const Duration(seconds: 10));

    final dir = await env.walletDir(w.walletId);
    await waitFor(
      () => BeamPrivateNodeCoordinator.forWalletDir(dir) != null,
      what: 'coordinator registered',
    );

    final pref = BeamPrivateNodePreference(
      beamRoot: () async => root,
      defaultValue: true,
    );
    final source = BeamWalletNodePanelSource(
      w,
      environment: env,
      preference: pref,
      pollInterval: const Duration(milliseconds: 50),
    );
    addTearDown(source.dispose);
    final seen = <BeamNodePanelSnapshot>[];
    final sub = source.changes.listen(seen.add);
    addTearDown(sub.cancel);

    await waitFor(
      () =>
          source.current.privateNode?.phase ==
              BeamPrivateNodePhase.downloading &&
          source.current.disk != null,
      what: 'downloading, with disk numbers',
    );
    final s = source.current;
    expect(s.assessment, isA<BeamSynced>());
    expect(s.node!.isOwned, isFalse);
    expect(s.privateNodeSupported, Platform.isMacOS || Platform.isLinux);
    expect(s.privateNodeEnabled, isTrue);
    expect(s.disk!.space.freeBytes, greaterThan(0));
    expect(s.disk!.freshNode, isTrue, reason: 'nothing under root/node yet');
    expect(BeamNodePanelModel.describe(s).privateTitle, 'Downloading 43%');
    expect(nodes.single.key, isNotNull, reason: 'started with the stored key');

    // "Stop" → stopped by the user; "Start private node" → a new node.
    await source.perform(BeamNodePanelAction.stop);
    await waitFor(
      () =>
          source.current.privateNode?.issue ==
          BeamPrivateNodeIssue.stoppedByUser,
      what: 'stopped by the user',
    );
    expect(nodes.single.stopped, isTrue);
    expect(
      BeamNodePanelModel.describe(source.current).primaryAction,
      BeamNodePanelAction.start,
    );
    await source.perform(BeamNodePanelAction.start);
    await waitFor(() => nodes.length == 2, what: 'a new node');
    await waitFor(
      () =>
          source.current.privateNode?.phase ==
          BeamPrivateNodePhase.downloading,
      what: 'downloading again',
    );

    // The switch: applied now (the coordinator stops the node) and stored
    // for the next run.
    await source.setPrivateNodeEnabled(false);
    await waitFor(
      () => source.current.privateNode?.phase == BeamPrivateNodePhase.off,
      what: 'off',
    );
    expect(nodes.last.stopped, isTrue);
    expect(source.current.privateNodeEnabled, isFalse);
    expect(await pref.read(), isFalse);
    expect(
      File(p.join(root, BeamPrivateNodePreference.fileName))
          .readAsStringSync(),
      '{"enabled":false}',
    );
    expect(w.currentNode!.isOwned, isFalse, reason: 'wallet stays public');
    expect(seen, isNotEmpty);
  });
}
