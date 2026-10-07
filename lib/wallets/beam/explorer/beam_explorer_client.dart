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

import '../../../networking/http.dart';
import 'explorer_table.dart';

/// SOCKS proxy for a request, as Campfire's [HTTP] layer takes it.
typedef BeamProxyInfo = ({InternetAddress host, int port});

/// Returns the proxy to use for the next request, or null for a direct
/// connection. It must **throw** when Tor is switched on but not connected:
/// the client then fails instead of falling back to clearnet.
/// `campfireProxyInfo` in `campfire_proxy_info.dart` follows Campfire's
/// Tor setting.
typedef BeamProxyInfoProvider = BeamProxyInfo? Function();

/// An independent view of the chain tip. The sync rules use this to check
/// the wallet's own node; it must never come from that node.
abstract interface class BeamNetworkTipSource {
  Future<BeamExplorerStatus> status({bool forceRefresh = false});
}

/// `GET /status` from one explorer node.
class BeamExplorerStatus {
  const BeamExplorerStatus({
    required this.height,
    required this.timestamp,
    required this.hash,
    required this.node,
    required this.receivedAt,
    this.serverTime,
    this.peersCount,
  });

  /// Decodes `{"height": 4067912, "timestamp": 1791271756.0, "hash": ...}`.
  /// `timestamp` arrives as a float. Throws [FormatException] on anything
  /// that is not a usable status.
  factory BeamExplorerStatus.fromJson(
    Object? json, {
    required String node,
    required DateTime receivedAt,
    DateTime? serverTime,
  }) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('status is not a JSON object');
    }
    final height = parseExplorerInt(json['height']);
    final timestamp = parseExplorerTimestamp(json['timestamp']);
    final hash = json['hash'];
    if (height == null || height <= 0) {
      throw const FormatException('status has no height');
    }
    if (timestamp == null) {
      throw const FormatException('status has no timestamp');
    }
    return BeamExplorerStatus(
      height: height,
      timestamp: timestamp,
      hash: hash is String ? hash : '',
      node: node,
      receivedAt: receivedAt,
      serverTime: serverTime,
      peersCount: parseExplorerInt(json['peers_count']),
    );
  }

  /// The explorer's tip height.
  final int height;

  /// Block timestamp of that tip (UTC).
  final DateTime timestamp;

  /// Block hash of that tip.
  final String hash;

  /// Base URL of the explorer node that answered.
  final String node;

  /// Device clock when the answer arrived.
  final DateTime receivedAt;

  /// The server's clock from the HTTP `Date` header, when it sent one.
  final DateTime? serverTime;

  final int? peersCount;

  /// How old the explorer's tip is at [now].
  ///
  /// Measured against the server's own clock when it sent one, plus the
  /// time elapsed on the device since the answer arrived, so a wrong device
  /// clock does not make a healthy explorer look stale.
  Duration tipAgeAt(DateTime now) =>
      (serverTime ?? receivedAt).difference(timestamp) +
      now.difference(receivedAt);

  /// How far the device clock was ahead of the server's (negative: behind),
  /// or null when the server sent no `Date` header. Accurate to a few
  /// seconds (`Date` has one-second resolution, plus network latency).
  Duration? get deviceClockOffset =>
      serverTime == null ? null : receivedAt.difference(serverTime!);

  @override
  String toString() =>
      'BeamExplorerStatus(height: $height, '
      'timestamp: ${timestamp.toIso8601String()}, node: $node)';
}

/// No explorer node gave a usable answer.
class BeamExplorerException implements Exception {
  BeamExplorerException(this.message, [this.failures = const {}]);

  final String message;

  /// Why each node failed, keyed by base URL. No request data is included.
  final Map<String, String> failures;

  @override
  String toString() => failures.isEmpty
      ? 'BeamExplorerException: $message'
      : 'BeamExplorerException: $message ($failures)';
}

/// Client for the public BEAM explorer API, with failover across nodes.
///
/// * Requests go through Campfire's [HTTP] layer with the proxy from
///   [BeamProxyInfoProvider], so Tor is honoured. If Tor is on but down,
///   nothing is sent.
/// * Each node gets a short timeout; on failure the next node is tried.
///   The node that last answered is tried first next time.
/// * [status] is cached for [statusCacheTtl] and concurrent calls share one
///   request, so the UI can poll it cheaply.
/// * A node whose own tip is older than [maxTipAge] is treated as stale: the
///   next node is tried, and a stale answer is returned only when no node is
///   fresh (the highest one).
class BeamExplorerClient implements BeamNetworkTipSource {
  BeamExplorerClient({
    required this._proxyInfo,
    this._http = const HTTP(),
    List<String> nodes = defaultNodes,
    this.statusTimeout = const Duration(seconds: 6),
    this.queryTimeout = const Duration(seconds: 30),
    this.statusCacheTtl = const Duration(seconds: 20),
    this.maxTipAge = const Duration(minutes: 10),
    this.hedgeAfter = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _nodes = List<String>.unmodifiable(nodes.map(_trimSlash)),
       _now = now ?? DateTime.now {
    if (_nodes.isEmpty) {
      throw ArgumentError.value(nodes, 'nodes', 'at least one node');
    }
  }

  /// Public explorer nodes, primary first (LightWallet
  /// `config/nodes.json` `mainnet.explorerNodes`).
  ///
  /// `explorer-api.beamprivacy.com` was dropped in October 2026: it fails
  /// the TLS handshake (unrecognized name), so every status check paid for
  /// a dead hop before reaching BeamSmart.
  static const defaultNodes = <String>[
    'https://explorer.0xmx.net/api',
    'https://BeamSmart.net:8000',
  ];

  final BeamProxyInfoProvider _proxyInfo;
  final HTTP _http;
  final List<String> _nodes;
  final DateTime Function() _now;

  /// Per-node timeout for [status].
  final Duration statusTimeout;

  /// Per-node timeout for heavier queries ([contract], [asset], [getJson]).
  /// `/asset` has taken 30 s on the primary node.
  final Duration queryTimeout;

  final Duration statusCacheTtl;
  final Duration maxTipAge;

  /// A query whose node has not answered by then is also sent to the next
  /// node, and the first good answer wins: explorer.0xmx.net sometimes holds
  /// a request for the whole [queryTimeout] (seen: 30 s for `/assets`, which
  /// BeamSmart answers in 0.3 s), and nothing should wait on that.
  final Duration hedgeAfter;

  List<String> get nodes => _nodes;

  int _preferred = 0;
  BeamExplorerStatus? _cached;
  DateTime? _cachedAt;
  Future<BeamExplorerStatus>? _statusInFlight;

  static final _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
  static final _endpointName = RegExp(r'^[a-z_]+$');

  /// The newest chain tip any explorer node will give us.
  ///
  /// Throws [BeamExplorerException] when no node answers.
  @override
  Future<BeamExplorerStatus> status({bool forceRefresh = false}) {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!forceRefresh && cached != null && cachedAt != null) {
      final age = _now().difference(cachedAt);
      if (!age.isNegative && age < statusCacheTtl) {
        return Future.value(cached);
      }
    }
    return _statusInFlight ??= _fetchStatus().whenComplete(() {
      _statusInFlight = null;
    });
  }

  Future<BeamExplorerStatus> _fetchStatus() async {
    final proxy = _proxyOrThrow();
    final failures = <String, String>{};
    BeamExplorerStatus? bestStale;
    for (final i in _nodeOrder()) {
      final node = _nodes[i];
      try {
        final r = await _get(node, 'status', null, statusTimeout, proxy);
        final s = BeamExplorerStatus.fromJson(
          r.json,
          node: node,
          receivedAt: r.receivedAt,
          serverTime: r.serverTime,
        );
        final age = s.tipAgeAt(r.receivedAt);
        if (age <= maxTipAge) {
          _preferred = i;
          _remember(s);
          return s;
        }
        failures[node] = 'stale: tip is ${age.inSeconds} s old';
        if (bestStale == null || s.height > bestStale.height) bestStale = s;
      } catch (e) {
        failures[node] = _describe(e);
      }
    }
    if (bestStale != null) {
      _remember(bestStale);
      return bestStale;
    }
    throw BeamExplorerException('no explorer node answered', failures);
  }

  void _remember(BeamExplorerStatus s) {
    _cached = s;
    _cachedAt = s.receivedAt;
  }

  /// `GET /contract?id=<cid>[&state=1][&nMaxTxs=n][&hMax=h]`, decoded.
  ///
  /// The result holds `Calls history`, `Locked Funds`, `Owned assets`,
  /// `Version History` (tables, see [ExplorerTable]), `State` (contract
  /// specific; the DEX has a `Pools` table), `h` and `kind`.
  Future<Map<String, Object?>> contract(
    String cid, {
    bool state = false,
    int? nMaxTxs,
    int? hMax,
  }) {
    if (!_hex64.hasMatch(cid)) {
      throw ArgumentError.value(cid, 'cid', 'must be 64 hex characters');
    }
    return _firstAnswer(
      'contract',
      {
        'id': cid.toLowerCase(),
        if (state) 'state': '1',
        if (nMaxTxs != null) 'nMaxTxs': '$nMaxTxs',
        if (hMax != null) 'hMax': '$hMax',
      },
      queryTimeout,
      _requireObject,
    );
  }

  /// `GET /asset?id=<id>[&nMaxOps=n]`, decoded.
  ///
  /// The live explorer returns only `Asset distribution` and
  /// `Asset history` tables; metadata is in the `Create` row's `Extra`.
  /// An unknown id gives the same keys with header-only tables.
  Future<Map<String, Object?>> asset(int id, {int? nMaxOps}) {
    if (id < 0) throw ArgumentError.value(id, 'id', 'must be >= 0');
    return _firstAnswer(
      'asset',
      {'id': '$id', if (nMaxOps != null) 'nMaxOps': '$nMaxOps'},
      queryTimeout,
      _requireObject,
    );
  }

  /// `GET /assets`: the raw on-chain metadata of every Confidential Asset,
  /// by asset id, in one request (203 assets, 66 KB, in October 2026).
  ///
  /// It says nothing about the user (everyone fetches the same table), so
  /// it is the private way to name assets the wallet does not hold. The
  /// text is the asset creator's and untrusted: it must go through
  /// `BeamAssetCatalog` before anything shows it.
  Future<Map<int, String>> assetMetadata() =>
      _firstAnswer('assets', null, queryTimeout, decodeAssetTable);

  /// The `/assets` table as asset id → metadata text. Rows without a
  /// positive id are skipped; a missing metadata cell is `""`. Throws
  /// [FormatException] when [json] is not that table, so the next node is
  /// tried.
  static Map<int, String> decodeAssetTable(Object? json) {
    final table = ExplorerTable.parse(json);
    if (!table.headers.contains('Aid') || !table.headers.contains('Metadata')) {
      throw const FormatException('not the assets table');
    }
    final out = <int, String>{};
    for (final row in table.rows) {
      final id = row.intOf('Aid');
      if (id == null || id <= 0) continue;
      final metadata = row['Metadata'];
      out[id] = metadata is String ? metadata : '';
    }
    return out;
  }

  /// `GET /<endpoint>?<query>` from the first node that answers with JSON.
  /// For endpoints without a typed method yet (`hdrs`, `block`, `assets`,
  /// `contracts`, ...). [endpoint] is a bare name such as `hdrs`.
  Future<Object?> getJson(
    String endpoint, {
    Map<String, String>? query,
    Duration? timeout,
  }) {
    if (!_endpointName.hasMatch(endpoint)) {
      throw ArgumentError.value(endpoint, 'endpoint', 'must be a bare name');
    }
    return _firstAnswer(endpoint, query, timeout ?? queryTimeout, (j) => j);
  }

  Future<T> _firstAnswer<T>(
    String endpoint,
    Map<String, String>? query,
    Duration timeout,
    T Function(Object? json) decode,
  ) async {
    final proxy = _proxyOrThrow();
    final failures = <String, String>{};
    final order = _nodeOrder().toList();
    final answer = Completer<T>();
    var launched = 0;
    var settled = 0;
    Timer? hedge;

    // The next node is asked when the last one failed, or has been silent
    // for [hedgeAfter]; the first good answer is used.
    void launchNext() {
      hedge?.cancel();
      if (answer.isCompleted || launched >= order.length) return;
      final i = order[launched++];
      final node = _nodes[i];
      hedge = Timer(hedgeAfter, launchNext);
      () async {
        try {
          final r = await _get(node, endpoint, query, timeout, proxy);
          final decoded = decode(r.json);
          if (!answer.isCompleted) {
            _preferred = i;
            answer.complete(decoded);
          }
        } catch (e) {
          failures[node] = _describe(e);
          launchNext();
        } finally {
          settled++;
          if (!answer.isCompleted &&
              settled == launched &&
              launched == order.length) {
            answer.completeError(
              BeamExplorerException('no explorer node answered', failures),
            );
          }
        }
      }();
    }

    launchNext();
    try {
      return await answer.future;
    } finally {
      hedge?.cancel();
    }
  }

  static Map<String, Object?> _requireObject(Object? json) {
    if (json is Map<String, Object?>) return json;
    throw const FormatException('answer is not a JSON object');
  }

  BeamProxyInfo? _proxyOrThrow() {
    try {
      return _proxyInfo();
    } catch (_) {
      // Tor is on but not usable. Do not fall back to a direct connection.
      throw BeamExplorerException(
        'Tor is enabled but not connected; explorer not contacted',
      );
    }
  }

  Iterable<int> _nodeOrder() sync* {
    final start = _preferred.clamp(0, _nodes.length - 1);
    for (var k = 0; k < _nodes.length; k++) {
      yield (start + k) % _nodes.length;
    }
  }

  /// Builds `<node>/<endpoint>?<query>`, keeping a base path such as `/api`.
  static Uri endpointUri(
    String node,
    String endpoint, [
    Map<String, String>? query,
  ]) {
    final base = Uri.parse(_trimSlash(node));
    return base.replace(
      path: '${base.path}/$endpoint',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Future<({Object? json, DateTime receivedAt, DateTime? serverTime})> _get(
    String node,
    String endpoint,
    Map<String, String>? query,
    Duration timeout,
    BeamProxyInfo? proxy,
  ) async {
    final response = await _http
        .get(
          url: endpointUri(node, endpoint, query),
          headers: const {'Accept': 'application/json'},
          proxyInfo: proxy,
          connectionTimeout: timeout,
        )
        .timeout(timeout);
    final receivedAt = _now();
    if (response.code != 200) {
      throw HttpException('HTTP ${response.code}');
    }
    final Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      throw const FormatException('answer is not JSON');
    }
    return (
      json: json,
      receivedAt: receivedAt,
      serverTime: _parseHttpDate(response.headers['date']),
    );
  }

  static DateTime? _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return HttpDate.parse(value);
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static String _describe(Object e) => switch (e) {
    TimeoutException() => 'timed out',
    SocketException(:final message) => 'network error: $message',
    HandshakeException() => 'TLS handshake failed',
    HttpException(:final message) => message,
    FormatException(:final message) => message,
    _ => e.runtimeType.toString(),
  };

  static String _trimSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}
