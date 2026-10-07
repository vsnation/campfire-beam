/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Every mainnet package the Qt wallet bundles, through the real installer
// and server. The packages are not in the repository; fetch them first:
//
//   test/beam/dapps/tool/fetch_bundled_dapps.sh
//
// Each test is skipped when its package is not in the cache.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_bridge.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_server.dart';

Future<(int, Map<String, String>, List<int>)> get(Uri uri) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(uri)
      ..followRedirects = false;
    final res = await req.close();
    final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
    final headers = <String, String>{};
    res.headers.forEach((k, v) => headers[k] = v.join(','));
    return (res.statusCode, headers, body);
  } finally {
    client.close(force: true);
  }
}

void main() {
  final cache =
      Platform.environment['CFB_DAPP_PACKAGES'] ??
      p.join(Platform.environment['HOME'] ?? '', '.cache/campfire-beam/dapps');

  test('the catalogue lists the 9 bundled packages', () {
    expect(dappBundledCatalogue, hasLength(9));
    expect({for (final e in dappBundledCatalogue) e.guid}, hasLength(9));
    for (final e in dappBundledCatalogue) {
      expect(e.url, startsWith('https://raw.githubusercontent.com/BeamMW/'));
      expect(() => e.csp.header, returnsNormally);
    }
  });

  for (final entry in dappBundledCatalogue) {
    final file = File(p.join(cache, entry.fileName));
    test(
      '${entry.fileName}: verified, installed, served with the bridge',
      () async {
        final bytes = await file.readAsBytes();
        expect(bytes.length, entry.size);
        expect(crypto.sha256.convert(bytes).toString(), entry.sha256);

        final pkg = DappPackage.read(bytes);
        final m = pkg.manifest;
        expect(m.name, entry.name);
        expect(m.guid, entry.guid);
        expect(m.version, entry.version);
        expect(m.apiVersion, entry.apiVersion);
        expect(m.minApiVersion, entry.minApiVersion);
        expect(m.startPath, 'app/index.html');
        expect(pkg.apiVersion, DappApiVersion.v7_0);
        expect(pkg.files.where((f) => f.path.contains('__MACOSX')), isEmpty);
        // The store's bundled icon is this package's own, byte for byte.
        final icon = pkg.files.firstWhere((f) => f.path == m.iconPath);
        expect(File(entry.iconAsset).readAsBytesSync(), icon.bytes);

        final tmp = await Directory.systemTemp.createTemp('cfb-bundled-');
        DappServer? server;
        try {
          final inst = await DappInstaller(tmp.path).install(pkg);
          final onDisk = Directory(inst.filesDirectory)
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .length;
          expect(onDisk, pkg.files.length);

          final token = DappBridge.newToken();
          server = await DappServer.start(
            inst,
            bridgeToken: token,
            csp: entry.csp,
          );

          final (status, headers, body) = await get(server.startUri);
          expect(status, 200);
          expect(headers['content-security-policy'], entry.csp.header);
          expect(headers['content-type'], 'text/html; charset=utf-8');
          final html = utf8.decode(body);
          final tag =
              '<script src="/__campfire/$token/bridge.js"></script>'
              '<link rel="stylesheet" href="/__campfire/$token/host.css">';
          final headAt = RegExp(
            r'<head[^>]*>',
            caseSensitive: false,
          ).firstMatch(html)!;
          expect(html.substring(headAt.end), startsWith(tag));
          expect(
            utf8.decode(
              pkg.files.firstWhere((f) => f.path == m.startPath).bytes,
            ),
            isNot(contains('Content-Security-Policy')),
            reason: 'no CSP of its own to combine with ours',
          );

          // Every script and stylesheet the page names loads.
          final refs = RegExp(r'''(?:src|href)=["']([^"':]+)["']''')
              .allMatches(html)
              .map((r) => r.group(1)!)
              .where((r) => !r.startsWith('/__campfire/'))
              .toSet();
          expect(refs, isNotEmpty);
          for (final ref in refs) {
            final uri = server.startUri.resolve(ref);
            final (s, h, _) = await get(uri);
            if (ref.endsWith('.js') || ref.endsWith('.css')) {
              expect(s, 200, reason: '$ref in ${entry.fileName}');
              expect(
                h['content-type'],
                ref.endsWith('.js')
                    ? 'text/javascript; charset=utf-8'
                    : 'text/css; charset=utf-8',
              );
            }
          }

          // The app shader(s) the page passes to invoke_contract.
          final shaders = pkg.files.where((f) => f.path.endsWith('.wasm'));
          expect(shaders, isNotEmpty);
          for (final w in shaders) {
            final (s, h, b) = await get(
              Uri.parse('${server.origin}/${Uri.encodeFull(w.path)}'),
            );
            expect(s, 200);
            expect(h['content-type'], 'application/wasm');
            expect(b.length, w.bytes.length);
          }

          final icon = m.iconPath;
          if (icon != null) {
            final (s, _, _) = await get(
              Uri.parse(
                '${server.origin}/'
                '${icon.split('/').map(Uri.encodeComponent).join('/')}',
              ),
            );
            expect(s, 200, reason: icon);
          }

          final (bs, _, bridge) = await get(
            Uri.parse('${server.origin}${server.bridgePath}'),
          );
          expect(bs, 200);
          expect(utf8.decode(bridge), contains(token));
        } finally {
          await server?.close();
          await tmp.delete(recursive: true);
        }
      },
      skip: file.existsSync()
          ? false
          : 'not fetched: run test/beam/dapps/tool/fetch_bundled_dapps.sh',
    );
  }
}
