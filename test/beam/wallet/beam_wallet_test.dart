/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamWallet against a fake host (sessions on FakeTransport), a fake
// explorer, fake secure storage and a real Isar: create / restore / open /
// refresh / send / delete, the password and owner-key lifecycle, the
// "core not installed" state, and the node-switch gate with a real
// BeamPrivateNodeCoordinator driven by a fake node.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/services/event_bus/events/global/node_connection_status_changed_event.dart';
import 'package:stackwallet/services/event_bus/events/global/wallet_sync_status_changed_event.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_process.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_node_switch_gate.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_payment_notice.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_secret_store.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_swaps_in_flight.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/models/tx_data.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../core/fixtures.dart';
import 'beam_wallet_test_support.dart';

const _height = 4100000;
const _myAddr =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

/// A real-looking regular BEAM address (public BEAM core test vector).
String _payee() =>
    ((jsonDecode(
                  File('test/beam/fixtures/beam_core_address_vectors.json')
                      .readAsStringSync(),
                ) as Map)['valid']
                as List)
            .cast<Map<String, Object?>>()
            .firstWhere((v) => v['type'] == 'regular')['address']!
        as String;

String _vector(String type) =>
    ((jsonDecode(
                  File('test/beam/fixtures/beam_core_address_vectors.json')
                      .readAsStringSync(),
                ) as Map)['valid']
                as List)
            .cast<Map<String, Object?>>()
            .firstWhere((v) => v['type'] == type)['address']!
        as String;

BigInt _g(num beam) => BigInt.from((beam * 100000000).round());

/// The core as the fake transports present it. Mutable between steps.
class _Core {
  Map<String, Object?> status = statusJson(
    height: _height,
    available: _g(0.05),
  );
  List<Map<String, Object?>> addrs = [ownAddressJson(_myAddr)];
  List<Map<String, Object?>> txs = [
    txJson(
      txId: '01' * 16,
      status: 3,
      income: true,
      value: 5000000,
      sender: '22' * 33,
      receiver: _myAddr,
      height: _height - 10,
      kernel: 'ab' * 32,
    ),
  ];
  final sent = <Map<String, Object?>>[];
  bool dropOnSend = false;
  bool knowsDroppedTx = true;
  String nextTxId = 'fe' * 16;

  Map<String, Object?> replies() => {
    'ev_subunsub': true,
    'wallet_status': (Map<String, Object?> _) => status,
    'addr_list': (Map<String, Object?> _) => addrs,
    'tx_list': (Map<String, Object?> _) => txs,
    'create_address': (Map<String, Object?> _) {
      addrs = [...addrs, ownAddressJson('33' * 33, createTime: 1790000500)];
      return '33' * 33;
    },
    'validate_address': (Map<String, Object?> params) => {
      'is_valid': true,
      'is_mine': false,
      'type': (params['address']! as String).length < 70
          ? 'regular'
          : 'offline',
    },
    'calc_change': fixtureEnvelope('calc_change'),
    'generate_tx_id': (Map<String, Object?> _) => nextTxId,
    'tx_send': (Map<String, Object?> params) {
      sent.add(params);
      if (dropOnSend) {
        throw const BeamConnectionException('connection dropped');
      }
      return {'txId': params['txId']};
    },
    'tx_status': (Map<String, Object?> params) {
      if (!knowsDroppedTx) {
        throw const BeamRpcException(-32001, 'Unknown tx');
      }
      return txJson(txId: params['txId']! as String, status: 0);
    },
  };
}

class _Node implements BeamPrivateNode {
  final _controller = StreamController<BeamNodeProgress>.broadcast();
  String? keyReceived;
  bool stopped = false;

  @override
  int? port = 40123;

  @override
  BeamNodeProgress progress = const BeamNodeProgress();

  @override
  Stream<BeamNodeProgress> get progressStream => _controller.stream;

  void emit(BeamNodeProgress next) {
    progress = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    keyReceived = ownerKey;
    emit(progress.copyWith(ownerAccounts: 1));
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
    tmp = await Directory.systemTemp.createTemp('beam_wallet_test_');
    isar = await openTestMainDb(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  late String root;
  late _Core core;
  late FakeBeamHost host;
  late FakeExplorer explorer;
  late FakeSecureStorage secure;
  late List<String> envLog;
  final created = <BeamWallet>[];

  final received = <BeamPaymentReceived>[];
  late BeamSwapsInFlight swaps;

  void installEnv({
    BeamPrivateNodeBuilder? node,
    bool privateNode = false,
    BeamHost Function(String root)? createHost,
  }) {
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: createHost ?? (_) => host,
      createExplorer: () => explorer,
      createPrivateNode: node,
      privateNodeSetting: BeamFixedPrivateNodeSetting(privateNode),
      explorerPollInterval: const Duration(milliseconds: 200),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
      privateNodeReadyHold: Duration.zero,
      onPaymentReceived: received.add,
      swapsInFlight: swaps,
      log: envLog.add,
    );
  }

  setUp(() async {
    root = (await Directory(
      p.join(tmp.path, 'root-${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true)).path;
    core = _Core();
    host = FakeBeamHost(replies: core.replies);
    explorer = FakeExplorer(_height);
    secure = FakeSecureStorage();
    envLog = [];
    received.clear();
    swaps = BeamSwapsInFlight();
    installEnv();
  });

  tearDown(() async {
    for (final w in created) {
      await w.exit();
    }
    created.clear();
  });

  Future<BeamWallet> newWallet({String? mnemonic, bool init = true}) async {
    final info = WalletInfo.createNew(
      coin: Beam(CryptoCurrencyNetwork.main),
      name: 'beam test',
    );
    final wallet = await Wallet.create(
      walletInfo: info,
      mainDB: MainDB.instance,
      secureStorageInterface: secure,
      nodeService: FakeNodeService(
        beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
      ),
      prefs: FakePrefs(),
      mnemonic: mnemonic ?? bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as BeamWallet;
    created.add(wallet);
    if (init) await wallet.init();
    return wallet;
  }

  String keyOf(BeamWallet w) => BeamSecretKeys.walletPassword(w.walletId);
  String ownerOf(BeamWallet w) => BeamSecretKeys.ownerKey(w.walletId);
  String dirOf(BeamWallet w) => p.join(root, 'wallets', w.walletId);

  group('create, restore, delete: password and owner key', () {
    test('create makes wallet.db with a random password, reads the owner '
        'key while closed, and stores both under the BEAM keys', () async {
      final w = await newWallet();
      expect(host.calls, ['initWallet', 'exportOwnerKey']);
      final password = await secure.read(key: keyOf(w));
      expect(password, isNotNull);
      expect(password!.length, greaterThanOrEqualTo(20));
      expect(keyOf(w), 'BEAM_WALLET_PASSWORD_${w.walletId.toUpperCase()}');
      expect(await secure.read(key: ownerOf(w)), 'fake-owner-key-1');
      expect(File(p.join(dirOf(w), 'wallet.db')).existsSync(), isTrue);
      expect(w.info.beamData!.restoreScanPending, isFalse);
      // The secrets are not in otherData (which goes into backups).
      expect(w.info.otherDataJsonString, isNot(contains(password)));
      expect(w.info.otherDataJsonString, isNot(contains('fake-owner-key')));

      // A second init (app restart) does nothing slow.
      host.calls.clear();
      await w.init();
      expect(host.calls, isEmpty);
    });

    test('a phrase with a bad checksum never reaches the core', () async {
      final words = bip39.generateMnemonic().split(' ');
      // Swap two words: still dictionary words, checksum almost surely off.
      final swapped = [...words]
        ..[0] = words[1]
        ..[1] = words[0];
      final phrase = bip39.validateMnemonic(swapped.join(' '))
          ? ([
              ...words,
            ]..[11] = words[11] == 'abandon' ? 'zoo' : 'abandon').join(' ')
          : swapped.join(' ');
      expect(bip39.validateMnemonic(phrase), isFalse);
      await expectLater(
        newWallet(mnemonic: phrase),
        throwsA(
          isA<BeamWalletException>().having(
            (e) => e.problem,
            'problem',
            BeamWalletProblem.invalidPhrase,
          ),
        ),
      );
      expect(host.calls, isEmpty);
    });

    test('restore: new password, new owner key, scanning flag, body '
        'requests on', () async {
      final mnemonic = bip39.generateMnemonic();
      final w = await newWallet(mnemonic: mnemonic, init: false);
      await w.init(isRestore: true);
      expect(host.calls, isEmpty);
      await w.recover(isRescan: false);
      final firstPassword = await secure.read(key: keyOf(w));
      expect(await secure.read(key: ownerOf(w)), 'fake-owner-key-1');
      expect(w.info.beamData!.restoreScanPending, isTrue);
      expect(w.isScanningForCoins, isTrue);

      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(host.requestBodies.last, isTrue);

      // A rescan rebuilds wallet.db: another fresh password and key.
      await w.recover(isRescan: true);
      expect(await secure.read(key: keyOf(w)), isNot(firstPassword));
      expect(await secure.read(key: ownerOf(w)), 'fake-owner-key-2');
      await waitFor(() => w.isOpen, what: 'reopen after rescan');
    });

    test('delete removes wallet.db and both secrets', () async {
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      await w.exit();
      expect(host.open, isEmpty);
      await deleteBeamWallet(walletId: w.walletId, secureStore: secure);
      expect(await secure.read(key: keyOf(w)), isNull);
      expect(await secure.read(key: ownerOf(w)), isNull);
      expect(Directory(dirOf(w)).existsSync(), isFalse);
    });

    test('an older wallet without a stored owner key gets it read once '
        'before opening, when the private node is on', () async {
      final w = await newWallet();
      await secure.delete(key: ownerOf(w));
      installEnv(node: (_, _) => _Node(), privateNode: true);
      host.calls.clear();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(host.calls.take(2), ['exportOwnerKey', 'openWallet']);
      expect(await secure.read(key: ownerOf(w)), 'fake-owner-key-2');
      expect(w.openTimings!.ownerKeyCapture, isNotNull);
    });
  });

  group('opening is instant, data arrives behind the cached view', () {
    test('open() returns at once while the core takes its time', () async {
      final w = await newWallet();
      // A previous session left a cached balance.
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      final cached = w.info.cachedBalance;
      expect(cached.spendable.raw, _g(0.05));
      await w.exit();

      host.openDelay = const Duration(milliseconds: 1500);
      core.status = statusJson(height: _height + 1, available: _g(0.07));
      final sw = Stopwatch()..start();
      await w.init();
      await w.open();
      final txCount = await isar.transactionV2s
          .where()
          .walletIdEqualTo(w.walletId)
          .count();
      final cachedNow = w.info.cachedBalance;
      sw.stop();
      // The view renders from Isar without waiting for the core.
      expect(sw.elapsedMilliseconds, lessThan(300));
      expect(cachedNow.spendable.raw, _g(0.05));
      expect(txCount, 1);
      expect(w.isOpen, isFalse);

      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(w.info.cachedBalance.spendable.raw, _g(0.07));
      expect(w.openTimings!.liveData!.inMilliseconds, greaterThan(1400));
    });

    test('live data: balance, per-asset cache, history, receiving address, '
        'chain height', () async {
      core.status = statusJson(
        height: _height,
        available: _g(0.05),
        receiving: _g(0.02),
        change: _g(0.02),
        extraTotals: [totalsJson(174, available: BigInt.from(1234))],
      );
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      await waitFor(
        () => w.info.cachedReceivingAddress == _myAddr,
        what: 'receiving address',
      );
      final b = w.info.cachedBalance;
      expect(b.spendable.raw, _g(0.05));
      expect(b.pendingSpendable.raw, _g(0.02));
      expect(b.total.raw, _g(0.07));
      expect(w.info.beamAssetTotals[174]!.available, BigInt.from(1234));
      expect(w.info.cachedChainHeight, _height);

      final txs = await isar.transactionV2s
          .where()
          .walletIdEqualTo(w.walletId)
          .findAll();
      expect(txs.single.txid, '01' * 16);
      expect(txs.single.isBeamTransaction, isTrue);
      final addr = await w.getCurrentReceivingAddress();
      expect(addr!.value, _myAddr);
      expect(addr.type, AddressType.mimbleWimble);
      expect(addr.subType, AddressSubType.receiving);
    });

    test('a wallet with no usable address gets a regular one', () async {
      core.addrs = [ownAddressJson(_myAddr, expired: true)];
      final w = await newWallet();
      await w.open();
      await waitFor(
        () => w.info.cachedReceivingAddress == '33' * 33,
        what: 'new address',
      );
      expect(
        host.lastTransport!.lastParams('create_address')['expiration'],
        'never',
      );
    });

    test('a payment that arrives while the wallet is open is announced '
        'once, when it completes; earlier and outgoing ones never', () async {
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      // The completed payment already there at open is history.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty);

      Future<void> emitTxs(List<Map<String, Object?>> txs) async {
        core.txs = txs;
        host.lastTransport!.emit('ev_txs_changed', {'change': 0});
        await waitFor(
          () =>
              isar.transactionV2s
                  .where()
                  .walletIdEqualTo(w.walletId)
                  .countSync() ==
              txs.length,
          what: '${txs.length} txs in Isar',
        );
      }

      final before = core.txs;
      final arriving = txJson(
        txId: '02' * 16,
        status: 1,
        income: true,
        value: 50000000,
        receiver: _myAddr,
      );
      final sent = txJson(
        txId: '03' * 16,
        status: 3,
        income: false,
        value: 1000000,
        receiver: '44' * 33,
      );
      await emitTxs([...before, arriving, sent]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(received, isEmpty, reason: 'still arriving; outgoing');

      final done = {...arriving, 'status': 3};
      await emitTxs([...before, done, sent]);
      await waitFor(() => received.isNotEmpty, what: 'announced');
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(received, hasLength(1));
      final p = received.single;
      expect(p.txId, '02' * 16);
      expect(p.value, _g(0.5));
      expect(p.assetId, 0);
      expect(p.walletName, w.info.name);
      expect(p.title, 'Received 0.5 BEAM');
    });

    // Seen in the DMG test: the scan percent went backwards after a
    // restart. The core counts block requests per session and recounts
    // what is left after a restart.
    test('scan progress never goes back when the core recounts after a '
        'restart', () async {
      final w = await newWallet(init: false);
      await w.init(isRestore: true);
      await w.recover(isRescan: false);
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      host.lastTransport!.emit('ev_sync_progress', {
        'sync_requests_done': 60,
        'sync_requests_total': 100,
      });
      await waitFor(
        () => w.info.beamData?.restoreScanTotal == 100,
        what: 'scan total kept',
      );
      expect(w.scanProgress!.fraction, closeTo(0.6, 1e-9));

      // A restarted core: 40 requests left, counted from 0.
      host.lastTransport!.emit('ev_sync_progress', {
        'sync_requests_done': 0,
        'sync_requests_total': 40,
      });
      await waitFor(() => w.scanProgress?.total == 100, what: 'recount read');
      expect(w.scanProgress!.fraction, closeTo(0.6, 1e-9));
      host.lastTransport!.emit('ev_sync_progress', {
        'sync_requests_done': 30,
        'sync_requests_total': 40,
      });
      await waitFor(
        () => (w.scanProgress?.fraction ?? 0) > 0.85,
        what: 'progress moves on',
      );
      expect(w.scanProgress!.fraction, closeTo(0.9, 1e-9));
      expect(w.info.beamData?.restoreScanTotal, 100);
    });

    test('a payment that completes while a restore scan runs is announced: '
        'a restore finds coins, never history rows', () async {
      final w = await newWallet(init: false);
      await w.init(isRestore: true);
      await w.recover(isRescan: false);
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(w.isScanningForCoins, isTrue);
      core.txs = [
        ...core.txs,
        txJson(
          txId: '05' * 16,
          status: 3,
          income: true,
          value: 1000000,
          receiver: _myAddr,
        ),
      ];
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => received.isNotEmpty, what: 'announced');
      expect(received.single.txId, '05' * 16);
      expect(received.single.title, 'Received 0.01 BEAM');
    });

    test('events drive refreshes: a new transaction shows up without '
        'polling', () async {
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      core.txs = [
        ...core.txs,
        txJson(
          txId: '02' * 16,
          status: 1,
          income: true,
          value: 1000000,
          receiver: _myAddr,
        ),
      ];
      core.status = statusJson(
        height: _height,
        available: _g(0.05),
        receiving: _g(0.01),
      );
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(
        () =>
            isar.transactionV2s
                .where()
                .walletIdEqualTo(w.walletId)
                .countSync() ==
            2,
        what: 'new tx in Isar',
      );
      await waitFor(
        () => w.info.cachedBalance.pendingSpendable.raw == _g(0.01),
        what: 'pending balance',
      );
      final tx = isar.transactionV2s
          .where()
          .txidWalletIdEqualTo('02' * 16, w.walletId)
          .findFirstSync()!;
      expect(tx.beamTxStatus, 'inProgress');
      expect(tx.height, isNull);
    });

    test('honest sync: synced only when the explorer agrees', () async {
      explorer.height = _height + 50; // the network is far ahead
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      await waitFor(
        () => w.syncAssessment is! BeamSyncConnecting,
        what: 'first verdict',
      );
      expect(w.canSpend, isFalse);
      explorer.height = _height + 1;
      await w.whenCanSend.timeout(const Duration(seconds: 5));
      expect(w.syncAssessment, isA<BeamSynced>());
    });

    test('honest sync: a fresh stored tip is not "synced" until the core '
        'has reached its node', () async {
      host.reachNode = false;
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      // is_in_sync is true and the explorer agrees, but no node yet.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(w.syncAssessment, isA<BeamSyncConnecting>());
      expect(w.canSpend, isFalse);
      host.lastTransport!.emit('ev_connection_changed', {
        'node_connected': true,
        'own_node': false,
      });
      await w.whenCanSend.timeout(const Duration(seconds: 5));
      expect(w.syncAssessment, isA<BeamSynced>());
    });

    // Seen in the DMG test: a wallet opened right after its restore showed
    // "Unable to sync" in the header while it was catching up, because the
    // header subscribed after "syncing" was sent and guessed the rest.
    test('statusNow says where the wallet is, for screens that subscribe '
        'late', () async {
      core.status = statusJson(height: 0);
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      await waitFor(
        () => w.syncAssessment is BeamSyncCatchingUp,
        what: 'catching up',
      );
      expect(w.statusNow.sync, WalletSyncStatus.syncing);
      expect(w.statusNow.node, NodeConnectionStatus.connected);

      core.status = statusJson(height: _height, available: _g(0.05));
      // Any core event re-reads the status.
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => w.canSpend, what: 'synced');
      expect(w.statusNow.sync, WalletSyncStatus.synced);
    });

    test('"BEAM core not installed": open() still returns, the state says '
        'so in plain words, refresh does not throw', () async {
      final w = await newWallet();
      installEnv(createHost: (_) => _MissingCoreHost());
      // A fresh environment has no cached host.
      await w.exit();
      final sw = Stopwatch()..start();
      await w.open();
      expect(sw.elapsedMilliseconds, lessThan(100));
      await waitFor(() => w.coreProblem != null, what: 'problem');
      expect(w.coreProblem!.problem, BeamWalletProblem.coreNotInstalled);
      expect('${w.coreProblem}', startsWith('BEAM core not installed.'));
      await w.refresh();
      expect(w.isOpen, isFalse);

      // Creating a wallet without the core fails with the same message.
      await expectLater(
        newWallet(),
        throwsA(
          isA<BeamWalletException>().having(
            (e) => e.problem,
            'problem',
            BeamWalletProblem.coreNotInstalled,
          ),
        ),
      );
    });

    test('a lost connection stops the core it belonged to before the wallet '
        'reopens', () async {
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      final lost = host.sessions.single;

      // The connection drops; the core behind it still has the wallet.
      lost.transport.simulateDisconnect();
      lost.transport.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => !w.isOpen, what: 'the loss noticed');

      await waitFor(
        () => host.sessions.length == 2 && w.isOpen,
        timeout: const Duration(seconds: 8),
        what: 'reopened on a new session',
      );
      expect(lost.closed, isTrue);
      expect(w.coreProblem, isNull);
    });

    test('a wallet whose core was still in use opens on the next '
        'refresh', () async {
      final w = await newWallet();
      host.openError = const BeamHostException(
        BeamHostError.walletInUse,
        'This wallet is already open or busy',
      );
      await w.open();
      await waitFor(
        () => w.coreProblem?.problem == BeamWalletProblem.walletInUse,
        what: 'walletInUse',
      );
      expect(w.isOpen, isFalse);

      await w.refresh();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(w.isOpen, isTrue);
    });

    test('exit closes the core; open works again', () async {
      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      final t = host.lastTransport!;
      await w.exit();
      expect(t.isConnected, isFalse);
      expect(host.open, isEmpty);
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(w.isOpen, isTrue);
    });
  });

  group('sending', () {
    Future<BeamWallet> ready() async {
      final w = await newWallet();
      await w.open();
      await w.whenCanSend.timeout(const Duration(seconds: 5));
      return w;
    }

    TxData tx(String address, num beam) => TxData(
      recipients: [
        TxRecipient(
          address: address,
          amount: Amount(rawValue: _g(beam), fractionDigits: 8),
          isChange: false,
          addressType: AddressType.mimbleWimble,
        ),
      ],
    );

    Matcher problem(BeamWalletProblem p) => throwsA(
      isA<BeamWalletException>().having((e) => e.problem, 'problem', p),
    );

    test('prepareSend validates and prices, never broadcasts', () async {
      final w = await ready();
      final prepared = await w.prepareSend(txData: tx(_payee(), 0.01));
      expect(prepared.fee!.raw, BigInt.from(100000));
      expect(prepared.recipients!.single.amount.raw, _g(0.01));
      final t = host.lastTransport!;
      expect(t.callsTo('validate_address'), hasLength(1));
      expect(t.callsTo('calc_change'), hasLength(1));
      expect(t.callsTo('tx_send'), isEmpty);
      expect(w.isBusy, isTrue, reason: 'node switch held for the confirm');

      final done = await w.confirmSend(txData: prepared);
      expect(done.txid, 'fe' * 16);
      expect(core.sent.single, {
        'address': _payee(),
        'value': 1000000,
        'fee': 100000,
        'asset_id': 0,
        'txId': 'fe' * 16,
      });
      expect(w.isBusy, isFalse);
    });

    test('a shared note is sent as the comment; nothing else is', () async {
      final w = await ready();
      final prepared = await w.prepareSend(txData: tx(_payee(), 0.001));
      await w.confirmSend(
        txData: prepared.copyWith(note: 'local only', noteOnChain: 'hi'),
      );
      expect(core.sent.single['comment'], 'hi');
    });

    test('an offline address is paid without the receiver online, at the '
        'push fee', () async {
      final w = await ready();
      final prepared = await w.prepareSend(
        txData: tx(_vector('offline'), 0.001),
      );
      expect(prepared.fee!.raw, BigInt.from(1100000));
      await w.confirmSend(txData: prepared);
      expect(core.sent.single['offline'], isTrue);
      expect(core.sent.single['fee'], 1100000);
    });

    test('errors are plain: not an address, too much, not synced, not '
        'open', () async {
      final w = await ready();
      await expectLater(
        w.prepareSend(txData: tx('not an address', 0.001)),
        problem(BeamWalletProblem.invalidAddress),
      );
      await expectLater(
        w.prepareSend(txData: tx(_payee(), 0.0495)),
        problem(BeamWalletProblem.insufficientFunds),
      );
      expect(w.isBusy, isFalse, reason: 'failed prepare releases the hold');

      explorer.height = _height + 100;
      await waitFor(() => !w.canSpend, what: 'falls behind');
      await expectLater(
        w.prepareSend(txData: tx(_payee(), 0.001)),
        problem(BeamWalletProblem.notSynced),
      );
      expect(host.lastTransport!.callsTo('tx_send'), isEmpty);

      await w.exit();
      await expectLater(
        w.confirmSend(
          txData: tx(_payee(), 0.001).copyWith(
            fee: Amount(rawValue: BigInt.from(100000), fractionDigits: 8),
          ),
        ),
        problem(BeamWalletProblem.notOpen),
      );
    });

    test('a dropped connection during tx_send is looked up, never '
        'resent', () async {
      final w = await ready();
      core.dropOnSend = true;
      final prepared = await w.prepareSend(txData: tx(_payee(), 0.001));
      final done = await w.confirmSend(txData: prepared);
      expect(done.txid, 'fe' * 16);
      expect(core.sent, hasLength(1));

      core.knowsDroppedTx = false;
      final again = await w.prepareSend(txData: tx(_payee(), 0.001));
      await expectLater(
        w.confirmSend(txData: again),
        problem(BeamWalletProblem.sendOutcomeUnknown),
      );
      expect(core.sent, hasLength(2));
    });

    test('fees: estimate from the core, default when it cannot say', () async {
      final w = await newWallet();
      expect(
        (await w.estimateFeeFor(
          Amount(rawValue: _g(1), fractionDigits: 8),
          BigInt.one,
        )).raw,
        BigInt.from(100000),
      );
      expect((await w.fees).medium, BigInt.from(100000));
    });
  });

  group('node switch gate and the private node', () {
    // A core without patches/0006 can run a swap twice when wallet-api is
    // restarted under it (2026-10-07). Node switches wait; quitting asks.
    test('a swap being confirmed holds node switches until it settles, and '
        'is listed for the quit guard', () async {
      Map<String, Object?> swap(int status) => txJson(
        txId: 'd1' * 16,
        status: status,
        txType: 12,
        fee: 1100000,
        invokeData: [
          {
            'contract_id': kDexContractId,
            'amounts': [
              {'asset_id': 0, 'amount': 2000000},
              {'asset_id': 174, 'amount': -16000000},
            ],
          },
        ],
      );
      final base = core.txs;

      final w = await newWallet();
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));
      expect(w.isBusy, isFalse);
      expect(swaps.isEmpty, isTrue);

      core.txs = [...base, swap(1)];
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => swaps.count == 1, what: 'swap tracked');
      expect(w.swapsInFlight, {'d1' * 16});
      expect(w.isBusy, isTrue);
      expect(w.nodeSwitchGate.reasons, contains('swap being confirmed'));
      var idle = false;
      unawaited(w.nodeSwitchGate.whenIdle().then((_) => idle = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(idle, isFalse, reason: 'a node switch would wait');

      core.txs = [...base, swap(3)];
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => swaps.isEmpty, what: 'swap settled');
      await waitFor(() => idle, what: 'gate free');
      expect(w.isBusy, isFalse);

      // Closing the wallet stops its core: nothing left to interrupt.
      core.txs = [...base, swap(5)];
      host.lastTransport!.emit('ev_txs_changed', {'change': 0});
      await waitFor(() => swaps.count == 1, what: 'tracked again');
      await w.exit();
      expect(swaps.isEmpty, isTrue);
    });

    test('gate: waits for release, expiry frees it, dispose frees '
        'everything', () async {
      final gate = BeamNodeSwitchGate();
      expect(gate.isBusy, isFalse);
      final lease = gate.hold('send');
      var idle = false;
      unawaited(gate.whenIdle().then((_) => idle = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(idle, isFalse);
      lease.release();
      await Future<void>.delayed(Duration.zero);
      expect(idle, isTrue);

      gate.hold('stale', maxHold: const Duration(milliseconds: 80));
      final t0 = DateTime.now();
      await gate.whenIdle();
      expect(DateTime.now().difference(t0).inMilliseconds, greaterThan(60));

      gate.hold('forever');
      var freed = false;
      unawaited(gate.whenIdle().then((_) => freed = true));
      gate.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(freed, isTrue);
      expect(gate.hold('after').isActive, isFalse);
    });

    // Seen in the DMG test: a restore scan over a public node was 7% after
    // 8 minutes (about 4.5 hours in all), and the private node, which would
    // finish it in about 1.5 hours, waited for the scan to end.
    test('a restored wallet still reading the chain starts its private node '
        'without waiting to be able to send', () async {
      final nodes = <_Node>[];
      installEnv(
        node: (_, _) {
          final n = _Node();
          nodes.add(n);
          return n;
        },
        privateNode: true,
      );
      core.status = statusJson(height: 0);
      final w = await newWallet(init: false);
      await w.init(isRestore: true);
      await w.recover(isRescan: false);
      expect(w.isScanningForCoins, isTrue);
      await w.open();
      await w.whenLive.timeout(const Duration(seconds: 5));

      await waitFor(
        () => w.syncAssessment is BeamSyncCatchingUp,
        what: 'catching up, not "connecting"',
      );
      expect(w.canSpend, isFalse);
      await waitFor(() => nodes.isNotEmpty, what: 'node created');
    });

    test('the coordinator gets the stored owner key, never pauses to '
        'export it, and its handover waits for a send to finish', () async {
      final nodes = <_Node>[];
      installEnv(
        node: (_, _) {
          final n = _Node();
          nodes.add(n);
          return n;
        },
        privateNode: true,
      );
      final w = await newWallet();
      final storedKey = await secure.read(key: ownerOf(w));
      host.calls.clear();
      await w.open();
      await w.whenCanSend.timeout(const Duration(seconds: 5));

      // Bring-up: the node starts with the stored key; no real export ran.
      await waitFor(() => nodes.isNotEmpty, what: 'node created');
      await waitFor(() => nodes.single.keyReceived != null, what: 'key');
      expect(nodes.single.keyReceived, storedKey);
      expect(host.calls.where((c) => c == 'exportOwnerKey'), isEmpty);
      await waitFor(() => w.isOpen, what: 'reopened after bring-up');

      // A send is being confirmed when the node becomes ready.
      final prepared = await w.prepareSend(
        txData: TxData(
          recipients: [
            TxRecipient(
              address: _payee(),
              amount: Amount(rawValue: _g(0.001), fractionDigits: 8),
              isChange: false,
              addressType: AddressType.mimbleWimble,
            ),
          ],
        ),
      );
      final publicTransport = host.lastTransport!;
      nodes.single.emit(
        nodes.single.progress.copyWith(
          phase: BeamNodePhase.txReplicationOn,
          myTipHeight: _height,
          myTipAt: DateTime.now(),
          ownerAccounts: 1,
        ),
      );
      // The node is ready: the handover starts, then waits for the send.
      await waitFor(
        () => w.privateNodeStatus?.phase == BeamPrivateNodePhase.switching,
        what: 'handover started',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(host.switches, isEmpty, reason: 'deferred while sending');
      expect(publicTransport.isConnected, isTrue);

      // The send completes on the public node, then the switch happens.
      await w.confirmSend(txData: prepared);
      expect(publicTransport.callsTo('tx_send'), hasLength(1));
      await waitFor(() => host.switches.isNotEmpty, what: 'switch');
      expect(host.switches.single.isOwned, isTrue);
      expect(host.switches.single.port, 40123);

      // The core confirms it holds the owner key.
      await waitFor(
        () => host.sessions.last.node.isOwned,
        what: 'owned session',
      );
      final owned = host.sessions.last.transport;
      await waitFor(() {
        owned.emit('ev_connection_changed', {
          'node_connected': true,
          'own_node': true,
        });
        return w.privateNodeStatus?.phase == BeamPrivateNodePhase.active;
      }, what: 'active');
      await waitFor(
        () => w.currentNode?.isOwned ?? false,
        what: 'wallet follows the new session',
      );
    });
  });
}

class _MissingCoreHost implements BeamHost {
  BeamHostException get _missing => const BeamHostException(
    BeamHostError.binaryMissing,
    'beam-wallet not found in /nowhere/bin',
  );

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) async => throw _missing;

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async => throw _missing;

  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async => throw _missing;

  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) async => throw _missing;
}
