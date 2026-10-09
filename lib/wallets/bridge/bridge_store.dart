/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where crossings are kept on this device: one JSON file, like the NEAR
// Intents swaps (`near_intents_store.dart`), but stricter, because a lost
// record can mean coins nobody claims:
//
// * every write goes to a temporary file that then replaces the real one,
//   so a crash mid-write leaves the old file, never half of one;
// * a record this version cannot read is kept as it was and written back
//   unchanged, never dropped; a file that is not JSON at all is moved
//   aside, not overwritten;
// * once a crossing knows its bridge message id, no other crossing of the
//   same route and direction may claim that id.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bridge_crossing.dart';

/// A second crossing tried to claim a bridge message another one has.
class BridgeStoreConflict implements Exception {
  const BridgeStoreConflict(this.message);

  final String message;

  @override
  String toString() => 'BridgeStoreConflict: $message';
}

abstract class BridgeStore {
  /// Every crossing, newest first.
  Future<List<BridgeCrossing>> all();

  Future<BridgeCrossing?> byId(String id);

  /// Writes [crossing], replacing the one with its id. Throws
  /// [BridgeStoreConflict] when another crossing of the same route and
  /// direction already has its message id.
  Future<void> save(BridgeCrossing crossing);
}

/// Throws when [c]'s message id belongs to another crossing in [others].
void checkBridgeUnique(BridgeCrossing c, Iterable<BridgeCrossing> others) {
  final id = c.msgId;
  if (id == null) return;
  for (final o in others) {
    if (o.id != c.id &&
        o.msgId == id &&
        o.routeId == c.routeId &&
        o.direction == c.direction) {
      throw BridgeStoreConflict(
        '${c.routeId} ${c.direction.name} message $id is already '
        'crossing ${o.id}',
      );
    }
  }
}

List<BridgeCrossing> _newestFirst(Iterable<BridgeCrossing> list) =>
    list.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

class MemoryBridgeStore implements BridgeStore {
  final Map<String, BridgeCrossing> _byId = {};

  /// Every save, in order (tests check what was written before a step).
  final List<BridgeCrossing> writes = [];

  @override
  Future<List<BridgeCrossing>> all() async => _newestFirst(_byId.values);

  @override
  Future<BridgeCrossing?> byId(String id) async => _byId[id];

  @override
  Future<void> save(BridgeCrossing crossing) async {
    checkBridgeUnique(crossing, _byId.values);
    _byId[crossing.id] = crossing;
    writes.add(crossing);
  }
}

/// [BridgeStore] in a JSON file ([file] decides where).
class FileBridgeStore implements BridgeStore {
  FileBridgeStore(this.file);

  final Future<File> Function() file;

  Map<String, BridgeCrossing>? _byId;

  /// Records this version could not read, written back as they were.
  final List<Object?> _unreadable = [];

  /// Writes one at a time, in order.
  Future<void> _queue = Future.value();

  Future<Map<String, BridgeCrossing>> _load() async {
    final loaded = _byId;
    if (loaded != null) return loaded;
    final byId = <String, BridgeCrossing>{};
    final f = await file();
    if (await f.exists()) {
      final Object? decoded;
      try {
        decoded = jsonDecode(await f.readAsString());
      } on FormatException {
        // Not ours to overwrite: keep it beside the new file.
        final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
        await f.rename('${f.path}.unreadable-$stamp');
        return _byId = byId;
      }
      for (final j in decoded is List ? decoded : const <Object?>[]) {
        try {
          final c = BridgeCrossing.fromJson((j as Map).cast<String, dynamic>());
          byId[c.id] = c;
        } catch (_) {
          _unreadable.add(j);
        }
      }
    }
    return _byId = byId;
  }

  @override
  Future<List<BridgeCrossing>> all() async =>
      _newestFirst((await _load()).values);

  @override
  Future<BridgeCrossing?> byId(String id) async => (await _load())[id];

  @override
  Future<void> save(BridgeCrossing crossing) {
    final done = _queue.then((_) => _save(crossing));
    _queue = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _save(BridgeCrossing crossing) async {
    final byId = await _load();
    checkBridgeUnique(crossing, byId.values);
    final next = {...byId, crossing.id: crossing};
    final f = await file();
    final tmp = File('${f.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(
      jsonEncode([
        for (final c in _newestFirst(next.values)) c.toJson(),
        ..._unreadable,
      ]),
      flush: true,
    );
    await tmp.rename(f.path);
    // Only once it is on disk does the store say it has it.
    _byId = next;
  }
}
