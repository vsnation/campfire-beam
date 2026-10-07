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
import 'dart:typed_data';

import '../../../services/tor_service.dart';
import '../host/beam_host.dart';
import '../host/beam_host_exception.dart';
import '../node/beam_private_node_preference.dart';

/// How the BEAM core reaches one node: the address it is given and, with
/// Tor on, the SOCKS5 proxy every connection goes through.
///
/// BEAM's SOCKS5 client sends IPv4 addresses only (proxy_connector.cpp
/// `Socks5_Protocol::makeRequest`): handed a host name it would resolve it
/// with this machine's DNS, outside Tor. So with Tor on, the name is resolved
/// THROUGH Tor (SOCKS5 RESOLVE, a Tor extension Arti implements) and the core
/// gets `ip:port` plus the proxy. The user's own node on 127.0.0.1 is reached
/// directly (it is this machine); the node's peers go through the proxy too.
class BeamNodeRoute {
  const BeamNodeRoute({required this.address, this.socksProxy});

  /// What the core connects to: `host:port` without Tor, `ip:port` with it.
  final BeamNodeEndpoint address;

  /// `127.0.0.1:<port>` of Tor's SOCKS5 proxy, or null for a direct
  /// connection.
  final String? socksProxy;

  bool get viaTor => socksProxy != null;

  @override
  String toString() => viaTor ? '$address via Tor' : '$address';
}

/// Resolves [BeamNodeEndpoint]s into [BeamNodeRoute]s, following Campfire's
/// Tor setting at the moment of each call. Fails closed: with Tor on and not
/// connected, or a name Tor cannot resolve, it throws and nothing connects.
abstract class BeamNodeRouter {
  /// Campfire's Tor switch and its embedded Arti.
  factory BeamNodeRouter.campfire() = _CampfireRouter;

  /// Always direct (tests, and builds without Tor).
  const factory BeamNodeRouter.direct() = _DirectRouter;

  /// True when connections must go through Tor now.
  bool get torOn;

  Future<BeamNodeRoute> route(BeamNodeEndpoint node);
}

class _DirectRouter implements BeamNodeRouter {
  const _DirectRouter();

  @override
  bool get torOn => false;

  @override
  Future<BeamNodeRoute> route(BeamNodeEndpoint node) async =>
      BeamNodeRoute(address: node);
}

class _CampfireRouter implements BeamNodeRouter {
  _CampfireRouter();

  @override
  bool get torOn => campfireTorEnabled();

  @override
  Future<BeamNodeRoute> route(BeamNodeEndpoint node) async {
    if (!torOn || isLoopbackHost(node.host)) {
      return BeamNodeRoute(address: node);
    }
    final ({InternetAddress host, int port}) proxy;
    try {
      proxy = TorService.sharedInstance.getProxyInfo();
    } catch (_) {
      throw const BeamHostException(
        BeamHostError.torNotReady,
        'Tor is on but not connected yet; not connecting outside Tor',
      );
    }
    final ip = await resolveThroughTor(
      node.host,
      proxyHost: proxy.host,
      proxyPort: proxy.port,
    );
    return BeamNodeRoute(
      address: BeamNodeEndpoint(ip, node.port, isOwned: node.isOwned),
      socksProxy: '${proxy.host.address}:${proxy.port}',
    );
  }
}

/// 127.0.0.0/8, ::1 and `localhost`: this machine, never proxied.
bool isLoopbackHost(String host) {
  if (host == 'localhost') return true;
  final ip = InternetAddress.tryParse(host);
  return ip != null && ip.isLoopback;
}

/// Resolves [host] to an IPv4 address through Tor's SOCKS5 port with Tor's
/// RESOLVE extension (command 0xF0): the lookup happens at a Tor exit, so
/// neither this machine's DNS nor its network sees the name. An IPv4
/// literal is returned as is. Throws [BeamHostException] (badNode for a
/// name Tor cannot resolve, torNotReady when the proxy does not answer).
Future<String> resolveThroughTor(
  String host, {
  required InternetAddress proxyHost,
  required int proxyPort,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) {
    if (literal.type == InternetAddressType.IPv4) return host;
    // BEAM's SOCKS5 client cannot send IPv6.
    throw BeamHostException(
      BeamHostError.badNode,
      'IPv6 node addresses cannot be used through Tor: $host',
    );
  }
  final name = utf8.encode(host);
  if (name.isEmpty || name.length > 255) {
    throw BeamHostException(BeamHostError.badNode, 'Bad node name: $host');
  }
  Socket? socket;
  try {
    socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
    final reader = _SocksReader(socket);
    // Greeting: version 5, one method, "no authentication".
    socket.add(const [5, 1, 0]);
    final hello = await reader.take(2).timeout(timeout);
    if (hello[0] != 5 || hello[1] != 0) {
      throw const BeamHostException(
        BeamHostError.torNotReady,
        'Tor SOCKS refused the greeting',
      );
    }
    // RESOLVE: VER 5, CMD 0xF0, RSV 0, ATYP 3 (domain), len, name, port 0.
    socket.add([5, 0xF0, 0, 3, name.length, ...name, 0, 0]);
    final head = await reader.take(4).timeout(timeout);
    if (head[0] != 5) {
      throw const BeamHostException(
        BeamHostError.torNotReady,
        'Tor SOCKS sent a malformed reply',
      );
    }
    if (head[1] != 0) {
      throw BeamHostException(
        BeamHostError.badNode,
        'Tor could not resolve $host (SOCKS reply ${head[1]})',
      );
    }
    switch (head[3]) {
      case 1:
        final a = await reader.take(4 + 2).timeout(timeout);
        return InternetAddress.fromRawAddress(
          Uint8List.fromList(a.sublist(0, 4)),
        ).address;
      default:
        throw BeamHostException(
          BeamHostError.badNode,
          'Tor resolved $host to an address BEAM cannot use through a proxy '
          '(type ${head[3]})',
        );
    }
  } on BeamHostException {
    rethrow;
  } on TimeoutException {
    throw const BeamHostException(
      BeamHostError.torNotReady,
      'Tor did not answer in time',
    );
  } on SocketException catch (e) {
    throw BeamHostException(
      BeamHostError.torNotReady,
      'Tor SOCKS proxy unreachable: ${e.osError?.message ?? e.message}',
    );
  } finally {
    socket?.destroy();
  }
}

/// Reads exact byte counts from a socket.
class _SocksReader {
  _SocksReader(Socket socket) {
    _sub = socket.listen(
      (data) {
        _buffer.addAll(data);
        _pump();
      },
      onError: (Object e) => _fail(e),
      onDone: () => _fail(const SocketException('Tor SOCKS closed')),
      cancelOnError: true,
    );
  }

  late final StreamSubscription<Uint8List> _sub;
  final List<int> _buffer = [];
  Completer<List<int>>? _want;
  int _wantLength = 0;
  Object? _error;

  Future<List<int>> take(int n) {
    final c = Completer<List<int>>();
    _want = c;
    _wantLength = n;
    _pump();
    return c.future;
  }

  void _pump() {
    final c = _want;
    if (c == null) return;
    if (_error != null) {
      _want = null;
      c.completeError(_error!);
      return;
    }
    if (_buffer.length < _wantLength) return;
    final out = _buffer.sublist(0, _wantLength);
    _buffer.removeRange(0, _wantLength);
    _want = null;
    c.complete(out);
  }

  void _fail(Object e) {
    _error = e;
    _pump();
    unawaited(_sub.cancel());
  }
}
