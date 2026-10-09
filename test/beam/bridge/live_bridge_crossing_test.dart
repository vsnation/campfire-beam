/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds: one bridge crossing on mainnet, through the app's own
// controller (quote → prepare → start → follow → claim), with two test
// wallets and a tiny amount:
//
// * BEAM side: LWTEST, opened IN PLACE on the in-process core (as
//   beam_split_live_test.dart does; never copied, never open elsewhere).
// * Ethereum side: a test Ethereum wallet, its key
//   given at run time in ETH_PK by a wrapper that derives it from the seed
//   (never printed). Every Ethereum request goes through Tor.
//
//   BEAM_BRIDGE_CROSS=1 BEAM_CORE_LIB=<libbeam_core.dylib> ETH_PK=<hex> \
//   BRIDGE_ROUTE=beam BRIDGE_DIRECTION=toBeam BRIDGE_AMOUNT=100 \
//   [BRIDGE_RESUME=1] [CFB_TOR_SOCKS=127.0.0.1:19050] \
//   [CFB_ETH_LIVE_RPC=https://eth2.stackwallet.com] \
//       scripts/beam/host_test.sh --no-analyze \
//       test/beam/bridge/live_bridge_crossing_test.dart
//
// Crossings are kept in ~/beam-campfire-test/run/bridge_live_crossings.json,
// so BRIDGE_RESUME=1 picks up any that a previous run left on the way (the
// app does the same on open). Evidence lines carry amounts, states, tx ids,
// hashes and message ids only.
@Timeout(Duration(minutes: 150))
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_secret_store.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/wallets/bridge/bridge_controller.dart';
import 'package:stackwallet/wallets/bridge/bridge_crossing.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_store.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/ethereum/bridge/bridge_price_feed.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_service.dart';
import 'package:stackwallet/wallets/ethereum/eth_http_client.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/eth_rpc.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:wallet/wallet.dart' as eth_wallet;
import 'package:web3dart/web3dart.dart' as web3;

import '../wallet/beam_wallet_test_support.dart';

void _evidence(String line) {
  // ignore: avoid_print
  print(
    '[evidence] ${DateTime.now().toIso8601String().substring(11, 19)} $line',
  );
}

String _units(BigInt v, int decimals) {
  final unit = BigInt.from(10).pow(decimals);
  final frac = (v.abs() % unit).toString().padLeft(decimals, '0');
  return '${v < BigInt.zero ? '-' : ''}${v.abs() ~/ unit}.$frac';
}

BigInt _parse(String text, int decimals) {
  final parts = text.split('.');
  final frac = (parts.length > 1 ? parts[1] : '')
      .padRight(decimals, '0')
      .substring(0, decimals);
  return BigInt.parse(parts[0]) * BigInt.from(10).pow(decimals) +
      (frac.isEmpty ? BigInt.zero : BigInt.parse(frac));
}

String _rand(int n) {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

Map<String, String> _testWallets(String home) {
  final f = File(p.join(home, '.config/campfire-beam/test_wallets.env'));
  if (!f.existsSync()) return const {};
  final out = <String, String>{};
  for (final line in f.readAsLinesSync()) {
    if (line.startsWith('#')) continue;
    final i = line.indexOf('=');
    if (i <= 0) continue;
    out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  return out;
}

/// Signs with the test wallet's key and broadcasts through [client]
/// (Tor). The bridge never asks for a permit signature.
class _KeySigner implements UniSwapSigner {
  _KeySigner(this._key, this._url, this._client);

  final web3.EthPrivateKey _key;
  final String _url;
  final http.Client Function() _client;

  @override
  String get address => _key.address.with0x.toLowerCase();

  @override
  Future<Uint8List> signDigest(Uint8List digest) =>
      throw StateError('the bridge signs no permit');

  @override
  Future<String> send(UniTxRequest tx) async {
    final c = web3.Web3Client(_url, _client());
    try {
      return await c.sendTransaction(
        _key,
        web3.Transaction(
          to: eth_wallet.EthereumAddress.fromHex(tx.to),
          data: tx.data,
          value: eth_wallet.EtherAmount.inWei(tx.value),
          maxGas: tx.gasLimit.toInt(),
          maxFeePerGas: eth_wallet.EtherAmount.inWei(tx.fees.maxFeePerGas),
          maxPriorityFeePerGas: eth_wallet.EtherAmount.inWei(
            tx.fees.maxPriorityFeePerGas,
          ),
        ),
        chainId: 1,
      );
    } finally {
      await c.dispose();
    }
  }
}

void main() {
  // The BEAM side reads its pinned shaders from the app's assets.
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HTTP request with 400; this test talks
  // to Ethereum (through Tor) for real.
  HttpOverrides.global = null;
  final env = Platform.environment;
  final home = env['HOME'] ?? '';
  final lib = env[kBeamCoreLibraryEnv];
  final pk = env['ETH_PK'];
  final secrets = _testWallets(home);
  final dbPath = secrets['LWTEST_WALLET_DB'];
  final password = secrets['LWTEST_WALLET_PASS'];
  final runDir = p.join(home, 'beam-campfire-test/run');
  final resume = env['BRIDGE_RESUME'] == '1';

  final String? skip;
  if (env['BEAM_BRIDGE_CROSS'] != '1') {
    skip = 'live: set BEAM_BRIDGE_CROSS=1';
  } else if (lib == null || lib.isEmpty) {
    skip = 'live: set $kBeamCoreLibraryEnv';
  } else if (pk == null || pk.isEmpty) {
    skip = 'live: set ETH_PK (from the wrapper)';
  } else if (dbPath == null || password == null) {
    skip = 'live: no LWTEST wallet in test_wallets.env';
  } else if (File(p.join(runDir, 'lwtest.json')).existsSync()) {
    skip = 'live: LWTEST is open in wapi.py; stop it first';
  } else {
    skip = null;
  }

  test('one bridge crossing on mainnet, through the app controller', () async {
    final socks = (env['CFB_TOR_SOCKS'] ?? '127.0.0.1:19050').split(':');
    final tor = (host: InternetAddress(socks[0]), port: int.parse(socks[1]));
    EthRpcHttpClient viaTor() => EthRpcHttpClient(route: (_) => tor);
    final url = env['CFB_ETH_LIVE_RPC'] ?? 'https://eth2.stackwallet.com';

    final root = p.join(home, 'beam-campfire-test', 'bridge-it-${_rand(8)}');
    await ensurePrivateDir(root);
    final beamRoot = p.join(root, 'beam');
    await ensurePrivateDir(beamRoot);
    final isarDir = Directory(p.join(root, 'isar'))..createSync();
    final isar = await openTestMainDb(isarDir);

    final log = <String>[];
    InProcessHost? host;
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => beamRoot,
      createHost: (r) => host ??= InProcessHost(
        rootDir: r,
        router: const BeamNodeRouter.direct(),
        locateLibrary: () async =>
            (await locateBeamCoreLibrary(beamRoot: r)).path,
        log: log.add,
      ),
      createExplorer: () => BeamExplorerClient(proxyInfo: () => null),
      explorerPollInterval: const Duration(seconds: 10),
      statusPollInterval: const Duration(seconds: 10),
      log: log.add,
    );

    final secure = FakeSecureStorage();
    final wallet = await Wallet.create(
      walletInfo: WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: 'bridge-it',
      ),
      mainDB: MainDB.instance,
      secureStorageInterface: secure,
      nodeService: FakeNodeService(
        beamTestNode('eu-node01.mainnet.beam.mw', 8100),
      ),
      prefs: FakePrefs(),
      mnemonic: bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as BeamWallet;
    final walletsDir = Directory(p.join(beamRoot, 'wallets'))
      ..createSync(recursive: true);
    final link = Link(p.join(walletsDir.path, wallet.walletId));
    await link.create(p.dirname(dbPath!));
    await BeamSecretStore(secure, wallet.walletId).writePassword(password!);
    _evidence('LWTEST opened in place (linked, not copied)');

    final key = web3.EthPrivateKey.fromHex(pk!);
    final eth = EthPipeService(
      rpc: EthRpc(
        url: url,
        clientFactory: viaTor,
        timeout: const Duration(seconds: 90),
      ),
      signer: _KeySigner(key, url, viaTor),
      priceFeed: BridgePriceFeed(
        clientFactory: viaTor,
        timeout: const Duration(seconds: 60),
      ),
    );
    _evidence('Ethereum side: the ETH test wallet, every request via Tor');

    try {
      await wallet.init();
      await wallet.open();
      await wallet.whenCanSend.timeout(const Duration(minutes: 5));
      _evidence('BEAM synced at ${wallet.syncAssessment.walletHeight}');

      final beam = BeamWalletServices.of(wallet).bridge;
      Directory(runDir).createSync(recursive: true);
      final store = FileBridgeStore(
        () async => File(p.join(runDir, 'bridge_live_crossings.json')),
      );
      final controller = BridgeController(
        beam: beam,
        eth: eth,
        store: store,
        beamWalletId: 'lwtest',
        ethWalletId: 'ethtest',
        autoPoll: false,
      );
      await controller.resumeAll();

      BridgeCrossing crossing;
      final route = bridgeRouteById(env['BRIDGE_ROUTE'] ?? 'beam');
      final direction = BridgeDirection.values.byName(
        env['BRIDGE_DIRECTION'] ?? 'toBeam',
      );
      final srcDecimals = direction == BridgeDirection.toEthereum
          ? 8
          : route.ethDecimals;
      final beamBefore = await beam.available(route.beamAssetId);
      final beamFeeBefore = await beam.available(0);
      final ethBefore = await eth.balance(route);
      _evidence(
        'before: BEAM wallet ${_units(beamBefore, 8)} ${route.beamSymbol}'
        '${route.isBeam ? '' : ', ${_units(beamFeeBefore, 8)} BEAM'}; '
        'Ethereum wallet ${_units(ethBefore, route.ethDecimals)} '
        '${route.ethSymbol}',
      );

      final open = [
        for (final c in controller.crossings)
          if (c.isOpen) c,
      ];
      if (resume && open.isNotEmpty) {
        crossing = open.first;
        _evidence('resuming ${crossing.id}: ${crossing.state.name}');
      } else {
        final amount = _parse(env['BRIDGE_AMOUNT'] ?? '100', srcDecimals);
        final q = await controller.quote(route, direction, amount);
        final dstDecimals = direction == BridgeDirection.toEthereum
            ? route.ethDecimals
            : 8;
        final fee = q.fee == null ? '?' : _units(q.fee!, srcDecimals);
        final now = q.feeNow == null
            ? ''
            : ' (its price now ${_units(q.feeNow!, 8)})';
        final gas = q.plan == null
            ? ''
            : ', Ethereum gas up to ${_units(q.plan!.maxGasCost, 18)} ETH';
        _evidence(
          'quote: ${_units(q.amount, srcDecimals)} → receives '
          '${_units(q.receives, dstDecimals)}, bridge fee $fee$now, '
          'BEAM network fee ${_units(q.beamNetworkFee, 8)}$gas',
        );
        if (q.block != null) {
          _evidence('blocked: ${q.block!.title}. ${q.block!.detail ?? ''}');
          // Which half said no, and why (the screen keeps it short).
          try {
            final k = await beam.receiveKey(route);
            _evidence('receive key: ${k.length} bytes');
            if (direction == BridgeDirection.toBeam) {
              await eth.planLock(
                route,
                value: q.amount,
                fee: q.fee ?? BigInt.zero,
                receiverKey: k,
              );
              _evidence('planLock: fine on its own');
            }
          } catch (e) {
            _evidence('cause: $e');
          }
        }
        expect(q.block, isNull, reason: q.block?.title);
        final prepared = await controller.prepare(q);
        crossing = await controller.start(prepared, autoClaim: true);
        _evidence('started ${crossing.id}: ${crossing.state.name}');
      }

      var last = '';
      final toEth = crossing.direction == BridgeDirection.toEthereum;
      final until = DateTime.now().add(
        toEth ? const Duration(minutes: 140) : const Duration(minutes: 60),
      );
      while (DateTime.now().isBefore(until)) {
        final c = await controller.poll(crossing.id) ?? crossing;
        crossing = c;
        final line =
            '${c.state.name}'
            '${c.beamTxId == null ? '' : ' beamTx ${c.beamTxId}'}'
            '${c.lockHash == null ? '' : ' lock ${c.lockHash}'}'
            '${c.msgId == null ? '' : ' msgId ${c.msgId}'}'
            '${c.height == null ? '' : ' height ${c.height}'}'
            '${c.claimTxId == null ? '' : ' claimTx ${c.claimTxId}'}'
            '${toEth ? ' blocksLeft ${controller.blocksLeft(c)}' : ''}';
        if (line != last) {
          _evidence(line);
          last = line;
        }
        if (c.state.isFinal) break;
        await Future<void>.delayed(const Duration(seconds: 20));
      }
      expect(crossing.state.isDone, isTrue, reason: crossing.state.name);

      final beamAfter = await beam.available(route.beamAssetId);
      final ethAfter = await eth.balance(route);
      _evidence(
        'after: BEAM wallet ${_units(beamAfter, 8)} ${route.beamSymbol} '
        '(${_units(beamAfter - beamBefore, 8)}); Ethereum wallet '
        '${_units(ethAfter, route.ethDecimals)} ${route.ethSymbol} '
        '(${_units(ethAfter - ethBefore, route.ethDecimals)})',
      );
    } finally {
      await wallet.exit();
      if (await link.exists()) await link.delete();
      await isar.close(deleteFromDisk: true);
      await Directory(root).delete(recursive: true);
    }
  }, skip: skip);
}
