/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The dApp page as it opens. Seen in the DMG (2026-10-07): Beam Asset Minter
// was a blank white page and Beam DEX its splash on white, because the
// dApps are drawn for the BEAM wallet's dark-blue page (white text) and
// Campfire showed its own light background, then the webview's white. Now
// the whole dApp area is the BEAM wallet's background from the first frame,
// "Opening <name>…" is on it, and the webview stays covered until the page
// has loaded.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_browser_view.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_manifest.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_avatar.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_surface.dart';

import 'dapp_store_view_test.dart' show dexGuid, hostFor, link;
import 'dapp_ui_harness.dart';

const _dappBlue = Color(0xff042548);

/// The colour of the golden boundary's pixel at [x], [y].
Future<Color> pixelAt(WidgetTester tester, int x, int y) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('golden')),
  );
  late Color c;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final i = (y * image.width + x) * 4;
    c = Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
    image.dispose();
  });
  return c;
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb_dapp_look_');
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
    // Not on disk: the page never gets past "Opening…" in a widget test.
    directory: '${root.path}/dapps/$dexGuid/1.0.0',
    installedAt: DateTime.utc(2026, 10, 7),
  );

  testWidgets('desktop (Campfire\'s dApp area at 1280x800): opening, on '
      'the BEAM wallet background', (tester) async {
    await loadCampfireFonts(tester);
    // 1280 - 225 (side menu) by 800 - 28 (title bar).
    setSurface(tester, const Size(1055, 772));
    await tester.pumpWidget(
      campfireApp(
        home: DappBrowserView(
          host: hostFor(link(root)),
          installation: dex(),
          desktop: true,
          webviewAvailable: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('dappOpening')), findsOneWidget);
    expect(find.text('Opening Beam DEX…'), findsOneWidget);
    expect(find.byType(DappSurface), findsWidgets);
    // Bottom corners of the dApp area: the wallet's blue, not Campfire's
    // light page.
    expect(await pixelAt(tester, 2, 769), _dappBlue);
    expect(await pixelAt(tester, 1052, 769), _dappBlue);
    // The top of the area continues the wallet's gradient: lighter blue.
    final top = await pixelAt(tester, 2, 83);
    expect(top, isNot(_dappBlue));
    expect(top.b, greaterThan(_dappBlue.b));

    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/browser_opening_desktop.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone: the BEAM wallet background reaches the bottom edge, '
      'under the "not up to date" note', (tester) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(375, 812));
    final l = link(root)..blocked = 'Catching up with the network.';
    await tester.pumpWidget(
      campfireApp(
        home: DappBrowserView(
          host: hostFor(l),
          installation: dex(),
          desktop: false,
          webviewAvailable: true,
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('dappWalletNotReady')), findsOneWidget);
    expect(find.text('Opening Beam DEX…'), findsOneWidget);
    expect(await pixelAt(tester, 2, 811), _dappBlue);
    expect(await pixelAt(tester, 372, 811), _dappBlue);

    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/browser_opening_mobile.png'),
    );
    await tester.pumpWidget(const SizedBox());
  });

  // (A missing bundled SVG is caught earlier: dapp_store_icons_test checks
  // every catalogue icon exists. flutter_svg's cache leaves a failed load's
  // error unhandled, so it cannot be exercised here.)
  testWidgets('a bundled picture that cannot load falls back to the letter', (
    tester,
  ) async {
    await loadCampfireFonts(tester);
    setSurface(tester, const Size(200, 100));
    await tester.pumpWidget(
      campfireApp(
        home: const Scaffold(
          body: DappAvatar(
            name: 'Nope',
            iconAsset: 'assets/beam/dapps/not-there.png',
          ),
        ),
      ),
    );
    await settleIcons(tester);
    expect(find.text('N'), findsOneWidget);
  });
}
