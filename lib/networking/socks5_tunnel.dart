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

import 'package:async/async.dart';

/// Where Tor's SOCKS5 proxy listens (`TorService.getProxyInfo()`).
typedef SocksProxy = ({InternetAddress host, int port});

/// Why a connection through the proxy did not open.
class Socks5TunnelException implements IOException {
  const Socks5TunnelException(this.message);

  final String message;

  @override
  String toString() => 'Socks5TunnelException: $message';
}

/// Opens [host]:[port] through the SOCKS5 proxy at [proxy] (RFC 1928),
/// sending the host NAME to the proxy (address type 3): the proxy resolves
/// it, so the name never reaches this device's DNS and `.onion` names work.
/// (socks5_proxy's `assignToHttpClient` looks the name up locally first.)
///
/// With [secure], TLS for [host] runs inside the tunnel. Nothing is ever
/// sent around the proxy: if it cannot be reached, this throws.
Future<Socket> connectThroughSocks5({
  required SocksProxy proxy,
  required String host,
  required int port,
  bool secure = false,
  Duration timeout = const Duration(seconds: 30),
  bool Function(X509Certificate)? onBadCertificate,
}) async {
  final name = ascii.encode(host);
  if (name.isEmpty || name.length > 255) {
    throw Socks5TunnelException('not a host name: "$host"');
  }
  final socket = await Socket.connect(proxy.host, proxy.port, timeout: timeout);
  final reader = _Reader(StreamQueue<Uint8List>(socket));
  try {
    final deadline = DateTime.now().add(timeout);
    socket.add(const [0x05, 0x01, 0x00]); // version 5, one method: no auth
    final method = await reader.take(2, deadline);
    if (method[0] != 0x05 || method[1] != 0x00) {
      throw const Socks5TunnelException('the proxy wants a login');
    }
    socket.add([
      0x05, 0x01, 0x00, 0x03, name.length, ...name, // CONNECT, by name
      (port >> 8) & 0xff, port & 0xff,
    ]);
    final head = await reader.take(4, deadline);
    if (head[0] != 0x05) {
      throw const Socks5TunnelException('not a SOCKS5 proxy');
    }
    if (head[1] != 0x00) {
      throw Socks5TunnelException(
        'the proxy could not reach $host:$port (${_reply(head[1])})',
      );
    }
    final rest = switch (head[3]) {
      0x01 => 4 + 2,
      0x04 => 16 + 2,
      0x03 => (await reader.take(1, deadline)).first + 2,
      _ => throw const Socks5TunnelException('bad reply from the proxy'),
    };
    await reader.take(rest, deadline);
  } catch (_) {
    socket.destroy();
    rethrow;
  }

  if (secure) {
    // The proxy says nothing more until the server answers our TLS hello,
    // so nothing was read past its reply. TLS takes the socket over.
    if (reader.hasBuffered) {
      socket.destroy();
      throw const Socks5TunnelException('unexpected data from the proxy');
    }
    return SecureSocket.secure(
      socket,
      host: host,
      onBadCertificate: onBadCertificate,
    );
  }
  return _TunnelSocket(socket, reader.remaining());
}

/// [connectThroughSocks5] for every connection [client] opens: plain and
/// TLS requests to any host go through [proxy], names resolved by it.
/// HTTP proxies from the environment are ignored (they would bypass Tor).
void routeHttpClientThroughSocks5(HttpClient client, SocksProxy proxy) {
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, _, _) async {
    final socket = connectThroughSocks5(
      proxy: proxy,
      host: uri.host,
      port: uri.hasPort ? uri.port : (uri.isScheme('https') ? 443 : 80),
      secure: uri.isScheme('https'),
      timeout: client.connectionTimeout ?? const Duration(seconds: 30),
    );
    return ConnectionTask.fromSocket(socket, () {
      // A cancelled request closes the tunnel once it is open.
      socket.then((s) => s.destroy(), onError: (Object _) {});
    });
  };
}

String _reply(int code) => switch (code) {
  0x01 => 'general failure',
  0x02 => 'not allowed',
  0x03 => 'network unreachable',
  0x04 => 'host unreachable',
  0x05 => 'connection refused',
  0x06 => 'TTL expired',
  0x07 => 'command not supported',
  0x08 => 'address type not supported',
  _ => 'code $code',
};

/// Reads exact byte counts off a socket during the handshake, and hands
/// whatever is left on to the tunnel.
class _Reader {
  _Reader(this._queue);

  final StreamQueue<Uint8List> _queue;
  final List<int> _buffer = [];

  bool get hasBuffered => _buffer.isNotEmpty;

  Future<List<int>> take(int n, DateTime deadline) async {
    while (_buffer.length < n) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero ||
          !await _queue.hasNext.timeout(left, onTimeout: () => false)) {
        throw const Socks5TunnelException('the proxy did not answer');
      }
      _buffer.addAll(await _queue.next);
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  /// The bytes after the handshake: any already read, then the socket's.
  Stream<Uint8List> remaining() async* {
    if (_buffer.isNotEmpty) yield Uint8List.fromList(_buffer);
    _buffer.clear();
    yield* _queue.rest;
  }
}

/// The tunnel as a [Socket]: reads come from what follows the handshake,
/// everything else is the proxy connection's own.
class _TunnelSocket extends StreamView<Uint8List> implements Socket {
  _TunnelSocket(this._socket, Stream<Uint8List> data) : super(data);

  final Socket _socket;

  @override
  Encoding get encoding => _socket.encoding;

  @override
  set encoding(Encoding value) => _socket.encoding = value;

  @override
  void add(List<int> data) => _socket.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> flush() => _socket.flush();

  @override
  void write(Object? object) => _socket.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _socket.writeln(object);

  @override
  InternetAddress get address => _socket.address;

  @override
  int get port => _socket.port;

  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;

  @override
  int get remotePort => _socket.remotePort;

  @override
  void destroy() => _socket.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
