/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, real funds: Split coins (B-UTXO-1) through the app's
// own path — BeamWallet.prepareSplit / confirmSplit on the in-process core —
// in ONE test wallet: 0.05 BEAM into 3 coins of 0.01666666.
// Nothing leaves the wallet but the fee; nothing is sent to any address.
// The operator logs the tx id in the project notes.
//
// The wallet is opened IN PLACE, not copied: a copy that splits coins would
// leave the original not knowing about the new ones. Its directory is linked
// into a throwaway app root, so wallet.db and its journal stay where they
// are. It must not be open anywhere else (rule R8): the test refuses while
// wapi.py has it running.
//
// LWTEST (LightWallet's test_wallet, which R9 allows for test funds), not
// FUNDER or FUNDER2: both of those wallet.db files are stale copies of seeds
// spent from elsewhere (TEST_LOG 2026-10-06 and -07). A split from each was
// refused by the node on 2026-10-08 ("Failed to register transaction");
// nothing moved. Opening a wallet also makes its directory 0700, as the
// app does for its own.
//
//   BEAM_SPLIT_IT=1 BEAM_CORE_LIB=<libbeam_core.dylib> \
//   [BEAM_SPLIT_LABEL=<test_wallets.env label, default LWTEST>] \
//       scripts/beam/host_test.sh --no-analyze \
//       test/beam/wallet/beam_split_live_test.dart
//
// The wallet's file and password are read at run time from
// ~/.config/campfire-beam/test_wallets.env (<LABEL>_WALLET_DB,
// <LABEL>_WALLET_PASS). Nothing secret is printed: evidence lines carry the
// tx id, kernel, heights, coin counts and amounts only.
@Timeout(Duration(minutes: 45))
library;

import 'dart:io';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/host/beam_core_location.dart';
import 'package:stackwallet/wallets/beam/host/in_process_host.dart';
import 'package:stackwallet/wallets/beam/host/secret_file.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/net/beam_node_route.dart';
import 'package:stackwallet/wallets/beam/utxo/beam_coins.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_balance_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_secret_store.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_tx_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_text.dart';
import 'package:stackwallet/widgets/beam/tx/beam_tx_view.dart';

import 'beam_wallet_test_support.dart';

const _count = 3;
final _size = BigInt.from(1666666); // 3 x 0.01666666 = 0.04999998 BEAM

void _evidence(String line) {
  // ignore: avoid_print
  print(
    '[evidence] ${DateTime.now().toIso8601String().substring(11, 19)} $line',
  );
}

String _beam(BigInt groth) {
  final unit = BigInt.from(100000000);
  return '${groth ~/ unit}.${(groth % unit).toString().padLeft(8, '0')}';
}

String _rand(int n) {
  const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
  final r = Random.secure();
  return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
}

/// `KEY=value` lines of the 0600 secrets file; a later line wins. Values
/// are never printed.
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

void main() {
  final env = Platform.environment;
  final home = env['HOME'] ?? '';
  final label = (env['BEAM_SPLIT_LABEL'] ?? 'LWTEST').toUpperCase();
  final lib = env[kBeamCoreLibraryEnv];
  final secrets = _testWallets(home);
  final dbPath = secrets['${label}_WALLET_DB'];
  final password = secrets['${label}_WALLET_PASS'];
  final runState = File(
    p.join(home, 'beam-campfire-test/run/${label.toLowerCase()}.json'),
  );

  final String? skip;
  if (env['BEAM_SPLIT_IT'] != '1') {
    skip = 'live: set BEAM_SPLIT_IT=1';
  } else if (lib == null || lib.isEmpty) {
    skip = 'live: set $kBeamCoreLibraryEnv';
  } else if (dbPath == null || password == null) {
    skip = 'live: no $label wallet in test_wallets.env';
  } else if (!File(dbPath).existsSync()) {
    skip = "live: $label's wallet.db is missing";
  } else if (runState.existsSync()) {
    skip = 'live: $label is open in wapi.py; stop it first (rule R8)';
  } else {
    skip = null;
  }

  test(
    'Split coins on mainnet: 0.05 BEAM into 3 coins, only the fee leaves',
    () async {
      final root = p.join(home, 'beam-campfire-test', 'split-it-${_rand(8)}');
      await ensurePrivateDir(root);
      final beamRoot = p.join(root, 'beam');
      await ensurePrivateDir(beamRoot);
      final isarDir = Directory(p.join(root, 'isar'))..createSync();
      final isar = await openTestMainDb(isarDir);

      final log = <String>[];
      final explorer = BeamExplorerClient(proxyInfo: () => null);
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
        createExplorer: () => explorer,
        explorerPollInterval: const Duration(seconds: 10),
        statusPollInterval: const Duration(seconds: 10),
        log: log.add,
      );

      final secure = FakeSecureStorage();
      final wallet = await Wallet.create(
        walletInfo: WalletInfo.createNew(
          coin: Beam(CryptoCurrencyNetwork.main),
          name: 'split-it',
        ),
        mainDB: MainDB.instance,
        secureStorageInterface: secure,
        nodeService: FakeNodeService(
          beamTestNode('eu-node01.mainnet.beam.mw', 8100),
        ),
        prefs: FakePrefs(),
        // Never reaches the core: the wallet file already exists.
        mnemonic: bip39.generateMnemonic(),
        mnemonicPassphrase: '',
      ) as BeamWallet;

      // The test wallet's directory, linked in place (never copied).
      final walletsDir = Directory(p.join(beamRoot, 'wallets'))
        ..createSync(recursive: true);
      final link = Link(p.join(walletsDir.path, wallet.walletId));
      await link.create(p.dirname(dbPath!));
      await BeamSecretStore(secure, wallet.walletId).writePassword(password!);
      _evidence('wallet $label opened in place (linked, not copied)');

      try {
        await wallet.init();
        final sw = Stopwatch()..start();
        await wallet.open();
        await wallet.whenCanSend.timeout(const Duration(minutes: 5));
        final api = wallet.coreApi!;
        _evidence(
          'synced in ${sw.elapsedMilliseconds} ms at '
          '${wallet.syncAssessment.walletHeight}',
        );

        final s0 = await api.walletStatus();
        final t0 = BeamBalanceMapper.totalsFor(s0, 0);
        expect(
          t0.sending + t0.receiving,
          BigInt.zero,
          reason: 'start with nothing in flight, so the balance check holds',
        );
        final before = (await wallet.loadCoins())[0]!;
        _evidence(
          'before: ${_beam(t0.available)} BEAM available in '
          '${before.available.length} coins (largest '
          '${_beam(before.available.first.amount)})',
        );

        final plan = BeamSplitPlan.sized(
          available: t0.available,
          count: _count,
          size: _size,
        );
        expect(plan, isNotNull, reason: 'the wallet holds enough to split');
        _evidence(
          'plan: $_count coins of ${_beam(_size)} = ${_beam(plan!.total)} '
          'BEAM, fee ${_beam(plan.fee)}',
        );

        final prepared = await wallet.prepareSplit(plan);
        final txId = await wallet.confirmSplit(prepared);
        _evidence('tx_split handed to the core: txId $txId');
        expect(wallet.isBusy, isFalse);

        // Until the core says completed (or failed).
        BeamTransaction? tx;
        String? lastStatus;
        final until = DateTime.now().add(const Duration(minutes: 25));
        while (DateTime.now().isBefore(until)) {
          tx = await api.txStatus(txId);
          if (tx.status.name != lastStatus) {
            lastStatus = tx.status.name;
            _evidence(
              'status ${tx.status.name}'
              '${tx.failureReason == null ? '' : ': ${tx.failureReason}'}',
            );
          }
          if (tx.status == BeamTxStatus.completed ||
              tx.status == BeamTxStatus.failed ||
              tx.status == BeamTxStatus.canceled) {
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 10));
        }
        expect(tx!.status, BeamTxStatus.completed);
        expect(tx.isSplit, isTrue, reason: 'no peer address on either side');
        _evidence(
          'completed at height ${tx.height}, kernel ${tx.kernel}, fee '
          '${_beam(tx.fee ?? BigInt.zero)}',
        );

        // The change is back: only the fee left.
        var t1 = BeamBalanceMapper.totalsFor(await api.walletStatus(), 0);
        final settle = DateTime.now().add(const Duration(minutes: 5));
        while ((t1.sending + t1.receiving + t1.change) > BigInt.zero &&
            DateTime.now().isBefore(settle)) {
          await Future<void>.delayed(const Duration(seconds: 5));
          t1 = BeamBalanceMapper.totalsFor(await api.walletStatus(), 0);
        }
        _evidence(
          'after: ${_beam(t1.available)} BEAM available '
          '(before ${_beam(t0.available)}, difference '
          '${_beam(t0.available - t1.available)})',
        );
        expect(t0.available - t1.available, plan.fee);

        final after = (await wallet.loadCoins())[0]!;
        final made = [
          for (final u in after.available)
            if (u.createTxId == txId && u.amount == _size) u,
        ];
        _evidence(
          'after: ${after.available.length} coins; ${made.length} new coins '
          'of ${_beam(_size)} from this split',
        );
        expect(made, hasLength(_count));

        // The history says what happened.
        final row = BeamTxView.of(
          BeamTxMapper.map(
            tx,
            walletId: wallet.walletId,
            ownAddresses: const {},
          ),
        )!;
        _evidence(
          'history: "${BeamTxText.title(row)}" / "${BeamTxText.status(row)}"',
        );
        expect(BeamTxText.title(row), 'Split into coins');
      } finally {
        await wallet.exit();
        // The link only; the wallet's directory stays as it is.
        if (await link.exists()) await link.delete();
        await isar.close(deleteFromDisk: true);
        await Directory(root).delete(recursive: true);
      }
    },
    skip: skip,
  );
}
