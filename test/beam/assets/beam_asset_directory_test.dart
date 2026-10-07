/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamAssetDirectory: every asset the DEX lists gets its on-chain name from
// one explorer read (the owner saw "#2", "#3", "#8" in the Create pool
// picker because only held assets were ever looked up), cached, refreshed
// rarely, with the core's get_asset_info as the fallback.
//
//   scripts/beam/host_test.sh --no-analyze test/beam/assets

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_directory.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';

class _MemoryCache implements BeamAssetDirectoryCache {
  _MemoryCache([this.saved]);

  BeamAssetDirectorySnapshot? saved;
  var saves = 0;

  @override
  BeamAssetDirectorySnapshot? load() => saved;

  @override
  Future<void> save(BeamAssetDirectorySnapshot snapshot) async {
    saves++;
    saved = snapshot;
  }
}

/// The explorer's table (raw metadata by id), counting reads.
class _Table {
  _Table(this.rows);

  Map<int, String> rows;
  Object? error;
  var reads = 0;

  Future<Map<int, String>> call() async {
    reads++;
    final e = error;
    if (e != null) throw e;
    return rows;
  }
}

/// The core's get_asset_info, counting calls per id.
class _Core {
  _Core(this.known);

  final Map<int, String> known;
  Object? error;
  final asked = <int>[];

  Future<BeamAssetMetadata> call(int id) async {
    asked.add(id);
    final e = error;
    if (e != null) throw e;
    final raw = known[id];
    if (raw == null) throw StateError('asset $id unknown');
    return BeamAssetMetadata.parse(raw);
  }
}

const _rays = 'STD:SCH_VER=1;N=RAYS;SN=RAYS;UN=RAYS;NTHUN=Flicker';
const _bb = 'STD:SCH_VER=1;N=BeamBots Token;SN=BB;UN=BB;NTHUN=MiniB';
const _pound = 'STD:SCH_VER=1;N=POUND;SN=GBP;UN=POUND;NTHUN=PENCE';

void main() {
  var now = DateTime.utc(2026, 10, 7, 12);

  BeamAssetDirectory directory({
    _Table? table,
    _Core? core,
    BeamAssetDirectoryCache? cache,
  }) => BeamAssetDirectory(
    readTable: table?.call,
    readOne: core?.call,
    cache: cache,
    now: () => now,
  );

  setUp(() => now = DateTime.utc(2026, 10, 7, 12));

  test('one explorer read names every asset; the core is not asked', () async {
    final table = _Table({2: _rays, 3: _bb, 8: _pound});
    final core = _Core({});
    final cache = _MemoryCache();
    final d = directory(table: table, core: core, cache: cache);
    var told = 0;
    d.addListener(() => told++);

    await d.ensure([2, 3, 8]);

    expect(table.reads, 1);
    expect(core.asked, isEmpty);
    expect(told, 1);
    expect(d.tableReadAt, now);
    // What the Create pool picker now shows instead of "#2 / Asset #2".
    final rays = BeamAssetCatalog.display(2, d.metadataOf(2));
    expect(rays.symbol, 'RAYS');
    expect(rays.name, 'RAYS');
    expect(rays.verified, isFalse);
    expect(rays.idLabel, '#2');
    expect(BeamAssetCatalog.display(3, d.metadataOf(3)).name, 'BeamBots Token');
    expect(BeamAssetCatalog.display(8, d.metadataOf(8)).symbol, 'POUND');
    // Saved for the next launch.
    expect(cache.saves, 1);
    expect(cache.saved!.assets.keys, {2, 3, 8});
  });

  test(
    'saved names are on screen at once; the table is re-read daily',
    () async {
      final table = _Table({2: _rays, 3: _bb});
      final d = directory(
        table: table,
        cache: _MemoryCache(
          BeamAssetDirectorySnapshot(now.subtract(const Duration(hours: 2)), {
            2: BeamAssetMetadata.parse(_rays),
          }),
        ),
      );
      // Before any read: the saved copy.
      expect(d.metadataOf(2)!.name, 'RAYS');

      await d.ensure([2]);
      expect(table.reads, 0, reason: 'two hours old and complete');

      now = now.add(const Duration(days: 1));
      await d.ensure([2]);
      expect(table.reads, 1, reason: 'older than a day');
      expect(d.metadataOf(3)!.name, 'BeamBots Token');
    },
  );

  test(
    'an asset the copy lacks: one new read, then at most every 30 min',
    () async {
      final table = _Table({2: _rays});
      final core = _Core({7777: 'STD:N=Newer;UN=NEW'});
      final d = directory(table: table, core: core);
      await d.ensure([2]);
      expect(table.reads, 1);

      // A pool for an asset created since: the table is read again...
      now = now.add(const Duration(minutes: 31));
      table.rows = {2: _rays, 5555: 'STD:N=Fresh;UN=FRSH'};
      await d.ensure([5555]);
      expect(table.reads, 2);
      expect(d.metadataOf(5555)!.unitName, 'FRSH');
      expect(core.asked, isEmpty);

      // ...but not again within 30 minutes: the core names the next one.
      now = now.add(const Duration(minutes: 5));
      await d.ensure([7777]);
      expect(table.reads, 2);
      expect(core.asked, [7777]);
      expect(d.metadataOf(7777)!.name, 'Newer');
    },
  );

  test('explorer down or Tor not connected: the core names what is shown, '
      'at most 20 per round', () async {
    final table = _Table({})
      ..error = BeamExplorerException(
        'Tor is enabled but not connected; explorer not contacted',
      );
    final core = _Core({for (var i = 1000; i < 1025; i++) i: 'STD:N=A$i'});
    final d = directory(table: table, core: core);

    await d.ensure([for (var i = 1000; i < 1025; i++) i]);
    expect(table.reads, 1);
    expect(core.asked, hasLength(BeamAssetDirectory.maxSingleLookups));
    expect(d.tableReadAt, isNull);

    await d.ensure();
    expect(table.reads, 1, reason: 'a failed read waits 30 minutes too');
    expect(core.asked, hasLength(25));
    expect(d.metadataOf(1024)!.name, 'A1024');
  });

  test('core not connected yet: nothing is marked unknown', () async {
    final core = _Core({2: _rays})
      ..error = const BeamConnectionException('not connected');
    final d = directory(core: core);
    await d.ensure([2, 3]);
    expect(core.asked, [2], reason: 'the round stops at the first');
    expect(d.metadataOf(2), isNull);

    core.error = null;
    await d.ensure();
    expect(d.metadataOf(2)!.name, 'RAYS');
  });

  test('an asset the core does not know is not asked again', () async {
    final core = _Core({});
    final d = directory(core: core);
    await d.ensure([4242]);
    await d.ensure([4242]);
    expect(core.asked, [4242]);
    expect(BeamAssetCatalog.display(4242, d.metadataOf(4242)).symbol, '#4242');
  });

  test('BEAM and verified assets are never looked up', () async {
    final core = _Core({});
    final d = directory(core: core);
    await d.ensure([0, 174, 7, 36]);
    expect(core.asked, isEmpty);
  });

  test('concurrent callers share one round, and its new ids', () async {
    final gate = Completer<Map<int, String>>();
    var reads = 0;
    final core = _Core({3: _bb});
    final d = BeamAssetDirectory(
      readTable: () {
        reads++;
        return gate.future;
      },
      readOne: core.call,
      now: () => now,
    );
    final a = d.ensure([2]);
    final b = d.ensure([3]);
    expect(identical(a, b), isTrue);
    gate.complete({2: _rays});
    await a;
    expect(reads, 1);
    expect(d.metadataOf(2)!.name, 'RAYS');
    // #3 was not in the table: the same round asked the core.
    expect(core.asked, [3]);
  });

  test(
    'names are the creator\'s text: cleaned, #id kept, copies flagged',
    () async {
      final table = _Table({
        999: 'STD:SCH_VER=1;N=FOMO;SN=FOMO;UN=FOMO',
        1001: 'STD:N=Pepe #174\u202E;UN=PEPE',
      });
      final d = directory(table: table);
      await d.ensure([999, 1001]);

      final copy = BeamAssetCatalog.display(999, d.metadataOf(999));
      expect(copy.verified, isFalse);
      expect(copy.symbol, 'FOMO');
      expect(copy.idLabel, '#999');
      expect(copy.impersonates, 174);

      final pepe = BeamAssetCatalog.display(1001, d.metadataOf(1001));
      expect(pepe.name, 'Pepe');
      expect(pepe.impersonates, 174);
    },
  );

  group('the saved copy (WalletInfo.otherData)', () {
    test('keeps only the name and ticker, cut to what is ever shown', () {
      final long = 'x' * 900;
      final m = BeamAssetMetadata.parse(
        'STD:SCH_VER=1;N=$long;SN=GBP;UN=POUND;NTHUN=PENCE;'
        'OPT_LONG_DESC=${'y' * 1000};OPT_LOGO_URL=https://example.com/a.png',
      );
      final t = WalletInfoAssetDirectoryCache.trimmed(m);
      expect(t, 'STD:N=${'x' * 512};SN=GBP;UN=POUND');
      expect(BeamAssetMetadata.parse(t).unitName, 'POUND');
      expect(
        WalletInfoAssetDirectoryCache.trimmed(BeamAssetMetadata.parse('junk')),
        '',
      );
    });

    test('round trip', () {
      final at = DateTime.utc(2026, 10, 7, 9);
      final raw = WalletInfoAssetDirectoryCache.encode(
        BeamAssetDirectorySnapshot(at, {
          2: BeamAssetMetadata.parse(_rays),
          8: BeamAssetMetadata.parse(_pound),
          1000: BeamAssetMetadata.parse(''),
        }),
      );
      final back = WalletInfoAssetDirectoryCache.decode(raw)!;
      expect(back.readAt, at);
      expect(back.assets[2]!.name, 'RAYS');
      expect(back.assets[8]!.shortName, 'GBP');
      expect(back.assets[1000]!.name, isNull);
      expect(raw.length, lessThan(200));

      final coreOnly = WalletInfoAssetDirectoryCache.decode(
        WalletInfoAssetDirectoryCache.encode(
          BeamAssetDirectorySnapshot(null, {2: BeamAssetMetadata.parse(_rays)}),
        ),
      )!;
      expect(coreOnly.readAt, isNull);
    });

    test('anything malformed is no copy at all', () {
      expect(WalletInfoAssetDirectoryCache.decode('[]'), isNull);
      expect(
        WalletInfoAssetDirectoryCache.decode('{"readAt":"x","assets":{}}'),
        isNull,
      );
      expect(
        WalletInfoAssetDirectoryCache.decode('{"readAt":1,"assets":{"a":""}}'),
        isNull,
      );
      expect(
        WalletInfoAssetDirectoryCache.decode('{"readAt":1,"assets":{"0":""}}'),
        isNull,
      );
    });
  });
}
