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
import '../dapp_consent.dart';
import 'dapp_approval_model.dart';
import 'dapp_wallet_link.dart';

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
/// the spendable balances, and whether the wallet may spend at all. Each
/// lookup is bounded by [lookupTimeout]; a slow wallet makes the sheet show
/// "Asset #id" and no balance check, never a wrong number. While the sheet
/// is open the wallet's node switch is held (project rules R11).
class DappApprovalPresenter implements DappConsentPolicy {
  DappApprovalPresenter(
    this.wallet, {
    this.lookupTimeout = const Duration(seconds: 3),
  });

  final DappWalletLink wallet;
  final Duration lookupTimeout;

  DappApprovalUi? _ui;

  /// The page on screen shows approvals with [ui] from now on.
  void attach(DappApprovalUi ui) => _ui = ui;

  /// Stops showing approvals with [ui] (if it is still the attached one).
  void detach(DappApprovalUi ui) {
    if (identical(_ui, ui)) _ui = null;
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
      for (final a in [...request.pays, ...request.receives])
        if (!BeamAssetCatalog.verified.containsKey(a.assetId)) a.assetId,
    };
    final lookups = await Future.wait([
      for (final id in unknown) _bounded(() => wallet.assetMetadata(id)),
    ]);
    final metadata = <int, BeamAssetMetadata?>{
      for (final (i, id) in unknown.indexed) id: lookups[i],
    };
    final available = await _bounded(wallet.availableBalances);
    return DappApprovalModel.build(
      request,
      metadata: metadata,
      available: available,
      spendBlockedReason: wallet.spendBlockedReason,
    );
  }

  Future<T?> _bounded<T>(Future<T?> Function() lookup) async {
    try {
      return await lookup().timeout(lookupTimeout);
    } catch (_) {
      return null;
    }
  }
}
