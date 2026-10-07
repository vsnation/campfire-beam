/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How each of the 9 bundled dApps looks in Campfire's dApp window, in a real
// browser engine: on the background the BEAM desktop wallet paints behind
// its transparent dApp view, and not cut at the size of Campfire's dApp
// area.
//
// Why this is needed: the packages are written for the Qt wallet, which
// shows them in a transparent web view over its own dark-blue background.
// Their pages paint no background of their own and set `color: white` on
// <body>. A host that lets the page's default white show through (macOS
// WKWebView ignores webview_flutter's setBackgroundColor) gets white text
// on a white page. Headless Chrome's default page background is white too,
// so this reproduces it.
//
// The dApp area at Campfire's 1280x800 desktop window with the side menu
// open: 1280 - 225 (menu) by 800 - 28 (title bar) - 82 (page header).
//
// Opt-in, like bundled_dapps_chrome_test.dart:
//
//   test/beam/dapps/tool/fetch_bundled_dapps.sh
//   export CFB_DAPP_CHROME=<path to the Chrome executable>
//   export CFB_DAPP_SHOTS=<folder>        # optional: keep a PNG of each
//   flutter test test/beam/dapps/bundled_dapps_look_test.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

import 'chrome_cdp.dart';

class _Reject implements DappConsentPolicy {
  @override
  Future<bool> approve(DappConsentRequest request) async => false;
}

/// Campfire's dApp area at a 1280x800 window, side menu open.
const _width = 1055;
const _height = 690;

/// Made-up wallet answers, enough for the pages to draw their main screens
/// instead of an error: the DEX's pools (a recorded `pools_view`), an asset
/// list naming every asset in them, nothing owned.
const Map<String, Object?> _walletStatus = {
  'current_height': 4070000,
  'current_state_hash':
      '0000000000000000000000000000000000000000000000000000000000000000',
  'current_state_timestamp': 1790000000,
  'prev_state_hash':
      '0000000000000000000000000000000000000000000000000000000000000000',
  'is_in_sync': true,
  'available': 250000000,
  'receiving': 0,
  'sending': 0,
  'maturing': 0,
  'locked': 0,
  'difficulty': 0,
  'totals': [
    {
      'asset_id': 0,
      'available': 250000000,
      'available_str': '250000000',
      'receiving': 0,
      'sending': 0,
      'maturing': 0,
      'locked': 0,
    },
  ],
};

Object? _invokeReply(Map<String, Object?> params, String pools) {
  final args = params['args'];
  final action = args is String
      ? RegExp(r'action=([a-z_]+)').firstMatch(args)?.group(1)
      : null;
  final recorded = jsonDecode(pools) as Map<String, Object?>;
  switch (action) {
    case 'view_all_assets':
      final res =
          (jsonDecode(((recorded['result']! as Map)['output']! as String))
                  as Map)['res']!
              as List;
      final aids = <int>{
        for (final pool in res.cast<Map<String, Object?>>()) ...[
          pool['aid1'] as int,
          pool['aid2'] as int,
        ],
      }..remove(0);
      return {
        'output': jsonEncode({
          'res': [
            for (final aid in aids.toList()..sort())
              {
                'aid': aid,
                'mintedLo': 100000000000,
                'mintedHi': 0,
                'owner_pk': '02${'00' * 32}',
                'height': 1000000,
                'metadata':
                    'STD:SCH_VER=1;N=Test asset $aid;SN=T$aid;UN=T$aid;'
                    'NTHUN=TGROTH',
              },
          ],
        }),
      };
    case 'view_owned':
      return {
        'output': jsonEncode({'res': <Object>[]}),
      };
    case 'farm_view': // dao-core-app: nothing staked yet
      return {
        'output': jsonEncode({
          'farming': {
            'duation': 1051200,
            'emission': 1000000000000,
            'h': 4070000,
            'h0': 1000000,
          },
          'user': {
            'beams_locked': 0,
            'beamX_old': 0,
            'beamX_recent': 0,
            'beamX': 0,
          },
        }),
      };
    case 'farm_get_yield':
      return {
        'output': jsonEncode({'yield': 0}),
      };
    default:
      return recorded;
  }
}

double _luma(img.Pixel px) =>
    (0.2126 * px.r + 0.7152 * px.g + 0.0722 * px.b) / 255;

void main() {
  final chrome = Platform.environment['CFB_DAPP_CHROME'];
  final shots = Platform.environment['CFB_DAPP_SHOTS'];
  final cache =
      Platform.environment['CFB_DAPP_PACKAGES'] ??
      p.join(Platform.environment['HOME'] ?? '', '.cache/campfire-beam/dapps');
  final pools = File('test/beam/contracts/dex/fixtures/pools_view.json')
      .readAsStringSync();

  for (final entry in dappBundledCatalogue) {
    final file = File(p.join(cache, entry.fileName));
    test(
      '${entry.fileName}: on the wallet background, not cut, at '
      '${_width}x$_height',
      () async {
        final pkg = DappPackage.read(file.readAsBytesSync());
        final tmp = await Directory.systemTemp.createTemp('cfb-look-');
        final cdp = await ChromeCdp.launch(chrome!);
        DappServer? server;
        try {
          final inst = await DappInstaller(tmp.path).install(pkg);
          final token = DappBridge.newToken();
          // As with Tor on: no remote origins, so nothing leaves the test.
          server = await DappServer.start(
            inst,
            bridgeToken: token,
            csp: DappCsp(allowEval: entry.needsEval),
          );
          final t = FakeTransport({
            'get_version': {'api_version': '7.4'},
            'ev_subunsub': true,
            'wallet_status': _walletStatus,
            'invoke_contract': (Map<String, Object?> params) =>
                _invokeReply(params, pools),
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
          cdp.events.listen((m) {
            if (m['method'] == 'Runtime.bindingCalled') {
              final params = (m['params'] as Map?) ?? const {};
              unawaited(bridge.onMessage(params['payload']! as String));
            }
          });
          await cdp.send('Runtime.enable');
          await cdp.send('Page.enable');
          await cdp.send('Emulation.setDeviceMetricsOverride', {
            'width': _width,
            'height': _height,
            'deviceScaleFactor': 1,
            'mobile': false,
          });
          // Campfire's desktop shape (dappUserAgentFor on macOS).
          await cdp.send('Emulation.setUserAgentOverride', {
            'userAgent': chromeUserAgents[DappBridgeShape.qt],
          });
          await cdp.send('Runtime.addBinding', {'name': '__cdpPost'});
          await cdp.send('Page.addScriptToEvaluateOnNewDocument', {
            'source':
                'window.$dappBridgeChannelName='
                '{postMessage:function(m){__cdpPost(m)}};',
          });
          await cdp.send('Page.navigate', {'url': server.startUri.toString()});
          for (var i = 0; i < 120; i++) {
            if (t.callsTo('invoke_contract').isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 250));
          }
          // Let the page render what it was given (and fade in).
          await Future<void>.delayed(const Duration(seconds: 3));

          final png = await cdp.screenshot();
          if (shots != null) {
            await Directory(shots).create(recursive: true);
            await File(
              p.join(
                shots,
                '${p.basenameWithoutExtension(entry.fileName)}.png',
              ),
            ).writeAsBytes(png);
            await File(
              p.join(
                shots,
                '${p.basenameWithoutExtension(entry.fileName)}.calls.txt',
              ),
            ).writeAsString(
              t.calls
                  .map((c) => '${c.method} ${c.params['args'] ?? ''}')
                  .join('\n'),
            );
          }
          final image = img.decodePng(png)!;
          expect(image.width, _width);

          // The corners: dark, as in the Qt wallet (background, or one of
          // the page's own dark panels), never the page's default white.
          for (final (x, y) in [
            (3, 3),
            (_width - 4, 3),
            (3, _height - 4),
            (_width - 4, _height - 4),
          ]) {
            expect(
              _luma(image.getPixel(x, y)),
              lessThan(0.5),
              reason: '${entry.fileName}: pixel ($x, $y) is light',
            );
          }
          var white = 0;
          for (final px in image) {
            if (px.r > 235 && px.g > 235 && px.b > 235) white++;
          }
          expect(
            white / (image.width * image.height),
            lessThan(0.2),
            reason: '${entry.fileName}: mostly white',
          );

          // Not cut: nothing wider than the dApp area.
          final scrollWidth = await cdp.evaluate(
            'document.documentElement.scrollWidth',
          );
          expect(scrollWidth, lessThanOrEqualTo(_width));

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
