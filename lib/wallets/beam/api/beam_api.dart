/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../models/beam_address.dart';
import '../models/beam_asset_info.dart';
import '../models/beam_call_results.dart';
import '../models/beam_json.dart';
import '../models/beam_transaction.dart';
import '../models/beam_utxo.dart';
import '../models/beam_version.dart';
import '../models/beam_wallet_status.dart';
import '../rpc/beam_transport.dart';

/// Typed wallet-api 7.4 calls.
///
/// Method and param names follow `wallet/api/v6_0` … `v7_4` at tag
/// `beam-7.5.14493`. Amounts go in and come out as [BigInt] in the asset's
/// smallest unit; asset ids are plain ints (0 = BEAM).
///
/// Errors: [BeamRpcException] when the core refuses, `TimeoutException` /
/// `BeamConnectionException` from the transport, [FormatException] when a
/// response does not have the documented shape, [ArgumentError] for a
/// request this class can tell is invalid before sending it.
class BeamApi {
  const BeamApi(this.transport);

  final BeamTransport transport;

  /// One shader lane per transport, shared by every [BeamApi] over it.
  static final _shaderLanes = Expando<_SerialLane>('beam shader calls');

  _SerialLane get _shaderLane => _shaderLanes[transport] ??= _SerialLane();

  Future<Object?> _call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) => transport.call(method, params, timeout);

  Future<Map<String, Object?>> _callMap(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async => BeamJson.map(await _call(method, params, timeout), method);

  // ---------------------------------------------------------------- status

  Future<BeamVersion> getVersion() async =>
      BeamVersion.fromJson(await _callMap('get_version'));

  /// [nzTotals]: only list assets with a non-zero balance.
  Future<BeamWalletStatus> walletStatus({bool? nzTotals}) async =>
      BeamWalletStatus.fromJson(
        await _callMap('wallet_status', {'nz_totals': ?nzTotals}),
      );

  /// Subscribes to (or, with `false`, unsubscribes from) push events on this
  /// connection. Listen to `transport.events` first: the core sends a snapshot
  /// of each newly subscribed stream straight after answering.
  Future<bool> subscribeEvents({
    bool syncProgress = true,
    bool systemState = true,
    bool assetsChanged = true,
    bool addrsChanged = true,
    bool utxosChanged = true,
    bool txsChanged = true,
    bool connectionChanged = true,
  }) async {
    final r = await _call('ev_subunsub', {
      'ev_sync_progress': syncProgress,
      'ev_system_state': systemState,
      'ev_assets_changed': assetsChanged,
      'ev_addrs_changed': addrsChanged,
      'ev_utxos_changed': utxosChanged,
      'ev_txs_changed': txsChanged,
      'ev_connection_changed': connectionChanged,
    });
    return r == true;
  }

  /// Returns the confirmed count.
  Future<int> setConfirmationsCount(int count) async {
    if (count < 0) throw ArgumentError.value(count, 'count');
    final r = await _callMap('set_confirmations_count', {'count': count});
    return BeamJson.integer(r, 'count');
  }

  Future<int> getConfirmationsCount() async =>
      BeamJson.integer(await _callMap('get_confirmations_count'), 'count');

  // ---------------------------------------------------------- transactions

  /// [status] and [assetId] and [height] become `filter` entries.
  Future<List<BeamTransaction>> txList({
    int? count,
    int? skip,
    int? assetId,
    BeamTxStatus? status,
    int? height,
  }) async {
    if (count != null && count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be positive');
    }
    if (status == BeamTxStatus.unknown) {
      throw ArgumentError.value(status, 'status');
    }
    final filter = <String, Object?>{
      'status': ?status?.code,
      'asset_id': ?assetId,
      'height': ?height,
    };
    final r = await _call('tx_list', {
      'count': ?count,
      'skip': ?skip,
      if (filter.isNotEmpty) 'filter': filter,
    });
    return List.unmodifiable(
      BeamJson.mapList(r, 'tx_list').map(BeamTransaction.fromJson),
    );
  }

  Future<BeamTransaction> txStatus(String txId) async =>
      BeamTransaction.fromJson(await _callMap('tx_status', {'txId': txId}));

  /// A 32-hex tx id to pass to [txSend] so a retry after a lost connection
  /// cannot pay twice.
  Future<String> generateTxId() async {
    final r = await _call('generate_tx_id');
    if (r is String) return r;
    throw const FormatException('generate_tx_id: expected a string');
  }

  /// Sends [value] of [assetId] to [address] and returns the tx id.
  ///
  /// [offline]: for an `offline` token, `true` makes a non-interactive
  /// shielded payment; otherwise the core sends a regular online tx to the
  /// token's SBBS part. [fee] defaults to the core's minimum (0.001 BEAM
  /// regular, 0.011 BEAM shielded); a lower fee is refused with -32602.
  Future<String> txSend({
    required String address,
    required BigInt value,
    BigInt? fee,
    int? assetId,
    String? comment,
    bool? offline,
    String? txId,
  }) async {
    final r = await _callMap('tx_send', {
      'address': address,
      'value': _amount(value, 'value'),
      'fee': ?(fee == null ? null : _amount(fee, 'fee')),
      'asset_id': ?assetId,
      'comment': ?comment,
      'offline': ?offline,
      'txId': ?txId,
    });
    return BeamJson.string(r, 'txId');
  }

  /// Splits coins of [assetId] into new coins of the given [coins] amounts.
  Future<String> txSplit({
    required List<BigInt> coins,
    BigInt? fee,
    int? assetId,
    String? txId,
  }) async {
    if (coins.isEmpty) throw ArgumentError.value(coins, 'coins', 'empty');
    final r = await _callMap('tx_split', {
      'coins': [for (final c in coins) _amount(c, 'coins[]')],
      'fee': ?(fee == null ? null : _amount(fee, 'fee')),
      'asset_id': ?assetId,
      'txId': ?txId,
    });
    return BeamJson.string(r, 'txId');
  }

  /// Fails with -32001 unless the tx can still be cancelled.
  Future<bool> txCancel(String txId) async =>
      await _call('tx_cancel', {'txId': txId}) == true;

  /// Deletes a finished tx from history. Fails while it is still active.
  Future<bool> txDelete(String txId) async =>
      await _call('tx_delete', {'txId': txId}) == true;

  /// Change and the exact fee for sending [amount]. [isPushTransaction]:
  /// the payment goes to a shielded address.
  Future<BeamCalcChange> calcChange({
    required BigInt amount,
    int? assetId,
    BigInt? fee,
    bool? isPushTransaction,
  }) async => BeamCalcChange.fromJson(
    await _callMap('calc_change', {
      'amount': _amount(amount, 'amount'),
      'asset_id': ?assetId,
      'fee': ?(fee == null ? null : _amount(fee, 'fee')),
      'is_push_transaction': ?isPushTransaction,
    }),
  );

  /// Hex proof; needs a `regular_new` (identity-carrying) receiver.
  Future<String> exportPaymentProof(String txId) async => BeamJson.string(
    await _callMap('export_payment_proof', {'txId': txId}),
    'payment_proof',
  );

  Future<BeamPaymentProofInfo> verifyPaymentProof(String paymentProof) async =>
      BeamPaymentProofInfo.fromJson(
        await _callMap('verify_payment_proof', {
          'payment_proof': paymentProof,
        }),
      );

  // ------------------------------------------------------------- addresses

  /// Returns the new token. `offline`, `max_privacy` and `public_offline`
  /// fail with -32005 unless the wallet can detect shielded coins (own node
  /// or body requests). [offlinePayments]: vouchers in an `offline` token.
  Future<String> createAddress({
    BeamAddressType type = BeamAddressType.regular,
    BeamAddressExpiration? expiration,
    String? comment,
    int? offlinePayments,
  }) async {
    if (type == BeamAddressType.unknown) {
      throw ArgumentError.value(type, 'type');
    }
    if (offlinePayments != null && offlinePayments <= 0) {
      throw ArgumentError.value(offlinePayments, 'offlinePayments');
    }
    final r = await _call('create_address', {
      'type': type.wireName,
      'expiration': ?expiration?.wireName,
      'comment': ?comment,
      'offline_payments': ?offlinePayments,
    });
    if (r is String) return r;
    throw const FormatException('create_address: expected a string');
  }

  /// [own]: only this wallet's addresses; otherwise contacts as well.
  Future<List<BeamAddress>> addrList({required bool own}) async {
    final r = await _call('addr_list', {'own': own});
    return List.unmodifiable(
      BeamJson.mapList(r, 'addr_list').map(BeamAddress.fromJson),
    );
  }

  /// Validating an `offline` token stores its vouchers in the wallet.
  Future<BeamAddressValidation> validateAddress(String address) async =>
      BeamAddressValidation.fromJson(
        await _callMap('validate_address', {'address': address}),
      );

  Future<void> editAddress(
    String address, {
    String? comment,
    BeamAddressExpiration? expiration,
  }) async {
    if (comment == null && expiration == null) {
      throw ArgumentError('editAddress needs a comment or an expiration');
    }
    await _call('edit_address', {
      'address': address,
      'comment': ?comment,
      'expiration': ?expiration?.wireName,
    });
  }

  Future<void> deleteAddress(String address) async {
    await _call('delete_address', {'address': address});
  }

  // ------------------------------------------------------- coins and assets

  /// [sortField] is a coin field name (`amount`, `maturity`, …).
  Future<List<BeamUtxo>> getUtxo({
    int? assetId,
    int? count,
    int? skip,
    String? sortField,
    bool? sortDescending,
  }) async {
    if (count != null && count <= 0) {
      throw ArgumentError.value(count, 'count', 'must be positive');
    }
    final sort = <String, Object?>{
      'field': ?sortField,
      'direction': ?(sortDescending == null
          ? null
          : (sortDescending ? 'desc' : 'asc')),
    };
    final r = await _call('get_utxo', {
      'count': ?count,
      'skip': ?skip,
      if (assetId != null) 'filter': {'asset_id': assetId},
      if (sort.isNotEmpty) 'sort': sort,
    });
    return List.unmodifiable(
      BeamJson.mapList(r, 'get_utxo').map(BeamUtxo.fromJson),
    );
  }

  /// Every asset the wallet knows. [refresh] asks the node first, which can
  /// take a while for hundreds of assets.
  Future<List<BeamAssetInfo>> assetsList({
    bool refresh = false,
    int? height,
    Duration? timeout,
  }) async {
    final r = await _callMap('assets_list', {
      'refresh': refresh,
      'height': ?height,
    }, timeout);
    return List.unmodifiable(
      BeamJson.mapList(r['assets'], 'assets').map(BeamAssetInfo.fromJson),
    );
  }

  /// Asset 0 (BEAM) has no asset info; the core refuses it.
  Future<BeamAssetInfo> getAssetInfo(int assetId) async {
    if (assetId <= 0) {
      throw ArgumentError.value(assetId, 'assetId', 'must be a CA id (> 0)');
    }
    return BeamAssetInfo.fromJson(
      await _callMap('get_asset_info', {'asset_id': assetId}),
    );
  }

  // ------------------------------------------------------------- contracts

  /// Runs an app shader. [contractBytes] is the shader itself, sent as a
  /// JSON byte array (the core also accepts `contract_file`, a path it reads
  /// from disk; this API never sends one).
  ///
  /// [createTx] must be stated: `true` lets the core build and broadcast the
  /// transaction itself; `false` returns `raw_data` for
  /// [processInvokeData], after a confirmation step. A contract call costs at
  /// least 0.011 BEAM, computed by the core.
  ///
  /// Calls on one [transport] run one at a time, in the order they were
  /// made, whichever [BeamApi] (and so whichever service) makes them. The
  /// core runs one app shader at a time: API 6.0 refuses an overlapping
  /// call ("Previous shader call is still in progress",
  /// `v6_api_handle.cpp:836`), and 6.1+ queues it in a `priority_queue`
  /// keyed on priority alone (`shaders_manager.h:99-110`), so calls of equal
  /// priority could run in any order. [timeout] counts from when this call
  /// is sent, not from when it was queued behind others.
  Future<BeamInvokeResult> invokeContract({
    required bool createTx,
    String? args,
    List<int>? contractBytes,
    int? priority,
    int? unique,
    Duration? timeout,
  }) async {
    if (contractBytes != null && contractBytes.isEmpty) {
      throw ArgumentError.value(contractBytes, 'contractBytes', 'empty');
    }
    final params = <String, Object?>{
      'contract': ?contractBytes,
      'args': ?args,
      'create_tx': createTx,
      'priority': ?priority,
      'unique': ?unique,
    };
    final r = await _shaderLane.run(
      () => _callMap('invoke_contract', params, timeout),
    );
    return BeamInvokeResult.fromJson(r);
  }

  /// Broadcasts the transaction [invokeContract] prepared with
  /// `createTx: false`. Returns the tx id.
  ///
  /// Not queued behind [invokeContract]: the core starts the transaction
  /// directly (`ShadersManager::ProcessTxData`, no shader runs, and the
  /// handler has no in-progress check, `v6_api_handle.cpp:909-912`), so a
  /// confirmed send never waits for a background view to finish.
  Future<String> processInvokeData(
    List<int> data, {
    String? confirmComment,
    Duration? timeout,
  }) async {
    if (data.isEmpty) throw ArgumentError.value(data, 'data', 'empty');
    final r = await _callMap('process_invoke_data', {
      'data': data,
      'confirm_comment': ?confirmComment,
    }, timeout);
    return BeamJson.string(r, 'txid');
  }

  // ---------------------------------------------------------------- helpers

  /// wallet-api reads amounts as unsigned 64-bit JSON numbers. A Dart int
  /// holds up to 2^63-1, which covers every real single-tx amount.
  static int _amount(BigInt v, String name) {
    if (v <= BigInt.zero) {
      throw ArgumentError.value(v, name, 'must be positive');
    }
    if (!v.isValidInt) {
      throw ArgumentError.value(v, name, 'above 2^63-1');
    }
    return v.toInt();
  }
}

/// Runs tasks one after another, in the order they were queued. A task that
/// fails does not hold up the ones queued behind it.
class _SerialLane {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
