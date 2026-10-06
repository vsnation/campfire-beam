/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:meta/meta.dart';

import '../../wallet/impl/beam_wallet.dart';
import '../contracts/dex/beam_pool.dart';
import '../wallet/beam_wallet_services.dart';
import 'beam_asset_holdings.dart';

/// Reads the DEX pools for the asset screens: lazily (only when an asset
/// screen asks), at most once per [maxAge], one read at a time per wallet.
/// One `pools_view` gives both the prices and which assets are LP tokens.
class BeamAssetMarketSource {
  @visibleForTesting
  BeamAssetMarketSource(this._readPools, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static final Map<String, BeamAssetMarketSource> _byWallet = {};

  /// The source of [wallet], on the wallet's shared services (one shader
  /// queue with every other BEAM screen).
  static BeamAssetMarketSource of(BeamWallet wallet) =>
      _byWallet[wallet.walletId] ??= BeamAssetMarketSource(
        () => BeamWalletServices.of(wallet).dex.listPools(includeEmpty: true),
      );

  static void forget(String walletId) => _byWallet.remove(walletId);

  final Future<List<BeamPool>> Function() _readPools;
  final DateTime Function() _now;

  BeamAssetMarket? _last;
  Future<BeamAssetMarket>? _reading;

  /// The last successful read, however old.
  BeamAssetMarket? get last => _last;

  /// Pools at most [maxAge] old; a failed read throws and keeps [last].
  Future<BeamAssetMarket> read({
    Duration maxAge = const Duration(minutes: 2),
    bool force = false,
  }) {
    final last = _last;
    if (!force && last != null && _now().difference(last.readAt) < maxAge) {
      return Future.value(last);
    }
    return _reading ??= () async {
      try {
        final market = BeamAssetMarket(await _readPools(), readAt: _now());
        _last = market;
        return market;
      } finally {
        _reading = null;
      }
    }();
  }
}
