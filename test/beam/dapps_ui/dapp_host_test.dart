/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The host glue without a webview: the shared-connection adapter, the
// per-page session lifecycle behind a real DappServer, the user agent
// rule, the pinned-package fetcher and the store controller.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_errors.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_scope.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_server.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_host_session.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_package_fetcher.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_shared_transport.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_store_controller.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_watched_consent_queue.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../contracts/dex/dex_fixtures.dart';
import '../dapps/dapp_session_fixtures.dart';
import '../dapps/dapp_test_zip.dart';
import 'dapp_ui_harness.dart';

/// Forwards to whichever transport is current, like BeamWalletTransport.
class _Switching implements BeamTransport {
  _Switching(this.current);

  BeamTransport current;

  @override
  Future<void> connect() async {}

  @override
  bool get isConnected => current.isConnected;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) => current.call(method, params, timeout);

  @override
  Stream<BeamEvent> get events => current.events;

  @override
  Future<void> close() async {}
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

DappCatalogueEntry _entryFor(List<int> bytes, {String guid = testGuid}) =>
    DappCatalogueEntry(
      fileName: 'test.dapp',
      name: 'Test dApp',
      guid: guid,
      version: '1.2.3',
      apiVersion: '7.0',
      minApiVersion: '7.0',
      sha256: crypto.sha256.convert(bytes).toString(),
      size: bytes.length,
    );

void main() {
  const g = BigInt.from;

  group('DappSharedTransport', () {
    late FakeTransport core;

    setUp(() {
      core = FakeTransport({
        'wallet_status': {
          'current_height': 4068244,
          'current_state_hash': 'aa',
          'current_state_timestamp': 1700000000,
          'prev_state_hash': 'bb',
          'is_in_sync': true,
          'available': 123,
          'totals': <Object?>[],
        },
        'tx_list': [
          {'txId': txId(1)},
          {'txId': txId(2)},
        ],
        'get_version': {'api_version': '7.4'},
        'invoke_contract': (Map<String, Object?> p) => {
          'output': '{"ok":1}',
          'txid': '0' * 32,
          'raw_data': [1, 2, 3],
        },
      });
    });

    test('a page\'s subscriptions never reach the wallet\'s connection, '
        'and new ones get a snapshot', () async {
      final t = DappSharedTransport(core);
      final got = <BeamEvent>[];
      final sub = t.events.listen(got.add);
      final r = await t.call('ev_subunsub', {
        'ev_system_state': true,
        'ev_txs_changed': true,
      });
      expect(r, isTrue);
      expect(core.callsTo('ev_subunsub'), isEmpty);
      await _settle();
      final state = got.firstWhere((e) => e.name == 'ev_system_state');
      expect(state.data, {
        'current_height': 4068244,
        'current_state_hash': 'aa',
        'current_state_timestamp': 1700000000,
        'prev_state_hash': 'bb',
        'is_in_sync': true,
      }, reason: 'no balances in a dApp event');
      final txs = got.firstWhere((e) => e.name == 'ev_txs_changed');
      expect(txs.data['change_str'], 'reset');
      expect(txs.data['txs'], hasLength(2));

      // Unsubscribing is local too; the wallet's own events keep flowing.
      await t.call('ev_subunsub', {'ev_txs_changed': false});
      expect(t.subscribed, {'ev_system_state'});
      expect(core.callsTo('ev_subunsub'), isEmpty);
      core.emit('ev_txs_changed', {'change_str': 'added', 'txs': []});
      await _settle();
      expect(got.last.name, 'ev_txs_changed', reason: 'the session filters');

      await sub.cancel();
      await t.close();
      expect(core.isConnected, isTrue, reason: 'never closes the wallet');
      expect(await core.call('get_version'), {'api_version': '7.4'});
    });

    test('invoke_contract joins the wallet\'s shader lane and answers in '
        'the core\'s shape', () async {
      final gates = <Completer<Object?>>[];
      core.reply('invoke_contract', (Map<String, Object?> p) {
        final c = Completer<Object?>();
        gates.add(c);
        return c.future;
      });
      final api = BeamApi(core);
      final t = DappSharedTransport(core, api: api);
      final wallet = api.invokeContract(createTx: false, args: 'wallet=1');
      final dapp = t.call('invoke_contract', {
        'contract': [1, 2],
        'args': 'dapp=1',
        'create_tx': false,
      });
      await _settle();
      expect(core.callsTo('invoke_contract'), hasLength(1));
      gates[0].complete({'output': 'w', 'txid': '0' * 32});
      await wallet;
      await _settle();
      expect(core.callsTo('invoke_contract'), hasLength(2));
      expect(core.lastParams('invoke_contract'), {
        'contract': [1, 2],
        'args': 'dapp=1',
        'create_tx': false,
      });
      gates[1].complete({
        'output': 'd',
        'txid': '0' * 32,
        'raw_data': [9],
      });
      expect(await dapp, {
        'output': 'd',
        'txid': '0' * 32,
        'raw_data': [9],
      });
    });

    test('events follow the wallet across a node handover', () async {
      final second = FakeTransport({});
      final shared = _Switching(core);
      final t = DappSharedTransport(
        shared,
        resubscribeDelay: const Duration(milliseconds: 5),
      );
      final got = <String>[];
      final sub = t.events.listen((e) => got.add('${e.name}:${e.data['n']}'));
      core.emit('ev_system_state', {'n': 1});
      await _settle();
      shared.current = second;
      await core.close(); // the old connection's events end
      await _settle();
      second.emit('ev_system_state', {'n': 2});
      await _settle();
      expect(got, ['ev_system_state:1', 'ev_system_state:2']);
      await sub.cancel();
      await t.close();
    });
  });

  group('DappHostSession', () {
    late Directory root;
    late DappInstaller installer;
    late DappInstallation installation;
    late FakeTransport core;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cfb_dapp_host_');
      installer = DappInstaller(root.path);
      installation = await installer.install(DappPackage.read(testPackage()));
      core = FakeTransport({
        'get_version': {'api_version': '7.4'},
        'process_invoke_data': (Map<String, Object?> p) => {'txid': txId(1)},
      });
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<String> tokenOf(DappHostSession s) async {
      final client = HttpClient();
      try {
        final req = await client.getUrl(s.startUri);
        final res = await req.close();
        final html = await utf8.decodeStream(res);
        return RegExp(r'/__campfire/([0-9a-f]+)/bridge\.js')
            .firstMatch(html)!
            .group(1)!;
      } finally {
        client.close(force: true);
      }
    }

    String msg(String token, String payload) =>
        jsonEncode({'v': 1, 'token': token, 'type': 'rpc', 'payload': payload});

    test('serves the dApp on its own origin, keeps the port, and routes '
        'the page\'s bridge to a session per page load', () async {
      final link = FakeWalletLink(
        root: root.path,
        transport: DappSharedTransport(core),
      );
      final queue = DappWatchedConsentQueue(ScriptedPolicy());
      final s = await DappHostSession.start(
        installation: installation,
        installer: installer,
        wallet: link,
        consent: queue,
        scopeStore: InMemoryDappScopeStore(),
      );
      expect(s.origin, startsWith('http://127.0.0.1:'));
      expect(await installer.savedPort(testGuid), s.server.port);
      expect(s.isOwnUrl('${s.origin}/app/index.html'), isTrue);
      expect(s.isOwnUrl('http://127.0.0.1:1/app/index.html'), isFalse);
      expect(s.isOwnUrl('https://127.0.0.1:${s.server.port}/'), isFalse);
      expect(s.isOwnUrl('http://localhost:${s.server.port}/'), isFalse);
      expect(DappHostSession.bundledEntryFor(installation), isNull);

      final token = await tokenOf(s);
      final evaluated = <String>[];
      s.pageStarted('${s.origin}/app/index.html', (js) async {
        evaluated.add(js);
      });
      await s.onMessage(msg(token, rq(7, 'get_version')));
      expect(evaluated.single, contains('7.4'));
      expect(evaluated.single, startsWith('window.__campfireBeam'));

      // A message with another token is dropped without an answer.
      await s.onMessage(msg('ab' * 16, rq(8, 'get_version')));
      expect(evaluated, hasLength(1));
      await s.close();
    });

    test('a reload or close withdraws the page\'s approvals (-32021) and '
        'nothing executes', () async {
      final link = FakeWalletLink(
        root: root.path,
        transport: DappSharedTransport(core),
      );
      final policy = ScriptedPolicy();
      final queue = DappWatchedConsentQueue(policy);
      final s = await DappHostSession.start(
        installation: installation,
        installer: installer,
        wallet: link,
        consent: queue,
        scopeStore: InMemoryDappScopeStore(),
      );
      final token = await tokenOf(s);
      final evaluated = <String>[];
      s.pageStarted('${s.origin}/app/index.html', (js) async {
        evaluated.add(js);
      });
      final first = s.currentSession;
      final pending = s.onMessage(
        msg(
          token,
          rq(1, 'process_invoke_data', {'data': rawDataVector('trade_plain')}),
        ),
      );
      await policy.waitShown(1);
      expect(queue.pending.value, 1);

      // Reload: a new session, the old page's approval is withdrawn.
      s.pageStarted('${s.origin}/app/index.html', (js) async {
        evaluated.add(js);
      });
      expect(identical(s.currentSession, first), isFalse);
      await pending;
      expect(policy.shown.single.isCancelled, isTrue);
      expect(first!.isClosed, isTrue);
      // The old page is gone, so nothing is delivered to it.
      expect(evaluated, isEmpty);
      expect(core.callsTo('process_invoke_data'), isEmpty);
      await _settle();
      expect(queue.pending.value, 0);

      // A page from elsewhere gets no session at all.
      s.pageStarted('https://example.com/', (js) async {});
      expect(s.currentSession, isNull);

      final port = s.server.port;
      await s.close();
      await expectLater(
        Socket.connect('127.0.0.1', port),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('servers a dApp from a file may reach', () {
    late Directory root;
    late DappInstaller installer;
    late DappInstallation installation;
    const explorer = 'https://explorer.0xmx.net';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cfb_dapp_reach_');
      installer = DappInstaller(root.path);
      installation = await installer.install(DappPackage.read(testPackage()));
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    Future<({String csp, String token})> load(DappHostSession s) async {
      final client = HttpClient();
      try {
        final res = await (await client.getUrl(s.startUri)).close();
        final html = await utf8.decodeStream(res);
        return (
          csp: res.headers.value('content-security-policy')!,
          token: RegExp(r'/__campfire/([0-9a-f]+)/bridge\.js')
              .firstMatch(html)!
              .group(1)!,
        );
      } finally {
        client.close(force: true);
      }
    }

    String refused(String token, String origin, [String d = 'connect-src']) =>
        jsonEncode({
          'v': 1,
          'token': token,
          'type': 'blocked',
          'payload': {'origin': origin, 'directive': d},
        });

    Future<DappHostSession> start(
      List<String> asked, {
      List<DappCatalogueEntry> catalogue = dappBundledCatalogue,
      bool allowRemoteOrigins = false,
    }) => DappHostSession.start(
      installation: installation,
      installer: installer,
      wallet: FakeWalletLink(root: root.path, transport: FakeTransport({})),
      consent: DappWatchedConsentQueue(ScriptedPolicy()),
      scopeStore: InMemoryDappScopeStore(),
      onAskToReach: asked.add,
      catalogue: catalogue,
      allowRemoteOrigins: allowRemoteOrigins,
    );

    test('starts with inline scripts and no server; asks about each '
        'refused public https server once', () async {
      final asked = <String>[];
      final s = await start(asked);
      expect(s.fromFile, isTrue);
      final page = await load(s);
      expect(page.csp, const DappCsp.fromFile([]).header);
      expect(page.csp, contains("script-src 'self' 'unsafe-inline'"));
      s.pageStarted('${s.origin}/app/index.html', (_) async {});
      for (final o in [
        explorer,
        explorer,
        'https://img.example.com',
        // Never asked about: not a public https server.
        'https://localhost',
        'https://10.0.0.1',
        'https://printer.local',
        'http://explorer.0xmx.net',
        'https://explorer.0xmx.net:443',
        'https://*.0xmx.net',
      ]) {
        await s.onMessage(refused(page.token, o));
      }
      await s.onMessage(
        refused(page.token, 'https://img.example.com', 'img-src'),
      );
      expect(asked, [explorer, 'https://img.example.com']);

      // A reload does not ask again ("Not now" lasts until it is closed),
      // and no open dApp asks about more than 16 servers.
      s.pageStarted('${s.origin}/app/index.html', (_) async {});
      await s.onMessage(refused(page.token, explorer));
      for (var i = 0; i < 20; i++) {
        await s.onMessage(refused(page.token, 'https://h$i.example.com'));
      }
      expect(asked, hasLength(16));
      expect(asked.take(3), [
        explorer,
        'https://img.example.com',
        'https://h0.example.com',
      ]);
      await s.close();
      await s.onMessage(refused(page.token, 'https://late.example.com'));
      expect(asked, hasLength(16));
    });

    test('Allow saves it with the dApp and the next page load reaches it; '
        'Remove access takes it back', () async {
      final asked = <String>[];
      final s = await start(asked);
      var page = await load(s);
      s.pageStarted('${s.origin}/app/index.html', (_) async {});
      await s.onMessage(refused(page.token, explorer));
      expect(asked, [explorer]);

      await s.allowOrigin(explorer);
      expect(s.allowedOrigins, [explorer]);
      expect(await installer.allowedOrigins(testGuid), [explorer]);
      page = await load(s);
      expect(page.csp, const DappCsp.fromFile([explorer]).header);
      expect(page.csp, contains("connect-src 'self' $explorer;"));
      expect(page.csp, contains("img-src 'self' data: blob: $explorer;"));
      await s.close();

      // The next visit starts with it.
      final again = await start(asked);
      expect(again.allowedOrigins, [explorer]);
      expect(
        (await load(again)).csp,
        contains("connect-src 'self' $explorer;"),
      );

      await again.revokeOrigin(explorer);
      expect(again.allowedOrigins, isEmpty);
      expect(await installer.allowedOrigins(testGuid), isEmpty);
      page = await load(again);
      expect(page.csp, contains("connect-src 'self';"));
      // Taken back: it may ask again.
      again.pageStarted('${again.origin}/app/index.html', (_) async {});
      await again.onMessage(refused(page.token, explorer));
      expect(asked, [explorer, explorer]);
      await again.close();
    });

    test('a server that cannot be saved is not allowed, and may be asked '
        'about again', () async {
      final asked = <String>[];
      final s = await start(asked);
      final page = await load(s);
      s.pageStarted('${s.origin}/app/index.html', (_) async {});
      await s.onMessage(refused(page.token, explorer));
      await installer.uninstall(testGuid);
      await expectLater(s.allowOrigin(explorer), throwsA(isA<StateError>()));
      expect(s.allowedOrigins, isEmpty);
      expect(page.csp, contains("connect-src 'self';"));
      await s.onMessage(refused(page.token, explorer));
      expect(asked, [explorer, explorer]);
      await s.close();
    });

    test(
      "a bundled dApp is never asked: its servers are the catalogue's",
      () async {
        final bytes = testPackage();
        final entry = DappCatalogueEntry(
          fileName: 'test.dapp',
          name: 'Test dApp',
          guid: testGuid,
          version: '1.2.3',
          apiVersion: '7.0',
          minApiVersion: '7.0',
          sha256: crypto.sha256.convert(bytes).toString(),
          size: bytes.length,
          remoteOrigins: const ['https://api.coingecko.com'],
        );
        // Even with servers saved for its guid (it was a file once).
        await installer.allowOrigin(testGuid, explorer);
        final asked = <String>[];
        for (final remote in [false, true]) {
          final s = await start(
            asked,
            catalogue: [entry],
            allowRemoteOrigins: remote,
          );
          expect(s.fromFile, isFalse);
          expect(s.allowedOrigins, isEmpty);
          final page = await load(s);
          expect(
            page.csp.split('; ').firstWhere((d) => d.startsWith('script-src')),
            isNot(contains('unsafe-inline')),
          );
          expect(page.csp, isNot(contains('0xmx')));
          expect(
            page.csp,
            contains(
              remote
                  ? "connect-src 'self' https://api.coingecko.com;"
                  : "connect-src 'self';",
            ),
          );
          s.pageStarted('${s.origin}/app/index.html', (_) async {});
          await s.onMessage(refused(page.token, 'https://img.example.com'));
          await expectLater(s.allowOrigin(explorer), throwsStateError);
          await expectLater(s.revokeOrigin(explorer), throwsStateError);
          await s.close();
        }
        expect(asked, isEmpty);
      },
    );
  });

  group('user agent', () {
    test('phones keep the mobile shape; everything else gets Qt', () {
      const android =
          'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36';
      const iphone =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15';
      const mac =
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
          'AppleWebKit/605.1.15';
      expect(dappUserAgentFor(android).shape, DappBridgeShape.mobile);
      expect(dappUserAgentFor(android).userAgent, android);
      expect(dappUserAgentFor(iphone).shape, DappBridgeShape.mobile);
      final m = dappUserAgentFor(mac);
      expect(m.shape, DappBridgeShape.qt);
      expect(m.userAgent, '$mac ${DappBridgeShape.qtUserAgentToken}');
      expect(
        dappUserAgentFor(null).userAgent,
        'Mozilla/5.0 ${DappBridgeShape.qtUserAgentToken}',
      );
      expect(dappUserAgentFor(m.userAgent).userAgent, m.userAgent);
    });
  });

  group('DappPackageFetcher', () {
    final bytes = testPackage();
    final entry = _entryFor(bytes);

    test('installs only the pinned bytes', () async {
      Uri? asked;
      final f = DappPackageFetcher((url) async {
        asked = url;
        return (status: 200, body: bytes);
      });
      final p = await f.fetch(entry);
      expect(p.manifest.guid, testGuid);
      expect(asked.toString(), entry.url);
      expect(asked!.host, 'raw.githubusercontent.com');
    });

    Future<DappFetchFailure> failure(
      DappHttpGet get, [
      DappCatalogueEntry? e,
    ]) async {
      try {
        await DappPackageFetcher(get).fetch(e ?? entry);
      } on DappFetchException catch (x) {
        return x.failure;
      }
      fail('fetched');
    }

    test('refuses a different package, a wrong size, a server error and a '
        'broken connection', () async {
      final other = testPackage(manifest: {'version': '9.9.9'});
      expect(
        await failure((_) async => (status: 200, body: other)),
        DappFetchFailure.mismatch,
      );
      final padded = [...bytes, 0];
      expect(
        await failure((_) async => (status: 200, body: padded)),
        DappFetchFailure.mismatch,
      );
      expect(
        await failure((_) async => (status: 404, body: const <int>[])),
        DappFetchFailure.server,
      );
      expect(
        await failure(
          (_) async => throw const SocketException('no route to host'),
        ),
        DappFetchFailure.network,
      );
      // Same length, different bytes.
      final flipped = [...bytes]..[bytes.length - 1] ^= 1;
      expect(
        await failure((_) async => (status: 200, body: flipped)),
        DappFetchFailure.mismatch,
      );
    });
  });

  group('DappStoreController', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('cfb_dapp_ctl_');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('installs a bundled dApp by hash, refuses a tampered download, '
        'and uninstalls', () async {
      final bytes = testPackage();
      final entry = _entryFor(bytes);
      var serve = <int>[...bytes]..[100] ^= 0xff;
      final c = DappStoreController(
        installer: DappInstaller(root.path),
        fetcher: DappPackageFetcher((_) async => (status: 200, body: serve)),
        catalogue: [entry],
      );
      await c.refresh();
      expect(c.installed, isEmpty);
      expect(c.available.single.guid, testGuid);
      expect(c.available.single.downloadLabel, endsWith(' KB download'));

      await expectLater(
        c.installBundled(entry),
        throwsA(isA<DappFetchException>()),
      );
      expect(c.installed, isEmpty, reason: 'nothing from tampered bytes');
      expect(c.isBusy(testGuid), isFalse);

      serve = bytes;
      final inst = await c.installBundled(entry);
      expect(inst.packageSha256, entry.sha256);
      expect(c.installed.single.isPinned, isTrue);
      expect(c.available, isEmpty);

      await c.uninstall(testGuid);
      expect(c.installed, isEmpty);
      c.dispose();
    });

    test('a package from a file is shown as not checked', () async {
      final file = File('${root.path}/x.dapp')..writeAsBytesSync(testPackage());
      final c = DappStoreController(
        installer: DappInstaller('${root.path}/w'),
        fetcher: DappPackageFetcher(
          (_) async => (status: 404, body: const <int>[]),
        ),
        catalogue: const [],
      );
      await c.refresh();
      final p = await c.readFile(file.path);
      expect(c.existingFor(p), isNull);
      await c.installPackage(p);
      expect(c.installed.single.isPinned, isFalse);
      expect(c.existingFor(p), isNotNull);
      await expectLater(
        c.readFile('${root.path}/missing.dapp'),
        throwsA(isA<DappInstallException>()),
      );
      c.dispose();
    });

    test('error wording names the next step and never blames the user', () {
      final texts = [
        for (final f in DappFetchFailure.values)
          dappInstallErrorText(DappFetchException(f, 'x'), name: 'Beam DEX'),
        for (final e in DappInstallError.values)
          dappInstallErrorText(DappInstallException(e, 'x'), name: 'Beam DEX'),
        dappInstallErrorText(StateError('x'), name: 'Beam DEX'),
      ];
      for (final t in texts) {
        expect(t, isNot(contains('you did')));
        expect(t.toLowerCase(), isNot(contains('invalid')));
        expect(t.toLowerCase(), isNot(contains('error')));
        expect(t.length, greaterThan(20));
      }
    });
  });

  group('DappWatchedConsentQueue', () {
    test('counts the requests waiting or on screen', () async {
      final policy = ScriptedPolicy();
      final q = DappWatchedConsentQueue(policy);
      DappConsentRequest r(int id) => DappConsentRequest(
        kind: DappConsentKind.contract,
        dapp: testIdentity(),
        requestId: id,
        pays: const [],
        receives: const [],
        fee: g(1100000),
        digest: 'ab',
      );
      final a = q.request(r(1), owner: 'page');
      final b = q.request(r(2), owner: 'page');
      expect(q.pending.value, 2);
      expect(q.waitingBehindCurrent, 1);
      await policy.waitShown(1);
      policy.answer(0, false);
      expect(await a, isFalse);
      await _settle();
      expect(q.pending.value, 1);
      q.cancel('page');
      expect(await b, isFalse);
      expect(q.pending.value, 0);
      expect(
        DappRpcErrors.messageFor(DappRpcErrors.userRejected),
        'Call is rejected by user',
      );
    });
  });
}
