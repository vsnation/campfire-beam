/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';
import 'package:meta/meta.dart';

import '../../../../l10n/amount_text.dart';
import '../../../../l10n/l10n.dart';
import '../../../../utilities/amount/amount.dart';
import '../../assets/beam_asset_catalog.dart';
import '../../models/beam_asset_info.dart';
import '../../price/beam_fiat_price.dart';
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
  const DappAssetLine(this.asset, this.amount, {this.fiat});

  final BeamAssetDisplay asset;

  /// Smallest units, always positive.
  final BigInt amount;

  /// What [amount] is worth in the user's currency, "≈ 1.19 USD" or
  /// "under 0.01 USD"; null when there is no price (lookups off, no price
  /// yet, or no DEX pool that prices the asset).
  final String? fiat;

  /// "0.80368764", "1,000", in the asset's own decimals (its NTH_RATIO); in
  /// smallest units, said so, while they are not known ([decimalsKnown]).
  String get amountText =>
      dappFormatAmount(amount, decimals: asset.decimals ?? 0);

  /// The asset's decimals are known: its metadata was read, or it is pinned.
  bool get decimalsKnown => asset.decimals != null;

  /// "0.80368764 FOMO"; an asset Campfire does not vouch for carries its
  /// id, so a look-alike "FOMO" can never read as the verified one:
  /// "1 FOMO (#175)".
  String get text => decimalsKnown
      ? '$amountText $unit'
      : appL10n.dappsSmallestUnits(amountText, unit);

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
    if (id == null) return appL10n.dappsCallNewContract;
    return contractName ?? appL10n.dappsCallContract(dappShortHex(id));
  }

  /// "Call 2 · Beam DEX · method 7".
  String get title =>
      appL10n.dappsCallTitle('$number', contractLabel, '$method');

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
    this.rebuild,
  });

  /// [metadata]: on-chain metadata of the assets Campfire does not vouch
  /// for (missing entries are shown as "Asset #id"). [available]: spendable
  /// balances, null when unknown (then no shortfall is computed).
  /// [spendBlockedReason]: why the wallet cannot spend right now, or null.
  ///
  /// [valueInGroth]: what an amount of an asset is worth in BEAM groth (the
  /// DEX's prices), and [fiat]: BEAM's price in the user's currency. With
  /// both, every amount also shows its fiat value.
  factory DappApprovalModel.build(
    DappConsentRequest request, {
    Map<int, BeamAssetMetadata?> metadata = const {},
    Map<int, BigInt>? available,
    String? spendBlockedReason,
    BigInt? Function(int assetId, BigInt amount)? valueInGroth,
    BeamFiatPrice? fiat,
  }) {
    BeamAssetDisplay show(int id) => BeamAssetCatalog.display(id, metadata[id]);
    String? fiatOf(int assetId, BigInt amount) {
      if (fiat == null || !fiat.known || amount <= BigInt.zero) return null;
      final groth = assetId == 0 ? amount : valueInGroth?.call(assetId, amount);
      return groth == null ? null : dappFiatText(groth, fiat);
    }

    DappAssetLine lineOf(int assetId, BigInt amount) =>
        DappAssetLine(show(assetId), amount, fiat: fiatOf(assetId, amount));
    DappAssetLine line(DappAssetAmount a) => lineOf(a.assetId, a.amount);

    final pays = [for (final a in request.pays) line(a)];
    final unknownPay = [
      for (final l in pays)
        if (!l.decimalsKnown) l,
    ];
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
    final totalOut = [for (final id in ids) lineOf(id, required[id]!)];
    final missing = available == null
        ? const <int, BigInt>{}
        : request.shortfall(available);
    final shortfall = [
      for (final id in ids)
        if (missing[id] != null) DappAssetLine(show(id), missing[id]!),
    ];
    final terms = request.rebuild;
    List<DappAssetLine> bounds(Map<int, BigInt> m) => [
      for (final id in m.keys.toList()..sort()) lineOf(id, m[id]!),
    ];
    final rebuild = terms == null
        ? null
        : DappRebuildView(
            terms: terms,
            dappName: dappDisplayText(request.dapp.name, maxLength: 64),
            maxPays: bounds(terms.maxPays),
            minReceives: bounds(terms.minReceives),
          );
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
      fee: lineOf(0, request.fee),
      totalOut: List.unmodifiable(totalOut),
      shortfall: List.unmodifiable(shortfall),
      lookalikes: List.unmodifiable(lookalikes),
      // A signature moves nothing: a wallet that may not spend can still
      // sign.
      blockedReason: kind == DappApprovalKind.signMessage
          ? null
          // A paid asset whose decimals are not known: its amount could
          // read 10^n off.
          : unknownPay.isNotEmpty
          ? appL10n.sendAssetDecimalsUnknown(unknownPay.first.unit)
          : spendBlockedReason,
      available: available == null ? null : Map.unmodifiable(available),
      calls: List.unmodifiable(calls),
      rebuild: rebuild,
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

  /// Set when the core may rebuild what is approved and sign the new
  /// version without asking again: whose app code would build it, and the
  /// worst it may then do.
  final DappRebuildView? rebuild;

  /// The user must tick "I understand" before approving: the app code that
  /// would rebuild this is not code Campfire vouches for.
  bool get needsAcknowledgement => rebuild?.needsAcknowledgement ?? false;

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
    return v == null ? origin : appL10n.dappsOriginVersion(origin, v);
  }

  /// The primary button: what happens when it is pressed.
  String get cta => switch (kind) {
    DappApprovalKind.swap => appL10n.dappsCtaSwap,
    DappApprovalKind.payment => appL10n.dappsCtaPayment,
    DappApprovalKind.contractPayment => appL10n.dappsCtaPayment,
    DappApprovalKind.withdrawal => appL10n.dappsCtaWithdrawal,
    DappApprovalKind.contractCall =>
      calls.length > 1
          ? appL10n.dappsCtaContractCalls
          : appL10n.dappsCtaContractCall,
    DappApprovalKind.signMessage => appL10n.dappsCtaSign,
    DappApprovalKind.feeOnly => appL10n.dappsCtaRequest,
  };

  /// One sentence under the dApp's name.
  String get summary => switch (kind) {
    DappApprovalKind.swap => appL10n.dappsSummarySwap,
    DappApprovalKind.payment => appL10n.dappsSummaryPayment,
    DappApprovalKind.contractPayment => appL10n.dappsSummaryContractPayment,
    DappApprovalKind.withdrawal => appL10n.dappsSummaryWithdrawal,
    DappApprovalKind.contractCall =>
      calls.length > 1
          ? appL10n.dappsSummaryContractCalls(calls.length)
          : appL10n.dappsSummarySignedCall,
    DappApprovalKind.signMessage => appL10n.dappsSummarySign,
    DappApprovalKind.feeOnly => appL10n.dappsSummaryFeeOnly,
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
      'regular' || 'regular_new' => appL10n.dappsAddressRegular,
      'offline' => appL10n.dappsAddressOffline,
      'max_privacy' => appL10n.dappsAddressMaxPrivacy,
      'public_offline' => appL10n.dappsAddressPublicOffline,
      _ => appL10n.dappsAddressUnknown,
    };
  }

  /// One warning per call the wallet signs: a signed call can change or
  /// move what the wallet holds in that contract with no funds moving.
  List<String> get signingWarnings => [
    for (final c in calls)
      if (c.signs)
        calls.length > 1
            ? appL10n.dappsSigningWarningCall('${c.number}', c.contractLabel)
            : appL10n.dappsSigningWarningThis(c.contractLabel),
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
    return appL10n.dappsPassThroughWarning;
  }

  /// Why each look-alike asset is not what its name says.
  List<String> get lookalikeWarnings => [
    for (final a in lookalikes)
      appL10n.dappsLookalikeWarning(
        a.symbol,
        a.idLabel,
        BeamAssetCatalog.verified[a.impersonates]!.symbol,
        '${a.impersonates}',
      ),
  ];

  /// "Not enough BEAM: this needs 0.111 BEAM and the wallet has 0.05 BEAM."
  List<String> get shortfallWarnings => [
    for (final s in shortfall)
      appL10n.dappsShortfall(
        s.unit,
        _need(s.asset.assetId),
        dappFormatAmount(
          available?[s.asset.assetId] ?? BigInt.zero,
          decimals: s.asset.decimals ?? 8,
        ),
      ),
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
/// 100000000000 → "1,000" ("1 000" in Russian; "." decimals in every
/// language). BEAM has 8 decimals, an asset its own
/// ([BeamAssetDisplay.decimals]);
/// nothing is ever rounded: what is shown is what moves.
String dappFormatAmount(BigInt amount, {int decimals = 8}) =>
    formatAmountUnits(amount, decimals: decimals);

/// The worst the core may sign after approval, for a request it can
/// rebuild ([DappRebuildTerms]), in the words the sheet uses.
@immutable
class DappRebuildView {
  const DappRebuildView({
    required this.terms,
    required this.dappName,
    required this.maxPays,
    required this.minReceives,
  });

  final DappRebuildTerms terms;
  final String dappName;

  /// The most each asset may cost, without the network fee.
  final List<DappAssetLine> maxPays;

  /// The least of each asset that must arrive; a zero amount means the
  /// asset may not arrive at all.
  final List<DappAssetLine> minReceives;

  bool get verified => terms.isVerifiedDex;

  /// Unverified code also needs the user's explicit "I understand".
  bool get needsAcknowledgement => !verified;

  /// Whose code would build the new version.
  String get appCodeLabel =>
      verified ? appL10n.dappsAppCodeVerified : appL10n.dappsAppCodeUnverified;

  /// The stored app code's fingerprint, "8b4a0616…12c3fa".
  String get appCodeFingerprint => dappShortHex(terms.appCodeSha256);

  /// The heading of the worst-case box.
  String get title => verified
      ? appL10n.dappsRebuildTitleVerified
      : appL10n.dappsRebuildTitleUnverified(dappName);

  /// What happens, before the worst-case amounts.
  String get explanation => verified
      ? appL10n.dappsRebuildExplainVerified(DappRebuildTerms.windowBlocks)
      : appL10n.dappsRebuildExplainUnverified(
          DappRebuildTerms.windowBlocks,
          dappName,
        );

  /// The tick the user must give for unverified code.
  String get acknowledgement => appL10n.dappsRebuildAcknowledge(dappName);
}

/// [groth] of BEAM in [fiat]'s currency, rounded down, as Campfire writes
/// money: "≈ 1.19 USD", "≈ 1.234,56 EUR" in a German locale, and
/// "under 0.01 USD" below a cent (never "0.00 USD"). Null without a price.
String? dappFiatText(BigInt groth, BeamFiatPrice fiat) {
  final price = fiat.price;
  if (!fiat.known || price == null) return null;
  final value = (Decimal.fromBigInt(groth) * price).shift(-8);
  final code = fiat.currency.toUpperCase();
  final cent = Decimal.parse('0.01');
  String money(Decimal d) => d
      .floor(scale: 2)
      .toAmount(fractionDigits: 2)
      .fiatString(locale: fiat.locale);
  if (value < cent) return appL10n.dappsFiatUnder('${money(cent)} $code');
  return '≈ ${money(value)} $code';
}
