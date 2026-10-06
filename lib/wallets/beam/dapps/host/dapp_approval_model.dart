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
import '../dapp_text.dart';
import '../dapp_wallet_keys.dart';

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

  /// Contract calls that move funds between contracts, or sign with a
  /// wallet key, while the wallet's own balance may not change: each call
  /// is shown on its own.
  contractCall,

  /// `sign_message`: a signature, no funds, no fee.
  signMessage,

  /// Nothing the wallet holds is touched; only the network fee is paid.
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

/// One contract call as the sheet lists it: what it alone moves, and
/// whether the wallet signs it.
@immutable
class DappCallLine {
  const DappCallLine({
    required this.number,
    required this.contractId,
    required this.contractName,
    required this.method,
    required this.pays,
    required this.receives,
    required this.signs,
  });

  /// 1-based position in the transaction.
  final int number;

  /// Null for a deployment.
  final String? contractId;

  /// "Beam DEX", or null for a contract Campfire does not know.
  final String? contractName;
  final int method;
  final List<DappAssetLine> pays;
  final List<DappAssetLine> receives;

  /// The wallet signs this call with one of its keys.
  final bool signs;

  /// "Beam DEX", "New contract", or "Contract 729fe098…ef9cbf".
  String get contractLabel {
    final id = contractId;
    if (id == null) return 'New contract';
    return contractName ?? 'Contract ${dappShortHex(id)}';
  }

  /// "Call 2 · Beam DEX · method 7".
  String get title => 'Call $number · $contractLabel · method $method';

  bool get movesFunds => pays.isNotEmpty || receives.isNotEmpty;
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
    required this.calls,
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
    final calls = [
      for (final (i, c) in request.calls.indexed)
        DappCallLine(
          number: i + 1,
          contractId: c.contractId,
          contractName: dappContractName(c.contractId),
          method: c.method,
          pays: [for (final a in c.pays) line(a)],
          receives: [for (final a in c.receives) line(a)],
          signs: c.signs,
        ),
    ];
    final movingCalls = calls.where((c) => c.movesFunds).length;
    final DappApprovalKind kind;
    if (request.kind == DappConsentKind.send) {
      kind = DappApprovalKind.payment;
    } else if (request.kind == DappConsentKind.signMessage) {
      kind = DappApprovalKind.signMessage;
    } else if (movingCalls > 1) {
      // The net hides which contract gets what: one call can empty a
      // contract and the next lock the same funds into another.
      kind = DappApprovalKind.contractCall;
    } else if (pays.isNotEmpty && receives.isNotEmpty) {
      kind = DappApprovalKind.swap;
    } else if (pays.isNotEmpty) {
      kind = DappApprovalKind.contractPayment;
    } else if (receives.isNotEmpty) {
      kind = DappApprovalKind.withdrawal;
    } else if (request.isFeeOnly) {
      kind = DappApprovalKind.feeOnly;
    } else {
      kind = DappApprovalKind.contractCall;
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
      for (final l in [
        ...pays,
        ...receives,
        for (final c in calls) ...[...c.pays, ...c.receives],
      ])
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
      // A signature moves nothing: a wallet that may not spend can still
      // sign.
      blockedReason: kind == DappApprovalKind.signMessage
          ? null
          : spendBlockedReason,
      available: available == null ? null : Map.unmodifiable(available),
      calls: List.unmodifiable(calls),
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

  /// Each contract call with its own flows, in order.
  final List<DappCallLine> calls;

  /// Show each call on its own: there is more than one, so a net total
  /// would hide which contract gets what.
  bool get showsCalls => calls.length > 1;

  bool get canApprove =>
      shortfall.isEmpty && blockedReason == null && !request.isCancelled;

  String get dappName => dappDisplayText(request.dapp.name, maxLength: 64);
  String get origin => request.dapp.origin;

  /// The dApp was installed from a file: Campfire did not check it, and its
  /// name is whatever the file says.
  bool get notCheckedByCampfire => !request.dapp.checkedByCampfire;

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
    DappApprovalKind.contractCall =>
      calls.length > 1 ? 'Approve contract calls' : 'Approve contract call',
    DappApprovalKind.signMessage => 'Sign message',
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
    DappApprovalKind.contractCall =>
      calls.length > 1
          ? 'Asks you to approve ${calls.length} contract calls. Check what '
                'each one moves.'
          : "Asks you to approve a contract call signed with your wallet's "
                'key.',
    DappApprovalKind.signMessage =>
      'Asks you to sign a message with a key from this wallet.',
    DappApprovalKind.feeOnly => 'Asks you to approve a contract call.',
  };

  /// The dApp's own words (`confirm_comment`, the shader's comment, or the
  /// message to sign), cleaned of control and bidi characters. Never shown
  /// as Campfire's.
  String? get message {
    final m = request.dappMessage;
    if (m == null) return null;
    // A message to sign is shown whole (the sanitizer caps it, and refuses
    // hidden characters): the user must see everything they sign.
    final t = dappDisplayText(m, maxLength: isSignMessage ? m.length : 1024);
    return t.isEmpty ? null : t;
  }

  /// "Beam DEX" for a contract Campfire knows, else null.
  String? contractNameOf(String contractId) => dappContractName(contractId);

  bool get isSignMessage => kind == DappApprovalKind.signMessage;

  /// The key a signature uses, as "6b3f1a20…c09e11", for [isSignMessage].
  String? get signKeyText {
    final k = request.sign?.keyMaterial;
    return k == null ? null : dappShortHex(k);
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

  /// One warning per call the wallet signs: a signed call can change or
  /// move what the wallet holds in that contract with no funds moving.
  List<String> get signingWarnings => [
    for (final c in calls)
      if (c.signs)
        '${calls.length > 1 ? 'Call ${c.number}' : 'This call'} signs with '
            "your wallet's key for ${c.contractLabel}. It can change or move "
            'what you hold in that contract.',
  ];

  /// Set when funds one call takes out of a contract are paid into another
  /// contract by a different call.
  String? get passThroughWarning {
    final inn = <int>{};
    final out = <int>{};
    for (final c in calls) {
      for (final r in c.receives) {
        inn.add(r.asset.assetId);
      }
      for (final p in c.pays) {
        out.add(p.asset.assetId);
      }
    }
    if (calls.length < 2 || inn.intersection(out).isEmpty) return null;
    return 'Funds one call takes out of a contract are paid into another '
        'contract by a different call. Check where they end up.';
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
