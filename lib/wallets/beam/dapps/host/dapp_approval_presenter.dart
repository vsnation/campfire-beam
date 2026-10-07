/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../assets/beam_asset_catalog.dart';
import '../../models/beam_asset_info.dart';
import '../../price/beam_fiat_price.dart';
import '../dapp_consent.dart';
import 'dapp_approval_model.dart';
import 'dapp_wallet_link.dart';

export 'dapp_wallet_link.dart' show DappAssetValuer;

/// Shows one approval and answers with the user's decision: true only when
/// the user pressed the approve button and passed Campfire's PIN or
/// password check.
typedef DappApprovalUi = Future<bool> Function(DappApprovalModel model);

/// The [DappConsentPolicy] behind Campfire's approval sheet.
///
/// The dApp page that is on screen [attach]es the function that opens the
/// sheet. With nothing attached (the page is closing, or a request arrives
/// from a page that is no longer shown) every request is rejected: nothing
/// is ever approved without the sheet.
///
/// Before the sheet opens, the presenter looks up what the sheet needs and
/// the request does not carry: names of assets Campfire does not vouch for,
/// the spendable balances, whether the wallet may spend at all, and what
/// the amounts are worth (the DEX's prices, and BEAM's price in the user's
/// currency from the page that [attach]ed). Each lookup is bounded by
/// [lookupTimeout]; a slow wallet makes the sheet show "Asset #id", no
/// balance check and no fiat values, never a wrong number. While the sheet
/// is open the wallet's node switch is held (project rules R11).
class DappApprovalPresenter implements DappConsentPolicy {
  DappApprovalPresenter(
    this.wallet, {
    this.lookupTimeout = const Duration(seconds: 3),
  });

  final DappWalletLink wallet;
  final Duration lookupTimeout;

  DappApprovalUi? _ui;
  BeamFiatPrice? Function()? _fiat;

  /// The page on screen shows approvals with [ui] from now on. [fiat] reads
  /// BEAM's price in the user's currency when a sheet opens (null: values
  /// in BEAM only).
  void attach(DappApprovalUi ui, {BeamFiatPrice? Function()? fiat}) {
    _ui = ui;
    _fiat = fiat;
  }

  /// Stops showing approvals with [ui] (if it is still the attached one).
  void detach(DappApprovalUi ui) {
    if (identical(_ui, ui)) {
      _ui = null;
      _fiat = null;
    }
  }

  bool get isAttached => _ui != null;

  @override
  Future<bool> approve(DappConsentRequest request) async {
    final ui = _ui;
    if (ui == null || request.isCancelled) return false;
    final release = wallet.holdForApproval('dApp approval');
    try {
      final model = await buildModel(request);
      if (request.isCancelled) return false;
      return identical(await ui(model), true) && !request.isCancelled;
    } catch (_) {
      return false;
    } finally {
      release();
    }
  }

  /// The sheet's model for [request], with lookups done.
  Future<DappApprovalModel> buildModel(DappConsentRequest request) async {
    final unknown = {
      for (final a in [
        ...request.pays,
        ...request.receives,
        for (final c in request.calls) ...[...c.pays, ...c.receives],
      ])
        if (!BeamAssetCatalog.verified.containsKey(a.assetId)) a.assetId,
    };
    final lookups = await Future.wait([
      for (final id in unknown) _bounded(() => wallet.assetMetadata(id)),
    ]);
    final metadata = <int, BeamAssetMetadata?>{
      for (final (i, id) in unknown.indexed) id: lookups[i],
    };
    final fiat = _readFiat();
    final results = await Future.wait<Object?>([
      _bounded(wallet.availableBalances),
      // Prices only matter when they can be shown.
      fiat != null && fiat.known && _needsPrices(request)
          ? _bounded(wallet.assetValuer)
          : Future<Object?>.value(),
    ]);
    final valuer = results[1] as DappAssetValuer?;
    return DappApprovalModel.build(
      request,
      metadata: metadata,
      available: results[0] as Map<int, BigInt>?,
      spendBlockedReason: wallet.spendBlockedReason,
      valueInGroth: valuer,
      fiat: fiat,
    );
  }

  BeamFiatPrice? _readFiat() {
    try {
      return _fiat?.call();
    } catch (_) {
      return null;
    }
  }

  /// Some amount is in an asset other than BEAM, so the DEX's prices are
  /// needed to value it.
  static bool _needsPrices(DappConsentRequest request) => [
    ...request.pays,
    ...request.receives,
    for (final c in request.calls) ...[...c.pays, ...c.receives],
  ].any((a) => a.assetId != 0);

  Future<T?> _bounded<T>(Future<T?> Function() lookup) async {
    try {
      return await lookup().timeout(lookupTimeout);
    } catch (_) {
      return null;
    }
  }
}
