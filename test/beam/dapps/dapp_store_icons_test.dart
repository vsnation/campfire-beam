/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The store shows each bundled dApp's own icon before it is installed, from
// a copy bundled in the app (never fetched); an installed dApp shows the
// icon from its own package.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_installer.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_manifest.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_store_controller.dart';
import 'package:stackwallet/widgets/beam/dapps/dapp_avatar.dart';

void main() {
  test('every bundled dApp has its icon in the app, named by its guid', () {
    for (final e in dappBundledCatalogue) {
      expect(e.iconAsset, 'assets/beam/dapps/${e.guid}.${e.iconExtension}');
      final f = File(e.iconAsset);
      expect(f.existsSync(), isTrue, reason: e.iconAsset);
      expect(f.lengthSync(), greaterThan(0), reason: e.iconAsset);
      final head = String.fromCharCodes(f.readAsBytesSync().take(8));
      if (e.iconExtension == 'svg') {
        expect(f.readAsStringSync(), contains('<svg'), reason: e.iconAsset);
      } else {
        expect(e.iconExtension, 'png');
        expect(head.substring(1, 4), 'PNG', reason: e.iconAsset);
      }
    }
    // Nothing else in the folder but the licence note.
    final names = Directory('assets/beam/dapps')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    expect(names, {
      for (final e in dappBundledCatalogue) '${e.guid}.${e.iconExtension}',
      'NOTICE.txt',
    });
    expect(
      File('assets/beam/dapps/NOTICE.txt').readAsStringSync(),
      contains('Apache License 2.0'),
    );
  });

  test('the icons folder is bundled under the BEAM flag', () {
    final pubspec = File('scripts/app_config/templates/pubspec.template.yaml')
        .readAsStringSync();
    final block = pubspec.substring(
      pubspec.lastIndexOf('# %%ENABLE_BEAM%%'),
      pubspec.lastIndexOf('# %%END_ENABLE_BEAM%%'),
    );
    expect(block, contains('#    - assets/beam/dapps/'));
  });

  test('available: the bundled icon; installed: its own package\'s icon', () {
    final dex = dappBundledCatalogue.firstWhere((e) => e.name == 'Beam DEX');
    final available = DappStoreItem(
      guid: dex.guid,
      name: dex.name,
      bundled: dex,
    );
    expect(available.iconAsset, dex.iconAsset);
    expect(available.iconFile, isNull);

    final installed = DappStoreItem(
      guid: dex.guid,
      name: dex.name,
      bundled: dex,
      installed: DappInstallation(
        manifest: DappManifest(
          guid: dex.guid,
          name: dex.name,
          description: 'AMM based decentralized exchange',
          startPath: 'app/index.html',
          iconPath: 'app/logo.svg',
        ),
        apiVersion: DappApiVersion.v7_0,
        packageSha256: dex.sha256,
        directory: '/dapps/${dex.guid}/1.0.0',
        installedAt: DateTime.utc(2026, 10, 7),
      ),
    );
    expect(installed.iconAsset, isNull);
    expect(installed.iconFile, endsWith('/files/app/logo.svg'));

    // A dApp from a file has no bundled icon.
    expect(const DappStoreItem(guid: 'f00d', name: 'Mine').iconAsset, isNull);
  });

  group('icons coloured by a <style> sheet', () {
    // flutter_svg ignores <style>: BANS's icon drew as a black disc.
    test('BANS: every class rule lands on its elements', () {
      final bans = dappBundledCatalogue.firstWhere(
        (e) => e.name == 'Beam Anonymous Name Service',
      );
      final svg = File(bans.iconAsset).readAsStringSync();
      expect(svg, contains('<style>'));
      final out = dappSvgInlineStyles(svg);
      expect(out, isNot(contains('<style')));
      expect(out, contains('<path class="cls-6" d="M19.05'));
      expect(out, contains('class="cls-6" d="'));
      // The teal emblem, the pink star, the dark disc in its mask.
      expect(out, contains('style="fill:#00f6d2"'));
      expect(out, contains('style="fill:#fe52ff"'));
      expect(out, contains('<g class="cls-2" style="mask:url(#mask)">'));
      // .cls-3,.cls-5{fill} then .cls-5,.cls-8{stroke} then .cls-5{…}:
      // in rule order, as CSS applies them.
      expect(
        out,
        contains('style="fill:#042548;stroke:#042548;stroke-miterlimit:10"'),
      );
      expect(out, contains('style="stroke:#042548;fill:none"'));
      // The masks' own shapes are white, as their rule says.
      expect(out, contains('class="cls-1" d="M25.5,50.5'));
      expect('style="fill:#fff"'.allMatches(out), hasLength(2));
    });

    test('an element\'s own style wins; other selectors are dropped', () {
      const svg =
          '<svg><style>.a{fill:red}.b{fill:blue;stroke:#000}'
          'path{fill:green}#x{fill:pink}</style>'
          '<path class="a b" style="fill:#123456" d="M0 0"/>'
          '<rect class="c" width="1"/></svg>';
      expect(
        dappSvgInlineStyles(svg),
        '<svg>'
        '<path class="a b" d="M0 0" style="fill:red;fill:blue;stroke:#000;'
        'fill:#123456"/>'
        '<rect class="c" width="1"/></svg>',
      );
    });

    test('an icon without a sheet is untouched', () {
      for (final e in dappBundledCatalogue) {
        if (e.iconExtension != 'svg') continue;
        final svg = File(e.iconAsset).readAsStringSync();
        if (svg.contains('<style')) continue;
        expect(dappSvgInlineStyles(svg), svg, reason: e.name);
      }
    });
  });
}
