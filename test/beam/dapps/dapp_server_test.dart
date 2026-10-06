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
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge_js.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_server.dart';

import 'dapp_test_zip.dart';

class Reply {
  Reply(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers;
  final List<int> body;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// A raw HTTP/1.1 request, so paths reach the server exactly as written.
Future<Reply> raw(
  int port,
  String target, {
  String method = 'GET',
  String? host,
}) async {
  final s = await Socket.connect(InternetAddress.loopbackIPv4, port);
  s.write(
    '$method $target HTTP/1.1\r\n'
    'Host: ${host ?? '127.0.0.1:$port'}\r\n'
    'Connection: close\r\n\r\n',
  );
  await s.flush();
  final bytes = <int>[];
  await s.listen(bytes.addAll).asFuture<void>();
  s.destroy();
  final text = latin1.decode(bytes);
  final split = text.indexOf('\r\n\r\n');
  final head = text.substring(0, split).split('\r\n');
  final status = int.parse(head.first.split(' ')[1]);
  final headers = <String, String>{
    for (final h in head.skip(1))
      h.substring(0, h.indexOf(':')).toLowerCase(): h
          .substring(h.indexOf(':') + 1)
          .trim(),
  };
  return Reply(status, headers, bytes.sublist(split + 4));
}

void main() {
  late Directory tmp;
  late DappInstallation inst;
  late DappServer server;
  final token = DappBridge.newToken();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cfb-dapp-srv-');
    inst = await DappInstaller(tmp.path).install(
      DappPackage.read(
        testPackage(
          extra: [
            ZipSpec.text('app/page two.html', '<html><body>2</body></html>'),
            ZipSpec.text('app/style.css', 'body{}'),
          ],
        ),
      ),
    );
    server = await DappServer.start(inst, bridgeToken: token);
  });

  tearDown(() async {
    await server.close();
    await tmp.delete(recursive: true);
  });

  void expectHardened(Reply r) {
    expect(r.headers['content-security-policy'], const DappCsp().header);
    expect(r.headers['x-content-type-options'], 'nosniff');
    expect(r.headers['x-frame-options'], 'DENY');
    expect(r.headers['referrer-policy'], 'no-referrer');
    expect(r.headers['cross-origin-resource-policy'], 'same-origin');
    expect(r.headers['cache-control'], 'no-store');
    expect(r.headers['permissions-policy'], contains('camera=()'));
  }

  test('binds 127.0.0.1 only', () {
    expect(server.origin, 'http://127.0.0.1:${server.port}');
    expect(server.startUri.toString(), '${server.origin}/app/index.html');
  });

  test('serves the page with the bridge first in <head>', () async {
    final r = await raw(server.port, '/app/index.html');
    expect(r.status, 200);
    expect(r.headers['content-type'], 'text/html; charset=utf-8');
    expectHardened(r);
    expect(
      r.text,
      contains(
        '<head><script src="/__campfire/$token/bridge.js"></script>\n'
        '    <meta charset="utf-8" />',
      ),
    );
    expect(r.text, isNot(contains('qrc:///')));
    expect(r.text, contains('<script src="$dappQwebchannelShimPath">'));
  });

  test('serves the bridge script for this token only', () async {
    final r = await raw(server.port, '/__campfire/$token/bridge.js');
    expect(r.status, 200);
    expect(r.headers['content-type'], 'text/javascript; charset=utf-8');
    expectHardened(r);
    expect(r.text, contains('var TOKEN = "$token";'));
    expect(r.text, contains("var CHANNEL = \"$dappBridgeChannelName\";"));
    final other = DappBridge.newToken();
    expect(
      (await raw(server.port, '/__campfire/$other/bridge.js')).status,
      404,
    );
    expect((await raw(server.port, '/__campfire/bridge.js')).status, 404);
    expect((await raw(server.port, dappQwebchannelShimPath)).status, 200);
  });

  test('serves files with their types, byte for byte', () async {
    final wasm = await raw(server.port, '/app/app.wasm');
    expect(wasm.status, 200);
    expect(wasm.headers['content-type'], 'application/wasm');
    expect(wasm.body, [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]);
    expectHardened(wasm);
    final js = await raw(server.port, '/app/index.js');
    expect(js.headers['content-type'], 'text/javascript; charset=utf-8');
    expect(js.text, 'console.log("hi");');
    final svg = await raw(server.port, '/app/icon.svg');
    expect(svg.headers['content-type'], 'image/svg+xml');
    final spaced = await raw(server.port, '/app/page%20two.html');
    expect(spaced.status, 200);
    expect(spaced.text, contains('/__campfire/$token/bridge.js'));
    final head = await raw(server.port, '/app/index.js', method: 'HEAD');
    expect(head.status, 200);
    expect(head.body, isEmpty);
  });

  test('the root redirects to the start page', () async {
    final r = await raw(server.port, '/');
    expect(r.status, 302);
    expect(r.headers['location'], '/app/index.html');
  });

  // Dot segments are already resolved by the request parser (so
  // `/__campfire/../app/index.html` is simply `/app/index.html`); the
  // segment checks and the resolved-path check are the next two lines.
  test('refuses traversal, hidden files, directories and odd paths', () async {
    File(p.join(inst.filesDirectory, '.secret')).writeAsStringSync('s');
    for (final target in [
      '/../install.json',
      '/app/../../install.json',
      '/%2e%2e/install.json',
      '/app/%2e%2e/%2e%2e/install.json',
      '/..%2finstall.json',
      '/app/..%5c..%5cinstall.json',
      '/app/%00index.html',
      '/.secret',
      '/app',
      '/app/',
      '//app/index.html',
      '/app//index.html',
      '/app/missing.js',
      '/manifest.json/x',
      '/C:/Windows/win.ini',
    ]) {
      final r = await raw(server.port, target);
      expect(r.status, anyOf(400, 404), reason: target);
      expect(r.text, isNot(contains('package_sha256')), reason: target);
      expect(r.text, isNot(contains('<html')), reason: target);
    }
  });

  test('refuses symlinks inside the dApp folder', () async {
    if (Platform.isWindows) return;
    Link(p.join(inst.filesDirectory, 'app', 'link.js'))
        .createSync(p.join(inst.directory, DappInstaller.recordFileName));
    Link(p.join(inst.filesDirectory, 'app', 'inner.js'))
        .createSync(p.join(inst.filesDirectory, 'app', 'index.js'));
    Link(p.join(inst.filesDirectory, 'up')).createSync(inst.directory);
    for (final target in [
      '/app/link.js',
      '/app/inner.js',
      '/up/install.json',
    ]) {
      final r = await raw(server.port, target);
      expect(r.status, 404, reason: target);
      expect(r.text, isNot(contains('package_sha256')), reason: target);
    }
  });

  test('refuses other hosts (DNS rebinding) and other methods', () async {
    for (final host in [
      'evil.example:${server.port}',
      'localhost:${server.port}',
      '127.0.0.1',
      '127.0.0.1:1',
    ]) {
      final r = await raw(server.port, '/app/index.html', host: host);
      expect(r.status, 403, reason: host);
      expectHardened(r);
    }
    for (final m in ['POST', 'PUT', 'DELETE', 'OPTIONS']) {
      final r = await raw(server.port, '/app/index.html', method: m);
      expect(r.status, 405, reason: m);
    }
  });

  test('is unreachable from any non-loopback address', () async {
    final addresses = [
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        for (final a in i.addresses)
          if (!a.isLoopback) a,
    ];
    if (addresses.isEmpty) {
      markTestSkipped('no non-loopback IPv4 address on this machine');
      return;
    }
    for (final a in addresses) {
      await expectLater(
        Socket.connect(a, server.port, timeout: const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
        reason: a.address,
      );
    }
  });

  test('keeps a saved port, falls back when it is taken', () async {
    final port = server.port;
    await server.close();
    server = await DappServer.start(
      inst,
      bridgeToken: token,
      preferredPort: port,
    );
    expect(server.port, port);
    expect(server.portChanged, isFalse);

    final blocker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final other = await DappServer.start(
        inst,
        bridgeToken: token,
        preferredPort: blocker.port,
      );
      expect(other.port, isNot(blocker.port));
      expect(other.portChanged, isTrue);
      await other.close();
    } finally {
      await blocker.close();
    }
  });

  group('pieces', () {
    test('bridge insertion falls back to <html>, the doctype, the start', () {
      String inject(String html) =>
          latin1.decode(DappServer.injectBridge(latin1.encode(html), '/b.js'));
      const tag = '<script src="/b.js"></script>';
      expect(
        inject('<!doctype html><HTML lang=en><HEAD id="h"><title>'),
        '<!doctype html><HTML lang=en><HEAD id="h">$tag<title>',
      );
      expect(inject('<html><body>x'), '<html>$tag<body>x');
      expect(inject('<!DOCTYPE html><body>x'), '<!DOCTYPE html>$tag<body>x');
      expect(inject('<body>x'), '$tag<body>x');
      expect(inject('<header>'), '$tag<header>', reason: 'not <head>');
      // Bytes that are not UTF-8 pass through untouched.
      final odd = [...latin1.encode('<head>'), 0xff, 0xfe, 0x80];
      expect(DappServer.injectBridge(odd, '/b.js'), [
        ...latin1.encode('<head>$tag'),
        0xff,
        0xfe,
        0x80,
      ]);
    });

    test('content types; unknown is opaque', () {
      expect(DappServer.contentTypeFor('a.WASM'), 'application/wasm');
      expect(DappServer.contentTypeFor('font.woff2'), 'font/woff2');
      expect(DappServer.contentTypeFor('x.exe'), 'application/octet-stream');
      expect(DappServer.contentTypeFor('README'), 'application/octet-stream');
    });

    test('CSP: eval only when allowed, https origins only', () {
      final strict = const DappCsp(allowEval: false).header;
      expect(strict, contains("script-src 'self';"));
      expect(strict, contains("default-src 'none'"));
      expect(strict, contains("frame-src 'none'"));
      expect(strict, contains("object-src 'none'"));
      expect(
        const DappCsp().header,
        contains("script-src 'self' 'unsafe-eval';"),
      );
      final remote = const DappCsp(remoteOrigins: ['https://api.coingecko.com'])
          .header;
      expect(remote, contains("connect-src 'self' https://api.coingecko.com;"));
      for (final bad in [
        'http://api.coingecko.com',
        'https://*.example.com',
        'https://a.com/path',
        "https://a.com; script-src *",
        '*',
      ]) {
        expect(
          () => DappCsp(remoteOrigins: [bad]).header,
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });
}
