/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Every failure the BANS module reports on purpose. [message] is plain
/// English that never blames the user and names what to do next, so the UI
/// can show it as is.
sealed class BansException implements Exception {
  const BansException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// What is wrong with a name.
enum BansNameProblem { empty, tooShort, tooLong, invalidCharacter }

/// The text is not a name the contract accepts (`app.cpp:252-272`,
/// `contract.h:41-51`). Checked before anything is sent.
final class BansInvalidName extends BansException {
  const BansInvalidName(this.input, this.problem, super.message);

  final String input;
  final BansNameProblem problem;
}

/// A value that is not a 33-byte BVM public key (66 hex characters, the last
/// byte 00 or 01).
final class BansInvalidKey extends BansException {
  const BansInvalidKey(this.input)
    : super(
        'That is not a name key. A name key is 66 characters of 0-9 and a-f; '
        'copy it again from the receiving wallet.',
      );

  final String input;
}

/// Why the app shader refused a request. The wire strings are the ones
/// `app.cpp` and `vault_anon/app_impl.h` pass to `OnError`.
enum BansRefusal {
  nameInvalid('name is invalid'),
  nameTooShort('name too short'),
  nameTooLong('name too long'),
  nameMissing('name not specified'),
  notRegistered('not registered'),
  ownedByOther('owned by other'),
  alreadyMine('already owned by me'),
  periodTooLong('validity period too long'),
  priceFeedUnavailable('price feed unavailable'),
  domainExpired('domain expired'),
  amountMissing('amount not specified'),
  notForSale('not for sale'),
  noChange('no change'),
  newOwnerMissing('new owner not set'),
  nothingToClaim('nothing to withdraw'),
  noFunds('no funds'),
  insufficientFunds('insufficient funds'),
  paymentNotFound('not detected'),
  contractStateMissing('state not found'),
  invalidAccountKey('invalid account key'),
  unknown('');

  const BansRefusal(this.wire);

  /// The exact text the shader writes into `{"error": ...}`.
  final String wire;

  static BansRefusal fromWire(String text) => values.firstWhere(
    (r) => r != unknown && r.wire == text,
    orElse: () => unknown,
  );
}

/// The app shader refused the request and said why ([refusal], with the
/// shader's own text in [shaderText]).
final class BansShaderRefused extends BansException {
  BansShaderRefused(this.shaderText)
    : refusal = BansRefusal.fromWire(shaderText),
      super(_messageFor(BansRefusal.fromWire(shaderText), shaderText));

  final BansRefusal refusal;
  final String shaderText;

  static String _messageFor(BansRefusal r, String text) => switch (r) {
    BansRefusal.nameInvalid =>
      'Names use only a-z, 0-9, - _ and ~, in lowercase.',
    BansRefusal.nameTooShort => 'Names need at least 3 characters.',
    BansRefusal.nameTooLong => 'Names can be at most 64 characters.',
    BansRefusal.nameMissing => 'Type a name first.',
    BansRefusal.notRegistered =>
      'No one owns this name. Check the spelling, or ask for their address.',
    BansRefusal.ownedByOther =>
      'This name belongs to another wallet, so this wallet cannot change it.',
    BansRefusal.alreadyMine => 'This name is already yours. Renew it instead.',
    BansRefusal.periodTooLong =>
      'A name can be paid for at most 50 years ahead. Choose fewer years.',
    BansRefusal.priceFeedUnavailable =>
      'The BEAM price feed is not updating right now, so names cannot be '
          'priced. Try again in a few minutes.',
    BansRefusal.domainExpired =>
      'This name has expired, so it cannot receive payments. Ask the '
          'recipient for an address instead.',
    BansRefusal.amountMissing => 'Enter an amount above zero.',
    BansRefusal.notForSale => 'This name is not listed for sale.',
    BansRefusal.noChange => 'That is already the price. Nothing to change.',
    BansRefusal.newOwnerMissing => 'Paste the receiving wallet\'s name key.',
    BansRefusal.nothingToClaim => 'There is nothing waiting to be claimed.',
    BansRefusal.noFunds => 'There is nothing waiting to be claimed.',
    BansRefusal.insufficientFunds =>
      'Less is waiting than that amount. Claim the full amount instead.',
    BansRefusal.paymentNotFound =>
      'That payment was not found for this wallet. Refresh and try again.',
    BansRefusal.contractStateMissing ||
    BansRefusal.invalidAccountKey ||
    BansRefusal.unknown =>
      'The name service could not do that ($text). Try again; if it '
          'keeps happening, report it.',
  };
}

/// Claiming name payments (`role=user,action=view` / `receive_all`, or a
/// `receive` with a one-time key) runs the shader at privilege 1, which
/// stock wallet-api refuses: the call fails in `get_PkEx`
/// (research/05 §B.7). Raised instead of the raw core error.
final class BansClaimUnsupported extends BansException {
  const BansClaimUnsupported([this.coreDetail])
    : super(
        'Claiming name payments needs the Campfire BEAM build of wallet-api. '
        'The payments are safe in the BEAM vault and can be claimed once '
        'this wallet runs that build.',
      );

  /// The core's error data, for logs. Contains no secrets.
  final Object? coreDetail;
}

/// The name changed owner between the moment it was shown to the user and
/// the moment the payment was built or about to be signed. Nothing was sent.
final class BansOwnerChanged extends BansException {
  BansOwnerChanged(this.name, this.expectedKey, this.currentKey)
    : super(
        '$name.beam just changed owner. Nothing was sent. Check with the '
        'recipient before sending.',
      );

  final String name;
  final String expectedKey;

  /// Null when the name is no longer registered at all.
  final String? currentKey;
}

/// The transaction the core built does not match what was asked for (wrong
/// contract, method, name, amount or asset). Nothing was sent. This should
/// never happen with the pinned shader; it stops a mismatch from being
/// signed if it does.
final class BansUnexpectedTransaction extends BansException {
  const BansUnexpectedTransaction(this.detail)
    : super(
        'The name service built a different transaction than requested, so '
        'it was not sent. Try again; if it keeps happening, report it.',
      );

  final String detail;
}

/// The bundled app shader is not the pinned build. Nothing is run with it.
final class BansShaderMismatch extends BansException {
  const BansShaderMismatch(this.actualSha256, this.actualSize)
    : super(
        'This copy of Campfire has a damaged name-service component. '
        'Reinstall Campfire from the official download.',
      );

  final String actualSha256;
  final int actualSize;
}
