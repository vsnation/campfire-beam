/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Shared by the gated live tests of the Airdrop, Minter and BlackHole
// modules: a transport guard that lets nothing through that could send a
// transaction, a recorder for fixtures, and the connection to the funder's
// wallet-api (port and ACL key read from its 0600 state file; the key is
// never printed).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/rpc/tcp_line_transport.dart';

/// Lets through `get_version`, `wallet_status` and `invoke_contract` with
/// `create_tx: false` for an allow-listed action only. `process_invoke_data`
/// and everything else is refused before it reaches the core: these tests
/// build transactions to read them, and must never be able to send one.
class BuildOnlyGuard implements BeamTransport {
  BuildOnlyGuard(this.inner, this.allowedActions);

  final BeamTransport inner;
  final Set<String> allowedActions;

  /// Every request that went through, `args` only (the shader bytes are
  /// dropped), with its result: the raw material for fixtures.
  final recorded = <({String method, String? args, Object? result})>[];

  bool allows(String method, Map<String, Object?> params) {
    if (method == 'get_version' || method == 'wallet_status') return true;
    if (method != 'invoke_contract') return false;
    if (params['create_tx'] != false) return false;
    final args = params['args'];
    if (args is! String) return false;
    final action = RegExp(r'(?:^|,)action=([a-z_]+)').firstMatch(args);
    return action != null && allowedActions.contains(action.group(1));
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    if (!allows(method, params)) {
      throw StateError('live test refused $method');
    }
    final r = await inner.call(method, params, timeout);
    recorded.add((method: method, args: params['args'] as String?, result: r));
    return r;
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

/// The funder's wallet-api, as `scripts/beam/live/wapi.py start funder
/// --tcp` left it.
TcpLineTransport funderTransport() {
  final home = Platform.environment['HOME']!;
  final state = jsonDecode(
    File('$home/beam-campfire-test/run/funder.json').readAsStringSync(),
  ) as Map<String, Object?>;
  if (state['mode'] != 'tcp') {
    throw StateError('start the funder with --tcp');
  }
  return TcpLineTransport(
    port: state['port']! as int,
    aclKey: state['key']! as String,
    defaultTimeout: const Duration(minutes: 3),
    log: (_) {},
  );
}

/// Where raw recordings go: outside the repo, owner-only.
Directory rawFixtureDir(String name) {
  final home = Platform.environment['HOME']!;
  final d = Directory('$home/beam-campfire-test/raw_fixtures/$name')
    ..createSync(recursive: true);
  Process.runSync('chmod', ['700', d.path]);
  return d;
}

/// The synthetic key every wallet-specific key is replaced with.
const fakeKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';

List<int> hexToBytes(String h) => [
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
];

/// [bytes] with every occurrence of [find] replaced by [replace] (same
/// length), and how many there were.
(List<int>, int) replaceBytes(List<int> bytes, List<int> find, List<int> to) {
  if (find.length != to.length) throw ArgumentError('length mismatch');
  final out = List<int>.of(bytes);
  var n = 0;
  for (var i = 0; i + find.length <= out.length; i++) {
    var hit = true;
    for (var j = 0; j < find.length; j++) {
      if (out[i + j] != find[j]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      out.setRange(i, i + find.length, to);
      n++;
    }
  }
  return (out, n);
}

/// Writes a JSON-RPC envelope like the recorded fixtures of other modules.
void writeEnvelope(File f, Object? result) {
  f.writeAsStringSync(
    const JsonEncoder.withIndent(' ')
        .convert({'id': 1, 'jsonrpc': '2.0', 'result': result}),
  );
  Process.runSync('chmod', ['600', f.path]);
}
