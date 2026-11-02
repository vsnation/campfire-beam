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

import 'package:isar_community/isar.dart';

import '../../../../l10n/l10n.dart';
import '../../../../models/balance.dart';
import '../../../../models/isar/models/beam/beam_asset_contract.dart';
import '../../../../models/paymint/fee_object_model.dart';
import '../../../../utilities/amount/amount.dart';
import '../../../../utilities/logger.dart';
import '../../../beam/api/beam_api.dart';
import '../../../beam/assets/beam_asset_catalog.dart';
import '../../../beam/assets/beam_asset_holdings.dart';
import '../../../beam/assets/beam_asset_registry.dart';
import '../../../beam/assets/beam_asset_text.dart';
import '../../../beam/models/beam_address.dart';
import '../../../beam/models/beam_asset_info.dart';
import '../../../beam/rpc/beam_connection_exception.dart';
import '../../../beam/rpc/beam_transport.dart';
import '../../../beam/wallet/beam_balance_mapper.dart';
import '../../../beam/wallet/beam_node_switch_gate.dart';
import '../../../beam/wallet/beam_send_rules.dart';
import '../../../beam/wallet/beam_wallet_errors.dart';
import '../../../crypto_currency/crypto_currency.dart';
import '../../../models/tx_data.dart';
import '../../supporting/beam_wallet_info_extension.dart';
import '../../wallet.dart';
import '../beam_wallet.dart';

/// One Confidential Asset (FOMO, BeamX, CHAD…) of a [BeamWallet], as a
/// Campfire token sub-wallet (mirrors `SolanaTokenWallet`).
///
/// Nothing here talks to the network on its own: BEAM keeps every asset in
/// the same wallet, so
///
/// * the balance is the parent's cached per-asset totals
///   (`WalletInfo.otherData[beamAssetTotals]`, written on every
///   `wallet_status`), mapped like BEAM's own;
/// * the history is the parent's transactions tagged `beamAsset:<id>`;
/// * receiving uses the parent's addresses (assets arrive at the same ones);
/// * sending goes through the parent's core with `tx_send` and `asset_id`.
///   The network fee is BEAM, not the asset: a wallet with FOMO and no BEAM
///   cannot send FOMO, and is told so before anything is built.
class BeamAssetWallet extends Wallet<Beam> {
  BeamAssetWallet(this.parent, BeamAssetContract asset)
    : _asset = asset,
      super(parent.cryptoCurrency);

  /// A sub-wallet sharing [parent]'s database, storage and settings.
  factory BeamAssetWallet.load({
    required BeamWallet parent,
    required BeamAssetContract asset,
  }) {
    final wallet = BeamAssetWallet(parent, asset);
    wallet.prefs = parent.prefs;
    wallet.nodeService = parent.nodeService;
    wallet.secureStorageInterface = parent.secureStorageInterface;
    wallet.mainDB = parent.mainDB;
    return wallet;
  }

  final BeamWallet parent;

  /// The asset's row as last read: the page's at first, then each sync's
  /// ([_syncContract]), so decimals read again since the page opened are the
  /// ones a payment is typed, shown and checked with.
  BeamAssetContract _asset;
  BeamAssetContract get asset => _asset;

  /// The decimals an amount of this asset may be typed and sent with: its
  /// current ones ([BeamAssetCatalog.decimalsOf]: pinned, or read by the core
  /// this run) when its row agrees with them; null otherwise (not read yet, or
  /// the row still holds an older version's 8), when nothing may be sent.
  int? get currentDecimals {
    final d = BeamAssetCatalog.decimalsOf(assetId, null);
    return d != null && d == asset.decimals ? d : null;
  }

  BeamGateLease? _preparedLease;

  /// Tx ids of prepared payments already handed to the core, whatever came
  /// back. A prepared payment carries its tx id from [prepareSend], so a
  /// second [confirmSend] of it is looked up instead of sent again (the
  /// core also refuses a tx id it already has).
  final Set<String> _handedOff = {};

  int get assetId => asset.assetId;
  String get tokenAddress => asset.address;
  String get tokenName => asset.name;
  String get tokenSymbol => asset.symbol;
  int get tokenDecimals => asset.decimals;

  /// The parent's: an asset wallet is a view of it, not a wallet of its own.
  @override
  String get walletId => parent.walletId;

  @override
  int get isarTransactionVersion => 2;

  @override
  FilterOperation? get changeAddressFilterOperation =>
      parent.changeAddressFilterOperation;

  @override
  FilterOperation? get receivingAddressFilterOperation =>
      parent.receivingAddressFilterOperation;

  /// The parent's transactions of this asset (`BeamTxMapper` tags them).
  @override
  FilterOperation? get transactionFilterOperation => FilterCondition.equalTo(
    property: r"contractAddress",
    value: tokenAddress,
  );

  /// This asset's totals from the parent's cache (zero when it holds none).
  BeamCachedAssetTotals get totals =>
      info.beamAssetTotals[assetId] ??
      BeamCachedAssetTotals(
        assetId: assetId,
        available: BigInt.zero,
        receiving: BigInt.zero,
        sending: BigInt.zero,
        maturing: BigInt.zero,
        change: BigInt.zero,
      );

  /// Campfire's [Balance] for this asset (8 decimals).
  Balance get balance => beamAssetBalance(totals, decimals: tokenDecimals);

  @override
  Future<void> init() async {
    await super.init();
    // Name the asset from the chain if it is not cached yet; never fatal.
    unawaited(_syncContract());
  }

  @override
  Future<void> exit() async {
    _preparedLease?.release();
    _preparedLease = null;
    await super.exit();
  }

  Future<void> _syncContract() async {
    try {
      final rows = await BeamAssetRegistry.sync(
        isar: mainDB.isar,
        heldIds: [assetId],
        api: parent.coreApi,
      );
      if (rows[assetId] case final row?) _asset = row;
    } catch (e) {
      Logging.instance.w("BEAM: asset $assetId not refreshed: $e");
    }
  }

  // ===========================================================================
  // Everything is the parent's

  @override
  Future<void> refresh() async {
    await parent.refresh();
    await _syncContract();
  }

  @override
  Future<void> recover({required bool isRescan}) async {
    // The parent rebuilds the whole wallet, assets included.
  }

  @override
  Future<void> updateNode() => parent.updateNode();

  @override
  Future<void> updateTransactions() => parent.updateTransactions();

  @override
  Future<void> updateBalance() => parent.updateBalance();

  @override
  Future<bool> updateUTXOs() async => false;

  @override
  Future<void> updateChainHeight() => parent.updateChainHeight();

  @override
  Future<bool> pingCheck() => parent.pingCheck();

  @override
  Future<void> checkSaveInitialReceivingAddress() =>
      parent.checkSaveInitialReceivingAddress();

  /// BEAM fees, in BEAM.
  @override
  Future<FeeObject> get fees => parent.fees;

  /// The BEAM fee the core would charge to send [amount] of this asset.
  @override
  Future<Amount> estimateFeeFor(Amount amount, BigInt feeRate) async {
    var fee = kBeamDefaultFee;
    final api = parent.coreApi;
    if (api != null && amount.raw > BigInt.zero) {
      try {
        final f = (await api.calcChange(
          amount: amount.raw,
          assetId: assetId,
        )).explicitFee;
        if (f > fee) fee = f;
      } catch (_) {
        // Not enough of the asset, or not open: the default fee.
      }
    }
    return Amount(rawValue: fee, fractionDigits: BeamAssetInfo.beamDecimals);
  }

  // ===========================================================================
  // Sending

  BeamApi _requireApi() =>
      parent.coreApi ??
      (throw parent.coreProblem ??
          BeamWalletException(
            BeamWalletProblem.notOpen,
            BeamWalletMessages.notOpen,
          ));

  String _units(BigInt raw) => BeamAssetText.amount(
    Amount(rawValue: raw, fractionDigits: tokenDecimals),
    asset,
    locale: 'en_US',
  );

  /// Validates and prices a payment of this asset; never broadcasts.
  ///
  /// The returned [TxData] carries the BEAM fee in [TxData.fee] and
  /// `{"assetId": id, "addressType": type, "txId": id}` in
  /// [TxData.otherData]. The tx id is generated here, once per prepared
  /// payment, so however often [confirmSend] is called for it the core sees
  /// one payment. Holds the parent's node switch until [confirmSend] (or ten
  /// minutes), so the private node cannot restart the core under the
  /// confirm screen.
  @override
  Future<TxData> prepareSend({required TxData txData}) async {
    final lease = parent.holdNodeSwitch(
      'asset send',
      maxHold: const Duration(minutes: 10),
    );
    try {
      final recipients = txData.recipients;
      if (recipients == null || recipients.length != 1) {
        throw BeamWalletException(
          BeamWalletProblem.other,
          appL10n.walletSendOneAddress,
        );
      }
      final recipient = recipients.first;
      final address = recipient.address.trim();
      BeamSendRules.checkAddress(address);
      // Typed with other decimals than the asset has now (its row was read
      // again meanwhile): nothing is built; the person reads the amount again.
      final places = currentDecimals;
      if (places == null || recipient.amount.fractionDigits != places) {
        throw BeamWalletException(
          BeamWalletProblem.other,
          appL10n.sendAssetDecimalsUnknown(BeamAssetText.symbolLabel(asset)),
        );
      }
      if (recipient.amount.raw <= BigInt.zero) {
        throw BeamWalletException(
          BeamWalletProblem.invalidAmount,
          appL10n.walletSendAmountAboveZero,
        );
      }
      final api = _requireApi();
      BeamSendRules.checkSynced(parent.syncAssessment);

      final validation = await api.validateAddress(address);
      if (!validation.isValid) {
        throw BeamWalletException(
          BeamWalletProblem.invalidAddress,
          appL10n.walletSendInvalidAddress,
        );
      }
      BeamSendRules.checkAddressType(validation.type);
      final mode = BeamSendMode.forType(validation.type);

      final status = await api.walletStatus();
      final assetAvailable = BeamBalanceMapper.totalsFor(
        status,
        assetId,
      ).available;
      final beamAvailable = BeamBalanceMapper.totalsFor(status, 0).available;

      final amount = recipient.amount.raw;
      if (amount > assetAvailable) {
        throw BeamWalletException(
          BeamWalletProblem.insufficientFunds,
          appL10n.walletSendNotEnoughAsset(
            tokenSymbol,
            _units(amount),
            _units(assetAvailable),
          ),
        );
      }

      BigInt fee;
      try {
        fee = (await api.calcChange(
          amount: amount,
          assetId: assetId,
        )).explicitFee;
      } catch (_) {
        fee = mode.minimumFee;
      }
      if (fee < mode.minimumFee) fee = mode.minimumFee;
      if (beamAvailable < fee) {
        throw BeamWalletException(
          BeamWalletProblem.insufficientFunds,
          BeamAssetText.needBeamForFee(
            tokenSymbol,
            fee,
            beamAvailable,
            locale: 'en_US',
          ),
        );
      }

      final txId = await api.generateTxId();

      _preparedLease?.release();
      _preparedLease = lease;
      return txData.copyWith(
        recipients: [
          recipient.copyWith(
            address: address,
            amount: Amount(rawValue: amount, fractionDigits: tokenDecimals),
          ),
        ],
        fee: Amount(rawValue: fee, fractionDigits: BeamAssetInfo.beamDecimals),
        otherData: jsonEncode({
          'assetId': assetId,
          'addressType': validation.type.wireName,
          'txId': txId,
        }),
      );
    } catch (e) {
      lease.release();
      throw beamWalletExceptionFrom(e);
    }
  }

  /// Sends what [prepareSend] priced (`tx_send` with this asset's id and
  /// the tx id generated there) and returns its tx id.
  ///
  /// A prepared payment reaches `tx_send` at most once: a dropped
  /// connection is looked up (`tx_status`), and a second call for the same
  /// prepared payment, after any outcome but a plain refusal, is only looked
  /// up, never sent. When the lookup cannot tell, it throws
  /// [BeamWalletProblem.sendOutcomeUnknown].
  @override
  Future<TxData> confirmSend({required TxData txData}) async {
    final lease = parent.holdNodeSwitch('confirm asset send');
    try {
      final recipient = txData.recipients?.singleOrNull;
      final fee = txData.fee;
      final txId = preparedTxId(txData);
      if (recipient == null ||
          fee == null ||
          txId == null ||
          _preparedAsset(txData) != assetId) {
        throw BeamWalletException(
          BeamWalletProblem.other,
          appL10n.walletSendNotPrepared,
        );
      }
      final mode = BeamSendMode.forType(
        BeamSendRules.checkAddress(recipient.address),
      );
      if (fee.raw < mode.minimumFee) {
        throw BeamWalletException(
          BeamWalletProblem.other,
          appL10n.walletSendFeeChanged,
        );
      }
      final api = _requireApi();
      if (_handedOff.contains(txId)) {
        // Already with the core: report it, never send it again.
        final sent = await _lookUpSent(
          api,
          txId,
          appL10n.walletSendAlreadyHandedOff,
        );
        return txData.copyWith(txid: sent);
      }
      BeamSendRules.checkSynced(parent.syncAssessment);
      // The decimals the amount was typed with must still be the asset's.
      if (recipient.amount.fractionDigits != currentDecimals) {
        throw BeamWalletException(
          BeamWalletProblem.other,
          appL10n.sendAssetDecimalsUnknown(BeamAssetText.symbolLabel(asset)),
        );
      }

      _handedOff.add(txId);
      String sentId;
      try {
        sentId = await api.txSend(
          address: recipient.address.trim(),
          value: recipient.amount.raw,
          fee: fee.raw,
          assetId: assetId,
          offline: mode.offlineFlag ? true : null,
          txId: txId,
        );
      } on BeamRpcException catch (e) {
        if (e.message.toLowerCase().contains('already exists')) {
          // The core has this tx id: it was handed over before.
          sentId = await _lookUpSent(api, txId);
        } else {
          // A plain refusal: nothing was started, so it may be tried again.
          _handedOff.remove(txId);
          throw BeamWalletException(
            e.message.toLowerCase().contains('funds')
                ? BeamWalletProblem.insufficientFunds
                : BeamWalletProblem.sendRejected,
            appL10n.walletSendNotSent(e.message),
          );
        }
      } on BeamConnectionException {
        sentId = await _lookUpSent(api, txId);
      } on TimeoutException {
        sentId = await _lookUpSent(api, txId);
      }
      unawaited(parent.updateBalance());
      unawaited(parent.updateTransactions());
      return txData.copyWith(txid: sentId);
    } catch (e) {
      throw beamWalletExceptionFrom(e);
    } finally {
      lease.release();
      _preparedLease?.release();
      _preparedLease = null;
    }
  }

  static int? _preparedAsset(TxData txData) {
    final other = txData.otherData;
    if (other == null) return null;
    try {
      final decoded = jsonDecode(other);
      return decoded is Map ? decoded['assetId'] as int? : null;
    } catch (_) {
      return null;
    }
  }

  /// The tx id [prepareSend] generated for this payment.
  static String? preparedTxId(TxData txData) {
    final other = txData.otherData;
    if (other == null) return null;
    try {
      final decoded = jsonDecode(other);
      final id = decoded is Map ? decoded['txId'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  /// The address type [prepareSend] found, for the confirm screen.
  static BeamAddressType? preparedAddressType(TxData txData) {
    final other = txData.otherData;
    if (other == null) return null;
    try {
      final decoded = jsonDecode(other);
      final wire = decoded is Map ? decoded['addressType'] : null;
      return wire is String ? BeamAddressType.fromWire(wire) : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String> _lookUpSent(
    BeamApi api,
    String txId, [
    String? message,
  ]) async {
    try {
      return (await api.txStatus(txId)).txId;
    } catch (_) {
      throw BeamWalletException(
        BeamWalletProblem.sendOutcomeUnknown,
        message ?? appL10n.walletSendOutcomeUnknown,
      );
    }
  }
}
