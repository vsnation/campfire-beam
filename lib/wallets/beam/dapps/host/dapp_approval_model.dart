/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../../assets/beam_asset_catalog.dart';
import '../../models/beam_asset_info.dart';
import '../dapp_consent.dart';

/// What a request does to the wallet, in the words the sheet uses.
enum DappApprovalKind {
  /// Funds leave and other funds arrive.
  swap,

  /// `tx_send`: a payment to an address.
  payment,

  /// A contract takes funds from the wallet, nothing comes back.
  contractPayment,

  /// A contract sends funds to the wallet, nothing leaves but the fee.
  withdrawal,

  /// No funds move; only the network fee is paid.
  feeOnly,
}

/// An amount of one asset, as the sheet shows it.
@immutable
class DappAssetLine {
  const DappAssetLine(this.asset, this.amount);

  final BeamAssetDisplay asset;

  /// Smallest units, always positive.
  final BigInt amount;

  /// "0.80368764", "1,000".
  String get amountText => dappFormatAmount(amount);

  /// "0.80368764 FOMO"; an asset Campfire does not vouch for carries its
  /// id, so a look-alike "FOMO" can never read as the verified one:
  /// "1 FOMO (#175)".
  String get text => '$amountText $unit';

  /// "FOMO", or "FOMO (#175)" for an asset Campfire does not vouch for.
  String get unit {
    final a = asset;
    if (a.verified || a.symbol == a.idLabel) return a.symbol;
    return '${a.symbol} (${a.idLabel})';
  }
}

/// Everything the approval sheet shows for one [DappConsentRequest].
///
/// Amounts, fee and contract ids come from [request], which `DappSession`
/// built from the exact parameters that will execute (for a contract, the
/// decoded `raw_data`). Nothing here comes from the dApp's description of
/// itself except [message], which the sheet labels as the dApp's words.
@immutable
class DappApprovalModel {
  const DappApprovalModel._({
    required this.request,
    required this.kind,
    required this.pays,
    required this.receives,
    required this.fee,
    required this.totalOut,
    required this.shortfall,
    required this.lookalikes,
    required this.blockedReason,
    required this.available,
  });

  /// [metadata]: on-chain metadata of the assets Campfire does not vouch
  /// for (missing entries are shown as "Asset #id"). [available]: spendable
  /// balances, null when unknown (then no shortfall is computed).
  /// [spendBlockedReason]: why the wallet cannot spend right now, or null.
  factory DappApprovalModel.build(
    DappConsentRequest request, {
    Map<int, BeamAssetMetadata?> metadata = const {},
    Map<int, BigInt>? available,
    String? spendBlockedReason,
  }) {
    BeamAssetDisplay show(int id) => BeamAssetCatalog.display(id, metadata[id]);
    DappAssetLine line(DappAssetAmount a) =>
        DappAssetLine(show(a.assetId), a.amount);

    final pays = [for (final a in request.pays) line(a)];
    final receives = [for (final a in request.receives) line(a)];
    final DappApprovalKind kind;
    if (request.kind == DappConsentKind.send) {
      kind = DappApprovalKind.payment;
    } else if (pays.isNotEmpty && receives.isNotEmpty) {
      kind = DappApprovalKind.swap;
    } else if (pays.isNotEmpty) {
      kind = DappApprovalKind.contractPayment;
    } else if (receives.isNotEmpty) {
      kind = DappApprovalKind.withdrawal;
    } else {
      kind = DappApprovalKind.feeOnly;
    }

    final required = request.required;
    final ids = required.keys.toList()..sort();
    final totalOut = [
      for (final id in ids) DappAssetLine(show(id), required[id]!),
    ];
    final missing = available == null
        ? const <int, BigInt>{}
        : request.shortfall(available);
    final shortfall = [
      for (final id in ids)
        if (missing[id] != null) DappAssetLine(show(id), missing[id]!),
    ];
    final seen = <int>{};
    final lookalikes = [
      for (final l in [...pays, ...receives])
        if (l.asset.impersonates != null && seen.add(l.asset.assetId)) l.asset,
    ];

    return DappApprovalModel._(
      request: request,
      kind: kind,
      pays: List.unmodifiable(pays),
      receives: List.unmodifiable(receives),
      fee: DappAssetLine(show(0), request.fee),
      totalOut: List.unmodifiable(totalOut),
      shortfall: List.unmodifiable(shortfall),
      lookalikes: List.unmodifiable(lookalikes),
      blockedReason: spendBlockedReason,
      available: available == null ? null : Map.unmodifiable(available),
    );
  }

  final DappConsentRequest request;
  final DappApprovalKind kind;

  /// Leaves the wallet, per asset, without the fee.
  final List<DappAssetLine> pays;

  /// Arrives in the wallet, per asset.
  final List<DappAssetLine> receives;

  /// The network fee, in BEAM.
  final DappAssetLine fee;

  /// Everything that leaves the wallet: [pays] plus [fee], per asset.
  final List<DappAssetLine> totalOut;

  /// What the wallet is missing for this, per asset; empty when it holds
  /// enough or the balance is unknown.
  final List<DappAssetLine> shortfall;

  /// Unverified assets named like a verified one.
  final List<BeamAssetDisplay> lookalikes;

  /// Why the wallet cannot spend right now, or null.
  final String? blockedReason;

  /// Spendable balances the shortfall was computed from; null when unknown.
  final Map<int, BigInt>? available;

  bool get canApprove =>
      shortfall.isEmpty && blockedReason == null && !request.isCancelled;

  String get dappName => request.dapp.name;
  String get origin => request.dapp.origin;

  /// "http://127.0.0.1:40000 · version 1.0.0".
  String get originLine {
    final v = request.dapp.version;
    return v == null ? origin : '$origin · version $v';
  }

  /// The primary button: what happens when it is pressed.
  String get cta => switch (kind) {
    DappApprovalKind.swap => 'Approve swap',
    DappApprovalKind.payment => 'Approve payment',
    DappApprovalKind.contractPayment => 'Approve payment',
    DappApprovalKind.withdrawal => 'Approve withdrawal',
    DappApprovalKind.feeOnly => 'Approve request',
  };

  /// One sentence under the dApp's name.
  String get summary => switch (kind) {
    DappApprovalKind.swap => 'Asks you to approve a swap.',
    DappApprovalKind.payment => 'Asks you to approve a payment.',
    DappApprovalKind.contractPayment =>
      'Asks you to approve a payment to a contract.',
    DappApprovalKind.withdrawal =>
      'Asks you to approve funds coming to your wallet.',
    DappApprovalKind.feeOnly => 'Asks you to approve a contract call.',
  };

  /// The dApp's own words (`confirm_comment` or the shader's comment).
  /// Never shown as Campfire's.
  String? get message {
    final m = request.dappMessage?.trim();
    return m == null || m.isEmpty ? null : m;
  }

  bool get isPayment => request.kind == DappConsentKind.send;

  /// The contracts called, full ids, in call order.
  List<String> get contractIds => request.contractIds;

  /// The request deploys a new contract.
  bool get deploys => request.calls.any((c) => c.deploys);

  /// "No funds move" requests.
  bool get isFeeOnly => kind == DappApprovalKind.feeOnly;

  /// "Regular address", "Offline address", … for a payment.
  String? get recipientType {
    final s = request.send;
    if (s == null) return null;
    return switch (s.addressType) {
      'regular' || 'regular_new' => 'Regular address',
      'offline' => 'Offline address',
      'max_privacy' => 'Max privacy address',
      'public_offline' => 'Public offline address',
      _ => 'Address type not recognised',
    };
  }

  /// Why each look-alike asset is not what its name says.
  List<String> get lookalikeWarnings => [
    for (final a in lookalikes)
      '"${a.symbol}" here is asset ${a.idLabel}, not the verified '
          '${BeamAssetCatalog.verified[a.impersonates]!.symbol} '
          '(#${a.impersonates}). Anyone can create an asset with any name.',
  ];

  /// "Not enough BEAM: this needs 0.111 BEAM and the wallet has 0.05 BEAM."
  List<String> get shortfallWarnings => [
    for (final s in shortfall)
      'Not enough ${s.unit}: this needs '
          '${_need(s.asset.assetId)} ${s.unit} and the wallet has '
          '${dappFormatAmount(available?[s.asset.assetId] ?? BigInt.zero)} '
          '${s.unit} available.',
  ];

  String _need(int assetId) =>
      totalOut.firstWhere((l) => l.asset.assetId == assetId).amountText;
}

/// [hex] as "729fe098…ef9cbf".
String dappShortHex(String hex, {int head = 8, int tail = 6}) =>
    hex.length <= head + tail + 1
    ? hex
    : '${hex.substring(0, head)}…${hex.substring(hex.length - tail)}';

/// [amount] smallest units of an asset with [decimals] decimals, with
/// thousands separators and no trailing zeros: 10000000 → "0.1",
/// 100000000000 → "1,000". Every BEAM asset has 8 decimals
/// (`BeamAssetInfo.decimalsFor`), so nothing is ever rounded: what is
/// shown is what moves.
String dappFormatAmount(BigInt amount, {int decimals = 8}) {
  final negative = amount.isNegative;
  final v = amount.abs();
  final base = BigInt.from(10).pow(decimals);
  final whole = (v ~/ base).toString();
  final frac = (v % base)
      .toString()
      .padLeft(decimals, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  final grouped = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) grouped.write(',');
    grouped.write(whole[i]);
  }
  final text = frac.isEmpty ? '$grouped' : '$grouped.$frac';
  return negative ? '-$text' : text;
}
