/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-DAPP-STRIP: what the dApp screen's wallet line is built from, over a
// REAL BeamWallet (fake host and explorer, real Isar). The line follows the
// wallet's own honest sync verdicts and connection events (the state the
// wallet home's banner shows), as they happen: no timer polls it.

import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/dapps/host/beam_wallet_dapp_link.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_wallet_link.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../wallet/beam_wallet_test_support.dart';

const _height = 4100000;

/// A host whose core is not installed: every open fails.
class _MissingCoreHost extends FakeBeamHost {
  _MissingCoreHost() : super(replies: () => const {});

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async => throw const BeamHostException(
    BeamHostError.binaryMissing,
    'wallet-api not found',
  );
}

void main() {
  late Directory tmp;
  late Isar isar;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_dapp_link_test_');
    isar = await openTestMainDb(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  late Map<String, Object?> status;
  late FakeBeamHost host;
  late FakeExplorer explorer;
  final opened = <BeamWallet>[];

  void installEnv(FakeBeamHost h) {
    final root = p.join(
      tmp.path,
      'root-${DateTime.now().microsecondsSinceEpoch}',
    );
    Directory(root).createSync(recursive: true);
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => h,
      createExplorer: () => explorer,
      privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
      explorerPollInterval: const Duration(milliseconds: 200),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
      privateNodeReadyHold: Duration.zero,
      log: (_) {},
    );
  }

  setUp(() {
    status = statusJson(height: _height);
    host = FakeBeamHost(
      replies: () => {
        'ev_subunsub': true,
        'wallet_status': (Map<String, Object?> _) => status,
        'addr_list': (Map<String, Object?> _) => const <Object?>[],
        'tx_list': (Map<String, Object?> _) => const <Object?>[],
      },
    );
    explorer = FakeExplorer(_height);
    installEnv(host);
  });

  tearDown(() async {
    for (final w in opened) {
      await BeamWalletServices.forget(w.walletId);
      await w.exit();
    }
    opened.clear();
  });

  Future<BeamWallet> newWallet() async {
    final w = await Wallet.create(
      walletInfo: WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: 'dapp link test',
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
    opened.add(w);
    await w.init();
    return w;
  }

  test('catching up: says so, then the change arrives by itself and the '
      'line goes', () async {
    status = statusJson(height: 0);
    final w = await newWallet();
    final link = BeamWalletDappLink(w);
    var changes = 0;
    final sub = link.walletChanges.listen((_) => changes++);
    await w.open();
    await waitFor(
      () => w.syncAssessment is BeamSyncCatchingUp,
      what: 'catching up',
    );
    expect(link.walletWait?.kind, DappWalletWaitKind.catchingUp);
    expect(link.spendBlockedReason, isNotNull, reason: 'approvals wait too');
    expect(changes, greaterThan(0), reason: 'the verdicts were announced');

    // The core gets there; one core event re-reads its status. Nobody asks
    // the link: the change is announced.
    final before = changes;
    status = statusJson(height: _height);
    host.lastTransport!.emit('ev_txs_changed', {'change': 0});
    await waitFor(() => w.canSpend, what: 'synced');
    await waitFor(() => changes > before, what: 'change announced');
    expect(link.walletWait, isNull);
    expect(link.spendBlockedReason, isNull);
    await sub.cancel();
  });

  test('connecting: the core has not reached its node yet', () async {
    host.reachNode = false;
    final w = await newWallet();
    final link = BeamWalletDappLink(w);
    var changes = 0;
    final sub = link.walletChanges.listen((_) => changes++);
    await w.open();
    await w.whenLive.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(link.walletWait?.kind, DappWalletWaitKind.connecting);

    final before = changes;
    host.lastTransport!.emit('ev_connection_changed', {
      'node_connected': true,
      'own_node': false,
    });
    await w.whenCanSend.timeout(const Duration(seconds: 5));
    await waitFor(() => changes > before, what: 'change announced');
    expect(link.walletWait, isNull);
    await sub.cancel();
  });

  test('a core that cannot start: "can\'t reach", and Try again asks the '
      'wallet to reconnect', () async {
    final w = await newWallet();
    installEnv(_MissingCoreHost());
    await w.exit();
    final link = BeamWalletDappLink(w);
    var changes = 0;
    final sub = link.walletChanges.listen((_) => changes++);
    await w.open();
    await waitFor(() => w.coreProblem != null, what: 'problem');
    await waitFor(() => changes > 0, what: 'change announced');
    expect(link.walletWait?.kind, DappWalletWaitKind.unreachable);
    await link.retryConnection(); // never throws
    expect(link.walletWait?.kind, DappWalletWaitKind.unreachable);
    await sub.cancel();
  });
}
