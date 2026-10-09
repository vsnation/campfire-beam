/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Where buys are kept on this device: one JSON file, written the way the
// bridge writes its crossings (`bridge_store.dart`), because a lost record
// is a deposit address the user can no longer look up:
//
// * every write goes to a temporary file that then replaces the real one,
//   so a crash mid-write leaves the old file, never half of one;
// * a record this version cannot read is kept as it was and written back
//   unchanged; a file that is not JSON at all is moved aside, never
//   overwritten;
// * nothing is ever deleted by Campfire itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'buybeam_order.dart';

abstract class BuyBeamStore {
  /// Every buy, newest first.
  Future<List<BuyBeamOrder>> all();

  /// Writes [order], replacing the one with its deposit address.
  Future<void> save(BuyBeamOrder order);
}

List<BuyBeamOrder> _newestFirst(Iterable<BuyBeamOrder> list) =>
    list.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

class MemoryBuyBeamStore implements BuyBeamStore {
  final Map<String, BuyBeamOrder> _byAddress = {};

  /// Every save, in order (tests check what was written before a step).
  final List<BuyBeamOrder> writes = [];

  @override
  Future<List<BuyBeamOrder>> all() async => _newestFirst(_byAddress.values);

  @override
  Future<void> save(BuyBeamOrder order) async {
    _byAddress[order.depositAddress] = order;
    writes.add(order);
  }
}

/// [BuyBeamStore] in a JSON file ([file] decides where).
class FileBuyBeamStore implements BuyBeamStore {
  FileBuyBeamStore(this.file);

  final Future<File> Function() file;

  Map<String, BuyBeamOrder>? _byAddress;

  /// Records this version could not read, written back as they were.
  final List<Object?> _unreadable = [];

  /// Writes one at a time, in order.
  Future<void> _queue = Future.value();

  Future<Map<String, BuyBeamOrder>> _load() async {
    final loaded = _byAddress;
    if (loaded != null) return loaded;
    final byAddress = <String, BuyBeamOrder>{};
    final f = await file();
    if (await f.exists()) {
      final Object? decoded;
      try {
        decoded = jsonDecode(await f.readAsString());
      } on FormatException {
        // Not ours to overwrite: keep it beside the new file.
        final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
        await f.rename('${f.path}.unreadable-$stamp');
        return _byAddress = byAddress;
      }
      for (final j in decoded is List ? decoded : const <Object?>[]) {
        try {
          final o = BuyBeamOrder.fromJson((j as Map).cast<String, dynamic>());
          byAddress[o.depositAddress] = o;
        } catch (_) {
          _unreadable.add(j);
        }
      }
    }
    return _byAddress = byAddress;
  }

  @override
  Future<List<BuyBeamOrder>> all() async =>
      _newestFirst((await _load()).values);

  @override
  Future<void> save(BuyBeamOrder order) {
    final done = _queue.then((_) => _save(order));
    _queue = done.then<void>((_) {}, onError: (Object _) {});
    return done;
  }

  Future<void> _save(BuyBeamOrder order) async {
    final byAddress = await _load();
    final next = {...byAddress, order.depositAddress: order};
    final f = await file();
    final tmp = File('${f.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(
      jsonEncode([
        for (final o in _newestFirst(next.values)) o.toJson(),
        ..._unreadable,
      ]),
      flush: true,
    );
    await tmp.rename(f.path);
    // Only once it is on disk does the store say it has it.
    _byAddress = next;
  }
}
