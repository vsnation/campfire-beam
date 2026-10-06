/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The dApp store (bundled catalogue + installed dApps, empty state) and
// the dApp page's "no dApp window on this platform" state, as goldens.

import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_manifest.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_host.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_package_fetcher.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_store_controller.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_browser_view.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_store_view.dart';

import '../dapps/dapp_test_zip.dart';
import 'dapp_ui_harness.dart';

const dexGuid = 'db851322f6674a6da3e84e9953db2ffd';
const ownGuid = 'f00dfeedf00dfeedf00dfeedf00dfeed';

/// The DEX entry of the real catalogue, pinned to [bytes] instead (the
/// real package is not in the repository).
DappCatalogueEntry pinnedTo(List<int> bytes) {
  final dex = dappBundledCatalogue.firstWhere((e) => e.guid == dexGuid);
  return DappCatalogueEntry(
    fileName: dex.fileName,
    name: dex.name,
    guid: dex.guid,
    version: dex.version,
    apiVersion: dex.apiVersion,
    minApiVersion: dex.minApiVersion,
    sha256: crypto.sha256.convert(bytes).toString(),
    size: bytes.length,
    connectsInWebShape: dex.connectsInWebShape,
  );
}

List<int> dexLookalikePackage() => testPackage(
  manifest: {
    'guid': dexGuid,
    'name': 'Beam DEX',
    'description': 'AMM based decentralized exchange for Confidential Assets',
    'version': '1.0.0',
    'icon': null,
  },
);

List<int> ownPackage() => testPackage(
  manifest: {
    'guid': ownGuid,
    'name': 'Fuddle Tools',
    'description': 'Word game helpers for the Fuddle contract',
    'version': '0.3.1',
    'publisher': 'a friend',
    'icon': null,
  },
);

FakeWalletLink link(Directory root) => FakeWalletLink(root: root.path);

DappHost hostFor(FakeWalletLink l) => DappHost(
  wallet: l,
  fetcher: DappPackageFetcher((_) async => (status: 404, body: const <int>[])),
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb_dapp_store_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<DappStoreController> controller(
    WidgetTester tester, {
    required bool installSome,
  }) async {
    final dexBytes = dexLookalikePackage();
    // With Beam DEX installed, its catalogue entry is pinned to the test
    // package (the real one is not in the repository); without, the real
    // catalogue is shown as is.
    final catalogue = installSome
        ? [
            pinnedTo(dexBytes),
            for (final e in dappBundledCatalogue)
              if (e.guid != dexGuid) e,
          ]
        : dappBundledCatalogue;
    final installer = DappInstaller(root.path);
    final c = DappStoreController(
      installer: installer,
      fetcher: DappPackageFetcher(
        (_) async => (status: 404, body: const <int>[]),
      ),
      catalogue: catalogue,
    );
    await tester.runAsync(() async {
      if (installSome) {
        await installer.install(DappPackage.read(dexBytes));
        await installer.install(DappPackage.read(ownPackage()));
      }
      await c.refresh();
    });
    return c;
  }

  Future<void> pumpStore(
    WidgetTester tester,
    DappStoreController c, {
    required bool desktop,
  }) async {
    final l = link(root);
    await tester.pumpWidget(
      campfireApp(
        home: DappStoreView(
          host: hostFor(l),
          controller: c,
          desktop: desktop,
          webviewAvailable: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('store: installed and bundled dApps (phone)', (tester) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(375, 812));
    final c = await controller(tester, installSome: true);
    await pumpStore(tester, c, desktop: false);

    expect(find.text('dApps'), findsOneWidget);
    expect(find.text('Installed'), findsOneWidget);
    expect(find.text('Beam DEX'), findsOneWidget);
    expect(
      find.text('Version 1.0.0 · the checked bundled package'),
      findsOneWidget,
    );
    expect(find.text('Fuddle Tools'), findsOneWidget);
    expect(
      find.text(
        'Version 0.3.1 · installed from a file, not checked by Campfire',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dappOpen_$dexGuid')), findsOneWidget);

    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/store_installed_and_bundled_mobile.png'),
    );
    c.dispose();
  });

  testWidgets('store: installed and bundled dApps (desktop)', (tester) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(1280, 1500));
    final c = await controller(tester, installSome: true);
    await pumpStore(tester, c, desktop: true);

    expect(find.text('Available'), findsOneWidget);
    for (final e in dappBundledCatalogue.where((e) => e.guid != dexGuid)) {
      expect(
        find.text(e.name, skipOffstage: false),
        findsOneWidget,
        reason: e.name,
      );
      expect(
        find.byKey(Key('dappInstall_${e.guid}'), skipOffstage: false),
        findsOneWidget,
      );
    }
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/store_installed_and_bundled_desktop.png'),
    );
    c.dispose();
  });

  testWidgets('store: nothing installed yet', (tester) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(375, 812));
    final c = await controller(tester, installSome: false);
    await pumpStore(tester, c, desktop: false);

    expect(find.text('No dApps installed yet'), findsOneWidget);
    expect(find.textContaining('Pick one under Available'), findsOneWidget);
    expect(find.text('Beam DEX'), findsOneWidget, reason: 'still on offer');
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/store_empty_mobile.png'),
    );
    c.dispose();
  });

  testWidgets('a dApp on a platform without the dApp window', (tester) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(375, 812));
    final installation = DappInstallation(
      manifest: const DappManifest(
        guid: dexGuid,
        name: 'Beam DEX',
        description: 'AMM based decentralized exchange',
        startPath: 'app/index.html',
        version: '1.0.0',
      ),
      apiVersion: DappApiVersion.v7_0,
      packageSha256: '00' * 32,
      directory: '${root.path}/dapps/$dexGuid/1.0.0',
      installedAt: DateTime.utc(2026, 10, 6),
    );
    final l = link(root);
    await tester.pumpWidget(
      campfireApp(
        home: DappBrowserView(
          host: hostFor(l),
          installation: installation,
          desktop: false,
          webviewAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text("Beam DEX can't open on this computer yet"),
      findsOneWidget,
    );
    expect(
      find.textContaining('Campfire opens dApps on macOS, Android and iOS.'),
      findsOneWidget,
    );
    expect(find.text('Back to dApps'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/browser_unavailable_mobile.png'),
    );
  });
}
