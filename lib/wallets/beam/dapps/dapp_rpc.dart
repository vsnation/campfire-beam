/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import '../rpc/beam_transport.dart';
import 'dapp_errors.dart';

/// A request a dApp page sent, parsed as the core parses one
/// (`ApiBase::parseCallInfo`, `api_base.cpp:120-150`).
@immutable
class DappRpcRequest {
  const DappRpcRequest(this.id, this.method, this.params);

  /// An `int` or a `String`, echoed back unchanged.
  final Object id;
  final String method;

  /// Never null: absent `params`, or `params` that are not an object, are
  /// an empty object.
  final Map<String, Object?> params;

  /// Parses [text]. Throws [DappRpcFailure] carrying the id when one could
  /// be read, so the error still reaches the right callback.
  static DappRpcRequest parse(String text, {required int maxLength}) {
    if (text.isEmpty) {
      throw DappRpcFailure(
        null,
        DappRpcErrors.error(DappRpcErrors.invalidJsonRpc, 'Empty request'),
      );
    }
    if (text.length > maxLength) {
      throw DappRpcFailure(
        null,
        DappRpcErrors.error(
          DappRpcErrors.invalidJsonRpc,
          'Request larger than $maxLength characters',
        ),
      );
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw DappRpcFailure(
        null,
        DappRpcErrors.error(DappRpcErrors.invalidJsonRpc, 'Malformed JSON'),
      );
    }
    if (json is! Map<String, Object?>) {
      throw DappRpcFailure(
        null,
        DappRpcErrors.error(DappRpcErrors.invalidJsonRpc, 'Not an object'),
      );
    }
    final id = json['id'];
    if (id is! int && id is! String) {
      throw DappRpcFailure(
        null,
        DappRpcErrors.error(
          DappRpcErrors.invalidJsonRpc,
          'ID can be integer or string only.',
        ),
      );
    }
    if (json['jsonrpc'] != '2.0') {
      throw DappRpcFailure(
        id,
        DappRpcErrors.error(
          DappRpcErrors.invalidJsonRpc,
          'Invalid JSON-RPC 2.0 header.',
        ),
      );
    }
    final method = json['method'];
    if (method is! String || method.isEmpty) {
      throw DappRpcFailure(
        id,
        DappRpcErrors.error(DappRpcErrors.invalidJsonRpc, 'Missing method'),
      );
    }
    // The core hands `params` to the method as it is, and reads named
    // parameters with `params.find(name)`, which finds nothing in anything
    // but an object (`api_base.cpp:151`, `getOptionalParam`). So params
    // that are not an object are no parameters at all, as there: the BANS
    // dApp asks for `get_version` with `"params": false` and gives up on
    // the wallet when that is refused.
    final params = json['params'];
    return DappRpcRequest(
      id as Object,
      method,
      params is Map<String, Object?> ? params : const {},
    );
  }
}

/// A request that is answered with an error without reaching the core.
class DappRpcFailure implements Exception {
  const DappRpcFailure(this.id, this.error);

  final Object? id;
  final BeamRpcException error;

  @override
  String toString() => 'DappRpcFailure($id, $error)';
}

/// JSON-RPC response strings in the core's envelope
/// (`ApiBase::formError`, `api_base.cpp:69-90`).
abstract final class DappRpcResponse {
  static String result(Object id, Object? result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

  /// The `id` is left out when it is not an int or a string, as the core
  /// does.
  static String error(Object? id, BeamRpcException e) => jsonEncode({
    'jsonrpc': '2.0',
    if (id is int || id is String) 'id': id,
    'error': {
      'code': e.code,
      'message': e.message,
      if (e.data != null) 'data': e.data,
    },
  });

  /// A push notification (`{"id": "ev_…", "result": …}`), as
  /// `v6_1_api_notify.cpp` sends them.
  static String event(String name, Object? data) =>
      jsonEncode({'jsonrpc': '2.0', 'id': name, 'result': data});
}

/// JSON with object keys sorted at every level and no whitespace: one text
/// per value, so a request can be bound to what the user approved by hash.
String canonicalJson(Object? value) {
  final out = StringBuffer();
  void write(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out
          ..write(jsonEncode(keys[i]))
          ..write(':');
        write(v[keys[i]]);
      }
      out.write('}');
    } else if (v is List) {
      out.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) out.write(',');
        write(v[i]);
      }
      out.write(']');
    } else {
      out.write(jsonEncode(v));
    }
  }

  write(value);
  return out.toString();
}

/// Lowercase hex SHA-256 of [text] as UTF-8.
String sha256Hex(String text) =>
    crypto.sha256.convert(utf8.encode(text)).toString();
