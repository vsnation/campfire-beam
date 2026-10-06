/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Read-only round trip against a real wallet-api in TCP line mode.
//
// Skipped unless BEAM_LIVE_TCP_PORT and BEAM_LIVE_TCP_KEY are set:
//
//   python3 -I scripts/beam/live/wapi.py start funder --port 10101 --tcp
//   export BEAM_LIVE_TCP_PORT=10101
//   export BEAM_LIVE_TCP_KEY="$(python3 -I -c 'import json, pathlib;
//     p = pathlib.Path.home() / "beam-campfire-test/run/funder.json";
//     print(json.load(open(p))["key"])')"
//   flutter test test/beam/core/live_tcp_test.dart
//   python3 -I scripts/beam/live/wapi.py stop funder
//
// Prints heights, counts, versions and event names only: never balances,
// addresses, tx ids or the key.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

/// Refuses anything but read-only methods, so this test cannot move funds or
/// change the wallet even if someone edits it carelessly.
class ReadOnlyGuard implements BeamTransport {
  ReadOnlyGuard(this.inner);

  static const allowed = {
    'get_version',
    'wallet_status',
    'tx_list',
    'assets_list',
    'ev_subunsub',
  };

  final BeamTransport inner;
  final sent = <String>[];

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    if (!allowed.contains(method)) {
      throw StateError('live test refused non-read-only method $method');
    }
    sent.add(method);
    return inner.call(method, params, timeout);
  }

  @override
  Future<void> connect() => inner.connect();
  @override
  bool get isConnected => inner.isConnected;
  @override
  Stream<BeamEvent> get events => inner.events;
  @override
  Future<void> close() => inner.close();
}

void main() {
  final port = int.tryParse(Platform.environment['BEAM_LIVE_TCP_PORT'] ?? '');
  final key = Platform.environment['BEAM_LIVE_TCP_KEY'] ?? '';
  final skip = (port == null || key.isEmpty)
      ? 'set BEAM_LIVE_TCP_PORT and BEAM_LIVE_TCP_KEY to run'
      : null;

  test('read-only calls and push events over TCP line mode', () async {
    final log = <String>[];
    final tcp = TcpLineTransport(port: port!, aclKey: key, log: log.add);
    final guard = ReadOnlyGuard(tcp);
    final api = BeamApi(guard);

    final events = <BeamEvent>[];
    final firstState = Completer<BeamEvent>();
    final sub = guard.events.listen((e) {
      events.add(e);
      if ((e.name == 'ev_system_state' || e.name == 'ev_sync_progress') &&
          !firstState.isCompleted) {
        firstState.complete(e);
      }
    });

    await guard.connect();
    expect(guard.isConnected, isTrue);

    final v = await api.getVersion();
    print(
      'get_version: api ${v.apiVersion}, beam ${v.beamVersion}, '
      'network ${v.networkName}',
    );
    expect(v.apiVersionMajor, 7);

    final s = await api.walletStatus();
    final age = DateTime.now().toUtc().difference(s.currentStateTime);
    print(
      'wallet_status: height ${s.currentHeight}, is_in_sync ${s.isInSync}, '
      'block age ${age.inSeconds} s, ${s.totals.length} asset totals',
    );
    expect(s.currentHeight, greaterThan(3928666));

    final txs = await api.txList(count: 5);
    print(
      'tx_list(count 5): ${txs.length} txs, statuses '
      '${txs.map((t) => t.status.name).toSet()}',
    );
    expect(txs.length, lessThanOrEqualTo(5));

    final assets = await api.assetsList();
    final labelled = assets.where((a) => a.metadata.nthRatio != null).length;
    print(
      'assets_list: ${assets.length} assets, $labelled with an NTH_RATIO '
      'label (informational; all shown with 8 decimals)',
    );
    expect(assets, isNotEmpty);

    final sw = Stopwatch()..start();
    expect(await api.subscribeEvents(), isTrue);
    final ev = await firstState.future.timeout(const Duration(seconds: 60));
    print(
      'first state event: ${ev.name} after ${sw.elapsedMilliseconds} ms, '
      'current_height ${ev.data['current_height']}, '
      'tip_height ${ev.data['tip_height']}',
    );
    // Give the initial snapshots of the other streams a moment to land.
    await Future<void>.delayed(const Duration(seconds: 3));
    final counts = <String, int>{};
    for (final e in events) {
      counts[e.name] = (counts[e.name] ?? 0) + 1;
    }
    print('events received: $counts');
    print('methods sent: ${guard.sent}');
    print('transport log: ${log.join(' | ')}');
    expect(guard.sent.toSet().difference(ReadOnlyGuard.allowed), isEmpty);

    await sub.cancel();
    await guard.close();
    expect(guard.isConnected, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('a wrong ACL key is refused by the core', () async {
    final tcp = TcpLineTransport(
      port: port!,
      aclKey: 'f' * key.length,
      log: (_) {},
    );
    await tcp.connect();
    await expectLater(
      tcp.call('get_version'),
      throwsA(isA<BeamRpcException>().having((e) => e.code, 'code', -32002)),
    );
    print('wrong ACL key: refused with -32002 as expected');
    await tcp.close();
  }, skip: skip);
}
