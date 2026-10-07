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

import 'package:flutter/foundation.dart';
import 'package:isar_community/isar.dart';

import '../../isar/models/wallet_info.dart';
import '../models/beam_asset_info.dart';
import '../rpc/beam_connection_exception.dart';
import 'beam_asset_catalog.dart';

/// On-chain names of every Confidential Asset, not only the ones the wallet
/// holds, for screens that list assets from the DEX (swap and pool pickers,
/// the pools list).
///
/// * One read of the explorer's `/assets` table names every asset at once,
///   says nothing about the user, and honours Tor
///   (`BeamExplorerClient.assetMetadata`). It is read when the saved copy
///   is older than [maxAge], or when a screen needs an asset the copy does
///   not have (one created since), at most every [retryAfter].
/// * What the table cannot name (explorer down, Tor not connected, a brand
///   new asset) is asked of the core one asset at a time
///   (`get_asset_info`), at most [maxSingleLookups] per round.
/// * The names are kept in [cache], so they are on screen at unlock.
///
/// Everything here is the asset creator's text: screens show it only
/// through `BeamAssetCatalog.display`, which cleans it, adds the `#id` and
/// flags copies of verified assets. Verified assets and BEAM are never
/// looked up: the catalogue names them.
class BeamAssetDirectory extends ChangeNotifier {
  BeamAssetDirectory({
    this._readTable,
    this._readOne,
    BeamAssetDirectoryCache? cache,
    DateTime Function()? now,
    this.maxAge = const Duration(days: 1),
    this.retryAfter = const Duration(minutes: 30),
  }) : _cache = cache,
       _now = now ?? DateTime.now {
    final saved = cache?.load();
    if (saved != null) {
      _known.addAll(saved.assets);
      _tableReadAt = saved.readAt;
    }
  }

  /// At most this many `get_asset_info` calls per round: a DEX listing
  /// hundreds of unknown assets must not hold the core up.
  static const int maxSingleLookups = 20;

  final Future<Map<int, String>> Function()? _readTable;
  final Future<BeamAssetMetadata> Function(int assetId)? _readOne;
  final BeamAssetDirectoryCache? _cache;
  final DateTime Function() _now;

  /// A table read older than this is read again.
  final Duration maxAge;

  /// The table is read at most this often, failed reads included.
  final Duration retryAfter;

  final Map<int, BeamAssetMetadata> _known = {};
  final Set<int> _wanted = {};
  final Set<int> _coreTried = {};
  DateTime? _tableReadAt;
  DateTime? _tableTriedAt;
  Future<void>? _running;
  bool _disposed = false;

  /// The on-chain metadata of [assetId], once known; null before that (the
  /// asset shows as "#id").
  BeamAssetMetadata? metadataOf(int assetId) => _known[assetId];

  /// When the explorer's table was last read, or null.
  DateTime? get tableReadAt => _tableReadAt;

  /// Makes sure [assetIds] get their names: reads the table when it is due,
  /// then asks the core for what is still missing. Never throws; listeners
  /// are told when anything new is known. Concurrent callers share one
  /// round, and ids added meanwhile are handled by it.
  Future<void> ensure([Iterable<int> assetIds = const []]) {
    for (final id in assetIds) {
      if (id > 0 && !BeamAssetCatalog.verified.containsKey(id)) {
        _wanted.add(id);
      }
    }
    return _running ??= _round().whenComplete(() => _running = null);
  }

  bool get _missingAny => _wanted.any((id) => !_known.containsKey(id));

  bool _tableDue() {
    if (_readTable == null) return false;
    final tried = _tableTriedAt;
    if (tried != null && _now().difference(tried) < retryAfter) return false;
    final read = _tableReadAt;
    if (read == null || _now().difference(read) >= maxAge) return true;
    return _missingAny;
  }

  Future<void> _round() async {
    var changed = false;
    if (_tableDue()) {
      _tableTriedAt = _now();
      try {
        final table = await _readTable!();
        for (final e in table.entries) {
          if (e.key <= 0) continue;
          _known[e.key] = BeamAssetMetadata.parse(e.value);
        }
        _tableReadAt = _now();
        changed = true;
      } catch (_) {
        // Explorer down, or Tor on but not connected: the core below.
      }
    }
    final read = _readOne;
    if (read != null) {
      var lookups = 0;
      for (final id in _wanted.toList()) {
        if (_known.containsKey(id) || _coreTried.contains(id)) continue;
        if (lookups++ >= maxSingleLookups) break;
        try {
          _known[id] = await read(id);
          _coreTried.add(id);
          changed = true;
        } on BeamConnectionException {
          // The core is not connected yet: every id waits for next time.
          break;
        } on TimeoutException {
          // Busy, not unknown: asked again next round.
          break;
        } catch (_) {
          // Unknown to the core: stays "#id" for this session.
          _coreTried.add(id);
        }
      }
    }
    if (!changed || _disposed) return;
    unawaited(
      _cache?.save(BeamAssetDirectorySnapshot(_tableReadAt, Map.of(_known))),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What [BeamAssetDirectoryCache] keeps: the names, and when the explorer's
/// table was read (null when only the core named them).
@immutable
class BeamAssetDirectorySnapshot {
  const BeamAssetDirectorySnapshot(this.readAt, this.assets);

  final DateTime? readAt;
  final Map<int, BeamAssetMetadata> assets;
}

/// Where [BeamAssetDirectory] keeps its names between launches.
abstract class BeamAssetDirectoryCache {
  /// The saved names, or null when there are none or they cannot be read.
  /// Never throws.
  BeamAssetDirectorySnapshot? load();

  /// Saves [snapshot]. Failures are swallowed: names are re-read anyway.
  Future<void> save(BeamAssetDirectorySnapshot snapshot);
}

/// The names in the wallet's own `WalletInfo.otherData`, like the DEX
/// price snapshot (`WalletInfoMarketCache`): deleted with the wallet, and
/// only public chain data, so nothing about the user is stored.
///
/// Only the name and ticker fields are kept (`N`, `SN`, `UN`), each cut to
/// what `BeamAssetCatalog` could ever show, so a creator's long description
/// never bloats it: about 10 KB for every asset on chain.
class WalletInfoAssetDirectoryCache implements BeamAssetDirectoryCache {
  WalletInfoAssetDirectoryCache({required this.info, required this.isar});

  final WalletInfo Function() info;
  final Isar Function() isar;

  static const String otherDataKey = 'beamAssetNamesV1';

  /// Longest field kept. `BeamAssetCatalog` cleans at most the first 512
  /// characters of a field, so nothing past that is ever shown.
  static const int maxField = 512;

  static const _fields = ['N', 'SN', 'UN'];

  @override
  BeamAssetDirectorySnapshot? load() {
    try {
      final raw = info().otherData[otherDataKey];
      if (raw is! String) return null;
      return decode(raw);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(BeamAssetDirectorySnapshot snapshot) async {
    try {
      await info().updateOtherData(
        newEntries: {otherDataKey: encode(snapshot)},
        isar: isar(),
      );
    } catch (_) {}
  }

  /// [metadata] reduced to its name and ticker, in the `STD:` form
  /// [BeamAssetMetadata.parse] reads back. Values never contain `;` (it
  /// separates them), so the round trip is exact.
  static String trimmed(BeamAssetMetadata metadata) {
    if (!metadata.isStdPrefixed) return '';
    final kept = [
      for (final k in _fields)
        if (metadata.values[k] case final v?)
          '$k=${v.length > maxField ? v.substring(0, maxField) : v}',
    ];
    return 'STD:${kept.join(';')}';
  }

  static String encode(BeamAssetDirectorySnapshot snapshot) => jsonEncode({
    'readAt': snapshot.readAt?.toUtc().millisecondsSinceEpoch,
    'assets': {
      for (final e in snapshot.assets.entries) '${e.key}': trimmed(e.value),
    },
  });

  /// The snapshot in [raw], or null when it is malformed.
  static BeamAssetDirectorySnapshot? decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map) return null;
    final at = json['readAt'];
    final assets = json['assets'];
    if ((at != null && at is! int) || assets is! Map) return null;
    final out = <int, BeamAssetMetadata>{};
    for (final e in assets.entries) {
      final id = int.tryParse('${e.key}');
      final text = e.value;
      if (id == null || id <= 0 || text is! String) return null;
      out[id] = BeamAssetMetadata.parse(text);
    }
    return BeamAssetDirectorySnapshot(
      at == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(at as int, isUtc: true),
      out,
    );
  }
}
