/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:meta/meta.dart';

import 'bans_exceptions.dart';
import 'bans_name.dart';
import 'bans_timeline.dart';

/// A sale price or a payment: [amount] of [assetId] in its smallest unit.
@immutable
class BansAmount {
  const BansAmount(this.assetId, this.amount);

  final int assetId;
  final BigInt amount;

  @override
  bool operator ==(Object other) =>
      other is BansAmount && other.assetId == assetId && other.amount == amount;

  @override
  int get hashCode => Object.hash(assetId, amount);

  @override
  String toString() => 'BansAmount($assetId, $amount)';
}

/// One name's on-chain record (`Domain`, `contract.h:64-66`).
@immutable
class BansDomain {
  const BansDomain({
    required this.name,
    required this.ownerKey,
    required this.expireHeight,
    this.salePrice,
  });

  final String name;

  /// The owner's BANS key. Every name a wallet owns has the same key.
  final String ownerKey;

  /// `hExpire`: the first height at which the name is no longer active.
  final int expireHeight;

  /// Set while the owner has it listed; buying pays exactly this.
  final BansAmount? salePrice;

  bool get isListed => salePrice != null;

  /// Status at the block after [tipHeight]. A name on hold reports
  /// [BansNameStatus.onHold] even when listed; check [isListed] too.
  BansNameStatus statusAt(int tipHeight) => BansTimeline.statusOf(
    expireHeight: expireHeight,
    tipHeight: tipHeight,
    listed: isListed,
  );
}

/// `role=manager,action=view_params`.
@immutable
class BansParams {
  const BansParams({
    required this.vaultCid,
    required this.daoVaultCid,
    required this.oracleCid,
    required this.activationHeight,
    this.usdPerBeamText,
  });

  /// The Anon-Vault that `pay` deposits into and claims withdraw from.
  final String vaultCid;

  /// Where registration and renewal fees go.
  final String daoVaultCid;
  final String oracleCid;
  final int activationHeight;

  /// The Oracle2 median, USD per BEAM, **truncated to 5 decimals** by the
  /// shader (`DocAddFloat(..., 5)`, `app.cpp:382-412`). Null when the feed
  /// is stale; registering and renewing then fail with
  /// "price feed unavailable".
  final String? usdPerBeamText;

  bool get priceFeedLive => usdPerBeamText != null;

  /// A price range from the 5-decimal median, for showing a price before
  /// the user commits. The exact amount comes only from the built
  /// transaction (`BansPrepared.summary`). Null when the feed is stale.
  BansPriceEstimate? estimate(BansName name, int periods) {
    final text = usdPerBeamText;
    if (text == null) return null;
    return BansPriceEstimate.fromMedianText(
      usdPerPeriod: name.usdPerPeriod,
      periods: periods,
      medianText: text,
    );
  }
}

/// A BEAM price range for [periods] of a name, from the oracle median as
/// `view_params` prints it.
///
/// The contract charges `floor(usd·10^8·periods / median)` groth
/// (`get_PriceBeams`, `contract.h:85-88`; `Float::Get` rounds down). The
/// printed median is truncated, so the true one lies in
/// `[printed, printed + 10^-digits)`, and the charge in
/// `[minGroth, maxGroth]`.
@immutable
class BansPriceEstimate {
  const BansPriceEstimate({
    required this.usdPerPeriod,
    required this.periods,
    required this.medianText,
    required this.minGroth,
    required this.maxGroth,
  });

  /// Throws [FormatException] for a median that is not a positive decimal.
  factory BansPriceEstimate.fromMedianText({
    required int usdPerPeriod,
    required int periods,
    required String medianText,
  }) {
    final m = RegExp(r'^(\d+)(?:\.(\d+))?$').firstMatch(medianText.trim());
    if (m == null) throw FormatException('median: "$medianText"');
    final frac = m.group(2) ?? '';
    final scale = BigInt.from(10).pow(frac.length);
    final digits = BigInt.parse('${m.group(1)}$frac');
    if (digits == BigInt.zero) throw FormatException('median: "$medianText"');
    final usdGroth = BigInt.from(usdPerPeriod) *
        BigInt.from(periods) *
        BigInt.from(100000000);
    final top = usdGroth * scale;
    return BansPriceEstimate(
      usdPerPeriod: usdPerPeriod,
      periods: periods,
      medianText: medianText,
      maxGroth: top ~/ digits,
      minGroth: top ~/ (digits + BigInt.one),
    );
  }

  final int usdPerPeriod;
  final int periods;
  final String medianText;
  final BigInt minGroth;
  final BigInt maxGroth;

  int get usdTotal => usdPerPeriod * periods;
}

/// A name payment waiting in the Anon-Vault for this wallet
/// (`anon[]` in `role=user,action=view`).
@immutable
class BansIncomingPayment {
  const BansIncomingPayment({
    required this.oneTimeKey,
    required this.assetId,
    required this.amount,
    this.name,
  });

  /// The vault account key; pass it to `receive` to claim this one.
  final String oneTimeKey;
  final int assetId;
  final BigInt amount;

  /// The name the sender paid, decrypted by the shader.
  final String? name;
}

/// `role=user,action=view`: my names, sale proceeds and name payments.
@immutable
class BansInbox {
  const BansInbox({
    required this.domains,
    required this.saleProceeds,
    required this.payments,
  });

  final List<BansDomain> domains;

  /// `raw[]`: funds held under my key, from names I sold.
  final List<BansAmount> saleProceeds;

  /// `anon[]`: payments sent to my names.
  final List<BansIncomingPayment> payments;

  bool get isEmpty => saleProceeds.isEmpty && payments.isEmpty;
}

/// Parses the JSON text an app shader writes into `invoke_contract`'s
/// `output`.
abstract final class BansOutput {
  /// Large integers are kept exact: the shader prints uint64 values that a
  /// JSON decoder would turn into doubles past 2^63, so any bare number of
  /// 16 or more digits is read as a string first.
  static final _bigNumber = RegExp(r'([:\[,]\s*)(-?\d{16,})(?=\s*[,}\]])');

  /// Decodes [output]. Throws [BansShaderRefused] when the shader reported
  /// an error, and [FormatException] when it is not a JSON object.
  static Map<String, Object?> decode(String output) {
    final text = output.trim().isEmpty ? '{}' : output;
    final Object? json;
    try {
      json = jsonDecode(
        text.replaceAllMapped(_bigNumber, (m) => '${m[1]}"${m[2]}"'),
      );
    } on FormatException {
      throw const FormatException('shader output is not JSON');
    }
    if (json is! Map) {
      throw const FormatException('shader output is not a JSON object');
    }
    final map = json.cast<String, Object?>();
    final error = map['error'];
    if (error is String) throw BansShaderRefused(error);
    return map;
  }

  /// `{"res": {"key": ...}}` from `my_key`.
  static String myKey(String output) =>
      _key(_map(decode(output)['res'], 'res'), 'key');

  /// `view_name`: the record, or null for `{}` (never registered).
  static BansDomain? viewName(String output, BansName name) {
    final res = decode(output)['res'];
    if (res == null) return null;
    return _domain(_map(res, 'res'), name.value);
  }

  /// `view_domain`: `{"domains": [...]}`.
  static List<BansDomain> viewDomain(String output) =>
      _domains(decode(output)['domains']);

  /// `view_params`: `{"res": {"vault", "dao-vault", "oracle", "price"?,
  /// "h0"}}`.
  static BansParams viewParams(String output) {
    final res = _map(decode(output)['res'], 'res');
    final price = res['price'];
    if (price != null && price is! String) {
      throw const FormatException('price: expected a string');
    }
    return BansParams(
      vaultCid: _cid(res, 'vault'),
      daoVaultCid: _cid(res, 'dao-vault'),
      oracleCid: _cid(res, 'oracle'),
      activationHeight: _int(res['h0'], 'h0'),
      usdPerBeamText: price as String?,
    );
  }

  /// `role=user,action=view` (`app.cpp:450-484`, `vault_anon/app_impl.h:
  /// 219-253`).
  static BansInbox userView(String output) {
    final res = _map(decode(output)['res'], 'res');
    return BansInbox(
      domains: _domains(res['domains']),
      saleProceeds: List.unmodifiable([
        for (final e in _list(res['raw'] ?? const <Object?>[], 'raw'))
          _amount(_map(e, 'raw[]')),
      ]),
      payments: List.unmodifiable([
        for (final e in _list(res['anon'] ?? const <Object?>[], 'anon'))
          _payment(_map(e, 'anon[]')),
      ]),
    );
  }

  static BansIncomingPayment _payment(Map<String, Object?> m) {
    final a = _amount(m);
    final name = m['domain'];
    return BansIncomingPayment(
      oneTimeKey: _key(m, 'pk'),
      assetId: a.assetId,
      amount: a.amount,
      name: name is String && name.isNotEmpty ? name : null,
    );
  }

  static List<BansDomain> _domains(Object? v) => List.unmodifiable([
    for (final e in _list(v, 'domains')) _namedDomain(_map(e, 'domains[]')),
  ]);

  static BansDomain _namedDomain(Map<String, Object?> m) {
    final name = m['name'];
    if (name is! String) {
      throw const FormatException('domains[].name: expected a string');
    }
    return _domain(m, name);
  }

  static BansDomain _domain(Map<String, Object?> m, String name) {
    final price = m['price'];
    return BansDomain(
      name: name,
      ownerKey: _key(m, 'key'),
      expireHeight: _int(m['hExpire'], 'hExpire'),
      salePrice: price == null ? null : _amount(_map(price, 'price')),
    );
  }

  static BansAmount _amount(Map<String, Object?> m) {
    final aid = _int(m['aid'], 'aid');
    final amount = _big(m['amount'], 'amount');
    return BansAmount(aid, amount);
  }

  static Map<String, Object?> _map(Object? v, String what) {
    if (v is Map) return v.cast<String, Object?>();
    throw FormatException('$what: expected a JSON object');
  }

  static List<Object?> _list(Object? v, String what) {
    if (v is List) return v.cast<Object?>();
    throw FormatException('$what: expected a JSON array');
  }

  static String _key(Map<String, Object?> m, String k) {
    final v = m[k];
    if (v is String && BansKey.isValid(v)) return v;
    throw FormatException('$k: expected a 33-byte key');
  }

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  static String _cid(Map<String, Object?> m, String k) {
    final v = m[k];
    if (v is String && _hex64.hasMatch(v)) return v;
    throw FormatException('$k: expected a contract id');
  }

  static int _int(Object? v, String what) {
    if (v is int && v >= 0) return v;
    if (v is String) {
      final p = int.tryParse(v);
      if (p != null && p >= 0) return p;
    }
    throw FormatException('$what: expected a non-negative integer');
  }

  static BigInt _big(Object? v, String what) {
    if (v is int && v >= 0) return BigInt.from(v);
    if (v is String) {
      final p = BigInt.tryParse(v);
      if (p != null && p >= BigInt.zero) return p;
    }
    throw FormatException('$what: expected a non-negative integer');
  }
}
