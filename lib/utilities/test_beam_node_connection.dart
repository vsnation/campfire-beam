/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';

import '../app_config.dart';
import '../providers/global/prefs_provider.dart';
import '../services/tor_service.dart';

/// What "Test connection" found at a BEAM node address.
enum BeamNodeTestResult {
  /// A BEAM node answered the start of its handshake.
  beamNode,

  /// Something answered, but not a BEAM node (e.g. a web server, or the
  /// wallet's own API port).
  notBeamNode,

  /// The connection opened, but nothing answered.
  noReply,

  /// Nothing accepted the connection (wrong host or port, offline, or the
  /// Tor proxy refused it).
  unreachable,

  /// Not a usable `host` and `port`.
  invalidAddress,
}

/// BEAM node addresses are `host:port`, not URLs (research/01 step 20).
/// The host rule is the one the wallet core is launched with
/// (`ProcessHost.validateNode`), so a node that passes here also opens.
abstract final class BeamNodeAddress {
  static final RegExp _host = RegExp(r'^[A-Za-z0-9][A-Za-z0-9.\-]*$');

  /// Null when [host] is usable, otherwise what is wrong in plain words.
  static String? hostProblem(String host) {
    final h = host.trim();
    if (h.isEmpty) return 'Enter the node address';
    if (RegExp(r'^[A-Za-z0-9.\-]+:\d*$').hasMatch(h)) {
      return 'Put the port number in the Port field';
    }
    if (h.length > 253 || !_host.hasMatch(h)) {
      return 'Use a host name like eu-nodes.mainnet.beam.mw or an IP '
          'address, without http:// or a path';
    }
    return null;
  }

  static bool isValidPort(int? port) =>
      port != null && port > 0 && port <= 65535;

  /// Splits what someone pasted ("eu-nodes.mainnet.beam.mw:8100",
  /// "tcp://1.2.3.4:8100 ", "node.example") into host and port.
  static ({String host, int? port}) split(String input) {
    var s = input.trim();
    final scheme = s.indexOf('://');
    if (scheme >= 0) s = s.substring(scheme + 3);
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    final colon = s.lastIndexOf(':');
    if (colon > 0 && colon == s.indexOf(':')) {
      final port = int.tryParse(s.substring(colon + 1));
      if (port != null) return (host: s.substring(0, colon), port: port);
    }
    return (host: s, port: null);
  }
}

/// One line for the result, never blaming the user.
String beamNodeTestMessage(BeamNodeTestResult r, String address) =>
    switch (r) {
      BeamNodeTestResult.beamNode => 'BEAM node found at $address',
      BeamNodeTestResult.notBeamNode =>
        "Something answers at $address, but it isn't a BEAM node. "
            'BEAM nodes usually use port 8100.',
      BeamNodeTestResult.noReply =>
        'Connected to $address, but no BEAM node answered. Try again in a '
            'moment.',
      BeamNodeTestResult.unreachable =>
        'No BEAM node answered at $address. Check the address and your '
            'internet connection.',
      BeamNodeTestResult.invalidAddress =>
        'Enter a host like eu-nodes.mainnet.beam.mw and a port like 8100.',
    };

/// The first 4 bytes of a BEAM node's answer to a handshake: "Bm", protocol
/// version 10, message 0x04 (`SChannelInitiate`) — `core/proto.cpp:339`,
/// `core/proto.h:349` at tag beam-7.5.14493. Measured 2026-10-06: both
/// `eu-nodes` and `us-nodes.mainnet.beam.mw:8100` answer
/// `42 6d 0a 04 20 00 00 00`; a web server answers `HTTP/1.1`.
const List<int> kBeamNodeHandshakeReply = [0x42, 0x6d, 0x0a, 0x04];

/// Tests [host]:[port] the way the wallet will use it: a TCP connection,
/// then the opening message of BEAM's node handshake (`SChannelInitiate`
/// with a fresh, valid curve point, exactly what a connecting wallet sends
/// first) and a check of the node's reply. The connection is closed right
/// after, as any client that leaves would.
///
/// With [proxyInfo] (Tor on), the connection goes through that SOCKS5 proxy
/// and the host name is resolved by the proxy, not on this device.
Future<BeamNodeTestResult> testBeamNodeConnection({
  required String host,
  required int port,
  ({InternetAddress host, int port})? proxyInfo,
  Duration? timeout,
  Random? random,
}) async {
  final h = host.trim();
  if (BeamNodeAddress.hostProblem(h) != null ||
      !BeamNodeAddress.isValidPort(port)) {
    return BeamNodeTestResult.invalidAddress;
  }
  final wait =
      timeout ??
      (proxyInfo == null
          ? const Duration(seconds: 10)
          : const Duration(seconds: 30));
  Socket socket;
  _ByteReader reader;
  try {
    if (proxyInfo == null) {
      socket = await Socket.connect(h, port, timeout: wait);
      reader = _ByteReader(socket);
    } else {
      socket = await Socket.connect(
        proxyInfo.host,
        proxyInfo.port,
        timeout: wait,
      );
      reader = _ByteReader(socket);
      if (!await _socks5Connect(socket, reader, h, port, wait)) {
        reader.cancel();
        socket.destroy();
        return BeamNodeTestResult.unreachable;
      }
    }
  } catch (_) {
    return BeamNodeTestResult.unreachable;
  }

  try {
    socket.add(beamNodeHandshakeOpening(random ?? Random.secure()));
    await socket.flush();
    final reply = await reader.take(kBeamNodeHandshakeReply.length, wait);
    if (reply == null) return BeamNodeTestResult.noReply;
    for (var i = 0; i < kBeamNodeHandshakeReply.length; i++) {
      if (reply[i] != kBeamNodeHandshakeReply[i]) {
        return BeamNodeTestResult.notBeamNode;
      }
    }
    return BeamNodeTestResult.beamNode;
  } catch (_) {
    return BeamNodeTestResult.noReply;
  } finally {
    reader.cancel();
    socket.destroy();
  }
}

/// The 40 bytes a connecting BEAM peer sends first: the 8-byte header
/// ("Bm", version 10, type 0x04, size 32 little-endian) and a nonce public
/// key — the x coordinate of k·G on secp256k1 for a random k, big-endian.
/// A valid point, so the node goes down its normal path and simply sees a
/// client leave.
Uint8List beamNodeHandshakeOpening(Random random) {
  final curve = ECCurve_secp256k1();
  BigInt k;
  do {
    var v = BigInt.zero;
    for (var i = 0; i < 32; i++) {
      v = (v << 8) | BigInt.from(random.nextInt(256));
    }
    k = v % curve.n;
  } while (k == BigInt.zero);
  final x = (curve.G * k)!.x!.toBigInteger()!;
  final out = Uint8List(40)
    ..setAll(0, kBeamNodeHandshakeReply)
    ..setAll(4, const [32, 0, 0, 0]);
  for (var i = 0; i < 32; i++) {
    out[39 - i] = ((x >> (8 * i)) & BigInt.from(0xff)).toInt();
  }
  return out;
}

/// SOCKS5 CONNECT by domain name (RFC 1928): the proxy resolves [host].
Future<bool> _socks5Connect(
  Socket socket,
  _ByteReader reader,
  String host,
  int port,
  Duration wait,
) async {
  socket.add(const [0x05, 0x01, 0x00]); // version 5, one method: no auth
  final method = await reader.take(2, wait);
  if (method == null || method[0] != 0x05 || method[1] != 0x00) return false;
  final name = ascii.encode(host);
  socket.add([
    0x05, 0x01, 0x00, 0x03, name.length, ...name, //
    (port >> 8) & 0xff, port & 0xff,
  ]);
  final head = await reader.take(4, wait);
  if (head == null || head[0] != 0x05 || head[1] != 0x00) return false;
  final rest = switch (head[3]) {
    0x01 => 4 + 2,
    0x04 => 16 + 2,
    0x03 => ((await reader.take(1, wait))?.first ?? 0) + 2,
    _ => -1,
  };
  if (rest < 0) return false;
  return await reader.take(rest, wait) != null;
}

/// Reads exact byte counts from a socket.
class _ByteReader {
  _ByteReader(Socket socket) {
    _sub = socket.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onError: (Object _) {
        _closed = true;
        _wake();
      },
      onDone: () {
        _closed = true;
        _wake();
      },
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buffer = [];
  bool _closed = false;
  Completer<void>? _waiter;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// The next [n] bytes, or null if the peer closed or [wait] passed first.
  Future<List<int>?> take(int n, Duration wait) async {
    final deadline = DateTime.now().add(wait);
    while (_buffer.length < n) {
      if (_closed) return null;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      final w = _waiter = Completer<void>();
      await w.future.timeout(left, onTimeout: () {});
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  void cancel() => unawaited(_sub.cancel());
}

/// [testBeamNodeConnection] with Campfire's Tor setting applied. Widget
/// tests override it.
typedef BeamNodeConnectionTester =
    Future<BeamNodeTestResult> Function({
      required String host,
      required int port,
    });

final testBeamNodeConnectionProvider = Provider<BeamNodeConnectionTester>((
  ref,
) {
  return ({required String host, required int port}) {
    final useTor =
        AppConfig.hasFeature(AppFeature.tor) &&
        ref.read(prefsChangeNotifierProvider).useTor;
    return testBeamNodeConnection(
      host: host,
      port: port,
      proxyInfo: useTor ? ref.read(pTorService).getProxyInfo() : null,
    );
  };
});
