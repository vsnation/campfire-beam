/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../contracts/common/invoke_data.dart';
import 'dapp_wallet_keys.dart';

/// Why a dApp's contract transaction was refused before the user saw it.
enum DappContractRefusal {
  /// The data asks the core to re-run the dApp's app code with wallet
  /// privileges (`AppInvokeData.m_Privilege > 0`).
  privileged,

  /// A call to a contract only Campfire's own screens may use.
  forbiddenContract,

  /// A call signed with a key Campfire's own modules use.
  reservedKey,
}

/// A dApp's contract transaction Campfire refuses to put in front of the
/// user. [message] is plain language, sent to the dApp as the error's
/// `data` and shown to the user.
class DappContractRefused implements Exception {
  const DappContractRefused(this.reason, this.message, {this.contractId});

  final DappContractRefusal reason;
  final String message;

  /// The contract the refused call targets, when there is one.
  final String? contractId;

  @override
  String toString() => 'DappContractRefused(${reason.name}): $message';
}

/// What a dApp may ask the wallet to sign through `process_invoke_data`.
///
/// * **No privilege.** A stored privilege above 0 would re-run the stored
///   app body with the wallet's own keys (`contract_transaction.cpp:648`).
/// * **No names.** BANS and its Anon-Vault move the user's names and the
///   payments sent to them with the user's key; only Campfire's Names
///   screen calls them.
/// * **No wallet keys.** An entry signed with a key Campfire's own modules
///   use (BANS, airdrops) could give away what those keys hold, with no
///   funds leaving the wallet (`DappWalletKeys.reserved`).
///
/// Data the core can rebuild after approval (a dependent entry with a
/// stored app body: BEAM's DEX builds every trade and liquidity change
/// this way) is allowed. The approval shows the worst the core may sign
/// instead, by the core's own rule (`DappRebuildTerms`), and says whose
/// app code would build it.
abstract final class DappContractPolicy {
  /// Throws [DappContractRefused] when a dApp may not submit [data].
  static void check(BeamInvokeData data) {
    final privilege = data.appPrivilege;
    if (privilege != null && privilege != 0) {
      throw const DappContractRefused(
        DappContractRefusal.privileged,
        'Campfire refused this request: it asks the wallet to run the '
        "dApp's own code with extra privileges. Nothing was sent.",
      );
    }
    for (final e in data.entries) {
      final cid = e.contractId;
      if (cid != null && DappWalletKeys.forbiddenContracts.contains(cid)) {
        throw DappContractRefused(
          DappContractRefusal.forbiddenContract,
          'Campfire refused this request: it calls '
          '${dappContractName(cid)}, which holds your names and the '
          'payments sent to them. Use Names in Campfire for that. Nothing '
          'was sent.',
          contractId: cid,
        );
      }
      for (final k in e.signatureKeyHashes) {
        final use = DappWalletKeys.reservedUse(k);
        if (use != null) {
          throw DappContractRefused(
            DappContractRefusal.reservedKey,
            'Campfire refused this request: it signs with the key that '
            'controls $use. Nothing was sent.',
            contractId: cid,
          );
        }
      }
    }
  }
}
