/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A dApp installed from a .dapp file, unmodified, in a real browser: the
// BEAM Explorer package (one inline script with inline handlers; it reads
// the chain from https://explorer.0xmx.net). It is installed, served by
// DappHostSession under the file policy (eval and inline scripts, no
// server) and opened in headless Chrome, whose native channel is wired to
// the session through the DevTools protocol, as in
// test/beam/dapps/bundled_dapps_chrome_test.dart.
//
// 1. The session alone: the inline script runs, the page's request to
//    explorer.0xmx.net is refused and reported, Allow lets the reloaded page
//    reach it (and show the chain's height, when the network is there),
//    Remove access refuses it again.
// 2. The dApp page itself (DappBrowserView) with Chrome as its window: the
//    prompt "Let BEAM Explorer connect to explorer.0xmx.net?" comes up from
//    that real refusal, and Allow reloads the page with the server allowed.
//
// Opt-in, because it needs Chrome and the package (not in the repository):
//
//   export CFB_DAPP_CHROME=<path to the Chrome executable>
//   export CFB_EXPLORER_DAPP=<path to beam-explorer.dapp>
//     (default: ~/beam-campfire-test/fixtures/beam-explorer.dapp)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/pages/beam/dapps/dapp_browser_view.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_host_session.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_network_sheets.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_webview.dart';

import '../dapps/chrome_cdp.dart';
import '../dapps/dapp_session_fixtures.dart';
import 'dapp_store_view_test.dart' show hostFor;
import 'dapp_ui_harness.dart';

const _explorer = 'https://explorer.0xmx.net';

/// Chrome wired to [session] as the webview glue wires a webview: the
/// channel to the session, a page session per load, the Qt user agent.
Future<ChromeCdp> _openIn(
  String chrome,
  DappHostSession session, {
  required List<String> security,
}) async {
  final cdp = await ChromeCdp.launch(chrome);
  cdp.events.listen((m) {
    final params = (m['params'] as Map?) ?? const {};
    if (m['method'] == 'Runtime.bindingCalled') {
      unawaited(session.onMessage(params['payload']! as String));
    } else if (m['method'] == 'Log.entryAdded') {
      final e = params['entry']! as Map;
      if (e['source'] == 'security') security.add('${e['text']}');
    }
  });
  await cdp.send('Runtime.enable');
  await cdp.send('Log.enable');
  await cdp.send('Page.enable');
  await cdp.send('Emulation.setUserAgentOverride', {
    'userAgent': chromeUserAgents[DappBridgeShape.qt],
  });
  // Stands in for the webview's JavaScript channel.
  await cdp.send('Runtime.addBinding', {'name': '__cdpPost'});
  await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
    'source':
        'window.$dappBridgeChannelName='
        '{postMessage:function(m){__cdpPost(m)}};',
  });
  return cdp;
}

void _pageStarted(DappHostSession s, ChromeCdp cdp) => s.pageStarted(
  s.startUri.toString(),
  (js) async => cdp.fire('Runtime.evaluate', {'expression': js}),
);

/// The real client (flutter_test answers every request of its own with 400
/// once a widget test is in the file).
class _RealHttp extends HttpOverrides {}

/// The chain height explorer.0xmx.net reports now, or null offline.
Future<int?> _explorerHeight() async {
  final client = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp())
    ..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse('$_explorer/api/status'));
    final res = await req.close().timeout(const Duration(seconds: 10));
    final json = jsonDecode(await utf8.decodeStream(res)) as Map;
    return json['height'] as int?;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

void main() {
  final chrome = Platform.environment['CFB_DAPP_CHROME'];
  final packagePath =
      Platform.environment['CFB_EXPLORER_DAPP'] ??
      p.join(
        Platform.environment['HOME'] ?? '',
        'beam-campfire-test/fixtures/beam-explorer.dapp',
      );
  final skip = chrome == null
      ? 'set CFB_DAPP_CHROME to a Chrome executable'
      : !File(packagePath).existsSync()
      ? 'no BEAM Explorer package at $packagePath (CFB_EXPLORER_DAPP)'
      : false;

  test(
    'BEAM Explorer from a file: its inline script runs, explorer.0xmx.net is '
    'asked about, and once allowed the page reaches it',
    () async {
      final root = await Directory.systemTemp.createTemp('cfb-explorer-');
      final installer = DappInstaller(root.path);
      final installation = await installer.install(
        DappPackage.read(File(packagePath).readAsBytesSync()),
      );
      expect(installation.manifest.name, 'BEAM Explorer');
      final asked = <String>[];
      final session = await DappHostSession.start(
        installation: installation,
        installer: installer,
        wallet: FakeWalletLink(
          root: root.path,
          transport: FakeTransport({
            'get_version': {'api_version': '7.4'},
          }),
        ),
        consent: DappConsentQueue(ScriptedPolicy()),
        onAskToReach: asked.add,
      );
      final security = <String>[];
      final cdp = await _openIn(chrome!, session, security: security);
      Future<void> until(bool Function() done, {int seconds = 20}) async {
        for (var i = 0; i < seconds * 10 && !done(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      try {
        expect(session.fromFile, isTrue);
        _pageStarted(session, cdp);
        await cdp.send('Page.navigate', {'url': session.startUri.toString()});
        await until(() => asked.contains(_explorer));

        // The page's own inline script ran (the CSP allows it for a file)
        // and defined its functions; nothing inline was refused.
        expect(await cdp.evaluate('typeof showPage'), 'function');
        expect(await cdp.evaluate('typeof API_BASE'), 'string');
        expect(
          security.where(
            (v) =>
                v.contains('inline script') ||
                v.contains('inline event handler'),
          ),
          isEmpty,
        );
        // Its request to the explorer was refused, reported, and is the
        // server the person is asked about.
        expect(security.where((v) => v.contains(_explorer)), isNotEmpty);
        expect(asked, contains(_explorer));
        expect(await cdp.evaluate('currentBlockHeight'), 0);

        // Allow: saved, and the reloaded page may reach it.
        await session.allowOrigin(_explorer);
        expect(await installer.allowedOrigins(installation.guid), [_explorer]);
        security.clear();
        _pageStarted(session, cdp);
        await cdp.send('Page.reload');
        await until(() => false, seconds: 1);
        Object? height;
        for (var i = 0; i < 150; i++) {
          height = await cdp.evaluate(
            'typeof currentBlockHeight === "number" ? currentBlockHeight : 0',
          );
          if (height is int && height > 0) break;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(security.where((v) => v.contains(_explorer)), isEmpty);
        expect(asked.where((o) => o == _explorer), hasLength(1));
        final live = await _explorerHeight();
        if (live != null) {
          // The page read the chain from the server it was allowed.
          expect(height, isA<int>());
          expect(((height! as int) - live).abs(), lessThanOrEqualTo(3));
        } else {
          markTestSkipped('explorer.0xmx.net unreachable: height not compared');
        }

        // Remove access: refused again on the next load, and asked again.
        await session.revokeOrigin(_explorer);
        security.clear();
        _pageStarted(session, cdp);
        await cdp.send('Page.reload');
        await until(() => asked.where((o) => o == _explorer).length == 2);
        expect(security.where((v) => v.contains(_explorer)), isNotEmpty);
        expect(asked.where((o) => o == _explorer), hasLength(2));
      } finally {
        await cdp.close();
        await session.close();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip,
  );

  testWidgets(
    'BEAM Explorer from a file in the dApp page: the explorer.0xmx.net '
    'prompt comes up from its real refused request',
    timeout: const Timeout(Duration(minutes: 2)),
    skip: skip != false,
    (tester) async {
      await loadCampfireFonts(tester);
      setSurface(tester, const Size(1055, 772));
      late Directory root;
      late DappInstaller installer;
      late DappInstallation installation;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('cfb-explorer-ui-');
        installer = DappInstaller(root.path);
        installation = await installer.install(
          DappPackage.read(File(packagePath).readAsBytesSync()),
        );
      });
      final security = <String>[];
      final windows = <_ChromeWindow>[];
      await tester.pumpWidget(
        campfireApp(
          home: DappBrowserView(
            host: hostFor(
              FakeWalletLink(root: root.path, transport: FakeTransport({})),
            ),
            installation: installation,
            desktop: true,
            webviewAvailable: true,
            torOn: false,
            webviewFactory:
                ({
                  required session,
                  required background,
                  required onExternalLink,
                  onLoaded,
                  onLoadFailed,
                }) async {
                  final w = _ChromeWindow(session, onLoaded);
                  windows.add(w);
                  return w;
                },
          ),
        ),
      );

      /// Real time for Chrome and the server, then the test's clock.
      Future<void> settle(bool Function() done, {int seconds = 30}) async {
        for (var i = 0; i < seconds * 10 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      final title = find.text(
        'Let BEAM Explorer connect to explorer.0xmx.net?',
      );
      try {
        await settle(() => windows.isNotEmpty);
        expect(windows, hasLength(1));
        final w = windows.single;
        await tester.runAsync(() => w.open(chrome!, security: security));
        await settle(() => title.evaluate().isNotEmpty);
        expect(title, findsOneWidget);
        expect(find.byKey(DappBrowserView.moreKey), findsOneWidget);
        expect(security.where((v) => v.contains(_explorer)), isNotEmpty);

        await tester.tap(find.byKey(DappReachPrompt.allowKey));
        await settle(() => w.reloads == 1);
        expect(w.reloads, 1);
        expect(title, findsNothing);
        late List<String> saved;
        await tester.runAsync(() async {
          saved = await installer.allowedOrigins(installation.guid);
        });
        expect(saved, [_explorer]);
        security.clear();
        await settle(() => false, seconds: 3);
        expect(security.where((v) => v.contains(_explorer)), isEmpty);
        // Not asked about again once it is allowed.
        expect(title, findsNothing);
      } finally {
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          for (final w in windows) {
            await w.close();
          }
          await root.delete(recursive: true);
        });
      }
    },
  );
}

/// Headless Chrome as the dApp page's window ([DappWebviewFactory]).
class _ChromeWindow implements DappWebview {
  _ChromeWindow(this.session, this.onLoaded);

  final DappHostSession session;
  final void Function()? onLoaded;
  ChromeCdp? _cdp;
  int reloads = 0;

  Future<void> open(String chrome, {required List<String> security}) async {
    final cdp = await _openIn(chrome, session, security: security);
    _cdp = cdp;
    _pageStarted(session, cdp);
    // Not awaited: the server answers in the test's clock.
    cdp.fire('Page.navigate', {'url': session.startUri.toString()});
    onLoaded?.call();
  }

  @override
  Widget widget() => const SizedBox.expand();

  @override
  Future<void> reload() async {
    reloads++;
    final cdp = _cdp;
    if (cdp == null) return;
    _pageStarted(session, cdp);
    cdp.fire('Page.reload', const {});
    onLoaded?.call();
  }

  Future<void> close() async => _cdp?.close();
}
