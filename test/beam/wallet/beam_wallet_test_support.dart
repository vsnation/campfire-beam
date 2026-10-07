/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Fakes for BeamWallet tests: Campfire services, a BEAM host whose sessions
// run on FakeTransport, an explorer, and a real Isar in a temp directory.
// No real key, password or address: every value below is made up.

import 'dart:async';
import 'dart:io';

import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/block_explorer.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/models/isar/models/contact_entry.dart';
import 'package:stackwallet/models/isar/models/isar_models.dart';
import 'package:stackwallet/models/isar/ordinal.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/models/node_model.dart';
import 'package:stackwallet/services/node_service.dart';
import 'package:stackwallet/utilities/enums/sync_type_enum.dart';
import 'package:stackwallet/utilities/prefs.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/frost_wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/spark_coin.dart';
import 'package:stackwallet/wallets/isar/models/token_wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info_meta.dart';

/// Opens Campfire's full Isar schema in [dir] and installs it as
/// `MainDB.instance`. Downloads the Isar core once (as
/// `db_version_migration_test.dart` does).
Future<Isar> openTestMainDb(Directory dir) async {
  await Isar.initializeIsarCore(download: true);
  final isar = await Isar.open(
    [
      TransactionSchema,
      TransactionNoteSchema,
      UTXOSchema,
      AddressSchema,
      AddressLabelSchema,
      EthContractSchema,
      SolContractSchema,
      TransactionBlockExplorerSchema,
      StackThemeSchema,
      ContactEntrySchema,
      OrdinalSchema,
      WalletInfoSchema,
      TransactionV2Schema,
      SparkCoinSchema,
      WalletInfoMetaSchema,
      TokenWalletInfoSchema,
      FrostWalletInfoSchema,
      WalletSolanaTokenInfoSchema,
      BeamAssetContractSchema,
    ],
    directory: dir.path,
    inspector: false,
    name: 'beam_wallet_test_${dir.path.hashCode.abs()}',
  );
  await MainDB.instance.initMainDB(mock: isar);
  return isar;
}

/// Prefs without Hive: only what wallets read.
class FakePrefs implements Prefs {
  @override
  SyncingType get syncType => SyncingType.allWalletsOnStartup;

  @override
  List<String> get walletIdsSyncOnStartup => const [];

  @override
  bool get useTor => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A NodeService that only knows one primary node.
class FakeNodeService implements NodeService {
  FakeNodeService(this.node);

  NodeModel? node;

  @override
  NodeModel? getPrimaryNodeFor({required CryptoCurrency currency}) => node;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NodeModel beamTestNode(String host, int port) => NodeModel(
  host: host,
  port: port,
  name: 'test node',
  id: 'beam_test_node_$host',
  useSSL: false,
  enabled: true,
  coinName: 'beam',
  isFailover: true,
  isDown: false,
  torEnabled: false,
  clearnetEnabled: true,
  isPrimary: true,
);

/// A fresh, fully known explorer tip.
class FakeExplorer implements BeamNetworkTipSource {
  FakeExplorer(this.height);

  int height;
  int calls = 0;
  bool fail = false;

  @override
  Future<BeamExplorerStatus> status({bool forceRefresh = false}) async {
    calls++;
    if (fail) throw BeamExplorerException('down');
    final now = DateTime.now().toUtc();
    return BeamExplorerStatus(
      height: height,
      timestamp: now.subtract(const Duration(seconds: 30)),
      hash: '',
      node: 'fake',
      receivedAt: now,
      serverTime: now,
    );
  }
}

class FakeBeamSession implements BeamSession {
  FakeBeamSession(this.host, this.node, this.transport, this.walletDir);

  final FakeBeamHost host;
  final String walletDir;

  @override
  final FakeTransport transport;

  @override
  final BeamNodeEndpoint node;

  bool closed = false;

  @override
  Future<BeamSession> switchNode(BeamNodeEndpoint node) async {
    host.switches.add(node);
    await close();
    return host.openWallet(
      walletDir: walletDir,
      password: host.passwords[walletDir]!,
      node: node,
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    host.open.remove(walletDir);
    await transport.close();
  }
}

/// A host that keeps "wallet.db" as a marker file and serves sessions on
/// [FakeTransport]s built by [replies].
class FakeBeamHost implements BeamHost, BeamWalletFileImporter {
  FakeBeamHost({required this.replies, this.openDelay = Duration.zero});

  /// Replies for each new session's transport.
  Map<String, Object?> Function() replies;
  Duration openDelay;

  /// Thrown by the next [openWallet], once.
  Object? openError;

  /// Whether a public session's core has reached its node: like a real
  /// wallet-api, it then answers an `ev_subunsub` that includes
  /// `ev_connection_changed` with a `node_connected: true` snapshot
  /// (`v6_1_api_handle.cpp:129`). Without that the wallet is never
  /// "synced". Owned (private node) sessions report nothing by themselves;
  /// tests emit `own_node` for them.
  bool reachNode = true;

  final Map<String, String> passwords = {};
  final Map<String, FakeBeamSession> open = {};
  final List<FakeBeamSession> sessions = [];
  final List<BeamNodeEndpoint> switches = [];
  final List<String> calls = [];
  final List<bool> requestBodies = [];
  int ownerKeyCounter = 0;

  FakeTransport? get lastTransport =>
      sessions.isEmpty ? null : sessions.last.transport;

  @override
  Future<void> initWallet({
    required String walletDir,
    required String password,
    required List<String> words,
  }) async {
    calls.add('initWallet');
    if (words.length != 12) throw StateError('12 words expected');
    await Directory(walletDir).create(recursive: true);
    final db = File(p.join(walletDir, 'wallet.db'));
    if (await db.exists()) throw StateError('wallet.db exists');
    await db.writeAsString('fake');
    passwords[walletDir] = password;
  }

  /// What opens each importable file: source path -> its password.
  final Map<String, String> importable = {};

  @override
  Future<void> importWalletFile({
    required String walletDir,
    required String sourcePath,
    required String password,
  }) async {
    calls.add('importWalletFile');
    final db = File(p.join(walletDir, 'wallet.db'));
    if (await db.exists()) {
      throw const BeamHostException(BeamHostError.walletExists, 'exists');
    }
    if (importable[sourcePath] != password) {
      throw const BeamHostException(
        BeamHostError.wrongPassword,
        'The password does not open this wallet file',
      );
    }
    await Directory(walletDir).create(recursive: true);
    await File(sourcePath).copy(db.path);
    passwords[walletDir] = password;
  }

  @override
  Future<BeamSession> openWallet({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
    bool requestBodies = false,
  }) async {
    calls.add('openWallet');
    this.requestBodies.add(requestBodies);
    if (openDelay > Duration.zero) await Future<void>.delayed(openDelay);
    final error = openError;
    if (error != null) {
      openError = null;
      throw error;
    }
    if (passwords[walletDir] != password) {
      throw StateError('wrong password');
    }
    if (open.containsKey(walletDir)) throw StateError('wallet in use');
    final r = replies();
    final transport = FakeTransport(r);
    if (r['ev_subunsub'] == true && !node.isOwned) {
      transport.reply('ev_subunsub', (Map<String, Object?> params) {
        if (reachNode && params['ev_connection_changed'] == true) {
          scheduleMicrotask(() {
            if (!transport.isConnected) return;
            transport.emit('ev_connection_changed', {
              'node_connected': true,
              'own_node': false,
            });
          });
        }
        return true;
      });
    }
    final s = FakeBeamSession(this, node, transport, walletDir);
    open[walletDir] = s;
    sessions.add(s);
    return s;
  }

  @override
  Future<String> exportOwnerKey({
    required String walletDir,
    required String password,
  }) async {
    calls.add('exportOwnerKey');
    if (open.containsKey(walletDir)) throw StateError('wallet is open');
    if (passwords[walletDir] != password) throw StateError('wrong password');
    return 'fake-owner-key-${++ownerKeyCounter}';
  }

  @override
  Future<void> rescan({
    required String walletDir,
    required String password,
    required BeamNodeEndpoint node,
  }) async {
    calls.add('rescan');
  }
}

/// A `wallet_status` result: synced at [height] unless said otherwise.
Map<String, Object?> statusJson({
  required int height,
  BigInt? available,
  BigInt? receiving,
  BigInt? sending,
  BigInt? maturing,
  BigInt? change,
  bool inSync = true,
  DateTime? tipTime,
  List<Map<String, Object?>> extraTotals = const [],
}) {
  final ts =
      (tipTime ?? DateTime.now().subtract(const Duration(seconds: 20)))
          .millisecondsSinceEpoch ~/
      1000;
  return {
    'current_height': height,
    'current_state_hash': 'aa' * 32,
    'current_state_timestamp': ts,
    'prev_state_hash': 'bb' * 32,
    'is_in_sync': inSync,
    'available': (available ?? BigInt.zero).toInt(),
    'receiving': (receiving ?? BigInt.zero).toInt(),
    'sending': (sending ?? BigInt.zero).toInt(),
    'maturing': (maturing ?? BigInt.zero).toInt(),
    'difficulty': 1.0,
    'totals': [
      totalsJson(
        0,
        available: available,
        receiving: receiving,
        sending: sending,
        maturing: maturing,
        change: change,
      ),
      ...extraTotals,
    ],
  };
}

Map<String, Object?> totalsJson(
  int assetId, {
  BigInt? available,
  BigInt? receiving,
  BigInt? sending,
  BigInt? maturing,
  BigInt? change,
}) {
  final z = BigInt.zero;
  String s(BigInt? v) => '${v ?? z}';
  final mat = maturing ?? z;
  final chg = change ?? z;
  return {
    'asset_id': assetId,
    'available_str': s(available),
    'available_regular_str': s(available),
    'available_mp_str': '0',
    'receiving_str': s(receiving),
    'receiving_regular_str': s(receiving),
    'receiving_mp_str': '0',
    'sending_str': s(sending),
    'sending_regular_str': s(sending),
    'sending_mp_str': '0',
    'maturing_str': s(maturing),
    'maturing_regular_str': s(maturing),
    'maturing_mp_str': '0',
    'change_str': s(change),
    // The core's "locked" is maturing + change, not a separate pot.
    'locked_str': '${mat + chg}',
  };
}

/// One own address entry for `addr_list`.
Map<String, Object?> ownAddressJson(
  String address, {
  int createTime = 1790000000,
  bool expired = false,
  String type = 'regular',
}) => {
  'address': address,
  'category': '',
  'comment': 'default',
  'create_time': createTime,
  'duration': 0,
  'expired': expired,
  'identity': 'cc' * 32,
  'own': true,
  'own_id': 1,
  'own_id_str': '1',
  'type': type,
  'wallet_id': address,
};

/// One `tx_list` entry. Amounts in groth.
Map<String, Object?> txJson({
  required String txId,
  required int status,
  int txType = 0,
  bool income = false,
  int value = 1000000,
  int fee = 100000,
  int assetId = 0,
  String sender = '',
  String receiver = '',
  int? height,
  int? confirmations,
  String? kernel,
  String comment = '',
  String? failureReason,
  int createTime = 1790000100,
  List<Map<String, Object?>>? invokeData,
}) => {
  'txId': txId,
  'status': status,
  'status_string': 'x',
  'tx_type': txType,
  'tx_type_string': 'simple',
  'income': income,
  if (invokeData == null) 'value': value,
  if (invokeData == null) 'asset_id': assetId,
  'fee': fee,
  'sender': sender,
  'receiver': receiver,
  'comment': comment,
  'create_time': createTime,
  'height': ?height,
  'confirmations': ?confirmations,
  'kernel': ?kernel,
  'failure_reason': ?failureReason,
  'invoke_data': ?invokeData,
};

/// Waits for [condition], polling; fails after [timeout].
Future<void> waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  String what = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
