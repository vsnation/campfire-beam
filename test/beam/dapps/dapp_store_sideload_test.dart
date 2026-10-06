/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Security review part 2, L-15 / dApp review L1: a `.dapp` file could reuse
// a bundled dApp's guid and inherit its origin, browser storage and
// transaction scope, and look exactly like the checked one.

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_errors.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_package_fetcher.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_store_controller.dart';

import 'dapp_test_zip.dart';

const _dexGuid = 'db851322f6674a6da3e84e9953db2ffd';

List<int> _package(String guid, String name) => testPackage(
  manifest: {
    'guid': guid,
    'name': name,
    'description': 'A test package',
    'version': '1.0.0',
    'icon': null,
  },
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb_dapp_sideload_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  DappStoreController controller([
    List<DappCatalogueEntry> catalogue = dappBundledCatalogue,
  ]) => DappStoreController(
    installer: DappInstaller(root.path),
    fetcher: DappPackageFetcher(
      (_) async => (status: 404, body: const <int>[]),
    ),
    catalogue: catalogue,
  );

  Future<String> write(List<int> bytes) async {
    final f = File('${root.path}/picked.dapp');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  test('a file using a bundled dApp\'s guid is refused', () async {
    final c = controller();
    final path = await write(_package(_dexGuid, 'Beam DEX'));
    await expectLater(
      c.readFile(path),
      throwsA(
        isA<DappInstallException>()
            .having((e) => e.error, 'error', DappInstallError.reservedGuid)
            .having((e) => e.dappName, 'dappName', 'Beam DEX'),
      ),
    );
    final text = dappInstallErrorText(
      const DappInstallException(
        DappInstallError.reservedGuid,
        'x',
        dappName: 'Beam DEX',
      ),
      name: 'this dApp',
    );
    expect(text, contains('claims to be Beam DEX'));
    expect(text, contains('Install Beam DEX from the Available list'));
  });

  test('installPackage refuses it too, and nothing is installed', () async {
    final c = controller();
    final package = DappPackage.read(_package(_dexGuid, 'Beam DEX'));
    await expectLater(
      c.installPackage(package),
      throwsA(isA<DappInstallException>()),
    );
    expect(await DappInstaller(root.path).list(), isEmpty);
  });

  test('the bundled package itself, byte for byte, is accepted', () async {
    final bytes = _package(_dexGuid, 'Beam DEX');
    final dex = dappBundledCatalogue.firstWhere((e) => e.guid == _dexGuid);
    final c = controller([
      DappCatalogueEntry(
        fileName: dex.fileName,
        name: dex.name,
        guid: dex.guid,
        version: dex.version,
        apiVersion: dex.apiVersion,
        minApiVersion: dex.minApiVersion,
        sha256: crypto.sha256.convert(bytes).toString(),
        size: bytes.length,
        connectsInWebShape: dex.connectsInWebShape,
      ),
    ]);
    final package = await c.readFile(await write(bytes));
    expect(package.manifest.guid, _dexGuid);
  });

  test('a different app with a bundled dApp\'s name is flagged', () async {
    final c = controller();
    final package = await c.readFile(
      await write(_package('f00dfeedf00dfeedf00dfeedf00dfeed', 'beam dex')),
    );
    expect(c.bundledNameCopiedBy(package), 'Beam DEX');
    final own = await c.readFile(
      await write(_package('f00dfeedf00dfeedf00dfeedf00dfeed', 'My Tools')),
    );
    expect(c.bundledNameCopiedBy(own), isNull);
  });
}
