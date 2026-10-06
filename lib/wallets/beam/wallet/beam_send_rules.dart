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
/// How a payment to one BEAM address type goes out
/// (`v6_api_parse.cpp:542-614`, research/02 §1.4.2).
class BeamSendMode {
  const BeamSendMode._(
    this.type, {
    required this.minimumFee,
    required this.offlineFlag,
    required this.receiverMustBeOnline,
    required this.explanation,
  });

  static final BigInt _regularFee = BigInt.from(100000);

  /// 100,000 + 1,000,000 per shielded output (`getBeamFeeParam`).
  static final BigInt _pushFee = BigInt.from(1100000);

  factory BeamSendMode.forType(BeamAddressType type) => switch (type) {
    BeamAddressType.regular || BeamAddressType.regularNew => BeamSendMode._(
      type,
      minimumFee: _regularFee,
      offlineFlag: false,
      receiverMustBeOnline: true,
      explanation:
          "The receiver's wallet has to come online to accept it; until "
          'then it shows as waiting.',
    ),
    // An offline address would otherwise be paid as a regular online
    // payment to its SBBS part; `offline: true` makes it the non-interactive
    // payment the receiver asked for by sharing an offline address.
    BeamAddressType.offline => BeamSendMode._(
      type,
      minimumFee: _pushFee,
      offlineFlag: true,
      receiverMustBeOnline: false,
      explanation:
          'Arrives even while the receiver\'s wallet is closed. Costs a '
          'higher network fee (0.011 BEAM).',
    ),
    BeamAddressType.maxPrivacy => BeamSendMode._(
      type,
      minimumFee: _pushFee,
      offlineFlag: false,
      receiverMustBeOnline: false,
      explanation:
          'Hidden among many other payments; the receiver can spend it '
          'after a while. Costs a higher network fee (0.011 BEAM).',
    ),
    BeamAddressType.publicOffline => BeamSendMode._(
      type,
      minimumFee: _pushFee,
      offlineFlag: false,
      receiverMustBeOnline: false,
      explanation:
          'A reusable donation address: arrives while the receiver is '
          'offline. Costs a higher network fee (0.011 BEAM).',
    ),
    BeamAddressType.unknown => throw ArgumentError.value(type, 'type'),
  };

  final BeamAddressType type;

  /// The core refuses anything lower ("The minimum fee is N GROTH").
  final BigInt minimumFee;

  /// Pass `"offline": true` to `tx_send`.
  final bool offlineFlag;

  /// Both wallets must be online within ~12 h (regular SBBS payments).
  final bool receiverMustBeOnline;

  /// One plain sentence for the confirm screen.
  final String explanation;
}

abstract final class BeamSendRules {
  static const _notAddress =
      "That isn't a BEAM address. Copy it again from the person you're "
      'paying.';

  /// Returns the address type, or throws when it is not a BEAM address.
  /// Every BEAM address type can be paid; [BeamSendMode] says how.
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

  /// Throws unless [type] (as the core classified the address) can be paid.
  static void checkAddressType(BeamAddressType type) {
    if (type == BeamAddressType.unknown) {
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
}
