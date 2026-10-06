/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/host/beam_host.dart';
import 'package:stackwallet/wallets/beam/host/beam_host_exception.dart';
import 'package:stackwallet/wallets/beam/host/process_host.dart';

Matcher _hostError(BeamHostError kind) =>
    isA<BeamHostException>().having((e) => e.kind, 'kind', kind);

void main() {
  group('validatePassword', () {
    test('accepts what Campfire generates and other safe passwords', () {
      for (final ok in [
        'aB3dE5fG7hJ9kL2mN4pQ6rS',
        'with inner space',
        'p@ss=w0rd!"\'',
        'ünïcødé-пароль',
      ]) {
        ProcessHost.validatePassword(ok);
      }
    });

    final bad = <String, String>{
      'empty': '',
      'hash (comment)': 'MyP@ss#2026!',
      'newline (option injection)': 'abc\nuse_acl=0',
      'carriage return': 'abc\rdef',
      'tab': 'abc\tdef',
      'NUL': 'abc\x00def',
      'leading space': ' abcdef',
      'trailing space': 'abcdef ',
      'too long': 'a' * 4096,
    };
    bad.forEach((name, value) {
      test('rejects $name', () {
        expect(
          () => ProcessHost.validatePassword(value),
          throwsA(_hostError(BeamHostError.invalidInput)),
        );
      });
    });

    test('never echoes the password', () {
      try {
        ProcessHost.validatePassword('VerySecret#Value');
        fail('expected a throw');
      } on BeamHostException catch (e) {
        expect(e.toString(), isNot(contains('VerySecret')));
      }
    });
  });

  group('validateWords', () {
    final valid = bip39.generateMnemonic().split(' ');

    test('accepts a generated 12-word phrase', () {
      expect(valid, hasLength(12));
      ProcessHost.validateWords(valid);
    });

    test('rejects 11 and 24 words', () {
      expect(
        () => ProcessHost.validateWords(valid.sublist(0, 11)),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
      final long = bip39.generateMnemonic(strength: 256).split(' ');
      expect(
        () => ProcessHost.validateWords(long),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
    });

    test('rejects uppercase, digits and separators', () {
      for (final bad in ['Abandon', 'aband0n', 'a;b', 'a b', '']) {
        final words = [...valid]..[3] = bad;
        expect(
          () => ProcessHost.validateWords(words),
          throwsA(_hostError(BeamHostError.invalidInput)),
          reason: 'word ${bad.codeUnits}',
        );
      }
    });

    test('rejects a word outside the BIP39 list', () {
      final words = [...valid]..[0] = 'notaword';
      expect(
        () => ProcessHost.validateWords(words),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
    });

    test('rejects a valid-word phrase with a wrong checksum', () {
      // Swapping two words keeps every word valid but almost always breaks
      // the checksum; find a swap that does.
      List<String>? broken;
      for (var i = 1; i < 12 && broken == null; i++) {
        final w = [...valid];
        final t = w[0];
        w[0] = w[i];
        w[i] = t;
        if (w[0] != w[i] && !bip39.validateMnemonic(w.join(' '))) broken = w;
      }
      expect(broken, isNotNull);
      expect(
        () => ProcessHost.validateWords(broken!),
        throwsA(_hostError(BeamHostError.invalidInput)),
      );
    });

    test('never echoes a word', () {
      final words = [...valid]..[5] = 'Zebra';
      try {
        ProcessHost.validateWords(words);
        fail('expected a throw');
      } on BeamHostException catch (e) {
        // Single words are no test: "only", "word" and "letter" are BIP39
        // words and may sit in the fixed message. An echo of the phrase
        // always contains two adjacent words.
        final text = e.toString();
        expect(text, isNot(contains('Zebra')));
        for (var i = 0; i + 1 < words.length; i++) {
          expect(text, isNot(contains('${words[i]} ${words[i + 1]}')));
          expect(text, isNot(contains('${words[i]};${words[i + 1]}')));
        }
      }
    });
  });

  group('node endpoints', () {
    test('parse host:port', () {
      final n = BeamNodeEndpoint.parse('eu-nodes.mainnet.beam.mw:8100');
      expect(n.host, 'eu-nodes.mainnet.beam.mw');
      expect(n.port, 8100);
      expect(n.isOwned, isFalse);
      expect(n.toString(), 'eu-nodes.mainnet.beam.mw:8100');
      final own = BeamNodeEndpoint.parse('127.0.0.1:10005', isOwned: true);
      expect(own.isOwned, isTrue);
      expect(own == BeamNodeEndpoint.parse('127.0.0.1:10005'), isFalse);
    });

    test('parse rejects malformed addresses', () {
      for (final bad in [
        'eu-nodes.mainnet.beam.mw',
        ':8100',
        'host:0',
        'host:65536',
        'host:http',
        'https://host:8100x',
      ]) {
        expect(
          () => BeamNodeEndpoint.parse(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('validateNode accepts names and IPv4', () {
      ProcessHost.validateNode(BeamNodeEndpoint.parse('127.0.0.1:10005'));
      ProcessHost.validateNode(
        BeamNodeEndpoint.parse('us-nodes.mainnet.beam.mw:8100'),
      );
    });

    test('validateNode rejects anything that is not a plain host', () {
      for (final host in ['-flag', 'a b', 'host;rm', 'http://x', '[::1]', '']) {
        expect(
          () => ProcessHost.validateNode(BeamNodeEndpoint(host, 8100)),
          throwsA(_hostError(BeamHostError.badNode)),
          reason: host,
        );
      }
      expect(
        () => ProcessHost.validateNode(const BeamNodeEndpoint('h', 0)),
        throwsA(_hostError(BeamHostError.badNode)),
      );
    });
  });

  group('layout', () {
    final host = ProcessHost(rootDir: '/data/beam');

    test('directories hang off the root', () {
      expect(host.runDir, p.normalize('/data/beam/run'));
      expect(host.logsDir, p.normalize('/data/beam/run/logs'));
      expect(host.nodeDir, p.normalize('/data/beam/node'));
      expect(
        host.walletDirFor('wallet_1-A'),
        p.normalize('/data/beam/wallets/wallet_1-A'),
      );
    });

    test('wallet ids cannot escape the wallets directory', () {
      for (final bad in ['..', '../x', 'a/b', '', 'x' * 65, 'a b']) {
        expect(
          () => host.walletDirFor(bad),
          throwsA(_hostError(BeamHostError.invalidInput)),
          reason: bad,
        );
      }
    });
  });
}
