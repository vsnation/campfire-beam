/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Import wallet.db (for people who have wallet.db files but no recovery
// phrases): a wallet from its file and password, with no
// recovery phrase stored and none made up; nothing left behind on failure;
// the original file never changed; rescan (which would delete the file to
// rebuild it from a phrase) refused.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_backup_notice.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_secret_store.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_file_import.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';

import 'beam_wallet_test_support.dart';

void main() {
  late Directory tmp;
  late Isar isar;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_import_test_');
    isar = await openTestMainDb(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  late String root;
  late FakeBeamHost host;
  late FakeSecureStorage secure;
  late File source;
  late List<int> sourceBytes;
  final opened = <BeamWallet>[];

  setUp(() async {
    root = (await Directory(
      p.join(tmp.path, 'root-${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true)).path;
    host = FakeBeamHost(replies: () => {});
    secure = FakeSecureStorage();
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => host,
      createExplorer: () => FakeExplorer(4100000),
    );
    source = File(p.join(tmp.path, 'from-elsewhere', 'alice', 'wallet.db'));
    await source.parent.create(recursive: true);
    sourceBytes = List.generate(4096, (i) => (i * 31) % 251);
    await source.writeAsBytes(sourceBytes);
    host.importable[source.path] = 'the-owners-own-password';
  });

  tearDown(() async {
    for (final w in opened) {
      await w.exit();
    }
    opened.clear();
  });

  Future<BeamWallet> import({String password = 'the-owners-own-password'}) =>
      importBeamWalletFile(
        name: 'alice',
        sourcePath: source.path,
        password: password,
        mainDB: MainDB.instance,
        secureStorage: secure,
        nodeService: FakeNodeService(
          beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
        ),
        prefs: FakePrefs(),
      );

  test('the file and its password become a wallet with no recovery phrase',
      () async {
    final wallet = await import();
    opened.add(wallet);

    expect(wallet.info.name, 'alice');
    expect(wallet.isImportedFromFile, isTrue);
    // A backup cannot hold it, and the backup screens say so.
    expect(beamWalletsNotInBackup([wallet]), ['alice']);
    expect(wallet.info.beamData?.importedFromFile, isTrue);
    expect(
      await wallet.info.isMnemonicVerified(isar),
      isTrue,
      reason: 'never nagged',
    );

    // No phrase stored, none made up.
    expect(
      await secure.read(key: Wallet.mnemonicKey(walletId: wallet.walletId)),
      isNull,
    );
    expect(await wallet.getMnemonicAsWords(), isEmpty);
    expect(await wallet.getMnemonic(), isEmpty);

    // The copy holds the file's bytes; the password opens it from now on.
    final dir = await BeamWalletEnvironment.instance.walletDir(
      wallet.walletId,
    );
    expect(
      await File(p.join(dir, 'wallet.db')).readAsBytes(),
      sourceBytes,
    );
    expect(
      await BeamSecretStore(secure, wallet.walletId).readPassword(),
      'the-owners-own-password',
    );
    expect(
      await BeamSecretStore(secure, wallet.walletId).readOwnerKey(),
      isNotNull,
      reason: 'read once for the private node',
    );
    expect(host.calls, isNot(contains('initWallet')), reason: 'no new file');

    // The original is untouched.
    expect(await source.readAsBytes(), sourceBytes);
  });

  test('a wrong password leaves nothing behind and blames no one', () async {
    final before = await isar.walletInfo.where().count();
    await expectLater(
      import(password: 'not-it'),
      throwsA(
        isA<BeamWalletException>()
            .having(
              (e) => e.problem,
              'problem',
              BeamWalletProblem.wrongPassword,
            )
            .having(
              (e) => e.message,
              'message',
              BeamImportMessages.wrongPassword,
            ),
      ),
    );
    expect(await isar.walletInfo.where().count(), before);
    final wallets = Directory(p.join(root, 'wallets'));
    final left = await wallets.exists()
        ? await wallets.list().toList()
        : const <FileSystemEntity>[];
    expect(left, isEmpty);
    expect(await source.readAsBytes(), sourceBytes);
    expect(BeamImportMessages.wrongPassword, isNot(contains('your fault')));
  });

  test('rescan is refused: it would delete the only copy of the wallet',
      () async {
    final wallet = await import();
    opened.add(wallet);
    final dir = await BeamWalletEnvironment.instance.walletDir(
      wallet.walletId,
    );
    await expectLater(
      wallet.recover(isRescan: true),
      throwsA(
        isA<BeamWalletException>().having(
          (e) => e.message,
          'message',
          BeamWalletMessages.importedNoRescan,
        ),
      ),
    );
    expect(await File(p.join(dir, 'wallet.db')).readAsBytes(), sourceBytes);
  });

  test('the flag survives a round trip through the stored info', () {
    const data = ExtraBeamWalletInfo(importedFromFile: true);
    expect(ExtraBeamWalletInfo.fromMap(data.toMap()).importedFromFile, isTrue);
    expect(
      ExtraBeamWalletInfo.fromMap(const ExtraBeamWalletInfo().toMap())
          .importedFromFile,
      isFalse,
    );
    expect(
      const ExtraBeamWalletInfo().toMap(),
      isNot(contains('importedFromFile')),
    );
  });
}
