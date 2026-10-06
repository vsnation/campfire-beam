/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'bans_constants.dart';
import 'bans_name.dart';

/// Builds the `args` string for every BANS app-shader action.
///
/// Argument names are the ones `app.cpp:21-85` declares. Every value is
/// validated before it is written: names only through [BansName], keys
/// through [BansKey], numbers as non-negative integers in range. Nothing a
/// user types can add a `,` or `=` and smuggle in another argument.
///
/// The shader reads each declared argument into an **uninitialised** local
/// when it is absent (`PAR_READ`, `app.cpp:734`), so the builders always
/// pass every argument an action reads, using the all-zero key where the
/// shader treats zero as "none".
class BansArgs {
  const BansArgs([this.cid = kBansCid]);

  /// The mainnet contract.
  static const mainnet = BansArgs();

  final String cid;

  static const _maxAid = 0xffffffff;
  static final _maxAmount = BigInt.parse('ffffffffffffffff', radix: 16);

  String _build(String role, String action, [Map<String, String>? more]) {
    final b = StringBuffer('role=$role,action=$action,cid=$cid');
    more?.forEach((k, v) => b.write(',$k=$v'));
    return b.toString();
  }

  // ---------------------------------------------------------- read-only

  /// `role=user,action=my_key`: this wallet's BANS key. Every name the
  /// wallet owns is registered to it.
  String myKey() => _build('user', 'my_key');

  /// `role=user,action=view`: my names plus payments waiting to be claimed.
  /// Needs privilege 1 (fails in `get_PkEx` on stock wallet-api).
  String userView() => _build('user', 'view');

  /// `role=manager,action=view_params`: vault, DAO vault and oracle CIDs,
  /// the oracle median (5 decimals) and the activation height.
  String viewParams() => _build('manager', 'view_params');

  /// `role=manager,action=view_name`: one name's record, or `{}`.
  String viewName(BansName name) =>
      _build('manager', 'view_name', {'name': name.value});

  /// `role=manager,action=view_domain`: every name, or with [ownerKey] only
  /// that key's names.
  String viewDomain({String? ownerKey}) => _build('manager', 'view_domain', {
    'pk': ownerKey == null ? BansKey.zero : BansKey.require(ownerKey),
  });

  // ------------------------------------------------------------- writes

  /// `role=user,action=domain_register`: [periods] years, 1 to 50.
  String register(BansName name, int periods) =>
      _build('user', 'domain_register', {
        'name': name.value,
        'nPeriods': '${_periods(periods)}',
      });

  /// `role=user,action=domain_extend`: owner only.
  String extend(BansName name, int periods) => _build('user', 'domain_extend', {
    'name': name.value,
    'nPeriods': '${_periods(periods)}',
  });

  /// `role=user,action=domain_set_owner`: gives the name to [newOwnerKey].
  String setOwner(BansName name, String newOwnerKey) =>
      _build('user', 'domain_set_owner', {
        'name': name.value,
        'pkOwner': BansKey.require(newOwnerKey),
      });

  /// `role=user,action=domain_set_price`: lists the name for [amount] of
  /// [assetId]; an [amount] of zero takes it off sale.
  String setPrice(BansName name, int assetId, BigInt amount) =>
      _build('user', 'domain_set_price', {
        'name': name.value,
        'aid': '${_aid(assetId)}',
        'amount': '${_amount(amount, allowZero: true)}',
      });

  /// `role=user,action=domain_buy`: pays the listed price.
  String buy(BansName name) => _build('user', 'domain_buy', {
    'name': name.value,
  });

  /// `role=manager,action=pay`: an anonymous deposit into the Anon-Vault for
  /// the name's owner. [amount] must be above zero.
  String pay(BansName name, int assetId, BigInt amount) =>
      _build('manager', 'pay', {
        'name': name.value,
        'aid': '${_aid(assetId)}',
        'amount': '${_amount(amount, allowZero: false)}',
      });

  /// `role=user,action=receive`. Without [oneTimeKey] it claims sale
  /// proceeds held under this wallet's key (privilege 0); with one it claims
  /// that anonymous payment (privilege 1). An [amount] of zero claims all.
  String receive({
    required int assetId,
    BigInt? amount,
    String? oneTimeKey,
  }) => _build('user', 'receive', {
    'pkOwner': oneTimeKey == null ? BansKey.zero : BansKey.require(oneTimeKey),
    'aid': '${_aid(assetId)}',
    'amount': '${_amount(amount ?? BigInt.zero, allowZero: true)}',
  });

  /// `role=user,action=receive_list`: claims each entry in full. A null key
  /// means sale proceeds (zero key). At most 998 entries (`app.cpp:684`).
  String receiveList(List<({String? oneTimeKey, int assetId})> entries) {
    if (entries.isEmpty || entries.length > 998) {
      throw ArgumentError.value(entries.length, 'entries', 'must be 1..998');
    }
    final more = <String, String>{};
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final k = e.oneTimeKey;
      more['key_${i + 1}'] = k == null ? BansKey.zero : BansKey.require(k);
      more['aid_${i + 1}'] = '${_aid(e.assetId)}';
    }
    return _build('user', 'receive_list', more);
  }

  /// `role=user,action=receive_all`: up to 30 claims per transaction.
  /// Needs privilege 1.
  String receiveAll() => _build('user', 'receive_all');

  // ------------------------------------------------------------ checks

  static int _periods(int n) {
    if (n < 1 || n > kBansMaxPeriods) {
      throw RangeError.range(n, 1, kBansMaxPeriods, 'periods');
    }
    return n;
  }

  static int _aid(int aid) {
    if (aid < 0 || aid > _maxAid) {
      throw RangeError.range(aid, 0, _maxAid, 'assetId');
    }
    return aid;
  }

  static BigInt _amount(BigInt v, {required bool allowZero}) {
    if (v < BigInt.zero || (!allowZero && v == BigInt.zero)) {
      throw ArgumentError.value(v, 'amount', 'must be positive');
    }
    if (v > _maxAmount) {
      throw ArgumentError.value(v, 'amount', 'above 2^64-1');
    }
    return v;
  }
}
