/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Which servers a dApp from a file may be allowed to reach: the web
// wallet's rules (pwa/src/lib/dapps/frame_policy.js), case by case.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_remote_origins.dart';

void main() {
  group('accepted', () {
    test('a public DNS name, with or without a port', () {
      for (final o in [
        'https://explorer.0xmx.net',
        'https://api.coingecko.com',
        'https://a.b',
        'https://xn--bcher-kva.example',
        'https://beamsmart.net:8000',
        'https://my-node.example.org:1',
        'https://my-node.example.org:65535',
        'https://0xmx.net',
      ]) {
        expect(dappRemoteOriginFor(o), o, reason: o);
      }
    });

    test('port 443 is the plain origin', () {
      expect(
        dappRemoteOriginFor('https://explorer.0xmx.net:443'),
        'https://explorer.0xmx.net',
      );
    });

    test('the host as the screen shows it', () {
      expect(dappOriginHost('https://explorer.0xmx.net'), 'explorer.0xmx.net');
      expect(
        dappOriginHost('https://beamsmart.net:8000'),
        'beamsmart.net:8000',
      );
    });
  });

  group('refused', () {
    void refuse(String why, List<String> origins) {
      test(why, () {
        for (final o in origins) {
          expect(dappRemoteOriginFor(o), isNull, reason: o);
        }
      });
    }

    refuse('not https', [
      'http://explorer.0xmx.net',
      'wss://explorer.0xmx.net',
      'ftp://a.com',
      '//a.com',
      'a.com',
    ]);
    refuse('an IPv4 address in any spelling', [
      'https://1.2.3.4',
      'https://127.0.0.1',
      'https://127.1',
      'https://2130706433',
      'https://0x7f.1',
      'https://0x7f000001',
      'https://0177.0.0.1',
      'https://192.168.1.1:8443',
    ]);
    refuse('an IPv6 address', [
      'https://[::1]',
      'https://[2001:db8::1]:443',
      'https://::1',
    ]);
    refuse('a single-label name', [
      'https://localhost',
      'https://intranet',
      'https://com',
    ]);
    refuse('a name of this device or the local network', [
      'https://foo.localhost',
      'https://printer.local',
      'https://db.internal',
      'https://nas.lan',
      'https://router.home',
      'https://1.0.0.127.in-addr.arpa',
      'https://site.test',
      'https://x.invalid',
      'https://abcdefghijklmnop.onion',
    ]);
    refuse('a wildcard', [
      'https://*.example.com',
      'https://*',
      '*',
      'https://ex*mple.com',
    ]);
    refuse('uppercase, a path, a query, credentials or a trailing dot', [
      'https://Explorer.0xmx.net',
      'HTTPS://explorer.0xmx.net',
      'https://explorer.0xmx.net/',
      'https://explorer.0xmx.net/api',
      'https://explorer.0xmx.net?x=1',
      'https://user@explorer.0xmx.net',
      'https://explorer.0xmx.net.',
      'https://explorer..net',
      'https://.explorer.net',
    ]);
    refuse('bad labels', [
      'https://-a.com',
      'https://a-.com',
      'https://a_b.com',
      'https://${'a' * 64}.com',
      'https://${List.filled(130, 'a').join('.')}.com',
    ]);
    refuse('a bad port', [
      'https://a.com:0',
      'https://a.com:080',
      'https://a.com:65536',
      'https://a.com:99999',
      'https://a.com:',
    ]);
    refuse('text that would widen a policy', [
      "https://a.com; script-src *",
      'https://a.com https://b.com',
      '',
    ]);
  });

  test('dappRemoteHostOk mirrors remoteHostOk', () {
    expect(dappRemoteHostOk('explorer.0xmx.net'), isTrue);
    expect(dappRemoteHostOk(''), isFalse);
    expect(dappRemoteHostOk('${'a.' * 127}com'), isFalse); // 257 chars
    expect(dappRemoteHostOk('a.0x'), isFalse);
    expect(dappRemoteHostOk('a.123'), isFalse);
    expect(dappRemoteHostOk('a.b1'), isTrue);
  });
}
