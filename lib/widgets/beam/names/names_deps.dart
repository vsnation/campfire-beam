/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../utilities/util.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import '../../../wallets/beam/contracts/bans/bans_models.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../../wallets/beam/models/beam_wallet_status.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import 'names_auth_gate.dart';

/// Asks the user to prove it is them before anything is signed (Campfire's
/// PIN on mobile, the wallet password on desktop).
///
/// True: passed. False: wrong PIN or password. Null: backed out.
typedef BeamNamesAuthGate = Future<bool?> Function(
  BuildContext context, {
  required String reason,
});

/// Everything the Names screens need, handed in by whoever opens them.
///
/// Keep one instance per wallet (for example next to
/// `BeamWalletServices.of(wallet)`): it remembers the last list of names, so
/// reopening the screen shows them at once (R11), and the names that are on
/// their way after a transaction.
class BeamNamesDeps {
  BeamNamesDeps({
    required this.bans,
    required this.sync,
    required this.balances,
    this.metadataOf = _noMetadata,
    this.authenticate = campfireNamesAuthGate,
    this.onSyncAction,
    this.onAddFunds,
    this.inboxMonitor,
    this.isDesktop,
    BansPendingNames? pending,
  }) : pending = pending ?? BansPendingNames();

  /// The BANS service of this wallet (`BeamWalletServices.of(w).bans`).
  final BeamBansService bans;

  /// The honest sync verdict. Only [BeamSynced] may sign.
  final ValueListenable<BeamSyncAssessment> sync;

  /// Per asset id, the wallet's totals from `wallet_status`.
  final ValueListenable<Map<int, BeamAssetTotals>> balances;

  /// On-chain metadata of an asset the wallet knows, for unverified names.
  final BeamAssetMetadata? Function(int assetId) metadataOf;

  /// Campfire's PIN / password gate.
  final BeamNamesAuthGate authenticate;

  /// Runs the sync banner's action ("Try another node", ...).
  final void Function(BeamSyncAction action)? onSyncAction;

  /// Opens Receive, so "Add BEAM" is never a dead end.
  final VoidCallback? onAddFunds;

  /// The wallet home's name-payment monitor; told to re-read after a claim.
  final BansInboxMonitor? inboxMonitor;

  /// Forces the desktop or mobile layout; null follows the platform.
  final bool? isDesktop;

  /// Names on their way after a transaction this session.
  final BansPendingNames pending;

  /// The last list of names read, shown while a fresh one loads.
  BansMyNames? lastNames;

  static BeamAssetMetadata? _noMetadata(int assetId) => null;

  bool get desktop => isDesktop ?? Util.isDesktop;

  bool get canSpend => sync.value.canSpend;

  BeamAssetDisplay display(int assetId) =>
      BeamAssetCatalog.display(assetId, metadataOf(assetId));

  /// The symbol to print after an amount of [assetId].
  String symbol(int assetId) {
    final d = display(assetId);
    return d.verified ? d.symbol : '${d.symbol} ${d.idLabel}';
  }

  /// What the wallet can spend of [assetId] now, or null when the wallet
  /// has not reported that asset (unknown is not zero).
  BigInt? available(int assetId) => balances.value[assetId]?.available;
}

/// A name transaction that was just signed and sent, as the confirmation
/// screen hands it back to the screen that opened it.
@immutable
class BeamNameSent {
  const BeamNameSent({required this.txId, required this.summary});

  final String txId;

  /// What was sent, decoded from the transaction itself.
  final BansSummary summary;

  BansAction get action => summary.action;
}

/// What a sent name transaction is expected to change.
enum BansPendingKind { register, buy, renew, transfer, list, unlist }

/// A name transaction sent this session and not yet visible in the names
/// list. Replaces Spark Names' `validUntil: -99999` marker with a real
/// record keyed by the transaction id.
@immutable
class BansPendingName {
  const BansPendingName({
    required this.name,
    required this.kind,
    required this.txId,
    required this.sentAt,
    this.expireAtLeast,
    this.listPrice,
  });

  final String name;
  final BansPendingKind kind;
  final String txId;
  final DateTime sentAt;

  /// For a renewal: the expiry the prepared transaction gives the name. It
  /// is exact for an active name and only later for one on hold (the term
  /// then counts from the block it is mined in).
  final int? expireAtLeast;

  /// For a listing: the price it sets.
  final BansAmount? listPrice;

  /// What the names list says while it is on its way.
  String get label => switch (kind) {
    BansPendingKind.register => 'Registering… usually under 2 minutes',
    BansPendingKind.buy => 'Buying… usually under 2 minutes',
    BansPendingKind.renew => 'Renewal on its way…',
    BansPendingKind.transfer => 'Transfer on its way…',
    BansPendingKind.list => 'Listing on its way…',
    BansPendingKind.unlist => 'Taking it off sale…',
  };
}

/// The names on their way, per wallet. Cleared as the names list shows each
/// change, or after [maxAge] (a transaction that failed shows in history).
class BansPendingNames extends ChangeNotifier {
  BansPendingNames({
    this.maxAge = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _now;
  final List<BansPendingName> _items = [];

  List<BansPendingName> get items => List.unmodifiable(_items);

  BansPendingName? of(String name) {
    for (final p in _items.reversed) {
      if (p.name == name) return p;
    }
    return null;
  }

  void add(BansPendingName p) {
    _items.add(p);
    notifyListeners();
  }

  /// Drops every entry [names] already reflects, and stale ones.
  void reconcile(BansMyNames names) {
    final byName = {for (final d in names.names) d.name: d};
    final before = _items.length;
    _items.removeWhere((p) {
      if (_now().difference(p.sentAt) > maxAge) return true;
      final d = byName[p.name];
      return switch (p.kind) {
        BansPendingKind.register || BansPendingKind.buy => d != null,
        BansPendingKind.renew =>
          d != null &&
              p.expireAtLeast != null &&
              d.expireHeight >= p.expireAtLeast!,
        BansPendingKind.transfer => d == null,
        BansPendingKind.list => d?.salePrice == p.listPrice,
        BansPendingKind.unlist => d != null && d.salePrice == null,
      };
    });
    if (_items.length != before) notifyListeners();
  }
}
