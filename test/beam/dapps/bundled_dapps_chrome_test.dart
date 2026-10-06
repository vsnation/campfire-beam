/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The 9 bundled dApps, unmodified, in a real browser: each is installed,
// served by DappServer (CSP + injected bridge) and opened in headless
// Chrome. The page's native channel is wired through the DevTools protocol
// to DappBridge -> DappSession -> FakeTransport, so every wallet call the
// page makes goes through the real gate and sanitizer. Nothing touches a
// wallet or the network.
//
// Opt-in, because it needs Chrome and the fetched packages:
//
//   test/beam/dapps/tool/fetch_bundled_dapps.sh
//   export CFB_DAPP_CHROME=<path to the Chrome executable>
//   flutter test test/beam/dapps/bundled_dapps_chrome_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_server.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

class _Reject implements DappConsentPolicy {
  @override
  Future<bool> approve(DappConsentRequest request) async => false;
}

/// Just enough of the Chrome DevTools protocol, over one flat session.
class _Cdp {
  _Cdp._(this._ws, this._profile, this._proc) {
    _ws.listen((raw) {
      final m = (jsonDecode(raw as String) as Map).cast<String, Object?>();
      final id = m['id'];
      if (id is int) {
        _pending.remove(id)?.complete(m);
      } else {
        _events.add(m);
      }
    });
  }

  final WebSocket _ws;
  final Directory _profile;
  final Process _proc;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();
  int _next = 0;
  String? session;

  Stream<Map<String, Object?>> get events => _events.stream;

  static Future<_Cdp> launch(String chrome) async {
    final profile = await Directory.systemTemp.createTemp('cfb-chrome-');
    final proc = await Process.start(chrome, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      '--no-first-run',
      '--no-default-browser-check',
      'about:blank',
    ]);
    unawaited(proc.stdout.drain<void>());
    unawaited(proc.stderr.drain<void>());
    final portFile = File(p.join(profile.path, 'DevToolsActivePort'));
    for (var i = 0; i < 100 && !portFile.existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final lines = portFile.readAsLinesSync();
    final ws = await WebSocket.connect('ws://127.0.0.1:${lines[0]}${lines[1]}');
    final cdp = _Cdp._(ws, profile, proc);
    final target = await cdp._send('Target.createTarget', {
      'url': 'about:blank',
    }, browser: true);
    final attached = await cdp._send('Target.attachToTarget', {
      'targetId': (target['result']! as Map)['targetId'],
      'flatten': true,
    }, browser: true);
    cdp.session = (attached['result']! as Map)['sessionId']! as String;
    return cdp;
  }

  Future<Map<String, Object?>> send(
    String method, [
    Map<String, Object?> params = const {},
  ]) => _send(method, params, browser: false);

  Future<Map<String, Object?>> _send(
    String method,
    Map<String, Object?> params, {
    required bool browser,
  }) {
    final id = ++_next;
    final c = Completer<Map<String, Object?>>();
    _pending[id] = c;
    _ws.add(
      jsonEncode({
        'id': id,
        'method': method,
        'params': params,
        if (!browser && session != null) 'sessionId': session,
      }),
    );
    return c.future.timeout(const Duration(seconds: 60));
  }

  /// Sends without waiting for the answer (results into the page).
  void fire(String method, Map<String, Object?> params) => _ws.add(
    jsonEncode({
      'id': ++_next,
      'method': method,
      'params': params,
      'sessionId': session,
    }),
  );

  Future<void> close() async {
    await _ws.close();
    _proc.kill();
    await _proc.exitCode;
    try {
      await _profile.delete(recursive: true);
    } catch (_) {}
  }
}

const _mac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36';
const _userAgents = {
  DappBridgeShape.qt: '$_mac ${DappBridgeShape.qtUserAgentToken}',
  DappBridgeShape.mobile:
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36',
  DappBridgeShape.web: _mac,
};

void main() {
  final chrome = Platform.environment['CFB_DAPP_CHROME'];
  final cache =
      Platform.environment['CFB_DAPP_PACKAGES'] ??
      p.join(Platform.environment['HOME'] ?? '', '.cache/campfire-beam/dapps');
  final pools = File('test/beam/contracts/dex/fixtures/pools_view.json')
      .readAsStringSync();

  for (final entry in dappBundledCatalogue) {
    for (final shape in DappBridgeShape.values) {
      final file = File(p.join(cache, entry.fileName));
      final expectConnect =
          shape != DappBridgeShape.web || entry.connectsInWebShape;
      test(
        '${entry.fileName} (${shape.name} shape) '
        '${expectConnect ? 'reaches the wallet' : 'does not connect'}',
        () async {
          final pkg = DappPackage.read(file.readAsBytesSync());
          final tmp = await Directory.systemTemp.createTemp('cfb-chr-');
          final cdp = await _Cdp.launch(chrome!);
          DappServer? server;
          try {
            final inst = await DappInstaller(tmp.path).install(pkg);
            final token = DappBridge.newToken();
            server = await DappServer.start(
              inst,
              bridgeToken: token,
              csp: entry.csp,
            );
            final t = FakeTransport({
              'get_version': {'api_version': '7.4'},
              'ev_subunsub': true,
              'invoke_contract': jsonDecode(pools),
            });
            final session = DappSession(
              identity: DappIdentity.fromManifest(pkg.manifest, server.origin),
              apiVersion: pkg.apiVersion,
              transport: t,
              consent: DappConsentQueue(_Reject()),
            );
            final bridge = DappBridge(
              session: session,
              token: token,
              evaluate: (js) async =>
                  cdp.fire('Runtime.evaluate', {'expression': js}),
            );
            final violations = <String>[];
            var handshakes = 0;
            cdp.events.listen((m) {
              final params = (m['params'] as Map?) ?? const {};
              if (m['method'] == 'Runtime.bindingCalled') {
                final payload = params['payload']! as String;
                if ((jsonDecode(payload) as Map)['type'] == 'hello') {
                  handshakes++;
                }
                unawaited(bridge.onMessage(payload));
              } else if (m['method'] == 'Log.entryAdded') {
                final e = params['entry']! as Map;
                if (e['source'] == 'security') violations.add('${e['text']}');
              }
            });
            await cdp.send('Runtime.enable');
            await cdp.send('Log.enable');
            await cdp.send('Page.enable');
            await cdp.send('Emulation.setUserAgentOverride', {
              'userAgent': _userAgents[shape],
            });
            // Stands in for the webview's JavaScript channel.
            await cdp.send('Runtime.addBinding', {'name': '__cdpPost'});
            await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
              'source':
                  'window.$dappBridgeChannelName='
                  '{postMessage:function(m){__cdpPost(m)}};',
            });
            await cdp.send('Page.navigate', {
              'url': server.startUri.toString(),
            });
            for (var i = 0; i < 120; i++) {
              if (t.callsTo('invoke_contract').isNotEmpty) break;
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            await Future<void>.delayed(const Duration(seconds: 1));

            final shaders = {
              for (final f in pkg.files)
                if (f.path.endsWith('.wasm') && !f.path.contains('wasm-client'))
                  f.bytes.length,
            };
            final calls = t.callsTo('invoke_contract');
            if (expectConnect) {
              expect(calls, isNotEmpty);
              for (final c in calls) {
                expect(c.params['create_tx'], isFalse);
                expect(c.params.containsKey('contract_file'), isFalse);
                // The page passes its own app shader (bans in the web
                // shape sends its first view without one).
                final contract = c.params['contract'];
                if (contract is List) {
                  expect(shaders, contains(contract.length));
                }
              }
            } else {
              expect(t.calls, isEmpty);
              expect(handshakes, 0);
            }
            // Our CSP blocks nothing these packages need. Known: bans'
            // loader SVG animation script, and (web shape) a script it
            // asks for that its package does not contain.
            final unexpected = violations.where(
              (v) =>
                  !(entry.fileName == 'bans.dapp' &&
                      (v.contains('Executing inline script') ||
                          v.contains('wasm-client.js'))),
            );
            expect(unexpected, isEmpty);
            await bridge.close();
            await session.close();
          } finally {
            await cdp.close();
            await server?.close();
            await tmp.delete(recursive: true);
          }
        },
        timeout: const Timeout(Duration(minutes: 2)),
        skip: chrome == null
            ? 'set CFB_DAPP_CHROME to a Chrome executable'
            : !file.existsSync()
            ? 'not fetched: run test/beam/dapps/tool/fetch_bundled_dapps.sh'
            : false,
      );
    }
  }
}
