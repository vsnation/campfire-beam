/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The NEAR Intents swaps a wallet started, kept on this device: each one's
// whole signed quote (1Click asks integrators to keep it, with its
// signature, to settle any dispute), so the user can come back to a
// deposit address and see where the swap is after closing the app.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'one_click_client.dart';

class NearIntentsSwap {
  NearIntentsSwap({
    required this.walletId,
    required this.quote,
    required this.origin,
    required this.createdAt,
    this.lastState,
    this.buyWbeam = true,
  });

  factory NearIntentsSwap.fromJson(Map<String, dynamic> j) => NearIntentsSwap(
    walletId: j['walletId'] as String,
    quote: OneClickQuote((j['quote'] as Map).cast<String, dynamic>()),
    origin: OneClickToken.fromJson(
      (j['origin'] as Map).cast<String, dynamic>(),
    ),
    createdAt: DateTime.parse(j['createdAt'] as String),
    lastState: OneClickState.parse(j['state'] as String? ?? ''),
    buyWbeam: j['buyWbeam'] as bool? ?? true,
  );

  final String walletId;
  final OneClickQuote quote;
  final OneClickToken origin;
  final DateTime createdAt;
  OneClickState? lastState;

  /// The user asked to buy WBEAM with the ETH once it arrives.
  final bool buyWbeam;

  String get depositAddress => quote.depositAddress!;

  bool get isOpen => !(lastState?.isFinal ?? false);

  Map<String, dynamic> toJson() => {
    'walletId': walletId,
    'quote': quote.raw,
    'origin': origin.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastState != null) 'state': lastState!.wire,
    'buyWbeam': buyWbeam,
  };
}

abstract class NearIntentsStore {
  Future<List<NearIntentsSwap>> all(String walletId);
  Future<void> save(NearIntentsSwap swap);
}

class MemoryNearIntentsStore implements NearIntentsStore {
  final List<NearIntentsSwap> _all = [];

  @override
  Future<List<NearIntentsSwap>> all(String walletId) async =>
      _all.where((s) => s.walletId == walletId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> save(NearIntentsSwap swap) async {
    _all.removeWhere((s) => s.depositAddress == swap.depositAddress);
    _all.add(swap);
  }
}

/// [NearIntentsStore] in a JSON file ([file] decides where).
class FileNearIntentsStore implements NearIntentsStore {
  FileNearIntentsStore(this.file);

  final Future<File> Function() file;
  List<NearIntentsSwap>? _cache;

  Future<List<NearIntentsSwap>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await file();
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        _cache = [
          for (final j in list.cast<Map<String, dynamic>>())
            NearIntentsSwap.fromJson(j),
        ];
      } else {
        _cache = [];
      }
    } catch (_) {
      _cache = [];
    }
    return _cache!;
  }

  @override
  Future<List<NearIntentsSwap>> all(String walletId) async =>
      (await _load()).where((s) => s.walletId == walletId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  Future<void> save(NearIntentsSwap swap) async {
    final list = await _load();
    list.removeWhere((s) => s.depositAddress == swap.depositAddress);
    list.add(swap);
    final f = await file();
    await f.writeAsString(jsonEncode([for (final s in list) s.toJson()]));
  }
}
