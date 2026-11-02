/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../l10n/l10n.dart';
import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../utilities/amount/amount.dart';
import '../../../utilities/beam/scan_recognize.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/contracts/bans/bans_exceptions.dart';
import '../../../wallets/beam/contracts/bans/bans_name.dart';
import '../../../wallets/beam/contracts/bans/bans_recipient.dart';
import '../../../wallets/beam/contracts/common/invoke_data.dart';
import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import '../../../wallets/beam/rpc/beam_transport.dart';
import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../../../wallets/beam/wallet/beam_send_rules.dart';
import '../../../wallets/beam/wallet/beam_wallet_errors.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/models/tx_data.dart';
import 'beam_send_backend.dart';
import 'beam_send_format.dart';
import 'beam_send_review.dart';

/// Where a message about the form belongs.
enum BeamSendField { recipient, asset, amount }

/// Why the Send button is off, in words a user can act on.
@immutable
class BeamSendIssue {
  const BeamSendIssue(
    this.field,
    this.message, {
    this.quiet = false,
    this.waitingAssetId,
  });

  final BeamSendField field;

  /// Shown under [field]. Never blames the user and names the fix.
  final String message;

  /// Nothing to say yet (an empty field): the button is off silently.
  final bool quiet;

  /// Set when the money is there but tied up in a transaction that has not
  /// finished: the asset whose coins are busy, which splitting them would
  /// avoid next time.
  final int? waitingAssetId;
}

/// The state of the BEAM send form: one recipient field that takes an
/// address or a name, an asset, an amount, a comment. It decides when the
/// Send button may be pressed and prepares the payment for the
/// confirmation screen. It never sends anything.
class BeamSendModel extends ChangeNotifier {
  BeamSendModel(
    this.backend, {
    Duration nameDebounce = const Duration(milliseconds: 400),
    this.feeDebounce = const Duration(milliseconds: 300),
  }) {
    _resolver = BansRecipientResolver(
      backend.resolveName,
      debounce: nameDebounce,
      paidOwner: backend.paidOwner,
    );
    _nameSub = _resolver.states.listen(_onNameState);
    _sync = backend.syncAssessment;
    _syncSub = backend.syncAssessments.listen(_onSync);
    _balances = backend.spendable();
    _returning = backend.returning();
    unawaited(_loadNames());
  }

  final BeamSendBackend backend;
  final Duration feeDebounce;

  late final BansRecipientResolver _resolver;
  late final StreamSubscription<BansRecipientState?> _nameSub;
  late final StreamSubscription<BeamSyncAssessment> _syncSub;

  late BeamSyncAssessment _sync;
  Map<int, BigInt> _balances = const {};
  Map<int, BigInt> _returning = const {};

  String _recipientText = '';
  BeamRecipientInput _recipient = const BeamRecipientEmpty();

  /// What the field holds when it is plainly not for BEAM: an Ethereum
  /// address or a link of another coin, chain or the web.
  ScanRecognition? _foreign;
  BansRecipientState? _nameState;

  /// A new owner of the name the person chose to pay after seeing it next
  /// to the one this wallet paid before (audit D-1); cleared with the field.
  String? _acceptedOwnerKey;

  int _assetId = 0;
  String _amountText = '';
  BigInt? _amount;
  bool _sendAll = false;
  String comment = '';

  BigInt? _addressFee;
  Timer? _feeTimer;
  int _feeGeneration = 0;

  bool _preparing = false;
  bool _disposed = false;

  // ------------------------------------------------------------- reading

  BeamSyncAssessment get sync => _sync;
  bool get canSpend => _sync.canSpend;

  /// The sync banner's text while sending is off, else null.
  BeamSyncMessage? get syncMessage =>
      _sync.canSpend ? null : BeamSyncMessages.describe(_sync);

  String get recipientText => _recipientText;
  BeamRecipientInput get recipient => _recipient;

  /// The name card's state; null unless the field holds a name.
  BansRecipientState? get nameState =>
      _recipient is BeamRecipientName ? _nameState : null;

  /// Whether the person chose to pay the name's new owner (audit D-1).
  bool get newOwnerAccepted {
    final s = nameState;
    return s is BansRecipientPayable &&
        s.ownerChangedSincePaid &&
        _acceptedOwnerKey == s.ownerKey;
  }

  /// The person saw both owner keys and chose to pay the new one.
  void acceptNewOwner() {
    final s = nameState;
    if (s is! BansRecipientPayable || !s.ownerChangedSincePaid) return;
    _acceptedOwnerKey = s.ownerKey;
    _notify();
  }

  bool get isName => _recipient is BeamRecipientName;
  bool get isAddress => _recipient is BeamRecipientAddress;

  int get assetId => _assetId;
  BeamAssetDisplay get asset => backend.asset(_assetId);
  BeamAssetDisplay assetOf(int id) => backend.asset(id);

  String get amountText => _amountText;
  BigInt? get amount => _amount;
  bool get sendAll => _sendAll;
  bool get preparing => _preparing;

  /// Spendable [id] (BEAM when omitted).
  BigInt available([int? id]) => _balances[id ?? _assetId] ?? BigInt.zero;

  /// [id]'s change still on its way back from an unfinished transaction.
  BigInt returning([int? id]) => _returning[id ?? _assetId] ?? BigInt.zero;

  /// The money is there, just not yet: [back] of [assetId] returns once a
  /// transaction finishes.
  static BeamSendIssue _waiting(String back, int assetId) => BeamSendIssue(
    BeamSendField.amount,
    appL10n.sendFundsReturning(back),
    waitingAssetId: assetId,
  );

  /// BEAM plus every asset the wallet can spend now, BEAM first.
  List<int> get assetChoices {
    final ids = [
      for (final e in _balances.entries)
        if (e.key != 0 && e.value > BigInt.zero) e.key,
    ]..sort();
    return [0, ...ids];
  }

  /// The fee this payment will cost in BEAM groth, as far as is known
  /// before it is built: the core's `calc_change` figure for an address,
  /// never below what the core asks for that address type (0.011 BEAM for
  /// offline, max-privacy and public addresses); the 0.011 BEAM minimum of
  /// a contract call for a name (the exact fee is decoded from the built
  /// transaction on the next screen).
  BigInt get feeEstimate {
    if (isName) return BeamContractFee.minimum;
    final mode = addressMode;
    final floor = mode?.minimumFee ?? kBeamDefaultFee;
    final fee = _addressFee ?? floor;
    return fee < floor ? floor : fee;
  }

  /// Whether [feeEstimate] is a lower bound rather than the figure.
  bool get feeIsMinimum => isName;

  /// How a payment to the address in the field goes out, or null.
  BeamSendMode? get addressMode {
    final r = _recipient;
    if (r is! BeamRecipientAddress) return null;
    try {
      return BeamSendMode.forType(r.type);
    } on ArgumentError {
      return null;
    }
  }

  /// The address type in plain words: (title, what it means for this
  /// payment). Null unless the field holds an address.
  (String, String)? get addressNote {
    final r = _recipient;
    final mode = addressMode;
    if (r is! BeamRecipientAddress || mode == null) return null;
    return switch (r.type) {
      BeamAddressType.regular || BeamAddressType.regularNew => (
        appL10n.sendAddressTypeRegular,
        appL10n.sendAddressRegularNote,
      ),
      BeamAddressType.offline => (
        appL10n.sendAddressTypeOffline,
        mode.explanation,
      ),
      BeamAddressType.maxPrivacy => (
        appL10n.sendAddressTypeMaxPrivacy,
        mode.explanation,
      ),
      BeamAddressType.publicOffline => (
        appL10n.sendAddressTypePublic,
        mode.explanation,
      ),
      BeamAddressType.unknown => null,
    };
  }

  /// Name payments carry no message; address payments share the comment.
  String get commentHint =>
      isName ? appL10n.sendCommentHintName : appL10n.sendCommentHintAddress;

  /// A heads-up that does not block sending.
  String? get warning {
    final a = _amount;
    if (isName &&
        _assetId == 0 &&
        a != null &&
        a > BigInt.zero &&
        a <= BeamContractFee.minimum) {
      return appL10n.sendNameClaimCostWarning(
        BeamSendFormat.beam(BeamContractFee.minimum),
      );
    }
    return null;
  }

  /// The first thing that keeps Send off, or null when it may be pressed.
  BeamSendIssue? get issue {
    final r = recipientIssue ?? assetIssue ?? amountIssue;
    if (r != null) return r;
    if (!_sync.canSpend) {
      final m = BeamSyncMessages.describe(_sync);
      return BeamSendIssue(BeamSendField.amount, m.title, quiet: true);
    }
    return null;
  }

  bool get canReview => issue == null && !_preparing;

  BeamSendIssue? get recipientIssue {
    final r = _recipient;
    switch (r) {
      case BeamRecipientEmpty():
        return BeamSendIssue(
          BeamSendField.recipient,
          appL10n.sendEnterRecipient,
          quiet: true,
        );
      case BeamRecipientInvalid(:final nameProblem):
        final foreign = _foreign;
        if (foreign != null) {
          return BeamSendIssue(
            BeamSendField.recipient,
            describeForeign(foreign),
          );
        }
        return BeamSendIssue(
          BeamSendField.recipient,
          _recipientText.trim().length > 20 || nameProblem == null
              ? appL10n.sendNotAddressOrName
              : BansName.describe(nameProblem),
        );
      case BeamRecipientAddress(:final type):
        try {
          BeamSendRules.checkAddressType(type);
        } on BeamWalletException catch (e) {
          return BeamSendIssue(BeamSendField.recipient, e.message);
        }
        return null;
      case BeamRecipientName():
        return switch (_nameState) {
          final BansRecipientPayable p
              when p.ownerChangedSincePaid && _acceptedOwnerKey != p.ownerKey =>
            BeamSendIssue(
              BeamSendField.recipient,
              appL10n.sendNameNewOwnerSincePaid,
              quiet: true,
            ),
          BansRecipientPayable() => null,
          null || BansRecipientResolving() => BeamSendIssue(
            BeamSendField.recipient,
            appL10n.sendCheckingName,
            quiet: true,
          ),
          BansRecipientNotPayable() => BeamSendIssue(
            BeamSendField.recipient,
            appL10n.sendNameCannotReceive,
            quiet: true,
          ),
          BansRecipientFailed() => BeamSendIssue(
            BeamSendField.recipient,
            appL10n.sendNameCouldNotCheck,
            quiet: true,
          ),
        };
    }
  }

  /// [text] read by the scan rules, when it is plainly meant for something
  /// else than BEAM: an Ethereum address or link, another coin's link, or a
  /// web link. Null for anything BEAM's own checks should judge.
  static ScanRecognition? foreignRecipient(String text) {
    final r = recognizeScan(text);
    return r.kind == ScanKind.eth || r.kind == ScanKind.unsupported ? r : null;
  }

  /// What the field says about a [foreignRecipient].
  static String describeForeign(ScanRecognition r) {
    if (r.kind == ScanKind.eth) return appL10n.sendForeignEthereum;
    return switch (r.reason) {
      ScanUnsupportedReason.link => appL10n.sendForeignWebLink,
      ScanUnsupportedReason.chain => appL10n.sendForeignChain,
      _ => appL10n.sendForeignOther,
    };
  }

  BeamSendIssue? get assetIssue {
    if (_assetId != 0 && isAddress) {
      return BeamSendIssue(
        BeamSendField.asset,
        appL10n.sendAssetToNameOnly(BeamSendFormat.symbol(asset)),
      );
    }
    return null;
  }

  BeamSendIssue? get amountIssue {
    final text = _amountText.trim();
    final a = _amount;
    if (text.isEmpty) {
      return BeamSendIssue(
        BeamSendField.amount,
        appL10n.sendEnterAmount,
        quiet: true,
      );
    }
    if (asset.decimals == null) {
      return BeamSendIssue(
        BeamSendField.amount,
        appL10n.sendAssetDecimalsUnknown(BeamSendFormat.symbol(asset)),
      );
    }
    if (a == null || a <= BigInt.zero) {
      return BeamSendIssue(BeamSendField.amount, appL10n.sendAmountAboveZero);
    }
    final fee = feeEstimate;
    final beam = available(0);
    if (_assetId == 0) {
      // "Send all" to an address: the fee comes out of the amount, as
      // Campfire does for every coin (BeamWallet.prepareSend).
      final feeFromAmount = isAddress && _sendAll && a == beam;
      if (feeFromAmount) {
        if (a <= fee) {
          return BeamSendIssue(
            BeamSendField.amount,
            appL10n.sendBalanceBelowFee(
              BeamSendFormat.beam(beam),
              BeamSendFormat.beam(fee),
            ),
          );
        }
        return null;
      }
      if (a + fee > beam) {
        final back = returning(0);
        if (back > BigInt.zero && a + fee <= beam + back) {
          return _waiting(BeamSendFormat.beam(back), 0);
        }
        final notEnough = feeIsMinimum
            ? appL10n.sendNotEnoughBeamMinFee
            : appL10n.sendNotEnoughBeam;
        return BeamSendIssue(
          BeamSendField.amount,
          notEnough(
            BeamSendFormat.beam(a),
            BeamSendFormat.beam(fee),
            BeamSendFormat.beam(a + fee),
            BeamSendFormat.beam(beam),
          ),
        );
      }
      return null;
    }
    final have = available();
    if (a > have) {
      final back = returning();
      if (back > BigInt.zero && a <= have + back) {
        return _waiting(BeamSendFormat.amount(back, asset), _assetId);
      }
      return BeamSendIssue(
        BeamSendField.amount,
        appL10n.sendNotEnoughAsset(
          BeamSendFormat.symbol(asset),
          BeamSendFormat.amount(have, asset),
        ),
      );
    }
    if (fee > beam) {
      final back = returning(0);
      if (back > BigInt.zero && fee <= beam + back) {
        return _waiting(BeamSendFormat.beam(back), 0);
      }
      final needsBeam = feeIsMinimum
          ? appL10n.sendFeeNeedsBeamMinFee
          : appL10n.sendFeeNeedsBeam;
      return BeamSendIssue(
        BeamSendField.amount,
        needsBeam(
          BeamSendFormat.beam(fee),
          BeamSendFormat.beam(beam),
          BeamSendFormat.symbol(asset),
        ),
      );
    }
    return null;
  }

  // ------------------------------------------------------------- editing

  /// Call on every change of the recipient field.
  void setRecipient(String text) {
    if (text == _recipientText) return;
    _recipientText = text;
    // An Ethereum address or another coin's link is never looked up as a
    // name ("0x5290…" is a valid name, and someone could register it).
    _foreign = foreignRecipient(text);
    _recipient = _foreign != null
        ? const BeamRecipientInvalid(null)
        : BeamRecipientInput.classify(text);
    _nameState = null;
    _acceptedOwnerKey = null;
    _resolver.input(_foreign != null ? '' : text);
    if (_recipient is! BeamRecipientAddress) _addressFee = null;
    _scheduleFee();
    _notify();
  }

  /// Looks the name in the field up again (the card's "Try again", or
  /// after the name changed owner).
  void recheckName() {
    if (_recipient is! BeamRecipientName) return;
    _nameState = null;
    _resolver.input(_recipientText);
    _notify();
  }

  void setAsset(int id) {
    if (id == _assetId) return;
    _assetId = id;
    _sendAll = false;
    // The typed text, read again in this asset's decimals.
    _amount = BeamSendFormat.parse(_amountText, places: asset.decimals);
    _notify();
  }

  /// Call on every change of the amount field ("." decimals in every
  /// language: [BeamSendFormat.parse]).
  void setAmountText(String text) {
    _amountText = text;
    // In the asset's own decimals (its NTH_RATIO); nothing while they are not read.
    _amount = BeamSendFormat.parse(text, places: asset.decimals);
    _sendAll = false;
    _scheduleFee();
    _notify();
  }

  /// Fills in everything that can be sent and returns the text for the
  /// amount field. BEAM to an address: the whole balance, the fee comes out
  /// of it on the next screen. BEAM to a name: the balance less the
  /// minimum fee. Any other asset: all of it (the fee is paid in BEAM).
  String useMax() {
    final have = available();
    BigInt max = have;
    if (_assetId == 0 && !isAddress) {
      max = have - BeamContractFee.minimum;
      if (max < BigInt.zero) max = BigInt.zero;
    }
    final places = asset.decimals;
    _amount = max > BigInt.zero && places != null ? max : null;
    _amountText = max > BigInt.zero
        ? BeamSendFormat.editable(max, places: places)
        : '';
    _sendAll = max > BigInt.zero;
    _scheduleFee();
    _notify();
    return _amountText;
  }

  /// Re-reads balances (the wallet's cache changed).
  void balancesChanged() {
    _balances = backend.spendable();
    _returning = backend.returning();
    unawaited(_loadNames());
    _notify();
  }

  // ------------------------------------------------------------ preparing

  /// Builds the payment for the confirmation screen: `prepareSend` for an
  /// address, `preparePay` (resolve, build, decode, resolve again) for a
  /// name. Throws a message the screen shows as is; never sends.
  Future<BeamSendReview> prepare(CryptoCurrency coin) async {
    if (_preparing) {
      // One payment is built at a time; a second call is never a second
      // payment.
      throw BeamWalletException(
        BeamWalletProblem.other,
        appL10n.sendAlreadyPreparing,
      );
    }
    final blocking = issue;
    if (blocking != null) {
      throw BeamWalletException(BeamWalletProblem.other, blocking.message);
    }
    _preparing = true;
    _notify();
    try {
      final r = _recipient;
      if (r is BeamRecipientAddress) return await _prepareAddress(coin, r);
      return await _prepareName(coin);
    } finally {
      _preparing = false;
      _notify();
    }
  }

  Future<BeamSendReview> _prepareAddress(
    CryptoCurrency coin,
    BeamRecipientAddress r,
  ) async {
    final tx = await backend.prepareSend(
      TxData(
        recipients: [
          TxRecipient(
            address: r.address,
            amount: Amount(rawValue: _amount!, fractionDigits: 8),
            isChange: false,
            addressType: AddressType.mimbleWimble,
          ),
        ],
        note: comment,
        noteOnChain: comment,
        otherData: _assetId == 0 ? null : jsonEncode({'assetId': _assetId}),
      ),
    );
    return BeamSendReview.address(
      coin: coin,
      backend: backend,
      txData: tx,
      addressType: r.type,
      asset: asset,
      comment: comment,
    );
  }

  Future<BeamSendReview> _prepareName(CryptoCurrency coin) async {
    final payable = _nameState! as BansRecipientPayable;
    final hold = backend.holdNodeSwitch(
      'name payment',
      maxHold: const Duration(minutes: 10),
    );
    try {
      var amount = _amount!;
      var prepared = await backend.preparePay(
        payable.name,
        _assetId,
        amount,
        expectedOwnerKey: payable.ownerKey,
        acceptedOwnerKey: _acceptedOwnerKey,
      );
      final beam = available(0);
      var fee = prepared.summary.fee;
      if (_assetId == 0 && amount + fee > beam) {
        if (_sendAll && beam > fee) {
          // "Send all": the fee decoded from the built payment is more than
          // the minimum kept back, so build it once more for what is left.
          amount = beam - fee;
          prepared = await backend.preparePay(
            payable.name,
            _assetId,
            amount,
            expectedOwnerKey: payable.ownerKey,
            acceptedOwnerKey: _acceptedOwnerKey,
          );
          fee = prepared.summary.fee;
        }
        if (amount + fee > beam) {
          throw BeamWalletException(
            BeamWalletProblem.insufficientFunds,
            appL10n.sendNotEnoughBeam(
              BeamSendFormat.beam(amount),
              BeamSendFormat.beam(fee),
              BeamSendFormat.beam(amount + fee),
              BeamSendFormat.beam(beam),
            ),
          );
        }
      } else if (_assetId != 0 && fee > beam) {
        throw BeamWalletException(
          BeamWalletProblem.insufficientFunds,
          appL10n.sendNameFeeNeedsBeam(
            BeamSendFormat.beam(fee),
            BeamSendFormat.beam(beam),
          ),
        );
      }
      final domain = payable.resolution.domain;
      return BeamSendReview.name(
        coin: coin,
        backend: backend,
        prepared: prepared,
        asset: asset,
        comment: comment,
        onHold: payable.onHold,
        listed: domain?.isListed ?? false,
        hold: hold,
      );
    } catch (e) {
      hold.release();
      if (e is BansOwnerChanged || e is BansOwnerChangedSincePaid) {
        recheckName();
      }
      rethrow;
    }
  }

  /// A failure while preparing or sending, as one plain sentence.
  static String describeError(Object e) {
    if (e is BansOwnerChanged) {
      return appL10n.sendNameChangedOwner('${e.name}.beam');
    }
    if (e is BansException) return e.message;
    if (e is BeamWalletException) return e.message;
    if (e is BeamConnectionException || e is TimeoutException) {
      return BeamWalletMessages.notOpen;
    }
    if (e is BeamRpcException) {
      return appL10n.sendWalletRefused(e.message);
    }
    return appL10n.sendSomethingWrong;
  }

  // ------------------------------------------------------------- internals

  void _onNameState(BansRecipientState? s) {
    if (_recipient is! BeamRecipientName) return;
    _nameState = s;
    _notify();
  }

  void _onSync(BeamSyncAssessment a) {
    final was = _sync.canSpend;
    _sync = a;
    final s = _nameState;
    // A name read while the wallet was behind is checked again once it has
    // caught up, so the card never keeps an old owner.
    if (!was && a.canSpend && s is BansRecipientPayable && s.maybeStale) {
      recheckName();
    }
    _notify();
  }

  void _scheduleFee() {
    _feeTimer?.cancel();
    final r = _recipient;
    final a = _amount;
    if (r is! BeamRecipientAddress || a == null || _assetId != 0) return;
    final generation = ++_feeGeneration;
    _feeTimer = Timer(feeDebounce, () async {
      try {
        final fee = await backend.estimateAddressFee(a);
        if (_disposed || generation != _feeGeneration) return;
        _addressFee = fee;
        _notify();
      } catch (_) {
        // The default fee stays; prepareSend gives the real one.
      }
    });
  }

  Future<void> _loadNames() async {
    try {
      await backend.loadAssetNames(_balances.keys);
    } catch (_) {
      return;
    }
    // An asset's decimals may have just been read: the typed text means what they say.
    _amount = BeamSendFormat.parse(_amountText, places: asset.decimals);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _feeTimer?.cancel();
    unawaited(_nameSub.cancel());
    unawaited(_syncSub.cancel());
    unawaited(_resolver.dispose());
    super.dispose();
  }
}
