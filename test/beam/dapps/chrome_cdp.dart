/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Just enough of the Chrome DevTools protocol to load a dApp in headless
// Chrome, wire its native channel to Dart, and look at the result. Shared by
// the opt-in real-browser tests (bundled_dapps_chrome_test.dart,
// bundled_dapps_look_test.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';

/// Headless Chrome over one flat DevTools session.
class ChromeCdp {
  ChromeCdp._(this._ws, this._profile, this._proc) {
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

  static Future<ChromeCdp> launch(String chrome) async {
    final profile = await Directory.systemTemp.createTemp('cfb-chrome-');
    final proc = await Process.start(chrome, [
      '--headless=new',
      '--remote-debugging-port=0',
      '--user-data-dir=${profile.path}',
      '--no-first-run',
      '--no-default-browser-check',
      // Same pixels on every machine: no GPU, no font hinting differences
      // from a display's scale.
      '--disable-gpu',
      '--force-device-scale-factor=1',
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
    final cdp = ChromeCdp._(ws, profile, proc);
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

  /// Evaluates [expression] in the page and returns its JSON value.
  Future<Object?> evaluate(String expression) async {
    final r = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
    });
    return ((r['result']! as Map)['result']! as Map)['value'];
  }

  /// A PNG of the viewport.
  Future<Uint8List> screenshot() async {
    final r = await send('Page.captureScreenshot', {'format': 'png'});
    return base64Decode((r['result']! as Map)['data']! as String);
  }

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

/// The user agent that selects each bridge shape in Chrome.
const Map<DappBridgeShape, String> chromeUserAgents = {
  DappBridgeShape.qt: '$_mac ${DappBridgeShape.qtUserAgentToken}',
  DappBridgeShape.mobile:
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/154.0.0.0 Mobile Safari/537.36',
  DappBridgeShape.web: _mac,
};
