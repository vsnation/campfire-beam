/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// B-DAPP-STRIP: a running dApp whose wallet core cannot answer yet. Seen in
// the DMG test: Beam DEX sat on its own splash while the wallet caught up.
// The line above the dApp now says, in plain words, what the wallet is
// doing, what it means for the dApp and what happens next; it goes by
// itself the moment the wallet says it can answer (the wallet's own change
// events: no timer polls it); "Try again" only where waiting may not be
// enough.
//
//   scripts/beam/host_test.sh --no-analyze --update-goldens --copy-goldens \
//       test/beam/dapps_ui/dapp_wallet_wait_test.dart

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_browser_view.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_manifest.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_wallet_link.dart';

import 'dapp_store_view_test.dart' show dexGuid, hostFor, link;
import 'dapp_ui_harness.dart';

const _strip = Key('dappWalletNotReady');
const _retry = Key('dappWalletRetry');

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb_dapp_wait_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  DappInstallation dex() => DappInstallation(
    manifest: const DappManifest(
      guid: dexGuid,
      name: 'Beam DEX',
      description: 'AMM based decentralized exchange',
      startPath: 'app/index.html',
      version: '1.0.0',
    ),
    apiVersion: DappApiVersion.v7_0,
    packageSha256: '00' * 32,
    // Not on disk: the page stays on "Opening…" in a widget test.
    directory: '${root.path}/dapps/$dexGuid/1.0.0',
    installedAt: DateTime.utc(2026, 10, 8),
  );

  Future<FakeWalletLink> open(
    WidgetTester tester, {
    required DappWalletWait? wait,
    required bool desktop,
  }) async {
    await loadCampfireFonts(tester);
    setSurface(
      tester,
      desktop ? const Size(1055, 772) : const Size(375, 812),
    );
    final l = link(root)..wait = wait;
    await tester.pumpWidget(
      campfireApp(
        home: DappBrowserView(
          host: hostFor(l),
          installation: dex(),
          desktop: desktop,
          webviewAvailable: true,
        ),
      ),
    );
    await tester.pump();
    return l;
  }

  testWidgets('phone, catching up: what it means for the dApp, how long, '
      'and that it goes by itself; then it does', (tester) async {
    final l = await open(
      tester,
      wait: const DappWalletWait(
        DappWalletWaitKind.catchingUp,
        timeLeft: Duration(minutes: 3),
      ),
      desktop: false,
    );
    expect(find.byKey(_strip), findsOneWidget);
    expect(
      find.text(
        "Your wallet is catching up — Beam DEX may not load until it's "
        'done.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        "About 3 minutes left. This goes away by itself when it's done.",
      ),
      findsOneWidget,
    );
    // Waiting is the fix: nothing to press.
    expect(find.byKey(_retry), findsNothing);
    // No jargon from the sync verdicts (blocks, nodes, "sending").
    expect(find.textContaining('block'), findsNothing);
    expect(find.textContaining('Sending'), findsNothing);
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/browser_wallet_catching_up_mobile.png'),
    );

    // The time left follows the wallet.
    l.setWait(
      const DappWalletWait(
        DappWalletWaitKind.catchingUp,
        timeLeft: Duration(seconds: 20),
      ),
    );
    await tester.pump();
    expect(
      find.text(
        "Less than a minute left. This goes away by itself when it's done.",
      ),
      findsOneWidget,
    );

    // Driven by the wallet's own changes, not by a timer: a state nobody
    // announced is not picked up, however long the screen stays open...
    l.wait = null;
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(_strip), findsOneWidget);
    // ...and the announced one is, at once.
    l.setWait(null);
    await tester.pump();
    expect(find.byKey(_strip), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone, still connecting: "a few seconds", goes by itself', (
    tester,
  ) async {
    final l = await open(
      tester,
      wait: const DappWalletWait(DappWalletWaitKind.connecting),
      desktop: false,
    );
    expect(
      find.text(
        "Your wallet is still connecting — Beam DEX may not load until "
        "it's connected.",
      ),
      findsOneWidget,
    );
    expect(
      find.text('This goes away by itself, usually within a few seconds.'),
      findsOneWidget,
    );
    expect(find.byKey(_retry), findsNothing);
    l.setWait(null);
    await tester.pump();
    expect(find.byKey(_strip), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('desktop, no network: says so, that the wallet keeps trying, '
      'and offers Try again', (tester) async {
    final l = await open(
      tester,
      wait: const DappWalletWait(DappWalletWaitKind.unreachable),
      desktop: true,
    );
    expect(
      find.text(
        "Your wallet can't reach the network — Beam DEX can't load until "
        'it does.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        'It keeps trying on its own, and this goes away once it connects.',
      ),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/browser_wallet_unreachable_desktop.png'),
    );
    await tester.tap(find.byKey(_retry));
    await tester.pump();
    expect(l.retries, 1);
    // A reconnect that works is announced like any other change.
    l.setWait(null);
    await tester.pump();
    expect(find.byKey(_strip), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stopped updating: old numbers, where to look, Try again', (
    tester,
  ) async {
    await open(
      tester,
      wait: const DappWalletWait(DappWalletWaitKind.stuck),
      desktop: false,
    );
    expect(
      find.text(
        'Your wallet has stopped updating — Beam DEX may show old numbers.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        "Your wallet's page says why and what to do. This goes away once "
        'it updates again.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(_retry), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a ready wallet: no line at all', (tester) async {
    await open(tester, wait: null, desktop: false);
    expect(find.byKey(_strip), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
