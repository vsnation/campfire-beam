/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamNodeLogParser and BeamNodeLogRedactor against real beam-node console
// lines: a restart of an existing node (LightWallet's node_data/logs,
// 7.5.13882, February 2026) and a fresh mainnet fast sync (7.5.14493,
// captured by beam_private_node_live_test.dart on 2026-10-06). Only public
// chain data is kept: heights, block hashes, public peer addresses. Owned
// account endpoints and node ids are replaced with made-up values.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_progress.dart';

/// A restart of a node that already had most of the chain (real lines, the
/// four owned-account endpoints and the node id replaced).
const _restartLog = [
  'I 2026-02-13.13:15:26.135 Beam Node 7.5.13882 (master)',
  'I 2026-02-13.13:15:26.135 Rules signature: network=mainnet',
  '\t0-ed91a717313c6eb0',
  '\t321321-6d622e615cfd29d0',
  '\t777777-1ce8f721bf0c9fa7',
  '\t1280000-3eaab6ab65b65f94',
  '\t1820000-b5a8b6b3617812c0',
  '\t1920000-1a68bdc7d7756bb4',
  'E 2026-02-13.13:15:26.235 unable to resolve: '
      'ap-node01.mainnet.beam.mw:8100',
  'I 2026-02-13.13:15:26.235 starting a node on 10005 port...',
  'I 2026-02-13.13:15:26.258 Mapping image found',
  'I 2026-02-13.13:15:26.260 Node ID=0123456789abcdef',
  'I 2026-02-13.13:15:26.261 Initial Tip: 3730843-c83dec48598edc09',
  'I 2026-02-13.13:15:26.261 Tx replication is OFF',
  'I 2026-02-13.13:15:26.261 Owned accounts :',
  '\tFakeEndpointAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
  '\tFakeEndpointBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
  '',
  'W 2026-02-13.13:15:27.278 Peer 188.245.67.33:8100 uses newer ext: 11',
  'I 2026-02-13.13:15:27.278 Tx replication is ON',
  'I 2026-02-13.13:15:27.279 Updating node: 100% (1/1)',
  'I 2026-02-11.18:28:57.397 Peer 188.245.67.32:8100 Tip: '
      '3728265-3d6f98c3eac6c7a0',
  'I 2026-02-11.18:28:57.406 Peer 188.245.67.33:8100 Tip: '
      '3728265-3d6f98c3eac6c7a0',
  'I 2026-02-11.18:28:57.406 Peer 188.245.67.33:8100 Tip: '
      '3728266-1d6f98c3eac6c7a0',
  'I 2026-02-13.13:16:01.004 My Tip: 3734003-b55ff18ce6dea0ab, '
      'Work = 2.51645e+14',
];

/// Fast sync of an older binary (real lines, 7.5.13882).
const _oldFastSync = [
  'I 2026-02-11.13:49:50.019 Updating node: 0% (0/52919)',
  'I 2026-02-11.13:49:52.000 Fast-sync mode up to height 3726551',
  'I 2026-02-11.13:50:23.554 Fast-sync succeeded',
  'I 2026-02-14.12:23:24.404 Updating node: 100% (10008/10008)',
];

/// A fresh fast sync, in the format BEAM 7.5.14493 prints
/// (`processor.cpp:397`, `:1916`, `:1959`). Heights are mainnet heights
/// from 2026-10-06.
const _freshFastSync = [
  'I 2026-10-06.12:10:00.001 Initial Tip: 0-0000000000000000',
  'I 2026-10-06.12:10:00.001 Tx replication is OFF',
  'I 2026-10-06.12:10:00.002 Owned accounts :',
  '\tFakeEndpointCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
  '',
  'I 2026-10-06.12:10:03.120 Updating node: 0% (0/4068050)',
  'I 2026-10-06.12:12:41.880 Updating node: 43% (1749261/4068050)',
  'I 2026-10-06.12:20:00.000 Fast-sync mode up to block number 4066610, '
      'TxoLo=4062290',
  'I 2026-10-06.12:25:00.000 Updating node: 87% (3539203/4068050)',
  'W 2026-10-06.12:26:00.000 Fast-sync failed: Utxo unsigned',
  'I 2026-10-06.12:30:00.000 Fast-sync succeeded',
  'I 2026-10-06.12:30:01.000 My Tip: 4066611-aabbccddeeff0011, '
      'Work = 2.71e+14',
  'I 2026-10-06.12:31:00.000 Updating node: 100% (4068050/4068050)',
  'I 2026-10-06.12:31:00.001 Tx replication is ON',
  'I 2026-10-06.12:32:00.000 My Tip: 4068051-0011aabbccddeeff, '
      'Work = 2.71e+14',
];

/// The first minutes of a real fresh node (7.5.14493, this repo's live
/// test, 2026-10-06; the owned-account endpoint replaced). BEAM logged
/// `Tx replication is ON` during the header download, at height 0, and will
/// not log it again in this process (`node.cpp:85-87`).
const _liveFreshStart = [
  'I 2026-10-06.12:09:16.116 Beam Node 7.5.1 (HEAD)',
  'I 2026-10-06.12:09:16.258 starting a node on 62462 port...',
  'I 2026-10-06.12:09:16.260 Rebuilding mapped image...',
  'I 2026-10-06.12:09:16.261 Initial Tip: 0-0000000000000000',
  'I 2026-10-06.12:09:16.261 Tx replication is OFF',
  'I 2026-10-06.12:09:16.261 Owned accounts added: 1',
  'I 2026-10-06.12:09:16.261 Rescanning owned Txos...',
  'I 2026-10-06.12:09:16.261 Recovered 0/0 unspent/total Txos',
  'I 2026-10-06.12:09:16.261 Owned accounts :',
  '\tFakeEndpointFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
  '',
  'I 2026-10-06.12:09:16.261 Requesting block Num-0-0000000000000000',
  'I 2026-10-06.12:09:17.266 Peer 188.245.67.32:8100 Tip: '
      '4068124-d12c8d190e059546',
  'I 2026-10-06.12:09:17.268 Num-4068124-d12c8d190e059546 Header accepted',
  'I 2026-10-06.12:09:17.268 Updating node: 0% (0/9)',
  'I 2026-10-06.12:09:18.416 Treasury verified',
  'I 2026-10-06.12:09:18.427 My Tip: 0-0000000000000000',
  'I 2026-10-06.12:09:18.428 Requesting header Num-4068123-8e9d804e471333b1',
  'I 2026-10-06.12:09:18.428 Updating node: 0% (10/36613125)',
  'I 2026-10-06.12:11:20.997 Updating node: 1% (434188/36613143)',
  'I 2026-10-06.12:11:20.998 Tx replication is ON',
  'I 2026-10-06.12:11:20.998 Updating node: 100% (9/9)',
  'I 2026-10-06.12:11:21.762 Peer 188.245.67.35:8100 Tip: '
      '4068126-3588ac4415cbfe63',
  'I 2026-10-06.12:15:59.500 Updating node: 3% (1165330/36613197)',
];

List<BeamNodeProgress> _feed(BeamNodeLogParser parser, List<String> lines) => [
  for (final l in lines) ?parser.add(l),
];

void main() {
  group('BeamNodeLogParser', () {
    test('restart of an existing node: tips, owners, peers, the '
        'replication marker', () {
      final parser = BeamNodeLogParser(now: () => DateTime.utc(2026, 10, 6));
      final seen = _feed(parser, _restartLog);
      final last = parser.progress;
      expect(last.initialTipHeight, 3730843);
      expect(last.myTipHeight, 3734003);
      expect(last.myTipAt, DateTime.utc(2026, 10, 6));
      expect(last.ownerAccounts, 2);
      expect(last.peersSeen, 2, reason: 'distinct peers that sent a tip');
      expect(last.percent, 100);
      expect(last.phase, BeamNodePhase.txReplicationOn);
      expect(last.txReplicationOn, isTrue);
      expect(last.error, isNull);
      // No fast sync on a restart: starting, then straight to ready.
      expect(seen.map((s) => s.phase).toSet(), {
        BeamNodePhase.starting,
        BeamNodePhase.txReplicationOn,
      });
    });

    test('older "up to height" fast-sync line is understood', () {
      final parser = BeamNodeLogParser();
      _feed(parser, _oldFastSync.take(2).toList());
      expect(parser.progress.phase, BeamNodePhase.fastSyncDownloading);
      expect(parser.progress.fastSyncTarget, 3726551);
      _feed(parser, _oldFastSync.skip(2).toList());
      expect(parser.progress.phase, BeamNodePhase.catchingUp);
      expect(parser.progress.percent, 100);
    });

    test('fresh fast sync: downloading with %, failure retried, then '
        'catching up, then ready', () {
      final parser = BeamNodeLogParser();
      final phases = <BeamNodePhase>[];
      for (final line in _freshFastSync) {
        final p = parser.add(line);
        if (p != null && (phases.isEmpty || phases.last != p.phase)) {
          phases.add(p.phase);
        }
        if (line.contains('43%')) {
          expect(parser.progress.percent, 43);
          expect(
            parser.progress.txReplicationOn,
            isFalse,
            reason: 'not ready while downloading',
          );
        }
      }
      expect(phases, [
        BeamNodePhase.starting,
        BeamNodePhase.fastSyncDownloading,
        BeamNodePhase.catchingUp,
        BeamNodePhase.txReplicationOn,
      ]);
      final last = parser.progress;
      expect(last.fastSyncTarget, 4066610);
      expect(last.fastSyncFailures, 1);
      expect(last.myTipHeight, 4068051);
      expect(last.ownerAccounts, 1);
    });

    test('live fresh node: the early replication line at height 0 does '
        'not count; done == total after fast sync does', () {
      final parser = BeamNodeLogParser();
      _feed(parser, _liveFreshStart);
      expect(parser.progress.txReplicationOn, isFalse);
      expect(parser.progress.phase, BeamNodePhase.starting);
      expect(parser.progress.ownerAccounts, 1);
      expect(parser.progress.myTipHeight, 0);
      expect(parser.progress.percent, 3);
      expect(parser.progress.peersSeen, 2);
      _feed(parser, [
        'I 2026-10-06.12:40:00.000 Fast-sync mode up to block number '
            '4066610, TxoLo=4062290',
        'I 2026-10-06.12:41:00.000 Updating node: 100% (36613197/36613197)',
      ]);
      expect(
        parser.progress.txReplicationOn,
        isFalse,
        reason: '100% during fast sync is not the tip',
      );
      _feed(parser, [
        'I 2026-10-06.12:50:00.000 Fast-sync succeeded',
        'I 2026-10-06.12:50:01.000 My Tip: 4066611-aabbccddeeff0011, '
            'Work = 2.71e+14',
        'I 2026-10-06.12:50:02.000 Updating node: 99% (36613190/36613197)',
      ]);
      expect(parser.progress.phase, BeamNodePhase.catchingUp);
      parser.add(
        'I 2026-10-06.12:52:00.000 Updating node: 100% (36613197/36613197)',
      );
      expect(parser.progress.phase, BeamNodePhase.txReplicationOn);
    });

    test('Tx replication ON inside fast sync does not count', () {
      final parser = BeamNodeLogParser();
      _feed(parser, [
        'I 2026-10-06.12:20:00.000 Fast-sync mode up to block number 10, '
            'TxoLo=5',
        'I 2026-10-06.12:20:01.000 Tx replication is ON',
      ]);
      expect(parser.progress.txReplicationOn, isFalse);
      expect(parser.progress.phase, BeamNodePhase.fastSyncDownloading);
    });

    test('a node started from storage mid-fast-sync is downloading, not '
        'ready', () {
      final parser = BeamNodeLogParser();
      _feed(parser, [
        'I 2026-10-06.12:20:00.000 Fast-sync mode up to block number '
            '4066610, TxoLo=4062290',
        'I 2026-10-06.12:20:00.001 Initial Tip: 2000000-00aa00bb00cc00dd',
        'I 2026-10-06.12:20:00.002 Tx replication is OFF',
      ]);
      expect(parser.progress.phase, BeamNodePhase.fastSyncDownloading);
    });

    test('key import failed is a typed key rejection (BEAM exits 0)', () {
      final parser = BeamNodeLogParser();
      _feed(parser, [
        'Reading config from /x/node/.s-0123456789abcdef.cfg',
        'I 2026-10-06.12:00:00.000 Rules signature: network=mainnet',
        'E 2026-10-06.12:00:00.100 key import failed',
      ]);
      expect(parser.progress.phase, BeamNodePhase.error);
      expect(parser.progress.error, BeamNodeError.ownerKeyRejected);
      final end = parser.finish(exitCode: 0, requested: false);
      expect(end.error, BeamNodeError.ownerKeyRejected);
      expect(end.exitCode, 0);
    });

    test('missing password for the key is a key rejection', () {
      final parser = BeamNodeLogParser();
      parser.add(
        'E 2026-10-06.12:00:00.100 Please, provide password for the keys.',
      );
      expect(parser.progress.error, BeamNodeError.ownerKeyRejected);
    });

    test('an empty owned-accounts list is refused: no keyless node', () {
      final parser = BeamNodeLogParser();
      _feed(parser, [
        'I 2026-10-06.12:00:00.000 Owned accounts :',
        '',
        'I 2026-10-06.12:00:01.000 Tx replication is ON',
      ]);
      expect(parser.progress.ownerAccounts, 0);
      expect(parser.progress.error, BeamNodeError.ownerKeyRejected);
      expect(
        parser.progress.phase,
        BeamNodePhase.error,
        reason: 'later lines do not revive a refused node',
      );
    });

    test('corruption and port failures are typed', () {
      final a = BeamNodeLogParser()..add('Corruption: 1row change failed');
      expect(a.progress.error, BeamNodeError.corrupted);
      final b = BeamNodeLogParser()
        ..add('E 2026-10-06.12:00:00.000 bind failed: address already in use');
      expect(b.progress.error, BeamNodeError.portUnavailable);
    });

    test('exit codes: requested stop vs crash', () {
      final a = BeamNodeLogParser()..add(_restartLog.last);
      expect(
        a.finish(exitCode: -15, requested: true).phase,
        BeamNodePhase.stopped,
      );
      final b = BeamNodeLogParser()..add(_restartLog.last);
      final end = b.finish(exitCode: -9, requested: false);
      expect(end.phase, BeamNodePhase.error);
      expect(end.error, BeamNodeError.exited);
      expect(end.myTipHeight, 3734003, reason: 'last height is kept');
    });

    test('a stale node at the HF6 boundary still parses as "ready"; the '
        'coordinator, not the parser, refuses it', () {
      final parser = BeamNodeLogParser();
      _feed(parser, [
        'I 2026-07-01.10:00:00.000 Initial Tip: 3928665-8f1d2c3b4a596877',
        'I 2026-07-01.10:00:00.000 Tx replication is OFF',
        'I 2026-07-01.10:00:00.000 Owned accounts :',
        '\tFakeEndpointDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD',
        '',
        'I 2026-07-01.10:00:01.000 Tx replication is ON',
        'I 2026-07-01.10:00:01.000 Updating node: 100% (1/1)',
      ]);
      expect(parser.progress.txReplicationOn, isTrue);
      expect(parser.progress.bestHeight, 3928665);
    });
  });

  group('BeamNodeLogRedactor', () {
    test('owned-account endpoints are withheld, the rules signature is '
        'kept, transaction dumps are dropped', () {
      final r = BeamNodeLogRedactor();
      final out = [
        for (final l in [
          ..._restartLog,
          'I 2026-02-13.13:15:27.548 Tx 4f12e907fc388dec',
          '\tI: 00e88f57f7f9075d',
          '\tO: 0eaaef6f2d49f12b',
        ])
          ?r.redact(l),
      ];
      final text = out.join('\n');
      expect(text, isNot(contains('FakeEndpoint')));
      expect(text, contains('\t[withheld]'));
      expect(text, contains('\t1920000-1a68bdc7d7756bb4'));
      expect(text, contains('My Tip: 3734003-b55ff18ce6dea0ab'));
      expect(text, isNot(contains('00e88f57f7f9075d')));
      expect(text, contains('Tx 4f12e907fc388dec'));
    });

    test('anything mentioning a key or password is withheld; BEAM\'s fixed '
        'errors are kept', () {
      final r = BeamNodeLogRedactor(['Hunter2-Correct-Horse']);
      expect(
        r.redact('owner_key=AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHH'),
        '[line withheld]',
      );
      expect(r.redact('E 2026-10-06.12:00:00.000 pass=x'), '[line withheld]');
      expect(
        r.redact('E 2026-10-06.12:00:00.000 key import failed'),
        'E 2026-10-06.12:00:00.000 key import failed',
      );
      expect(
        r.redact(
          'E 2026-10-06.12:00:00.000 Please, provide password for the keys.',
        ),
        'E 2026-10-06.12:00:00.000 Please, provide password for the keys.',
      );
      expect(
        r.redact('I 2026-10-06.12:00:00.000 echo Hunter2-Correct-Horse'),
        'I 2026-10-06.12:00:00.000 echo [redacted]',
      );
    });

    test('base64-shaped tokens are replaced, hex hashes kept', () {
      final r = BeamNodeLogRedactor();
      const b64 = 'Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6cXV4Zm9vYmFyYmF6+/==';
      expect(
        r.redact('I 2026-10-06.12:00:00.000 something $b64 here'),
        'I 2026-10-06.12:00:00.000 something [redacted] here',
      );
      const hex =
          '5544224be139a4aa5544224be139a4aa5544224be139a4aa5544224be139a4aa';
      expect(
        r.redact('I 2026-10-06.12:00:00.000 block $hex'),
        'I 2026-10-06.12:00:00.000 block $hex',
      );
    });

    test('a real "Reading config from" line passes (it holds a path only)',
        () {
      final r = BeamNodeLogRedactor();
      const line = 'Reading config from /x/node/.s-0123456789abcdef.cfg';
      expect(r.redact(line), line);
    });
  });
}
