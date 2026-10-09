/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A SOCKS5 proxy on 127.0.0.1 standing in for Tor's: it records every
// CONNECT (the name or address asked for, and the port) and relays the
// connection to [target] (a local server), whatever name was asked. And a
// JSON-RPC server that answers eth_chainId / eth_blockNumber and records
// what reached it. No traffic leaves this machine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

typedef SocksConnect = ({int addressType, String host, int port});

class FakeSocksProxy {
  FakeSocksProxy._(this._server, this.target);

  /// Relays to [target]; with [target] null it records the request, answers
  /// "host unreachable", or (with [keepFirstBytes]) keeps the first bytes
  /// the client sends after the handshake and closes.
  static Future<FakeSocksProxy> start({
    ({InternetAddress host, int port})? target,
    bool keepFirstBytes = false,
  }) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FakeSocksProxy._(server, target)
      .._keepFirstBytes = keepFirstBytes;
    server.listen(proxy._serve);
    return proxy;
  }

  final ServerSocket _server;
  final ({InternetAddress host, int port})? target;
  bool _keepFirstBytes = false;

  final List<SocksConnect> connects = [];
  final List<List<int>> firstBytes = [];
  int connections = 0;

  ({InternetAddress host, int port}) get info =>
      (host: InternetAddress.loopbackIPv4, port: _server.port);

  Future<void> _serve(Socket client) async {
    connections++;
    final buffer = <int>[];
    final more = StreamController<void>.broadcast();
    var done = false;
    late final StreamSubscription<Uint8List> sub;
    Socket? upstream;
    var relaying = false;
    sub = client.listen(
      (data) {
        if (relaying) {
          upstream?.add(data);
          return;
        }
        buffer.addAll(data);
        more.add(null);
      },
      onDone: () {
        done = true;
        more.add(null);
        upstream?.destroy();
      },
      onError: (Object _) {},
    );
    Future<List<int>?> take(int n) async {
      while (buffer.length < n) {
        if (done) return null;
        await more.stream.first;
      }
      final out = buffer.sublist(0, n);
      buffer.removeRange(0, n);
      return out;
    }

    try {
      final hello = await take(2);
      if (hello == null) return;
      await take(hello[1]);
      client.add([0x05, 0x00]);
      final head = await take(4);
      if (head == null) return;
      final String host;
      switch (head[3]) {
        case 0x03:
          final len = (await take(1))!.first;
          host = ascii.decode((await take(len))!);
        case 0x01:
          host = InternetAddress.fromRawAddress(
            Uint8List.fromList((await take(4))!),
          ).address;
        default:
          host = '?';
      }
      final p = (await take(2))!;
      connects.add((addressType: head[3], host: host, port: p[0] << 8 | p[1]));

      final t = target;
      if (t == null) {
        if (_keepFirstBytes) {
          client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
          firstBytes.add(await take(1) ?? const []);
        } else {
          client.add([0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        }
        await client.flush();
        client.destroy();
        return;
      }
      upstream = await Socket.connect(t.host, t.port);
      client.add([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]);
      relaying = true;
      if (buffer.isNotEmpty) upstream.add(List.of(buffer));
      buffer.clear();
      upstream.listen(
        client.add,
        onDone: client.destroy,
        onError: (Object _) => client.destroy(),
      );
    } catch (_) {
      client.destroy();
      await sub.cancel();
    }
  }

  Future<void> close() => _server.close();
}

/// A JSON-RPC server for eth_chainId and eth_blockNumber. [silent]: accepts
/// connections and never answers.
class FakeEthRpc {
  FakeEthRpc._(this._server);

  static Future<FakeEthRpc> start({
    int chainId = 1,
    int blockNumber = 21000000,
    bool silent = false,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rpc = FakeEthRpc._(server);
    server.listen((req) async {
      final body = await utf8.decodeStream(req);
      rpc.requests.add((path: req.uri.path, body: body));
      if (silent) return;
      final call = jsonDecode(body) as Map;
      final result = switch (call['method']) {
        'eth_chainId' => '0x${chainId.toRadixString(16)}',
        'eth_blockNumber' => '0x${blockNumber.toRadixString(16)}',
        _ => null,
      };
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': result}),
        );
      await req.response.close();
    });
    return rpc;
  }

  final HttpServer _server;
  final List<({String path, String body})> requests = [];

  int get port => _server.port;

  ({InternetAddress host, int port}) get address =>
      (host: InternetAddress.loopbackIPv4, port: _server.port);

  List<String> get methods => [
    for (final r in requests) (jsonDecode(r.body) as Map)['method'] as String,
  ];

  Future<void> close() => _server.close(force: true);
}
