/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../utilities/amount/amount.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_service.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/models/tx_data.dart';
import 'beam_send_backend.dart';
import 'beam_send_format.dart';

/// Where a BEAM payment goes.
enum BeamSendKind {
  /// A regular `tx_send` to a BEAM address.
  address,

  /// An anonymous name payment: a deposit into the BEAM vault that only the
  /// name's owner can claim (a contract call, not a `tx_send`).
  name,
}

/// One prepared BEAM payment, exactly as the confirmation screen shows it.
///
/// Every number here comes from what the core prepared: the amount and fee
/// of `prepareSend` for an address, and the amount and fee decoded from the
/// built transaction for a name. Nothing is sent until [send], which the
/// confirmation screen calls only after Campfire's PIN / password gate.
class BeamSendReview {
  BeamSendReview._({
    required this.kind,
    required this.coin,
    required this.backend,
    required this.destination,
    required this.asset,
    required this.amount,
    required this.fee,
    required this.comment,
    required this.txData,
    this.addressType,
    this.name,
    this.ownerKey,
    this.nameOnHold = false,
    this.nameListed = false,
    this.prepared,
    this._hold,
  });

  /// A payment to an address, from `prepareSend`'s [txData].
  factory BeamSendReview.address({
    required CryptoCurrency coin,
    required BeamSendBackend backend,
    required TxData txData,
    required BeamAddressType addressType,
    required BeamAssetDisplay asset,
    required String comment,
  }) {
    final r = txData.recipients!.single;
    return BeamSendReview._(
      kind: BeamSendKind.address,
      coin: coin,
      backend: backend,
      destination: r.address,
      addressType: addressType,
      asset: asset,
      amount: r.amount.raw,
      fee: txData.fee!.raw,
      comment: comment,
      txData: txData,
    );
  }

  /// A payment to a name, from `preparePay`'s decoded transaction.
  factory BeamSendReview.name({
    required CryptoCurrency coin,
    required BeamSendBackend backend,
    required BansPrepared prepared,
    required BeamAssetDisplay asset,
    required String comment,
    required bool onHold,
    required bool listed,
    BeamSendHold? hold,
  }) {
    final s = prepared.summary;
    final paid = s.youPay.single;
    final name = s.name!;
    return BeamSendReview._(
      kind: BeamSendKind.name,
      coin: coin,
      backend: backend,
      destination: name.display,
      name: name,
      ownerKey: s.ownerKey,
      nameOnHold: onHold,
      nameListed: listed,
      asset: asset,
      amount: paid.amount,
      fee: s.fee,
      comment: comment,
      prepared: prepared,
      hold: hold,
      txData: TxData(
        recipients: [
          TxRecipient(
            address: name.display,
            amount: Amount(rawValue: paid.amount, fractionDigits: 8),
            isChange: false,
            addressType: AddressType.unknown,
          ),
        ],
        fee: Amount(rawValue: s.fee, fractionDigits: 8),
        note: comment,
      ),
    );
  }

  final BeamSendKind kind;
  final CryptoCurrency coin;
  final BeamSendBackend backend;

  /// The address, or `alice.beam`.
  final String destination;
  final BeamAddressType? addressType;
  final BansName? name;

  /// The key the payment was built for (names only).
  final String? ownerKey;
  final bool nameOnHold;
  final bool nameListed;

  final BeamAssetDisplay asset;

  /// What the recipient gets, in units of [asset].
  final BigInt amount;

  /// The network fee in BEAM groth.
  final BigInt fee;

  /// Local note (and, for an address, the comment the receiver sees).
  final String comment;

  /// Campfire's view of the payment, for its confirmation screen.
  final TxData txData;

  /// The built name payment (names only).
  final BansPrepared? prepared;

  BeamSendHold? _hold;
  bool _sent = false;

  bool get isName => kind == BeamSendKind.name;

  /// `72e3…51ef` (names only).
  String? get ownerFingerprint {
    final k = ownerKey;
    return k == null ? null : BansKey.fingerprint(k);
  }

  /// BEAM leaving the wallet, fee included.
  BigInt get totalBeam => asset.assetId == 0 ? amount + fee : fee;

  /// "1.5 BEAM + 0.011 BEAM fee" style total for the green total row.
  String get totalText => asset.assetId == 0
      ? BeamSendFormat.beam(totalBeam)
      : '${BeamSendFormat.amount(amount, asset)} + '
            '${BeamSendFormat.beam(fee)}';

  /// The confirmation button's label.
  String get sendLabel => isName
      ? 'Send to $destination'
      : 'Send ${BeamSendFormat.amount(amount, asset)}';

  /// Sends the payment and returns its transaction id. Called by the
  /// confirmation screen after the PIN / password gate.
  ///
  /// A payment whose outcome is unknown (the connection dropped while it
  /// was being sent) is never sent a second time from here: [canRetry]
  /// turns false and the user is sent to their history instead.
  Future<String> send() async {
    if (_sent) {
      throw const BeamWalletException(
        BeamWalletProblem.sendOutcomeUnknown,
        'This payment was already handed to the wallet. Check your '
        'transaction history before sending again.',
      );
    }
    beamCheckCanSpend(backend);
    _sent = true;
    final String txId;
    try {
      switch (kind) {
        case BeamSendKind.address:
          txId = await backend.confirmSend(
            txData.copyWith(note: comment, noteOnChain: comment),
          );
        case BeamSendKind.name:
          txId = await backend.executePay(prepared!);
      }
    } catch (e) {
      // Refusals happen before anything is sent; a dropped connection
      // while sending may not have.
      _sent = isOutcomeUnknown(e);
      rethrow;
    }
    dispose();
    if (comment.isNotEmpty) {
      try {
        await backend.saveNote(txId, comment);
      } catch (_) {
        // The payment went out; a lost local note must not hide that.
      }
    }
    backend.refresh();
    return txId;
  }

  /// False once a send may have reached the network.
  bool get canRetry => !_sent;

  /// Whether [error], thrown while sending, leaves it open whether the
  /// payment went out.
  static bool isOutcomeUnknown(Object error) =>
      (error is BeamWalletException &&
          error.problem == BeamWalletProblem.sendOutcomeUnknown) ||
      error is BeamConnectionException ||
      error is TimeoutException;

  /// Lets the private node restart wallet-api again. Safe to call twice.
  void dispose() {
    _hold?.release();
    _hold = null;
  }
}
