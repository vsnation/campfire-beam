/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A dApp installed from a file reaches only the servers the person allowed
// for it. The dApp page in front of a real DappHostSession (real server,
// installer and bridge; a stand-in for the webview): its page is refused a
// server, Campfire asks "Let <dApp> connect to <host>?", Allow saves it and
// reloads, Not now holds until the dApp is closed, and More (⋯) lists the
// servers with Remove access. As goldens on a phone and a desktop.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/dapps/dapp_browser_view.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_host_session.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_network_sheets.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_webview.dart';

import '../dapps/dapp_test_zip.dart';
import 'dapp_store_view_test.dart' show hostFor;
import 'dapp_ui_harness.dart';

const _explorer = 'https://explorer.0xmx.net';
const _guid = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6';

/// Real I/O runs inside these: a hang fails the test instead of the run.
const _limit = Timeout(Duration(minutes: 1));

/// Stands in for the webview: each load starts a page session, as
/// `onPageStarted` does, and reports it has loaded.
class _Window implements DappWebview {
  _Window(this.session, this.onLoaded) {
    _load();
  }

  final DappHostSession session;
  final void Function()? onLoaded;
  int reloads = 0;

  void _load() {
    session.pageStarted('${session.origin}/app/index.html', (_) async {});
    onLoaded?.call();
  }

  @override
  Widget widget() => const SizedBox.expand(key: Key('dappPage'));

  @override
  Future<void> reload() async {
    reloads++;
    _load();
  }
}

void main() {
  late Directory root;
  late DappInstaller installer;
  late DappInstallation installation;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cfb_dapp_net_');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Lets real I/O (the server, the installer's files) finish, a little at
  /// a time, until [done].
  Future<void> settleReal(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The page's bridge token, from the page as served (over a raw socket:
  /// flutter_test answers every HttpClient request with 400). The server
  /// answers in the test's clock, so this pumps until it has.
  Future<String> tokenOf(WidgetTester tester, DappHostSession s) async {
    String? token;
    await tester.runAsync(() async {
      final port = s.server.port;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.write(
        'GET ${s.startUri.path} HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\nConnection: close\r\n\r\n',
      );
      final bytes = <int>[];
      unawaited(
        socket.listen(bytes.addAll).asFuture<void>().then((_) {
          socket.destroy();
          token = RegExp(r'/__campfire/([0-9a-f]+)/bridge\.js')
              .firstMatch(latin1.decode(bytes))!
              .group(1);
        }),
      );
    });
    await settleReal(tester, () => token != null);
    return token!;
  }

  /// The page tells the wallet a request to [origin] was refused, as the
  /// bridge script does on `securitypolicyviolation`. (In the test's clock,
  /// as the webview's channel delivers it on the UI thread.)
  Future<void> refuse(
    WidgetTester tester,
    DappHostSession s,
    String token,
    String origin,
  ) async {
    await s.onMessage(
      jsonEncode({
        'v': 1,
        'token': token,
        'type': 'blocked',
        'payload': {'origin': origin, 'directive': 'connect-src'},
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The BEAM Explorer page (its name and version, from a file) open on a
  /// phone or a desktop. Returns its window.
  Future<_Window> open(
    WidgetTester tester, {
    required bool desktop,
    List<String> allowed = const [],
    bool torOn = false,
  }) async {
    await loadCampfireFonts(tester);
    setSurface(tester, desktop ? const Size(1055, 772) : const Size(375, 812));
    await tester.runAsync(() async {
      installer = DappInstaller(root.path);
      installation = await installer.install(
        DappPackage.read(
          testPackage(
            manifest: {
              'guid': _guid,
              'name': 'BEAM Explorer',
              'version': '1.0.0',
              'icon': null,
            },
          ),
        ),
      );
      for (final o in allowed) {
        await installer.allowOrigin(_guid, o);
      }
    });
    final windows = <_Window>[];
    final l = FakeWalletLink(root: root.path, transport: FakeTransport({}));
    await tester.pumpWidget(
      campfireApp(
        home: DappBrowserView(
          host: hostFor(l),
          installation: installation,
          desktop: desktop,
          webviewAvailable: true,
          torOn: torOn,
          webviewFactory:
              ({
                required session,
                required background,
                required onExternalLink,
                onLoaded,
                onLoadFailed,
              }) async {
                final w = _Window(session, onLoaded);
                windows.add(w);
                return w;
              },
        ),
      ),
    );
    await settleReal(tester, () => windows.isNotEmpty);
    return windows.single;
  }

  Future<void> close(WidgetTester tester) async {
    // Toasts run out, then the page closes its server.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }

  final askTitle = find.text('Let BEAM Explorer connect to explorer.0xmx.net?');

  for (final desktop in [false, true]) {
    final size = desktop ? 'desktop' : 'mobile';

    testWidgets(
      '$size: a refused server is asked about by name; Allow '
      'saves it and reloads the dApp',
      timeout: _limit,
      (tester) async {
        final w = await open(tester, desktop: desktop);
        expect(find.byKey(DappBrowserView.moreKey), findsOneWidget);
        final token = await tokenOf(tester, w.session);
        await refuse(tester, w.session, token, _explorer);

        expect(askTitle, findsOneWidget);
        expect(
          find.text(
            'explorer.0xmx.net will see your IP address and everything BEAM '
            'Explorer asks it.',
          ),
          findsOneWidget,
        );
        // The words of the web wallet; "⋯" is drawn as the More icon.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is RichText &&
                w.text.toPlainText() ==
                    DappNetworkText.askDetail('BEAM Explorer')
                        .replaceAll('⋯', '\uFFFC'),
          ),
          findsOneWidget,
        );
        expect(
          DappNetworkText.askDetail('BEAM Explorer'),
          'Allow it only if you trust BEAM Explorer and that server: BEAM '
          'Campfire checked neither. BEAM Explorer could also tell the '
          'server what it can read from your wallet without asking, such '
          'as your balance. You can take this back in More (⋯) at any time.',
        );
        expect(find.text(DappNetworkText.torNote), findsNothing);
        expect(find.text('Allow'), findsOneWidget);
        expect(find.text('Not now'), findsOneWidget);
        await expectLater(
          find.byKey(const ValueKey('golden')),
          matchesGoldenFile('goldens/network_prompt_$size.png'),
        );

        await tester.runAsync(() async {
          await tester.tap(find.byKey(DappReachPrompt.allowKey));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await settleReal(tester, () => w.reloads == 1);
        expect(askTitle, findsNothing);
        expect(
          find.text(
            'BEAM Explorer can now reach explorer.0xmx.net. Reloading it…',
          ),
          findsOneWidget,
        );
        expect(w.session.allowedOrigins, [_explorer]);
        late List<String> saved;
        await tester.runAsync(() async {
          saved = await installer.allowedOrigins(_guid);
        });
        expect(saved, [_explorer]);
        await close(tester);
      },
    );
  }

  testWidgets(
    'Not now holds until the dApp is closed; several servers are '
    'asked about one at a time',
    timeout: _limit,
    (tester) async {
      final w = await open(tester, desktop: false);
      final token = await tokenOf(tester, w.session);
      await refuse(tester, w.session, token, _explorer);
      await refuse(tester, w.session, token, 'https://beamsmart.net:8000');
      // Never asked about: this device and the local network.
      await refuse(tester, w.session, token, 'https://localhost');
      await refuse(tester, w.session, token, 'https://192.168.1.10');
      expect(askTitle, findsOneWidget);

      await tester.tap(find.byKey(DappReachPrompt.notNowKey));
      await tester.pumpAndSettle();
      expect(
        find.text('Let BEAM Explorer connect to beamsmart.net:8000?'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(DappReachPrompt.notNowKey));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dappReachTitle')), findsNothing);

      // The page reloads and is refused again: not asked again.
      await w.reload();
      await refuse(tester, w.session, token, _explorer);
      expect(find.byKey(const Key('dappReachTitle')), findsNothing);
      expect(w.session.allowedOrigins, isEmpty);
      await close(tester);
    },
  );

  testWidgets(
    'with Tor on, the prompt says the dApp does not use it',
    timeout: _limit,
    (tester) async {
      final w = await open(tester, desktop: false, torOn: true);
      final token = await tokenOf(tester, w.session);
      await refuse(tester, w.session, token, _explorer);
      expect(askTitle, findsOneWidget);
      expect(find.text(DappNetworkText.torNote), findsOneWidget);
      await tester.tap(find.byKey(DappReachPrompt.notNowKey));
      await tester.pumpAndSettle();
      await close(tester);
    },
  );

  for (final desktop in [false, true]) {
    final size = desktop ? 'desktop' : 'mobile';

    testWidgets(
      '$size: More lists the servers; Remove access takes one '
      'back and reloads',
      timeout: _limit,
      (tester) async {
        final w = await open(
          tester,
          desktop: desktop,
          allowed: [_explorer, 'https://beamsmart.net:8000'],
        );
        expect(w.session.allowedOrigins, [
          _explorer,
          'https://beamsmart.net:8000',
        ]);
        await tester.tap(find.byKey(DappBrowserView.moreKey));
        await tester.pumpAndSettle();

        expect(find.text('Servers it can reach'), findsOneWidget);
        expect(
          find.text(
            'Version 1.0.0 · unknown publisher · installed from a file, not '
            'checked by BEAM Campfire.',
          ),
          findsOneWidget,
        );
        expect(find.text('explorer.0xmx.net'), findsOneWidget);
        expect(find.text('beamsmart.net:8000'), findsOneWidget);
        expect(
          find.text('Sees your IP address and what it is asked'),
          findsNWidgets(2),
        );
        expect(
          find.text('Remove access', findRichText: true),
          findsNWidgets(2),
        );
        await expectLater(
          find.byKey(const ValueKey('golden')),
          matchesGoldenFile('goldens/network_servers_$size.png'),
        );

        await tester.runAsync(() async {
          await tester.tap(find.byKey(DappServersSheet.removeKey(_explorer)));
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await settleReal(tester, () => w.reloads == 1);
        expect(
          find.text(
            'BEAM Explorer can no longer reach explorer.0xmx.net. '
            'Reloading it…',
          ),
          findsOneWidget,
        );
        expect(w.session.allowedOrigins, ['https://beamsmart.net:8000']);
        late List<String> saved;
        await tester.runAsync(() async {
          saved = await installer.allowedOrigins(_guid);
        });
        expect(saved, ['https://beamsmart.net:8000']);

        // Taken back: refused again, it is asked about again.
        final token = await tokenOf(tester, w.session);
        await refuse(tester, w.session, token, _explorer);
        expect(askTitle, findsOneWidget);
        await tester.tap(find.byKey(DappReachPrompt.notNowKey));
        await tester.pumpAndSettle();
        await close(tester);
      },
    );
  }

  testWidgets('More with no server yet says it asks first', timeout: _limit, (
    tester,
  ) async {
    final w = await open(tester, desktop: false);
    await tester.tap(find.byKey(DappBrowserView.moreKey));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'None. When BEAM Explorer tries to reach a server, BEAM Campfire '
        'asks you first.',
      ),
      findsOneWidget,
    );
    await expectLater(
      find.byKey(const ValueKey('golden')),
      matchesGoldenFile('goldens/network_servers_none_mobile.png'),
    );
    await tester.tap(find.byKey(DappServersSheet.reloadKey));
    await tester.pumpAndSettle();
    expect(w.reloads, 1);
    await close(tester);
  });
}
