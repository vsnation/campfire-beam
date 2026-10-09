/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds (at most 0.01 BEAM per tx here, own
// wallets only, every tx logged in the project notes by the operator).
//
// TOKEN variant: the same throwaway wallet receives 0.01 BEAM + 0.01 FOMO and
// sends FOMO back through BeamAssetWallet (the asset screens' wallet).
//
// A NEW BeamWallet is created through the Dart API (Wallet.create + init)
// with the real ProcessHost and the pinned HF6 binaries, in a throwaway app
// root under ~/beam-campfire-test/it-wallet-<rand>/ (0700). Then:
//
//   1. R11 budgets: cached view, live data, able to send — on the first
//      (cold) open and on three re-opens of the recently opened wallet;
//   2. the funder pays the new wallet 0.01 BEAM (regular SBBS, both online);
//   3. the new wallet pays 0.005 BEAM back with prepareSend/confirmSend;
//   4. it returns the rest with a "send all" (fee taken from the amount);
//   5. history and balances are asserted, and the wallet is closed.
//
// The funder must already run in TCP mode on the same public node:
//
//   python3 -I scripts/beam/live/wapi.py start funder --port 10105 --tcp \
//       --node eu-node01.mainnet.beam.mw:8100
//   BEAM_WALLET_IT=1 \
//   BEAM_BIN_DIR=$HOME/Desktop/Beam/LightWallet/binaries/macos \
//   BEAM_IT_FUNDER_ADDRESS=<a funder regular address> \
//   [BEAM_IT_FUNDER_LABEL=<wapi.py label, default funder>] \
//   [BEAM_IT_NODE=<node host, default eu-node01.mainnet.beam.mw>] \
//       flutter test --no-pub test/beam/wallet/beam_wallet_live_test.dart
//   python3 -I scripts/beam/live/wapi.py stop funder
//
// The new wallet's phrase, wallet.db path and password are appended to
// ~/.config/campfire-beam/test_wallets.env (0600) under label ITWALLET right
// after creation, so the funds are never stranded. Nothing secret is
// printed: evidence lines carry tx ids cut to 12 characters, heights,
// amounts and timings only.
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_binaries.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_secret_store.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_shutdown.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/models/tx_data.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import 'beam_wallet_test_support.dart';

/// The public node the new wallet uses (`BEAM_IT_NODE`, host only); put it
/// on the funder's node so the SBBS messages have the shortest path.
final String _node =
    Platform.environment['BEAM_IT_NODE'] ?? 'eu-node01.mainnet.beam.mw';
const _fee = 100000;

void _evidence(String line) {
  // ignore: avoid_print
  print('[evidence] $line');
}

String _rand(int n) {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

String _short(String id) => id.length <= 12 ? id : id.substring(0, 12);

BigInt _g(num beam) => BigInt.from((beam * 100000000).round());

String _beam(BigInt groth) => (groth.toDouble() / 1e8).toStringAsFixed(8);

/// The wapi.py label of the paying wallet (`BEAM_IT_FUNDER_LABEL`, default
/// `funder`).
final String _funderLabel =
    Platform.environment['BEAM_IT_FUNDER_LABEL'] ?? 'funder';

/// Runs `wapi.py call <funder> <method> <params>` and returns `result`.
Future<Object?> _funder(String method, Map<String, Object?> params) async {
  final r = await Process.run('python3', [
    '-I',
    'scripts/beam/live/wapi.py',
    'call',
    _funderLabel,
    method,
    jsonEncode(params),
  ]);
  if (r.exitCode != 0) {
    throw StateError('wapi.py $method failed (exit ${r.exitCode})');
  }
  final decoded = jsonDecode('${r.stdout}') as Map;
  if (decoded.containsKey('error')) {
    throw StateError('funder $method: ${jsonEncode(decoded['error'])}');
  }
  return decoded['result'];
}

/// Keeps the throwaway wallet recoverable (test_wallets.env) and makes the
/// secret scan refuse its phrase and password anywhere in the repo
/// (secret_denylist.txt). Both files are 0600, outside the repo.
Future<void> _appendSecrets(
  Map<String, String> entries, {
  required List<String> denylist,
}) async {
  final dir = p.join(Platform.environment['HOME']!, '.config/campfire-beam');
  final env = File(p.join(dir, 'test_wallets.env'));
  final buffer = StringBuffer(
    '\n# ITWALLET: B-WALLET-1 live test throwaway '
    '(${DateTime.now().toUtc().toIso8601String()})\n',
  );
  entries.forEach((k, v) => buffer.writeln('$k=$v'));
  await env.writeAsString(
    buffer.toString(),
    mode: FileMode.append,
    flush: true,
  );
  final deny = File(p.join(dir, 'secret_denylist.txt'));
  await deny.writeAsString(
    '${denylist.join('\n')}\n',
    mode: FileMode.append,
    flush: true,
  );
  await Process.run('chmod', ['600', env.path, deny.path]);
}

void main() {
  final enabled = Platform.environment['BEAM_WALLET_IT'] == '1';
  final binDir = Platform.environment[BeamBinaries.binDirEnv];
  final funderAddress = Platform.environment['BEAM_IT_FUNDER_ADDRESS'];
  final home = Platform.environment['HOME'];

  test(
    'BEAM token on mainnet: receive FOMO, send FOMO with the asset sub-wallet, '
    'return the rest',
    () async {
      final itRoot = Directory(
        p.join(home!, 'beam-campfire-test', 'it-wallet-${_rand(8)}'),
      );
      await ensurePrivateDir(itRoot.path);
      final beamRoot = p.join(itRoot.path, 'beam');
      await ensurePrivateDir(beamRoot);
      final isarDir = Directory(p.join(itRoot.path, 'isar'))..createSync();
      final isar = await openTestMainDb(isarDir);
      _evidence(
        'app root ~/${p.relative(itRoot.path, from: home)} (0700), '
        'binaries ${p.basename(binDir!)}',
      );

      final hostLog = <String>[];
      final explorer = BeamExplorerClient(proxyInfo: () => null);
      BeamWalletEnvironment.instance = BeamWalletEnvironment(
        beamRoot: () async => beamRoot,
        createHost: (root) => ProcessHost(
          rootDir: root,
          // flutter_tester is x86_64 under Rosetta; the pinned arm64
          // binaries run natively.
          binaries: BeamBinaries(
            binDir: binDir,
            platform: Platform.isMacOS ? 'macos-arm64' : null,
          ),
          log: hostLog.add,
          startupTimeout: const Duration(seconds: 30),
        ),
        createExplorer: () => explorer,
        explorerPollInterval: const Duration(seconds: 5),
        statusPollInterval: const Duration(seconds: 30),
        log: hostLog.add,
      );

      final secure = FakeSecureStorage();
      final mnemonic = bip39.generateMnemonic();
      final info = WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: 'it-wallet',
      );
      final wallet = await Wallet.create(
        walletInfo: info,
        mainDB: MainDB.instance,
        secureStorageInterface: secure,
        nodeService: FakeNodeService(beamTestNode(_node, 8100)),
        prefs: FakePrefs(),
        mnemonic: mnemonic,
        mnemonicPassphrase: '',
      ) as BeamWallet;

      BigInt spendable() => wallet.info.cachedBalance.spendable.raw;
      List<TransactionV2> history() => isar.transactionV2s
          .where()
          .walletIdEqualTo(wallet.walletId)
          .findAllSync();

      try {
        // --- create ---
        final createSw = Stopwatch()..start();
        await wallet.init();
        createSw.stop();
        final password = await secure.read(
          key: BeamSecretKeys.walletPassword(wallet.walletId),
        );
        final ownerKey = await secure.read(
          key: BeamSecretKeys.ownerKey(wallet.walletId),
        );
        expect(password, isNotNull);
        expect(ownerKey, isNotNull, reason: 'owner key read at create (R11)');
        final dbPath = p.join(
          beamRoot,
          'wallets',
          wallet.walletId,
          'wallet.db',
        );
        expect(File(dbPath).existsSync(), isTrue);
        await _appendSecrets(
          {
            'ITWALLET_SEED': mnemonic,
            'ITWALLET_WALLET_DB': dbPath,
            'ITWALLET_WALLET_PASS': password!,
          },
          denylist: [mnemonic, mnemonic.replaceAll(' ', ';'), password],
        );
        _evidence(
          'created wallet.db + exported owner key in '
          '${createSw.elapsedMilliseconds} ms; password '
          '${password.length} chars and owner key in secure storage; '
          'phrase saved as ITWALLET in ~/.config (0600)',
        );

        // --- first (cold) open ---
        await wallet.open();
        await wallet.whenLive.timeout(const Duration(seconds: 60));
        await wallet.whenCanSend.timeout(const Duration(minutes: 5));
        _evidence('cold open: ${wallet.openTimings}');
        final address = wallet.info.cachedReceivingAddress;
        expect(address, isNotEmpty);
        final saved = await wallet.getCurrentReceivingAddress();
        expect(saved!.type, AddressType.mimbleWimble);
        _evidence(
          'receiving address: regular (${address.length} hex chars), '
          'synced at ${wallet.syncAssessment.walletHeight}',
        );

        Future<BigInt> fomoAvailable() async =>
            (await wallet.coreApi!.walletStatus()).totalsFor(174)?.available ??
            BigInt.zero;
        Future<void> waitAsync(
          Future<bool> Function() ok,
          String what, {
          Duration timeout = const Duration(minutes: 20),
        }) async {
          final sw = Stopwatch()..start();
          while (!await ok()) {
            if (sw.elapsed > timeout) fail('timed out: $what');
            await Future<void>.delayed(const Duration(seconds: 10));
          }
        }

        Future<String> waitDone(String txId, String what) async {
          final sw = Stopwatch()..start();
          await waitAsync(() async {
            final t = await wallet.coreApi!.txStatus(txId);
            return t.statusString == 'completed' ||
                t.statusString == 'received' ||
                t.statusString == 'sent';
          }, what);
          final t = await wallet.coreApi!.txStatus(txId);
          _evidence(
            '$what: ${_short(txId)} ${t.statusString} at height ${t.height} '
            'after ${sw.elapsed.inSeconds} s',
          );
          return t.statusString;
        }

        // --- funder -> it-wallet: 0.01 BEAM (for fees) and 0.01 FOMO ---
        final beamIn =
            (await _funder('tx_send', {
                  'address': address,
                  'value': 1000000,
                  'fee': _fee,
                }) as Map)['txId']
                as String;
        final fomoIn =
            (await _funder('tx_send', {
                  'address': address,
                  'value': 1000000,
                  'fee': _fee,
                  'asset_id': 174,
                }) as Map)['txId']
                as String;
        _evidence(
          'funder sent 0.01 BEAM (${_short(beamIn)}) and 0.01 FOMO '
          '(${_short(fomoIn)})',
        );
        await waitAsync(
          () async =>
              spendable() >= _g(0.01) && await fomoAvailable() >= _g(0.01),
          'BEAM and FOMO arrived',
        );
        _evidence(
          'received: spendable ${_beam(spendable())} BEAM, '
          '${_beam(await fomoAvailable())} FOMO',
        );

        // --- the token sub-wallet the asset screens use ---
        final rows = await BeamAssetRegistry.sync(
          isar: isar,
          heldIds: const [174],
          api: wallet.coreApi,
        );
        final fomo = BeamAssetWallet.load(parent: wallet, asset: rows[174]!);
        await fomo.init();
        await wallet.whenCanSend.timeout(const Duration(minutes: 2));

        TxData send(BigInt groth) => TxData(
          recipients: [
            TxRecipient(
              address: funderAddress!,
              amount: Amount(rawValue: groth, fractionDigits: 8),
              isChange: false,
              addressType: AddressType.mimbleWimble,
            ),
          ],
        );
        final prepared = await fomo.prepareSend(txData: send(_g(0.005)));
        _evidence(
          'FOMO prepareSend 0.005: fee ${_beam(prepared.fee!.raw)} BEAM '
          '(paid in BEAM)',
        );
        expect(prepared.fee!.raw >= BigInt.from(_fee), isTrue);
        expect(prepared.fee!.raw <= _g(0.02), isTrue);
        final outTxId = (await fomo.confirmSend(txData: prepared)).txid!;
        await waitDone(outTxId, 'FOMO 0.005 sent');
        final funderView = await _funder('tx_status', {'txId': outTxId}) as Map;
        _evidence(
          'funder sees ${_short(outTxId)}: ${funderView['status_string']}, '
          'asset ${funderView['asset_id']}, value ${funderView['value']}',
        );
        expect(funderView['asset_id'], 174);
        expect('${funderView['value']}', '500000');

        // --- return the rest: remaining FOMO, then all BEAM ---
        await waitAsync(
          () async => await fomoAvailable() >= _g(0.005),
          'remaining FOMO available',
          timeout: const Duration(minutes: 10),
        );
        final fomoRest = await fomoAvailable();
        final preparedRest = await fomo.prepareSend(txData: send(fomoRest));
        final restTxId = (await fomo.confirmSend(txData: preparedRest)).txid!;
        await waitDone(restTxId, 'FOMO rest ${_beam(fomoRest)} sent');
        expect(await fomoAvailable(), BigInt.zero);

        await waitFor(
          () => spendable() > BigInt.from(_fee),
          timeout: const Duration(minutes: 10),
          what: 'BEAM change available',
        );
        await wallet.whenCanSend.timeout(const Duration(minutes: 2));
        final preparedAll = await wallet.prepareSend(txData: send(spendable()));
        final allTxId = (await wallet.confirmSend(txData: preparedAll)).txid!;
        await waitDone(allTxId, 'BEAM send-all');
        await fomo.exit();
      } finally {
        for (final t in history()) {
          _evidence(
            'final history ${_short(t.txid)} ${t.type.name} '
            '${t.beamTxStatus} height ${t.height}',
          );
        }
        await wallet.exit();
        await shutdownBeamChildren();
        final leaked = hostLog.where(
          (l) => l.contains(mnemonic.split(' ').take(3).join(' ')),
        );
        expect(leaked, isEmpty, reason: 'no phrase in the host log');
        _evidence(
          'host log (${hostLog.length} lines): '
          '${hostLog.take(12).join(' | ')}',
        );
        final balance = wallet.info.cachedBalance.total.raw;
        if (balance <= _g(0.001)) {
          await Directory(p.join(beamRoot, 'wallets', wallet.walletId))
              .delete(recursive: true);
          _evidence(
            'balance ${_beam(balance)} BEAM <= 0.001: wallet directory '
            'deleted (phrase kept as ITWALLET)',
          );
        } else {
          _evidence(
            'balance ${_beam(balance)} BEAM > 0.001: wallet KEPT at '
            '~/${p.relative(itRoot.path, from: home)}',
          );
        }
        await isar.close();
      }
    },
    skip: !enabled
        ? 'set BEAM_WALLET_IT=1 (live mainnet, moves real BEAM)'
        : (binDir == null || funderAddress == null)
        ? 'needs BEAM_BIN_DIR and BEAM_IT_FUNDER_ADDRESS'
        : false,
  );
}
