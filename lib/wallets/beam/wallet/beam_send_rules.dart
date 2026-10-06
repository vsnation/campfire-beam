/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../address/beam_address_format.dart';
import '../models/beam_address.dart';
import '../sync/beam_sync_messages.dart';
import '../sync/beam_sync_state.dart';
import 'beam_wallet_errors.dart';

/// The core's minimum fee for a regular transfer: 0.001 BEAM
/// (`getBeamFeeParam`, `v6_api_parse.cpp:371-389`). Used only when the core
/// cannot be asked (`calc_change`); the confirm screen shows the core's own
/// figure.
final BigInt kBeamDefaultFee = BigInt.from(100000);

/// The send checks that need no core: address shape and type, amount, fee
/// against the available balance, sync state. Every failure is a
/// [BeamWalletException] whose message a user can act on.
abstract final class BeamSendRules {
  static const _notAddress =
      "That isn't a BEAM address. Copy it again from the person you're "
      'paying.';

  /// Returns the address type, or throws when it cannot be sent to (yet).
  ///
  /// Regular SBBS addresses (`regular` hex, `regular_new` base58) are
  /// accepted. Offline, max-privacy and public offline addresses need the
  /// shielded pool (task B-ADDR-1) and are refused with a clear message.
  static BeamAddressType checkAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      throw const BeamWalletException(
        BeamWalletProblem.invalidAddress,
        'Enter the address you want to pay.',
      );
    }
    final type = BeamAddressFormat.typeOf(trimmed) ?? BeamAddressType.unknown;
    checkAddressType(type);
    return type;
  }

  /// Throws unless [type] (as the core classified the address) can be paid
  /// now.
  static void checkAddressType(BeamAddressType type) {
    switch (type) {
      case BeamAddressType.regular:
      case BeamAddressType.regularNew:
        return;
      case BeamAddressType.offline:
      case BeamAddressType.maxPrivacy:
      case BeamAddressType.publicOffline:
        throw BeamWalletException(
          BeamWalletProblem.unsupportedAddressType,
          'This is a ${_typeName(type)} address. Campfire can only pay '
          'regular BEAM addresses for now. Ask for a regular address.',
        );
      case BeamAddressType.unknown:
        throw const BeamWalletException(
          BeamWalletProblem.invalidAddress,
          _notAddress,
        );
    }
  }

  /// Throws unless sending is allowed by the honest sync verdict.
  static void checkSynced(BeamSyncAssessment assessment) {
    if (assessment.canSpend) return;
    final m = BeamSyncMessages.describe(assessment);
    throw BeamWalletException(
      BeamWalletProblem.notSynced,
      m.detail == null ? m.title : '${m.title}. ${m.detail}',
    );
  }

  /// Checks [amount] and [fee] against [available] (all in groth). Returns
  /// the amount to send: when [amount] is the whole balance, the fee comes
  /// out of it (Campfire's "send all"), as Epic Cash does.
  static BigInt checkAmount({
    required BigInt amount,
    required BigInt fee,
    required BigInt available,
    int fractionDigits = 8,
  }) {
    if (amount <= BigInt.zero) {
      throw const BeamWalletException(
        BeamWalletProblem.invalidAmount,
        'Enter an amount above zero.',
      );
    }
    var send = amount;
    if (amount == available && amount > fee) send = amount - fee;
    if (send + fee > available) {
      throw BeamWalletException(
        BeamWalletProblem.insufficientFunds,
        'Not enough BEAM. Sending ${formatBeam(send, fractionDigits)} plus '
        'the ${formatBeam(fee, fractionDigits)} fee needs '
        '${formatBeam(send + fee, fractionDigits)}, and '
        '${formatBeam(available, fractionDigits)} is available.',
      );
    }
    if (!(send + fee).isValidInt) {
      throw const BeamWalletException(
        BeamWalletProblem.invalidAmount,
        'That amount is too large.',
      );
    }
    return send;
  }

  /// "0.005 BEAM": trailing zeros dropped, at least one decimal place.
  static String formatBeam(BigInt groth, [int fractionDigits = 8]) {
    final unit = BigInt.from(10).pow(fractionDigits);
    final negative = groth.isNegative;
    final abs = groth.abs();
    final whole = abs ~/ unit;
    var frac = (abs % unit).toString().padLeft(fractionDigits, '0');
    frac = frac.replaceFirst(RegExp(r'0+$'), '');
    if (frac.isEmpty) frac = '0';
    return '${negative ? '-' : ''}$whole.$frac BEAM';
  }

  static String _typeName(BeamAddressType t) => switch (t) {
    BeamAddressType.offline => 'offline',
    BeamAddressType.maxPrivacy => 'max-privacy',
    BeamAddressType.publicOffline => 'public offline',
    _ => t.wireName,
  };
}
