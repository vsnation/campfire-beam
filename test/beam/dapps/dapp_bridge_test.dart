/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import 'dapp_session_fixtures.dart';

/// The argument of `window.__campfireBeam.deliver(<string literal>)`.
String delivered(String script) {
  const head = 'window.__campfireBeam&&window.__campfireBeam.deliver(';
  expect(script, startsWith(head));
  expect(script, endsWith(');'));
  return jsonDecode(script.substring(head.length, script.length - 2)) as String;
}

void main() {
  group('native end', () {
    late FakeTransport t;
    late List<String> scripts;
    late DappBridge bridge;
    final token = DappBridge.newToken();

    setUp(() {
      t = FakeTransport({
        'get_version': {'api_version': '7.4'},
        'ev_subunsub': true,
      });
      scripts = [];
      bridge = DappBridge(
        session: testSession(t, ScriptedPolicy()),
        token: token,
        evaluate: (js) async => scripts.add(js),
      );
    });

    String envelope(String type, Object? payload, {String? tok, int v = 1}) =>
        jsonEncode({
          'v': v,
          'token': tok ?? token,
          'type': type,
          'payload': payload,
        });

    test('a request is answered into the page', () async {
      await bridge.onMessage(envelope('rpc', rq('call-1', 'get_version')));
      expect(decode(delivered(scripts.single)), {
        'jsonrpc': '2.0',
        'id': 'call-1',
        'result': {'api_version': '7.4'},
      });
    });

    test('messages without the token, or malformed, are dropped', () async {
      for (final m in [
        envelope('rpc', rq(1, 'get_version'), tok: DappBridge.newToken()),
        envelope('rpc', rq(1, 'get_version'), tok: token.substring(1)),
        envelope('rpc', rq(1, 'get_version'), v: 2),
        envelope('rpc', {'not': 'a string'}),
        envelope('other', rq(1, 'get_version')),
        jsonEncode({'token': token, 'type': 'rpc'}),
        'not json',
        '[]',
      ]) {
        await bridge.onMessage(m);
      }
      expect(scripts, isEmpty);
      expect(t.calls, isEmpty);
    });

    test('the handshake negotiates and answers', () async {
      await bridge.onMessage(
        envelope('hello', {'apiver': '7.0', 'apivermin': '7.0'}),
      );
      expect(scripts.last, contains('.handshake(true)'));
      expect(bridge.session.apiVersion, DappApiVersion.v7_0);
      await bridge.onMessage(
        envelope('hello', {'apiver': '9.0', 'apivermin': '8.0'}),
      );
      expect(scripts.last, contains('.handshake(false)'));
    });

    test('events reach the page; nothing after close', () async {
      await bridge.onMessage(
        envelope('rpc', rq(1, 'ev_subunsub', {'ev_system_state': true})),
      );
      t.emit('ev_system_state', {'current_height': 7});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(decode(delivered(scripts.last))['id'], 'ev_system_state');
      final n = scripts.length;
      await bridge.close();
      t.emit('ev_system_state', {'current_height': 8});
      await bridge.onMessage(envelope('rpc', rq(2, 'get_version')));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(scripts, hasLength(n));
    });

    test('delivery survives line separators and quotes', () {
      final tricky = 'a${String.fromCharCode(0x2028)}b"</script>\\';
      final js = DappBridge.deliverScript(tricky);
      expect(js.contains(String.fromCharCode(0x2028)), isFalse);
      expect(delivered(js), tricky);
    });
  });

  group('page end (bridge script run in Node with a stub DOM)', () {
    final hasNode = () {
      try {
        return Process.runSync('node', ['--version']).exitCode == 0;
      } catch (_) {
        return false;
      }
    }();

    test('mobile, Qt and web-extension shapes', () async {
      final dir = await Directory.systemTemp.createTemp('cfb-bridge-js-');
      try {
        final token = DappBridge.newToken();
        final script = File('${dir.path}/bridge.js')
          ..writeAsStringSync(dappBridgeScript(token: token));
        final harness = File('${dir.path}/harness.js')
          ..writeAsStringSync(_harness);
        final r = await Process.run('node', [harness.path, script.path]);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        final out = (jsonDecode(r.stdout as String) as Map)
            .cast<String, Object?>();

        final android = out['android']! as Map;
        expect(android['posted'], [
          {
            'v': 1,
            'token': token,
            'type': 'rpc',
            'payload': '{"jsonrpc":"2.0","id":1,"method":"get_version"}',
          },
        ]);
        expect(android['events'], ['{"id":1,"result":{}}']);

        final ios = out['ios']! as Map;
        expect(ios['callback'], ['{"id":2}']);
        expect(ios['events'], isEmpty);

        final qt = out['qt']! as Map;
        expect(qt['hasStyle'], isTrue);
        expect(qt['posted'], [
          {
            'v': 1,
            'token': token,
            'type': 'rpc',
            'payload': '{"jsonrpc":"2.0","id":"q","method":"tx_list"}',
          },
        ]);
        expect(qt['connected'], ['{"id":"q"}']);
        expect(qt['afterDisconnect'], isEmpty);
        expect(qt['events'], ['{"id":"after"}']);
        expect(qt['qrcSrc'], dappQwebchannelShimPath);
        expect(qt['otherSrc'], 'index.js');

        final web = out['web']! as Map;
        expect(web['hello'], {
          'v': 1,
          'token': token,
          'type': 'hello',
          'payload': {
            'apiver': '7.0',
            'apivermin': '6.0',
            'appname': 'Beam DEX',
          },
        });
        expect(web['beamApiBefore'], isFalse);
        expect(web['windowMessages'], contains('apiInjected'));
        expect(jsonDecode(web['call']! as String), {
          'jsonrpc': '2.0',
          'id': 'call-1',
          'method': 'tx_status',
          'params': {'txId': 'ab'},
        });
        expect(web['callback'], ['{"id":"call-1"}']);
        expect(web['events'], isEmpty);

        final rejected = out['rejected']! as Map;
        expect(rejected['windowMessages'], contains('rejected'));
        expect(rejected['beamApi'], isFalse);

        expect(out['idempotent'], isTrue);
        expect(out['frozen'], isTrue);
        expect(out['ignoresForeignMessages'], isTrue);
      } finally {
        await dir.delete(recursive: true);
      }
    }, skip: hasNode ? false : 'node is not installed');
  });
}

/// Loads the bridge into a fresh V8 context whose globals stand in for a
/// browser window, drives each shape the way the bundled dApps do
/// (`utils.js`, `BeamDappConnector.js`), and prints what happened as JSON.
const _harness = r'''
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const tick = () => new Promise((r) => setTimeout(r, 5));

function env(ua) {
  const posted = [];
  const events = [];
  const windowMessages = [];
  const listeners = {};
  const docListeners = {};
  class CustomEvent {
    constructor(type, init) {
      this.type = type;
      this.detail = init && init.detail;
    }
  }
  class HTMLScriptElement {}
  const store = new WeakMap();
  Object.defineProperty(HTMLScriptElement.prototype, 'src', {
    configurable: true, enumerable: true,
    get() { return store.get(this) || ''; },
    set(v) { store.set(this, String(v)); },
  });
  const document = {
    addEventListener(t, f) {
      (docListeners[t] = docListeners[t] || []).push(f);
    },
    dispatchEvent(e) {
      (docListeners[e.type] || []).forEach((f) => f(e));
      return true;
    },
  };
  document.addEventListener(
      'onCallWalletApiResult', (e) => events.push(e.detail));
  const w = {
    origin: 'http://127.0.0.1:40000',
    navigator: { userAgent: ua },
    document, CustomEvent, HTMLScriptElement, setTimeout,
    CampfireBeam: { postMessage(m) { posted.push(JSON.parse(m)); } },
    addEventListener(t, f) { (listeners[t] = listeners[t] || []).push(f); },
    postMessage(data, origin, source) {
      windowMessages.push(data);
      // In a page, ev.source is the window itself: the context's global.
      const ev = { data, origin: w.origin, source: source || inner };
      setTimeout(() => (listeners.message || []).forEach((f) => f(ev)), 0);
    },
  };
  w.window = w;
  vm.createContext(w);
  const inner = vm.runInContext('this', w);
  vm.runInContext(src, w);
  return { w, posted, events, windowMessages, HTMLScriptElement };
}

(async () => {
  const out = {};

  // Android: request as a string, result as a document event.
  {
    const e = env('Mozilla/5.0 (Linux; Android 14) Mobile');
    e.w.BEAM.callWalletApi('{"jsonrpc":"2.0","id":1,"method":"get_version"}');
    e.w.__campfireBeam.deliver('{"id":1,"result":{}}');
    out.android = { posted: e.posted, events: e.events };
  }

  // iPhone: result through the registered callback, no event.
  {
    const e = env('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)');
    const got = [];
    e.w.BEAM.callWalletApiResult((j) => got.push(j));
    e.w.__campfireBeam.deliver('{"id":2}');
    out.ios = { callback: got, events: e.events };
  }

  // Qt: qwebchannel.js script, QWebChannel, connect/disconnect.
  {
    const e = env('Mozilla/5.0 QtWebEngine/6.11.1 BEAM/7.5');
    const s = new e.HTMLScriptElement();
    s.src = 'qrc:///qtwebchannel/qwebchannel.js';
    const s2 = new e.HTMLScriptElement();
    s2.src = 'index.js';
    const channel = await new Promise((r) =>
      new e.w.QWebChannel(e.w.qt.webChannelTransport, r));
    const api = channel.objects.BEAM.api;
    const got = [];
    const f = (j) => got.push(j);
    api.callWalletApiResult.connect(f);
    api.callWalletApi('{"jsonrpc":"2.0","id":"q","method":"tx_list"}');
    e.w.__campfireBeam.deliver('{"id":"q"}');
    api.callWalletApiResult.disconnect(f);
    // With no listener left, delivery falls back to the document event.
    e.w.__campfireBeam.deliver('{"id":"after"}');
    out.qt = {
      hasStyle: typeof channel.objects.BEAM.style.content_main === 'string',
      posted: e.posted, connected: got, afterDisconnect: got.slice(1),
      events: e.events, qrcSrc: s.src, otherSrc: s2.src,
    };
  }

  // Web extension: create_beam_api handshake, then BeamApi.
  {
    const e = env('Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15');
    e.w.postMessage({ type: 'create_beam_api', apiver: '7.0', apivermin: '6.0',
      appname: 'Beam DEX', is_reconnect: false }, e.w.origin);
    await tick();
    const hello = e.posted[0];
    const before = !!e.w.BeamApi;
    e.w.__campfireBeam.handshake(true);
    const got = [];
    await e.w.BeamApi.callWalletApiResult((j) => got.push(j));
    e.w.BeamApi.callWalletApi('call-1', 'tx_status', { txId: 'ab' });
    e.w.__campfireBeam.deliver('{"id":"call-1"}');
    out.web = {
      hello, beamApiBefore: before, windowMessages: e.windowMessages,
      call: e.posted[1].payload, callback: got, events: e.events,
    };
  }

  // Web extension refused.
  {
    const e = env('Mozilla/5.0 (Windows NT 10.0)');
    e.w.__campfireBeam.handshake(false);
    out.rejected = { windowMessages: e.windowMessages, beamApi: !!e.w.BeamApi };
  }

  // Loading twice changes nothing; the delivery object cannot be replaced.
  {
    const e = env('Mozilla/5.0 (Macintosh)');
    const first = e.w.__campfireBeam;
    vm.runInContext(src, e.w);
    out.idempotent = e.w.__campfireBeam === first;
    try { e.w.__campfireBeam = null; } catch (_) {}
    try { first.deliver = null; } catch (_) {}
    out.frozen = e.w.__campfireBeam === first &&
        typeof first.deliver === 'function';
  }

  // A create_beam_api posted by another window (a frame) is ignored.
  {
    const e = env('Mozilla/5.0 (Macintosh)');
    e.w.postMessage({ type: 'create_beam_api', apiver: '7.0' }, '*', {});
    await tick();
    out.ignoresForeignMessages = e.posted.length === 0;
  }

  process.stdout.write(JSON.stringify(out));
})().catch((err) => { console.error(err); process.exit(1); });
''';
