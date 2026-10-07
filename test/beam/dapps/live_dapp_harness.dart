/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A bundled dApp, unmodified, in headless Chrome, talking to a REAL wallet
// through exactly the path the app uses: bridge script -> DappBridge ->
// DappSession (gate, sanitizer, consent, scope) -> DappSharedTransport ->
// BeamApi's shader lane -> TcpLineTransport -> wallet-api. Only the webview
// is replaced (by Chrome over the DevTools protocol) and the approval sheet
// (by [DappConsentPolicy] the test supplies).
//
// Used by the opt-in live tests in this folder. Records every request the
// page makes and every answer it gets, and the page's console errors, so a
// failing dApp call can be traced to its cause.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/beam_dex_service.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_server.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_shared_transport.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_wallet_link.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/price/beam_asset_pricer.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

import 'chrome_cdp.dart';

/// The running wallet-api of a `wapi.py` label (port and ACL key from its
/// 0600 state file; nothing secret is printed).
Future<TcpLineTransport> liveWalletTransport(String label) async {
  final home = Platform.environment['HOME']!;
  final state = jsonDecode(
    File('$home/beam-campfire-test/run/$label.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final t = TcpLineTransport(
    port: state['port']! as int,
    aclKey: state['key']! as String,
    defaultTimeout: const Duration(minutes: 2),
    log: (_) {},
  );
  await t.connect();
  return t;
}

/// One request the page made and what it got back.
class DappExchange {
  DappExchange(this.method, this.request);

  final String method;
  final Map<String, Object?> request;
  Map<String, Object?>? response;
  final sw = Stopwatch()..start();
  Duration? took;

  Map<String, Object?>? get error =>
      response?['error'] as Map<String, Object?>?;
  Object? get result => response?['result'];

  /// The shader's own error text, for an `invoke_contract` whose output is
  /// `{"error": ...}`.
  String? get shaderError {
    final r = result;
    if (r is! Map || r['output'] is! String) return null;
    try {
      final o = jsonDecode(r['output']! as String);
      if (o is Map && o['error'] != null) return '${o['error']}';
    } catch (_) {}
    return null;
  }

  String summary() {
    final params = request['params'];
    final buf = StringBuffer(method);
    if (params is Map) {
      final args = params['args'];
      if (args is String) buf.write(' args=${_cut(args, 160)}');
      final c = params['contract'];
      if (c is List) buf.write(' contract=${c.length}B');
      final d = params['data'];
      if (d is List) buf.write(' data=${d.length}B');
      final other = params.keys
          .where((k) => !{'args', 'contract', 'data'}.contains(k))
          .toList();
      if (other.isNotEmpty) buf.write(' keys=$other');
    }
    buf.write(' -> ');
    final e = error;
    if (response == null) {
      buf.write('NO ANSWER');
    } else if (e != null) {
      buf.write('ERROR ${e['code']} ${e['message']} ${e['data'] ?? ''}');
    } else {
      final r = result;
      if (r is Map && r.containsKey('output')) {
        buf.write('output=${_cut('${r['output']}', 200)}');
        if (r['raw_data'] is List) {
          buf.write(' raw_data=${(r['raw_data']! as List).length}B');
        }
      } else {
        buf.write(_cut(jsonEncode(r), 200));
      }
    }
    if (took != null) buf.write('  (${took!.inMilliseconds} ms)');
    return buf.toString();
  }

  static String _cut(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…(${s.length})';
}

/// A bundled dApp open in headless Chrome against a live wallet.
class LiveDappRun {
  LiveDappRun._(
    this.entry,
    this.cdp,
    this.server,
    this.session,
    this.bridge,
    this.transport,
    this._tmp,
  );

  final DappCatalogueEntry entry;
  final ChromeCdp cdp;
  final DappServer server;
  final DappSession session;
  final DappBridge bridge;
  final DappSharedTransport transport;
  final Directory _tmp;

  final exchanges = <DappExchange>[];
  final console = <String>[];
  final _byId = <String, DappExchange>{};

  /// Opens [entry] (from the fetched package cache) with [shape].
  static Future<LiveDappRun> open(
    DappCatalogueEntry entry, {
    required String chrome,
    required BeamTransport wallet,
    required DappConsentQueue consent,
    DappBridgeShape shape = DappBridgeShape.qt,
    String? cache,
    int width = 1055,
    int height = 690,
  }) async {
    final dir =
        cache ??
        Platform.environment['CFB_DAPP_PACKAGES'] ??
        p.join(Platform.environment['HOME']!, '.cache/campfire-beam/dapps');
    final pkg = DappPackage.read(
      File(p.join(dir, entry.fileName)).readAsBytesSync(),
    );
    final tmp = await Directory.systemTemp.createTemp('cfb-live-');
    final inst = await DappInstaller(tmp.path).install(pkg);
    final token = DappBridge.newToken();
    final server = await DappServer.start(
      inst,
      bridgeToken: token,
      csp: entry.csp,
    );
    final cdp = await ChromeCdp.launch(chrome);
    final transport = DappSharedTransport(wallet);
    final session = DappSession(
      identity: DappIdentity.fromManifest(
        pkg.manifest,
        server.origin,
        checkedByCampfire: true,
      ),
      apiVersion: pkg.apiVersion,
      transport: transport,
      consent: consent,
    );
    late final LiveDappRun run;
    final bridge = DappBridge(
      session: session,
      token: token,
      evaluate: (js) async {
        run._delivered(js);
        cdp.fire('Runtime.evaluate', {'expression': js});
      },
    );
    run = LiveDappRun._(entry, cdp, server, session, bridge, transport, tmp);
    cdp.events.listen((m) {
      final params = (m['params'] as Map?) ?? const {};
      switch (m['method']) {
        case 'Runtime.bindingCalled':
          final payload = params['payload']! as String;
          run._requested(payload);
          unawaited(bridge.onMessage(payload));
        case 'Runtime.consoleAPICalled':
          if (params['type'] == 'error' || params['type'] == 'warning') {
            final args = (params['args'] as List? ?? const [])
                .map((a) => (a as Map)['value'] ?? a['description'] ?? '')
                .join(' ');
            run.console.add('${params['type']}: $args');
          }
        case 'Runtime.exceptionThrown':
          final d = params['exceptionDetails'] as Map?;
          final what = (d?['exception'] as Map?)?['description'] ?? d?['text'];
          run.console.add('exception: $what');
      }
    });
    await cdp.send('Runtime.enable');
    await cdp.send('Page.enable');
    await cdp.send('Emulation.setDeviceMetricsOverride', {
      'width': width,
      'height': height,
      'deviceScaleFactor': 1,
      'mobile': false,
    });
    await cdp.send('Emulation.setUserAgentOverride', {
      'userAgent': chromeUserAgents[shape],
    });
    await cdp.send('Runtime.addBinding', {'name': '__cdpPost'});
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
      'source':
          'window.$dappBridgeChannelName='
          '{postMessage:function(m){__cdpPost(m)}};',
    });
    await cdp.send('Page.navigate', {'url': server.startUri.toString()});
    return run;
  }

  void _requested(String raw) {
    try {
      final env = jsonDecode(raw) as Map<String, Object?>;
      if (env['type'] != 'rpc') return;
      final req = jsonDecode(env['payload']! as String) as Map<String, Object?>;
      final x = DappExchange('${req['method']}', req);
      exchanges.add(x);
      _byId['${req['id']}'] = x;
    } catch (_) {}
  }

  void _delivered(String js) {
    const head = 'window.__campfireBeam.deliver(';
    final i = js.indexOf(head);
    if (i < 0) return;
    try {
      final lit = js.substring(i + head.length, js.lastIndexOf(');'));
      final json =
          jsonDecode(jsonDecode(lit) as String) as Map<String, Object?>;
      if (!json.containsKey('id')) return; // an event
      final x = _byId.remove('${json['id']}');
      if (x == null) return;
      x.response = json;
      x.took = x.sw.elapsed;
    } catch (_) {}
  }

  /// Exchanges to [method] so far.
  List<DappExchange> calls(String method) =>
      exchanges.where((x) => x.method == method).toList();

  /// Waits until [test] holds or [timeout] passes.
  Future<bool> waitFor(
    bool Function() test, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      if (test()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return test();
  }

  /// Waits until every request made so far has been answered and nothing
  /// new arrived for [quiet].
  Future<void> settle({
    Duration quiet = const Duration(seconds: 4),
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final sw = Stopwatch()..start();
    var lastCount = -1;
    var still = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      final open = exchanges.any((x) => x.response == null);
      if (exchanges.length != lastCount || open) {
        lastCount = exchanges.length;
        still = Stopwatch()..start();
      } else if (still.elapsed >= quiet) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> close() async {
    await bridge.close();
    await session.close();
    await transport.close();
    await cdp.close();
    await server.close();
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  }
}

/// Records what reaches the core.
class LiveSpyTransport implements BeamTransport {
  LiveSpyTransport(this.inner);

  final BeamTransport inner;
  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    calls.add((method, params));
    return inner.call(method, params, timeout);
  }

  List<Map<String, Object?>> to(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  @override
  Future<void> connect() => inner.connect();
  @override
  bool get isConnected => inner.isConnected;
  @override
  Stream<BeamEvent> get events => inner.events;
  @override
  Future<void> close() async {}
}

/// [DappWalletLink] over a live wallet-api, as `BeamWalletDappLink` reads a
/// `BeamWallet`: balances and asset names from the core, prices from the
/// DEX, and "can spend" from `is_in_sync`.
class LiveWalletLink implements DappWalletLink {
  LiveWalletLink(this.spy) : api = BeamApi(spy);

  final LiveSpyTransport spy;
  final BeamApi api;
  bool inSync = false;

  @override
  Future<String> dappsRoot() async => Directory.systemTemp.path;

  @override
  BeamTransport dappTransport(DappIdentity dapp) => DappSharedTransport(spy);

  @override
  Future<Map<int, BigInt>?> availableBalances() async {
    final s = await api.walletStatus();
    inSync = s.isInSync;
    return {for (final t in s.totals) t.assetId: t.available};
  }

  @override
  Future<BeamAssetMetadata?> assetMetadata(int assetId) async =>
      (await api.getAssetInfo(assetId)).metadata;

  @override
  Future<DappAssetValuer?> assetValuer() async {
    final dex = BeamDexService(
      api,
      ammAppShader(const FileShaderSource('assets/beam/shaders')),
    );
    return BeamAssetPricer(await dex.listPools()).valueInGroth;
  }

  @override
  String? get spendBlockedReason =>
      inSync ? null : 'The wallet is not in sync with the network.';

  @override
  void Function() holdForApproval(String reason) => () {};
}
