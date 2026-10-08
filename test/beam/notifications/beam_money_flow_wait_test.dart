/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-NOTIFY-PERM: the system's notification question waits while a money
// flow is open, over REAL BeamWallets: whatever holds a wallet's node switch
// (a send being confirmed, a swap, a claim, a dApp approval) holds the
// question back, and letting go lets it through.

import 'dart:async';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_payment_notice.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import '../wallet/beam_wallet_test_support.dart';

void main() {
  late Directory tmp;
  late Isar isar;
  final made = <BeamWallet>[];

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_money_flow_test_');
    isar = await openTestMainDb(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
    final root = p.join(tmp.path, 'root');
    Directory(root).createSync(recursive: true);
    final host = FakeBeamHost(
      replies: () => {
        'wallet_status': (Map<String, Object?> _) => <String, Object?>{},
      },
    );
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => host,
      createExplorer: () => FakeExplorer(4100000),
      privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
      log: (_) {},
    );
  });

  tearDownAll(() async {
    for (final w in made) {
      await w.exit();
    }
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  Future<BeamWallet> newWallet(String name) async {
    final w = await Wallet.create(
      walletInfo: WalletInfo.createNew(
        coin: Beam(CryptoCurrencyNetwork.main),
        name: name,
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
    made.add(w);
    await w.init();
    return w;
  }

  test('nothing open: at once', () async {
    final a = await newWallet('a');
    await beamNoMoneyFlowOpen(wallets: [a]).timeout(
      const Duration(seconds: 1),
    );
  });

  test('a send being confirmed in one wallet, a swap in another: waits for '
      'both to end', () async {
    final a = await newWallet('a');
    final b = await newWallet('b');
    final send = a.holdNodeSwitch('confirm send');
    final swap = b.holdNodeSwitch('swap');
    var through = false;
    unawaited(
      beamNoMoneyFlowOpen(wallets: [a, b]).then((_) => through = true),
    );
    await pumpEventQueue();
    expect(through, isFalse);

    send.release();
    await pumpEventQueue();
    expect(through, isFalse, reason: 'the swap is still open');

    swap.release();
    await pumpEventQueue();
    expect(through, isTrue);
  });

  test('a flow that opens while waiting is waited for too', () async {
    final a = await newWallet('a');
    final first = a.holdNodeSwitch('claim');
    var through = false;
    unawaited(beamNoMoneyFlowOpen(wallets: [a]).then((_) => through = true));
    await pumpEventQueue();
    // The claim ends and an approval opens in the same moment.
    final second = a.holdNodeSwitch('dApp approval');
    first.release();
    await pumpEventQueue();
    expect(through, isFalse);
    second.release();
    await pumpEventQueue();
    expect(through, isTrue);
  });
}
