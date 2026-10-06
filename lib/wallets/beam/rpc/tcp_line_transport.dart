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

import '../../../utilities/logger.dart';
import 'beam_connection_exception.dart';
import 'beam_transport.dart';

/// [BeamTransport] over a `wallet-api` child process in TCP line mode
/// (`--use_http=0`): one JSON object per line in each direction, on one
/// persistent loopback connection.
///
/// wallet-api keeps event subscriptions per connection, so one transport
/// holds one socket for its whole life. Responses can arrive out of order
/// (async methods such as `invoke_contract` answer later) and are matched by
/// `id`. Lines whose `id` is a string starting with `ev_` are push events.
///
/// Lines have no length cap here; wallet-api must run with
/// `--tcp_max_line=16777216` because a contract shader is sent as a JSON byte
/// array of several hundred KB.
///
/// Only method names and durations are logged. Params and results carry
/// addresses and amounts and never reach a log.
class TcpLineTransport implements BeamTransport {
  TcpLineTransport({
    required this.port,
    this.aclKey,
    this.defaultTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 10),
    this.onDisconnected,
    void Function(String message)? log,
  }) : _log = log ?? _defaultLog;

  /// Loopback port wallet-api listens on.
  final int port;

  /// The per-launch ACL key, sent as `"key"` in every request. Null only for
  /// a wallet-api started without `--use_acl` (tests).
  final String? aclKey;

  /// Applies to every [call] that does not pass its own timeout.
  final Duration defaultTimeout;
  final Duration connectTimeout;

  /// Called once when the connection drops without [close] having been
  /// called, after every pending request has failed. The argument is the
  /// socket error, or null for a clean EOF.
  final void Function(Object? error)? onDisconnected;

  final void Function(String message) _log;

  static void _defaultLog(String message) => Logging.instance.d(message);

  final _events = StreamController<BeamEvent>.broadcast();
  final _pending = <int, _Pending>{};

  Socket? _socket;
  StreamSubscription<String>? _lines;
  Future<void>? _connecting;
  Future<void> _writeTail = Future.value();
  int _nextId = 1;
  bool _closed = false;

  @override
  bool get isConnected => _socket != null;

  /// Events arrive only while someone listens. Subscribe before calling
  /// `ev_subunsub`: the core sends an initial snapshot of every newly
  /// subscribed stream right after the response.
  @override
  Stream<BeamEvent> get events => _events.stream;

  /// Opens the socket. Safe to call again after a drop to reconnect; event
  /// listeners carry over, subscriptions (`ev_subunsub`) do not.
  @override
  Future<void> connect() {
    if (_closed) {
      return Future.error(
        const BeamConnectionException('transport is closed'),
      );
    }
    if (_socket != null) return Future.value();
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<void> _connect() async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: connectTimeout,
      );
    } on SocketException catch (e) {
      throw BeamConnectionException('cannot connect to wallet-api', e);
    }
    if (_closed) {
      socket.destroy();
      throw const BeamConnectionException('transport is closed');
    }
    socket.setOption(SocketOption.tcpNoDelay, true);
    // Write-side failures surface through _write and the read side's
    // onError/onDone; keep them from also escaping as uncaught errors.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    _socket = socket;
    _writeTail = Future.value();
    // allowMalformed: one bad byte in, say, a tx comment must not drop the
    // connection and every pending call with it.
    _lines = const LineSplitter()
        .bind(const Utf8Decoder(allowMalformed: true).bind(socket))
        .listen(
          _onLine,
          onError: (Object e) => _dropped(socket, e),
          onDone: () => _dropped(socket, null),
          cancelOnError: true,
        );
  }

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    final socket = _socket;
    if (socket == null) {
      return Future.error(
        BeamConnectionException(
          _closed ? 'transport is closed' : 'not connected',
        ),
      );
    }

    final id = _nextId++;
    final request = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
      if (aclKey != null) 'key': aclKey,
    };
    final List<int> bytes;
    try {
      bytes = utf8.encode('${jsonEncode(request)}\n');
    } on JsonUnsupportedObjectError catch (e) {
      return Future.error(ArgumentError('params for $method: ${e.cause}'));
    }

    final wait = timeout ?? defaultTimeout;
    final pending = _Pending(method, Stopwatch()..start());
    pending.timer = Timer(wait, () {
      if (_pending.remove(id) == null) return;
      _log('beam rpc $method timed out after ${wait.inMilliseconds} ms');
      pending.completer.completeError(
        TimeoutException('wallet-api did not answer $method', wait),
      );
    });
    _pending[id] = pending;

    unawaited(
      _write(socket, bytes).catchError((Object e) {
        _fail(id, BeamConnectionException('write failed', e));
      }),
    );
    return pending.completer.future;
  }

  /// Writes go out one at a time: a flush must finish before the next add,
  /// or the socket sink throws "StreamSink is bound to a stream".
  Future<void> _write(Socket socket, List<int> bytes) {
    final done = _writeTail.then((_) async {
      if (!identical(socket, _socket)) {
        throw const BeamConnectionException('connection dropped');
      }
      socket.add(bytes);
      await socket.flush();
    });
    _writeTail = done.catchError((Object _) {});
    return done;
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _log('beam rpc: ignored a line that is not JSON (${line.length} chars)');
      return;
    }
    if (decoded is! Map) {
      _log('beam rpc: ignored a line that is not a JSON object');
      return;
    }
    final msg = decoded.cast<String, Object?>();
    final id = msg['id'];

    if (id is String && id.startsWith('ev_')) {
      final result = msg['result'];
      _events.add(
        BeamEvent(
          id,
          result is Map
              ? result.cast<String, Object?>()
              : <String, Object?>{'result': result},
        ),
      );
      return;
    }
    if (id is! int) {
      _log('beam rpc: ignored a message with an unknown id type');
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return; // timed out already
    pending.timer?.cancel();
    final ms = pending.stopwatch.elapsedMilliseconds;

    final error = msg['error'];
    if (error != null) {
      final e = error is Map
          ? error.cast<String, Object?>()
          : const <String, Object?>{};
      final code = e['code'];
      final message = e['message'];
      final ex = BeamRpcException(
        code is int ? code : 0,
        message is String ? message : 'malformed error object',
        e['data'],
      );
      _log('beam rpc ${pending.method} error ${ex.code} in $ms ms');
      pending.completer.completeError(ex);
      return;
    }
    _log('beam rpc ${pending.method} ok in $ms ms');
    pending.completer.complete(msg['result']);
  }

  void _fail(int id, Object error) {
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer?.cancel();
    pending.completer.completeError(error);
  }

  void _failAll(Object error) {
    final all = _pending.values.toList();
    _pending.clear();
    for (final p in all) {
      p.timer?.cancel();
      p.completer.completeError(error);
    }
  }

  void _dropped(Socket socket, Object? error) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _lines = null;
    socket.destroy();
    _log(
      'beam rpc: connection lost'
      '${error == null ? '' : ' (${error.runtimeType})'}',
    );
    _failAll(BeamConnectionException('connection to wallet-api lost', error));
    onDisconnected?.call(error);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final socket = _socket;
    _socket = null;
    final lines = _lines;
    _lines = null;
    _failAll(const BeamConnectionException('transport closed'));
    await lines?.cancel();
    socket?.destroy();
    await _events.close();
  }
}

class _Pending {
  _Pending(this.method, this.stopwatch);

  final String method;
  final Stopwatch stopwatch;
  final completer = Completer<Object?>();
  Timer? timer;
}
