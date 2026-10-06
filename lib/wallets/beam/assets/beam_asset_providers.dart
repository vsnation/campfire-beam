/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';

import '../../../models/balance.dart';
import '../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../providers/db/main_db_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../isar/providers/wallet_info_provider.dart';
import '../../wallet/impl/beam_wallet.dart';
import '../../wallet/supporting/beam_wallet_info_extension.dart';
import '../wallet/beam_balance_mapper.dart';
import 'beam_asset_holdings.dart';
import 'beam_asset_market_source.dart';
import 'beam_hidden_assets.dart';

/// The open BEAM wallet [walletId] names, or null when it is not a BEAM
/// wallet. Tests override this.
final pBeamWallet = Provider.family<BeamWallet?, String>((ref, walletId) {
  final wallet = ref.watch(pWallets).getWallet(walletId);
  return wallet is BeamWallet ? wallet : null;
});

/// Per-asset totals from the wallet's cache (`beamAssetTotals`), so asset
/// balances render at unlock without waiting for the core (R11).
final pBeamAssetTotals =
    Provider.family<Map<int, BeamCachedAssetTotals>, String>(
      (ref, walletId) => ref.watch(pWalletInfo(walletId)).beamAssetTotals,
    );

/// One asset's balance, mapped exactly like BEAM's.
final pBeamAssetBalance =
    Provider.family<Balance, ({String walletId, int assetId})>((ref, key) {
      final totals = ref.watch(pBeamAssetTotals(key.walletId))[key.assetId];
      return beamAssetBalance(
        totals ??
            BeamCachedAssetTotals(
              assetId: key.assetId,
              available: BigInt.zero,
              receiving: BigInt.zero,
              sending: BigInt.zero,
              maturing: BigInt.zero,
              change: BigInt.zero,
            ),
      );
    });

/// The asset ids the user hid from [walletId]'s list.
final pBeamHiddenAssetIds = Provider.family<Set<int>, String>(
  (ref, walletId) => BeamHiddenAssets.read(ref.watch(pWalletInfo(walletId))),
);

class _ContractsWatcher extends ChangeNotifier {
  _ContractsWatcher(this._collection) {
    _value = _read();
    _sub = _collection.watchLazy().listen((_) {
      _value = _read();
      notifyListeners();
    });
  }

  final IsarCollection<BeamAssetContract> _collection;
  late final StreamSubscription<void> _sub;
  late Map<int, BeamAssetContract> _value;

  Map<int, BeamAssetContract> get value => _value;

  Map<int, BeamAssetContract> _read() => Map.unmodifiable({
    for (final c in _collection.where().findAllSync()) c.assetId: c,
  });

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

final _contractsWatcher = ChangeNotifierProvider<_ContractsWatcher>((ref) {
  return _ContractsWatcher(ref.watch(mainDBProvider).isar.beamAssetContracts);
});

/// Every cached asset row, by asset id.
final pBeamAssetContracts = Provider<Map<int, BeamAssetContract>>(
  (ref) => ref.watch(_contractsWatcher).value,
);

/// DEX prices and LP tokens for [walletId]'s asset screens; null while they
/// cannot be read (core still connecting). Invalidate to re-read.
final pBeamAssetMarket = FutureProvider.family<BeamAssetMarket?, String>((
  ref,
  walletId,
) async {
  final wallet = ref.watch(pBeamWallet(walletId));
  if (wallet == null) return null;
  final source = BeamAssetMarketSource.of(wallet);
  try {
    return await source.read();
  } catch (_) {
    return source.last;
  }
});

/// The assets [walletId] holds, valued and ordered, hidden ones flagged.
final pBeamAssetHoldings = Provider.family<List<BeamAssetHolding>, String>((
  ref,
  walletId,
) {
  return BeamAssetHoldings.build(
    totals: ref.watch(pBeamAssetTotals(walletId)),
    contracts: ref.watch(pBeamAssetContracts),
    hidden: ref.watch(pBeamHiddenAssetIds(walletId)),
    market: ref.watch(pBeamAssetMarket(walletId)).asData?.value,
  );
});
