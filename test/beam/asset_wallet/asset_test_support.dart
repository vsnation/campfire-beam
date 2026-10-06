/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared set-up for the Confidential Asset tests: a real BeamWallet on a
// fake host whose sessions run on FakeTransport, answering from the
// sanitized fixtures (test/beam/fixtures) plus a few made-up assets, a real
// Isar with Campfire's schema and BeamAssetContract, and the recorded DEX
// pools. No real key, password, seed or user address: every value that
// is not a public fixture is made up.

import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/models/isar/models/block_explorer.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/models/isar/models/contact_entry.dart';
import 'package:stackwallet/models/isar/models/isar_models.dart';
import 'package:stackwallet/models/isar/ordinal.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/contracts/common/shader_output.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_pool.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/frost_wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/spark_coin.dart';
import 'package:stackwallet/wallets/isar/models/token_wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info_meta.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../contracts/dex/dex_fixtures.dart';
import '../core/fixtures.dart';
import '../wallet/beam_wallet_test_support.dart';

export '../wallet/beam_wallet_test_support.dart';

const int testHeight = 4100000;

/// A made-up own address (not a real wallet's).
const String testOwnAddress =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

/// A made-up unverified asset nobody vouches for.
const int pepeId = 777;

/// A made-up asset that copies FOMO's name and ticker.
const int fakeFomoId = 999;

BigInt g(num units) => BigInt.from((units * 100000000).round());

/// A regular BEAM address from the BEAM core's own public test vectors.
String vectorAddress(String type) =>
    ((jsonDecode(
                  File('test/beam/fixtures/beam_core_address_vectors.json')
                      .readAsStringSync(),
                ) as Map)['valid']
                as List)
            .cast<Map<String, Object?>>()
            .firstWhere((v) => v['type'] == type)['address']!
        as String;

/// Campfire's Isar schema plus [BeamAssetContractSchema], installed as
/// `MainDB.instance`.
Future<Isar> openAssetTestDb(Directory dir) async {
  // Widget tests mock HTTP; the Isar core is fetched once with the real
  // client (as db_version_migration_test.dart does in a plain test).
  final mocked = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    await Isar.initializeIsarCore(download: true);
  } finally {
    HttpOverrides.global = mocked;
  }
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
    name: 'beam_asset_test_${dir.path.hashCode.abs()}',
  );
  await MainDB.instance.initMainDB(mock: isar);
  return isar;
}

/// The recorded mainnet DEX pools (`pools_view`, height 4068104).
List<BeamPool> recordedPools({bool includeEmpty = true}) => [
  for (final row in ShaderOutput.list(
    ShaderOutput.decode(dexOutput('pools_view'))['res'],
    'res',
  ))
    BeamPool.fromJson(ShaderOutput.map(row, 'res[]')),
].where((p) => includeEmpty || !p.isEmpty).toList();

/// The fixture wallet's per-asset balances (`wallet_status.json`): BEAM, RFC,
/// BeamX, four LP tokens, FOMO, GIGA and CHAD.
Map<int, BigInt> fixtureAvailable() => {
  for (final t in fixtureMap('wallet_status')['totals']! as List)
    ((t as Map)['asset_id']! as int): BigInt.from(t['available']! as int),
};

/// The core the fake transports present. Mutable between steps.
class AssetCore {
  AssetCore() {
    final fixture = fixtureAvailable();
    beamAvailable = fixture[0]!;
    assets = {
      for (final e in fixture.entries)
        if (e.key != 0) e.key: e.value,
      pepeId: g(1500),
      fakeFomoId: g(10000),
    };
  }

  late BigInt beamAvailable;
  BigInt beamReceiving = BigInt.zero;
  bool inSync = true;
  late Map<int, BigInt> assets;
  Map<int, BigInt> receiving = {};

  /// Every `tx_send` the core was handed, including ones made to fail.
  final sent = <Map<String, Object?>>[];
  final calcChangeCalls = <Map<String, Object?>>[];
  String nextTxId = 'fe' * 16;

  /// Thrown by `tx_send` after it is recorded in [sent] (null: it works),
  /// e.g. a dropped connection after the core took the payment.
  Object? txSendThrows;

  /// Thrown by `tx_status` (null: it answers that the tx exists).
  Object? txStatusThrows;

  /// The fee calc_change answers with (groth).
  int explicitFee = 100000;

  List<Map<String, Object?>> txs = [
    // FOMO: 50 in (done), 12.5 out (waiting for the receiver).
    txJson(
      txId: 'a1' * 16,
      status: 3,
      income: true,
      value: 5000000000,
      assetId: 174,
      sender: '22' * 33,
      receiver: testOwnAddress,
      height: testHeight - 300,
      kernel: 'ab' * 32,
      createTime: 1790000100,
    ),
    txJson(
      txId: 'a2' * 16,
      status: 1,
      value: 1250000000,
      assetId: 174,
      sender: testOwnAddress,
      receiver: '33' * 33,
      createTime: 1790000900,
    ),
    // BeamX: 2 in.
    txJson(
      txId: 'b1' * 16,
      status: 3,
      income: true,
      value: 200000000,
      assetId: 7,
      sender: '44' * 33,
      receiver: testOwnAddress,
      height: testHeight - 200,
      kernel: 'cd' * 32,
      createTime: 1790000500,
    ),
    // BEAM: 0.05 in.
    txJson(
      txId: 'c1' * 16,
      status: 3,
      income: true,
      value: 5000000,
      sender: '55' * 33,
      receiver: testOwnAddress,
      height: testHeight - 100,
      kernel: 'ef' * 32,
      createTime: 1790000700,
    ),
  ];

  /// The fixture's asset metadata plus the made-up assets.
  List<Map<String, Object?>> assetsList() => [
    ...(fixtureMap('assets_list')['assets']! as List)
        .cast<Map<Object?, Object?>>()
        .map((a) => a.cast<String, Object?>()),
    _asset(pepeId, 'STD:SCH_VER=1;N=Pepe Coin;SN=Pepe;UN=PEPE;NTHUN=groth'),
    _asset(fakeFomoId, 'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO;NTHUN=fomo'),
  ];

  static Map<String, Object?> _asset(int id, String metadata) => {
    'asset_id': id,
    'emission': 2100000000000000,
    'emission_str': '2100000000000000',
    'isOwned': 0,
    'lockHeight': 3000000,
    'metadata': metadata,
    'ownerId': 'dd' * 32,
    'refreshHeight': testHeight,
  };

  Map<String, Object?> status() => statusJson(
    height: testHeight,
    available: beamAvailable,
    receiving: beamReceiving,
    inSync: inSync,
    extraTotals: [
      for (final e in assets.entries)
        totalsJson(e.key, available: e.value, receiving: receiving[e.key]),
    ],
  );

  Map<String, Object?> replies() => {
    'ev_subunsub': true,
    'wallet_status': (Map<String, Object?> _) => status(),
    'addr_list': (Map<String, Object?> _) => [ownAddressJson(testOwnAddress)],
    'tx_list': (Map<String, Object?> _) => txs,
    'assets_list': (Map<String, Object?> _) => {'assets': assetsList()},
    'get_asset_info': (Map<String, Object?> params) =>
        assetsList().firstWhere((a) => a['asset_id'] == params['asset_id']),
    'validate_address': (Map<String, Object?> params) {
      final a = params['address']! as String;
      final type = a == vectorAddress('offline')
          ? 'offline'
          : a == vectorAddress('max_privacy')
          ? 'max_privacy'
          : 'regular';
      return {'is_valid': true, 'is_mine': false, 'type': type};
    },
    'calc_change': (Map<String, Object?> params) {
      calcChangeCalls.add(params);
      return {
        'change': 0,
        'change_str': '0',
        'asset_change': 0,
        'asset_change_str': '0',
        'explicit_fee': explicitFee,
        'explicit_fee_str': '$explicitFee',
      };
    },
    'generate_tx_id': (Map<String, Object?> _) => nextTxId,
    'tx_send': (Map<String, Object?> params) {
      sent.add(params);
      final fail = txSendThrows;
      if (fail != null) throw fail;
      return {'txId': params['txId']};
    },
    'tx_status': (Map<String, Object?> params) {
      final fail = txStatusThrows;
      if (fail != null) throw fail;
      return txJson(txId: params['txId']! as String, status: 0);
    },
  };
}

/// A BEAM wallet on [AssetCore], opened and live (balance, per-asset totals
/// and history from the core are in Isar).
class AssetHarness {
  AssetHarness(this.root);

  final String root;
  final core = AssetCore();
  late final FakeBeamHost host = FakeBeamHost(replies: core.replies);
  final explorer = FakeExplorer(testHeight);
  final secure = FakeSecureStorage();
  final log = <String>[];

  void installEnvironment() {
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => host,
      createExplorer: () => explorer,
      privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
      // Long polls: nothing fires while a widget test pumps frames.
      explorerPollInterval: const Duration(hours: 1),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: const Duration(hours: 1),
      log: log.add,
    );
  }

  Future<BeamWallet> openWallet({String name = 'Campfire BEAM'}) async {
    installEnvironment();
    final info = WalletInfo.createNew(
      coin: Beam(CryptoCurrencyNetwork.main),
      name: name,
    );
    final wallet = await Wallet.create(
      walletInfo: info,
      mainDB: MainDB.instance,
      secureStorageInterface: secure,
      nodeService: FakeNodeService(
        beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
      ),
      prefs: FakePrefs(),
      mnemonic: bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as BeamWallet;
    await wallet.init();
    await wallet.open();
    await wallet.whenLive.timeout(const Duration(seconds: 10));
    await wallet.whenCanSend.timeout(const Duration(seconds: 10));
    return wallet;
  }
}

Future<Directory> tempRoot(String name) async {
  final dir = await Directory.systemTemp.createTemp(name);
  await Directory(p.join(dir.path, 'isar')).create(recursive: true);
  return dir;
}
