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
import 'package:stackwallet/models/isar/models/blockchain_data/transaction.dart';
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
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
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
    'BeamWallet on mainnet: R11 budgets, receive 0.01, send 0.005, return the '
    'rest',
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

        // --- R11 on a recently opened wallet ---
        final budgets = <String>[];
        final overBudget = <String>[];
        for (var i = 1; i <= 3; i++) {
          await wallet.exit();
          await Future<void>.delayed(const Duration(seconds: 2));
          final sw = Stopwatch()..start();
          await wallet.init();
          await wallet.open();
          final cachedBalance = wallet.info.cachedBalance;
          final cachedTxs = isar.transactionV2s
              .where()
              .walletIdEqualTo(wallet.walletId)
              .countSync();
          final cachedView = sw.elapsedMilliseconds;
          expect(cachedBalance, isNotNull);
          expect(wallet.isOpen, isFalse, reason: 'view did not wait');
          await wallet.whenLive.timeout(const Duration(seconds: 30));
          final live = sw.elapsedMilliseconds;
          await wallet.whenCanSend.timeout(const Duration(seconds: 60));
          final canSend = sw.elapsedMilliseconds;
          budgets.add(
            'reopen $i: cached view $cachedView ms ($cachedTxs txs), '
            'live $live ms, can send $canSend ms '
            '(${wallet.openTimings})',
          );
          _evidence(budgets.last);
          // Checked after the money flow, so a missed budget still leaves
          // the payment evidence.
          if (cachedView > 300) overBudget.add('reopen $i cached $cachedView');
          if (live > 3000) overBudget.add('reopen $i live $live');
          if (canSend > 10000) overBudget.add('reopen $i can send $canSend');
        }

        // --- funder -> it-wallet 0.01 BEAM ---
        final before = spendable();
        final funderSend = await _funder('tx_send', {
          'address': address,
          'value': 1000000,
          'fee': _fee,
        }) as Map;
        final inTxId = funderSend['txId'] as String;
        _evidence('funder tx_send 0.01 BEAM fee 0.001: ${_short(inTxId)}');
        final inSw = Stopwatch()..start();
        await waitFor(
          () => spendable() >= before + _g(0.01),
          timeout: const Duration(minutes: 20),
          what: 'incoming 0.01 BEAM available',
        );
        final inTx = history().firstWhere((t) => t.txid == inTxId);
        expect(inTx.type, TransactionType.incoming);
        expect(inTx.beamTxStatus, 'completed');
        expect(
          inTx.getAmountReceivedInThisWallet(fractionDigits: 8).raw,
          _g(0.01),
        );
        _evidence(
          'received ${_short(inTxId)} completed at height ${inTx.height} '
          'after ${inSw.elapsed.inSeconds} s; spendable '
          '${_beam(spendable())} BEAM',
        );

        // --- it-wallet -> funder 0.005 BEAM ---
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
        final prepared = await wallet.prepareSend(txData: send(_g(0.005)));
        expect(prepared.fee!.raw, BigInt.from(_fee));
        expect(wallet.coreApi!.transport.isConnected, isTrue);
        final confirmed = await wallet.confirmSend(txData: prepared);
        final outTxId = confirmed.txid!;
        _evidence(
          'it-wallet confirmSend 0.005 BEAM fee 0.001: '
          '${_short(outTxId)}',
        );
        final outSw = Stopwatch()..start();
        await waitFor(
          () => history()
              .where((t) => t.txid == outTxId && t.beamTxStatus == 'completed')
              .isNotEmpty,
          timeout: const Duration(minutes: 20),
          what: 'outgoing 0.005 completed',
        );
        final outTx = history().firstWhere((t) => t.txid == outTxId);
        expect(outTx.type, TransactionType.outgoing);
        expect(
          outTx
              .getAmountSentFromThisWallet(fractionDigits: 8, subtractFee: true)
              .raw,
          _g(0.005),
        );
        expect(outTx.getFee(fractionDigits: 8).raw, BigInt.from(_fee));
        final funderView = await _funder('tx_status', {'txId': outTxId}) as Map;
        expect(funderView['status'], 3, reason: 'funder sees it completed');
        _evidence(
          'sent ${_short(outTxId)} completed at height ${outTx.height} after '
          '${outSw.elapsed.inSeconds} s; funder status '
          '${funderView['status_string']}',
        );

        // --- return the rest: send all ---
        await waitFor(
          () => spendable() >= _g(0.004),
          timeout: const Duration(minutes: 10),
          what: 'change 0.004 available',
        );
        await wallet.whenCanSend.timeout(const Duration(minutes: 2));
        final rest = spendable();
        final preparedAll = await wallet.prepareSend(txData: send(rest));
        final restAmount = preparedAll.recipients!.single.amount.raw;
        expect(restAmount, rest - BigInt.from(_fee), reason: 'fee taken out');
        final allTxId = (await wallet.confirmSend(txData: preparedAll)).txid!;
        _evidence(
          'it-wallet send-all ${_beam(restAmount)} BEAM fee 0.001: '
          '${_short(allTxId)}',
        );
        await waitFor(
          () => history()
              .where((t) => t.txid == allTxId && t.beamTxStatus == 'completed')
              .isNotEmpty,
          timeout: const Duration(minutes: 20),
          what: 'send-all completed',
        );
        await waitFor(
          () => wallet.info.cachedBalance.total.raw == BigInt.zero,
          timeout: const Duration(minutes: 5),
          what: 'balance back to 0',
        );
        final allTx = history().firstWhere((t) => t.txid == allTxId);
        _evidence(
          'send-all ${_short(allTxId)} completed at height ${allTx.height}; '
          'balance total ${_beam(wallet.info.cachedBalance.total.raw)} BEAM',
        );

        // --- history ---
        final all = history();
        expect(
          all.map((t) => t.txid).toSet(),
          containsAll([inTxId, outTxId, allTxId]),
        );
        for (final t in all) {
          final label = t.statusLabel(
            currentChainHeight: wallet.info.cachedChainHeight,
            minConfirms: 1,
            minCoinbaseConfirms: 240,
          );
          _evidence(
            'history ${_short(t.txid)} ${t.type.name} ${t.beamTxStatus} '
            'height ${t.height} label "$label"',
          );
        }
        final ownerKeyAfter = await secure.read(
          key: BeamSecretKeys.ownerKey(wallet.walletId),
        );
        expect(ownerKeyAfter, ownerKey, reason: 'no re-export needed');
        expect(overBudget, isEmpty, reason: 'R11 budgets');
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
