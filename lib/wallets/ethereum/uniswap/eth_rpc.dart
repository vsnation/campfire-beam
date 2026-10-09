/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Ethereum JSON-RPC calls the Uniswap screens need, over the wallet's
// own RPC (the node chosen in its network settings) and the wallet's own
// HTTP client, which goes through Tor when Tor is on. Nothing here talks to
// any other server.
//
// * [EthRpc.call] / [EthRpc.batch]: plain and batched requests.
// * [EthRpc.multicall]: many read-only contract calls in one eth_call
//   (Multicall3.aggregate3), each allowed to fail on its own.
// * [EthRpc.getLogsAdaptive]: an event search over a long block range that
//   shrinks its chunks to whatever range the RPC accepts.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'abi.dart';
import 'uniswap_constants.dart';

/// An error the RPC returned (as opposed to a network failure).
class EthRpcError implements Exception {
  EthRpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;

  /// Revert data for a failed eth_call / eth_estimateGas, when given.
  final String? data;

  /// The node refused a log search because the block range is too long.
  bool get isRangeTooLong {
    final m = message.toLowerCase();
    return m.contains('range') ||
        m.contains('block') && (m.contains('limit') || m.contains('max')) ||
        m.contains('too many') ||
        m.contains('exceed') ||
        m.contains('archive') ||
        m.contains('10000') ||
        m.contains('query returned more than');
  }

  /// The largest range the message names ("max block range 100000",
  /// "ranges over 10000 blocks", "up to a 10 block range"), if any.
  int? get suggestedRange {
    final numbers = RegExp(r'(\d[\d,]*)')
        .allMatches(message)
        .map((m) => int.tryParse(m.group(1)!.replaceAll(',', '')))
        .whereType<int>()
        .where((n) => n >= 10 && n <= 5000000)
        .toList();
    if (numbers.isEmpty) return null;
    return numbers.reduce((a, b) => a < b ? a : b);
  }

  @override
  String toString() => 'EthRpcError($code): $message';
}

/// One call inside a [EthRpc.multicall].
class EthCall {
  const EthCall(this.to, this.data);

  final String to;
  final Uint8List data;
}

/// What one [EthCall] returned.
class EthCallResult {
  const EthCallResult(this.success, this.data);

  final bool success;
  final Uint8List data;
}

/// A log the node returned.
class EthLog {
  const EthLog({
    required this.address,
    required this.topics,
    required this.data,
    required this.blockNumber,
  });

  factory EthLog.fromJson(Map<String, dynamic> j) => EthLog(
    address: (j['address'] as String).toLowerCase(),
    topics: [for (final t in j['topics'] as List) (t as String).toLowerCase()],
    data: hexToBytes(j['data'] as String),
    blockNumber: int.parse(j['blockNumber'] as String),
  );

  final String address;
  final List<String> topics;
  final Uint8List data;
  final int blockNumber;

  Map<String, dynamic> toJson() => {
    'address': address,
    'topics': topics,
    'data': bytesToHex(data),
    'blockNumber': '0x${blockNumber.toRadixString(16)}',
  };
}

typedef EthHttpClientFactory = http.Client Function();

class EthRpc {
  EthRpc({
    required this.url,
    required this.clientFactory,
    this.timeout = const Duration(seconds: 30),
  });

  /// The RPC URL (the wallet's current Ethereum node).
  final String url;

  /// A new HTTP client per request (Tor-aware in the app).
  final EthHttpClientFactory clientFactory;
  final Duration timeout;

  int _id = 0;

  Future<Object?> call(String method, List<Object?> params) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': ++_id,
      'method': method,
      'params': params,
    });
    final decoded = await _post(body);
    return _result(decoded as Map<String, dynamic>);
  }

  /// Several requests in one HTTP round trip (each its own result or
  /// [EthRpcError], in order). Falls back to one by one if the node does
  /// not take batches.
  Future<List<Object?>> batch(List<(String, List<Object?>)> requests) async {
    if (requests.isEmpty) return const [];
    final first = _id + 1;
    final body = jsonEncode([
      for (final r in requests)
        {'jsonrpc': '2.0', 'id': ++_id, 'method': r.$1, 'params': r.$2},
    ]);
    final decoded = await _post(body);
    if (decoded is! List) {
      // A node that does not do batches answers with one error object.
      return [
        for (final r in requests)
          await call(
            r.$1,
            r.$2,
          ).then<Object?>((v) => v, onError: (Object e) => e),
      ];
    }
    final byId = {
      for (final item in decoded.cast<Map<String, dynamic>>())
        item['id'] as int: item,
    };
    return [
      for (var i = 0; i < requests.length; i++)
        if (byId[first + i] case final item?)
          _resultOrError(item)
        else
          EthRpcError(-1, 'no answer in batch'),
    ];
  }

  Future<int> blockNumber() async =>
      int.parse(await call('eth_blockNumber', const []) as String);

  Future<int> chainId() async =>
      int.parse(await call('eth_chainId', const []) as String);

  Future<Uint8List> ethCall(
    String to,
    Uint8List data, {
    String? from,
    BigInt? value,
    String block = 'latest',
  }) async {
    final r = await call('eth_call', [
      {
        if (from != null) 'from': from,
        'to': to,
        'data': bytesToHex(data),
        if (value != null && value > BigInt.zero)
          'value': '0x${value.toRadixString(16)}',
      },
      block,
    ]);
    return hexToBytes(r! as String);
  }

  Future<BigInt> estimateGas({
    required String from,
    required String to,
    required Uint8List data,
    BigInt? value,
  }) async {
    final r = await call('eth_estimateGas', [
      {
        'from': from,
        'to': to,
        'data': bytesToHex(data),
        if (value != null && value > BigInt.zero)
          'value': '0x${value.toRadixString(16)}',
      },
    ]);
    return BigInt.parse((r! as String).substring(2), radix: 16);
  }

  /// [calls] through Multicall3.aggregate3, every call allowed to fail.
  /// Split into requests of [chunk] calls so no single eth_call runs out
  /// of the node's gas cap.
  Future<List<EthCallResult>> multicall(
    List<EthCall> calls, {
    int chunk = 40,
  }) async {
    final out = <EthCallResult>[];
    for (var i = 0; i < calls.length; i += chunk) {
      final part = calls.sublist(
        i,
        i + chunk > calls.length ? calls.length : i + chunk,
      );
      final data = encodeCall('aggregate3((address,bool,bytes)[])', [
        [
          for (final c in part) [c.to, true, c.data],
        ],
      ]);
      final raw = await ethCall(UniswapAddresses.multicall3, data);
      final decoded = abiDecode('(bool,bytes)[]', raw).first as List;
      for (final r in decoded) {
        final pair = r as List;
        out.add(EthCallResult(pair[0] as bool, pair[1] as Uint8List));
      }
    }
    return out;
  }

  /// eth_getLogs.
  Future<List<EthLog>> getLogs({
    required String address,
    required List<String?> topics,
    required int fromBlock,
    required int toBlock,
  }) async {
    final r = await call('eth_getLogs', [
      {
        'address': address,
        'topics': topics,
        'fromBlock': '0x${fromBlock.toRadixString(16)}',
        'toBlock': '0x${toBlock.toRadixString(16)}',
      },
    ]);
    return [
      for (final l in (r! as List).cast<Map<String, dynamic>>())
        EthLog.fromJson(l),
    ];
  }

  /// The logs of [fromBlock]…[toBlock], asking for the whole range first
  /// and, when the node refuses, for chunks it accepts (from its message,
  /// else 100 000, then 10 000 blocks). Gives up after [maxRequests] and
  /// returns what it found with the last block it covered, so a later
  /// search can carry on from there.
  Future<({List<EthLog> logs, int scannedTo, bool complete})> getLogsAdaptive({
    required String address,
    required List<String?> topics,
    required int fromBlock,
    required int toBlock,
    int maxRequests = 40,
    int? knownRange,
  }) async {
    final logs = <EthLog>[];
    var range = knownRange ?? (toBlock - fromBlock + 1);
    var start = fromBlock;
    var requests = 0;
    while (start <= toBlock) {
      if (requests >= maxRequests) {
        return (logs: logs, scannedTo: start - 1, complete: false);
      }
      final end = start + range - 1 > toBlock ? toBlock : start + range - 1;
      requests++;
      try {
        logs.addAll(
          await getLogs(
            address: address,
            topics: topics,
            fromBlock: start,
            toBlock: end,
          ),
        );
        start = end + 1;
      } on EthRpcError catch (e) {
        if (!e.isRangeTooLong || range <= 1) rethrow;
        final suggested = e.suggestedRange;
        final next = suggested != null && suggested < range
            ? suggested
            : range > 100000
            ? 100000
            : range > 10000
            ? 10000
            : range ~/ 10;
        if (next < 1000) {
          // A node that only searches a few blocks at a time cannot cover
          // years of history; let the caller fall back.
          rethrow;
        }
        range = next;
      }
    }
    return (logs: logs, scannedTo: toBlock, complete: true);
  }

  // --------------------------------------------------------------- private

  Future<Object?> _post(String body) async {
    final client = clientFactory();
    try {
      final response = await client
          .post(
            Uri.parse(url),
            headers: const {'content-type': 'application/json'},
            body: body,
          )
          .timeout(timeout);
      if (response.statusCode == 429) {
        throw EthRpcError(429, 'The RPC is busy (too many requests).');
      }
      if (response.body.isEmpty) {
        throw EthRpcError(response.statusCode, 'Empty answer from the RPC');
      }
      try {
        return jsonDecode(response.body);
      } on FormatException {
        throw EthRpcError(
          response.statusCode,
          'The RPC did not answer with JSON (HTTP ${response.statusCode})',
        );
      }
    } finally {
      client.close();
    }
  }

  static Object? _result(Map<String, dynamic> m) {
    if (m['error'] case final Map<String, dynamic> e) {
      throw EthRpcError(
        (e['code'] as num?)?.toInt() ?? -1,
        (e['message'] as String?) ?? 'RPC error',
        e['data'] is String ? e['data'] as String : null,
      );
    }
    return m['result'];
  }

  static Object? _resultOrError(Map<String, dynamic> m) {
    try {
      return _result(m);
    } on EthRpcError catch (e) {
      return e;
    }
  }
}
