/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dapp_api_version.dart';
import 'dapp_errors.dart';
import 'dapp_method_table.dart';

/// The core's per-method "allowed for apps" rule, enforced in Campfire.
///
/// wallet-api runs with no app identity, so it applies none of the app
/// restrictions itself (research/04 §7.1). This gate puts back the first
/// of them, exactly as `AppsApi::AnyThread_callWalletApiChecked` does
/// (`wallet/client/apps_api/apps_api.h:185-260`):
///
/// * a method the negotiated API version does not declare is answered
///   `-32601` (as the core's parser does, `api_base.cpp:142-146`);
/// * a declared method flagged APPS_BLOCKED is answered `-32020`.
///
/// The table is generated from the core source ([dappCoreMethodTable]).
/// What an allowed method may then do is narrowed further by
/// `DappRequestSanitizer` and `DappSession`.
class DappMethodGate {
  DappMethodGate(this.version)
    : _table = dappCoreMethodTable[version.methodTable.label]!;

  final DappApiVersion version;
  final Map<String, bool> _table;

  /// The two methods that move funds; each needs the user's approval.
  static const consentMethods = {'tx_send', 'process_invoke_data'};

  /// True when a dApp may call [method] in this version.
  bool allows(String method) => _table[method] ?? false;

  /// True when this version declares [method] at all.
  bool declares(String method) => _table.containsKey(method);

  /// Throws the core's error for a method a dApp may not call.
  void check(String method) {
    final allowed = _table[method];
    if (allowed == null) {
      throw DappRpcErrors.error(DappRpcErrors.methodNotFound, method);
    }
    if (!allowed) throw DappRpcErrors.error(DappRpcErrors.notAllowed);
  }

  /// Every method a dApp may call in this version, sorted.
  List<String> get allowedMethods => [
    for (final e in _table.entries)
      if (e.value) e.key,
  ]..sort();
}
