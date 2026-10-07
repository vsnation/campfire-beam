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

import 'package:meta/meta.dart';

import '../contracts/common/invoke_data.dart';
import '../rpc/beam_connection_exception.dart';
import '../rpc/beam_transport.dart';
import 'dapp_api_version.dart';
import 'dapp_consent.dart';
import 'dapp_contract_policy.dart';
import 'dapp_errors.dart';
import 'dapp_identity.dart';
import 'dapp_method_gate.dart';
import 'dapp_request_sanitizer.dart';
import 'dapp_rpc.dart';
import 'dapp_scope.dart';
import 'dapp_wallet_keys.dart';

/// Something a dApp did that needs no approval in the core but that the
/// user may want to hear about (research/04 §7.4.7).
enum DappActivityKind {
  /// `sign_message`: a signature with a key derived from this wallet. Not
  /// reported any more: `sign_message` now asks the user first.
  signedMessage,

  /// `send_message`: an SBBS message sent from this wallet.
  sentMessage,

  /// Campfire refused a request before it reached the user or the core;
  /// [DappActivity.detail] says why, in plain language.
  refused,
}

class DappActivity {
  const DappActivity(this.kind, this.dapp, {this.detail});

  final DappActivityKind kind;
  final DappIdentity dapp;

  /// For [DappActivityKind.refused]: what was refused and why.
  final String? detail;
}

/// One running dApp page and the wallet.
///
/// Every request string from the page's bridge goes through [handle]:
///
/// 1. parse as JSON-RPC 2.0 ([DappRpcRequest]);
/// 2. the core's app allowlist for the negotiated API version
///    ([DappMethodGate]): unknown `-32601`, blocked `-32020`;
/// 3. parameter rules ([DappRequestSanitizer]): no `contract_file`, no
///    `create_tx: true`, no hidden parameters on payments;
/// 4. for `tx_send`, `process_invoke_data` and `sign_message`, a
///    [DappConsentRequest] built from the exact parameters that will
///    execute, put to the user through [consent]; rejection is `-32021`.
///    Contract data a dApp may not submit ([DappContractPolicy]) and
///    signatures with Campfire's own keys ([DappWalletKeys]) are refused
///    with `-32020` before anyone is asked;
/// 5. scoping: the dApp sees and touches only the transactions and
///    addresses it created ([DappScope]), and gets no balances from
///    `wallet_status`, as the core does for apps;
/// 6. forwarding to wallet-api on [transport], with `invoke_contract` and
///    `process_invoke_data` one at a time (wallet-api refuses a shader call
///    while another is running).
///
/// [transport] must be this session's own wallet-api connection: event
/// subscriptions (`ev_subunsub`) belong to a connection, and the session
/// forwards a page's subscription to it. [handle] never throws; every
/// failure is a JSON-RPC error string for the page.
class DappSession {
  DappSession({
    required this.identity,
    required DappApiVersion apiVersion,
    required this.transport,
    required this.consent,
    DappScopeStore? scopeStore,
    this.limits = const DappRequestLimits(),
    this.onActivity,
    this.onCallBusy,
  }) : _version = apiVersion,
       _gate = DappMethodGate(apiVersion),
       _sanitizer = DappRequestSanitizer(limits),
       _scopeStore = scopeStore ?? InMemoryDappScopeStore() {
    _events = transport.events.listen(
      (e) => _eventTail = _eventTail.then((_) => _forwardEvent(e)),
    );
  }

  final DappIdentity identity;
  final BeamTransport transport;
  final DappConsentQueue consent;
  final DappRequestLimits limits;
  final void Function(DappActivity activity)? onActivity;

  /// +1 when a call to the wallet starts, -1 when it ends: the screen shows
  /// that the dApp is waiting on the wallet (a contract read can take tens
  /// of seconds, with the dApp's own page blank meanwhile).
  final void Function(int delta)? onCallBusy;

  DappApiVersion _version;
  DappMethodGate _gate;
  final DappRequestSanitizer _sanitizer;
  final DappScopeStore _scopeStore;
  Future<DappScope>? _scopeLoad;
  late final StreamSubscription<BeamEvent> _events;
  Future<void> _eventTail = Future.value();
  final _subscribed = <String>{};
  final _notifications = StreamController<String>.broadcast();
  Future<void> _shaderTail = Future.value();

  /// The app shader this dApp sent last. wallet-api keeps one compiled
  /// shader per process and reuses it for any call that omits `contract`,
  /// and that shader may belong to another dApp or to the wallet's own
  /// privileged BANS module. A call without `contract` therefore gets this
  /// dApp's own bytes back, never whatever ran last.
  List<int>? _ownShader;
  int _inFlight = 0;
  bool _closed = false;

  /// Called with the parameters about to execute after an approval, before
  /// they are checked against what was approved. Tests use it to prove a
  /// change made after approval is refused.
  @visibleForTesting
  void Function(Map<String, Object?> params)? debugBeforeExecute;

  static const _stdFee = 100000; // FeeSettings::get_DefaultStd
  static const _shieldedFee = 1100000; // get_DefaultShieldedOut
  static const _unknownTxId = 'Unknown transaction ID.';
  static const _addressMissing = "Provided address doesn't exist.";
  static const _proofFailed =
      'Failed to export payment proof, transaction does not exist.';
  static const _statusKeys = {
    'current_height',
    'current_state_hash',
    'current_state_timestamp',
    'prev_state_hash',
    'is_in_sync',
  };

  /// The API version this page is served.
  DappApiVersion get apiVersion => _version;

  /// Push notifications for the page: `ev_*` envelopes as JSON strings,
  /// only for events the page subscribed to and filtered to its scope.
  Stream<String> get notifications => _notifications.stream;

  bool get isClosed => _closed;

  /// The web-extension handshake (`create_beam_api`): negotiates the
  /// version the page asked for, as at launch. Returns false (the bridge
  /// then posts `rejected`) when this wallet cannot serve it.
  bool handshake({String? apiver, String? apivermin}) {
    final v = DappApiVersion.negotiate(
      wanted: (apiver == null || apiver.isEmpty) ? null : apiver,
      minimum: apivermin,
    );
    if (v == null || _closed) return false;
    _version = v;
    _gate = DappMethodGate(v);
    return true;
  }

  /// Answers one request string from the page.
  Future<String> handle(String text) async {
    Object? id;
    try {
      final req = DappRpcRequest.parse(
        text,
        maxLength: limits.maxRequestLength,
      );
      id = req.id;
      if (_closed) {
        throw DappRpcErrors.error(
          DappRpcErrors.internalError,
          'dApp session closed',
        );
      }
      _gate.check(req.method);
      final params = _sanitizer.sanitize(req);
      if (_inFlight >= limits.maxInFlight) {
        throw DappRpcErrors.error(DappRpcErrors.throttle);
      }
      _inFlight++;
      try {
        return DappRpcResponse.result(req.id, await _dispatch(req, params));
      } finally {
        _inFlight--;
      }
    } on DappRpcFailure catch (f) {
      return DappRpcResponse.error(f.id, f.error);
    } on BeamRpcException catch (e) {
      return DappRpcResponse.error(id, e);
    } on TimeoutException {
      return DappRpcResponse.error(
        id,
        DappRpcErrors.error(
          DappRpcErrors.internalError,
          'The wallet did not answer in time; the outcome is unknown',
        ),
      );
    } on BeamConnectionException {
      return DappRpcResponse.error(
        id,
        DappRpcErrors.error(
          DappRpcErrors.internalError,
          'The wallet connection was lost; the outcome is unknown',
        ),
      );
    } catch (_) {
      return DappRpcResponse.error(
        id,
        DappRpcErrors.error(DappRpcErrors.internalError),
      );
    }
  }

  /// Ends the session: withdraws its pending approvals (they answer
  /// `-32021`) and stops forwarding events. Does not close [transport].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    consent.cancel(this);
    await _events.cancel();
    await _notifications.close();
  }

  Future<Object?> _dispatch(
    DappRpcRequest req,
    Map<String, Object?> params,
  ) async {
    switch (req.method) {
      case 'tx_send':
        return _send(req, params);
      case 'process_invoke_data':
        return _contract(req, params);
      case 'invoke_contract':
        final call = _withOwnShader(params);
        return _oneShaderAtATime(() => _call(req.method, call));
      case 'ev_subunsub':
        final r = await _call(req.method, params);
        for (final e in params.entries) {
          if (e.value == true) {
            _subscribed.add(e.key);
          } else {
            _subscribed.remove(e.key);
          }
        }
        return r;
      case 'wallet_status':
        final r = await _call(req.method, params);
        if (r is! Map) return r;
        return {
          for (final k in _statusKeys)
            if (r.containsKey(k)) k: r[k],
        };
      case 'tx_list':
        return _txList(params);
      case 'tx_status':
      case 'tx_cancel':
      case 'tx_delete':
        await _requireOwnTx(
          params['txId'],
          DappRpcErrors.invalidParams,
          _unknownTxId,
        );
        return _call(req.method, params);
      case 'export_payment_proof':
        await _requireOwnTx(
          params['txId'],
          DappRpcErrors.paymentProofExportError,
          _proofFailed,
        );
        return _call(req.method, params);
      case 'addr_list':
        final r = await _call(req.method, params);
        final own = (await _scope()).addresses;
        if (r is! List) return r;
        return [
          for (final a in r)
            if (a is Map && own.contains(a['address'])) a,
        ];
      case 'edit_address':
      case 'delete_address':
        final address = params['address'];
        if (address is! String ||
            !(await _scope()).addresses.contains(address)) {
          throw DappRpcErrors.error(
            DappRpcErrors.invalidAddress,
            _addressMissing,
          );
        }
        return _call(req.method, params);
      case 'create_address':
        final r = await _call(req.method, params);
        if (r is String && params['use_default_signature'] != true) {
          await _remember(address: r);
        }
        return r;
      case 'tx_asset_info':
        final r = await _call(req.method, params);
        await _rememberTxFrom(r);
        return r;
      case 'sign_message':
        return _signMessage(req, params);
      case 'send_message':
        onActivity?.call(DappActivity(DappActivityKind.sentMessage, identity));
        return _call(req.method, params);
      default:
        return _call(req.method, params);
    }
  }

  // ------------------------------------------------------------- consent

  Future<Object?> _send(DappRpcRequest req, Map<String, Object?> params) async {
    final address = params['address']! as String;
    final check = await _call('validate_address', {'address': address});
    final info = check is Map ? check : const <Object?, Object?>{};
    if (info['is_valid'] != true) {
      throw DappRpcErrors.error(
        DappRpcErrors.invalidAddress,
        'Invalid receiver address or token.',
      );
    }
    final type = info['type'] is String ? info['type']! as String : 'unknown';
    final push =
        type == 'max_privacy' ||
        type == 'public_offline' ||
        (type == 'offline' && params['offline'] == true);
    final minFee = push ? _shieldedFee : _stdFee;
    final fee = (params['fee'] as int?) ?? minFee;
    if (fee < minFee) {
      throw DappRpcErrors.error(
        DappRpcErrors.invalidParams,
        'Failed to initiate the operation. The minimum fee is $minFee GROTH.',
      );
    }
    final from = params['from'];
    if (from is String && !(await _scope()).addresses.contains(from)) {
      throw DappRpcErrors.error(
        DappRpcErrors.invalidAddress,
        'Invalid sender address.',
      );
    }

    // The fee is always explicit in what executes, so the core cannot pick
    // a different one from what the user saw.
    final forwarded = {...params, 'fee': fee};
    final canonical = canonicalJson({'method': 'tx_send', 'params': forwarded});
    final comment = params['comment'] as String?;
    final request = DappConsentRequest(
      kind: DappConsentKind.send,
      dapp: identity,
      requestId: req.id,
      pays: [
        DappAssetAmount(
          (params['asset_id'] as int?) ?? 0,
          BigInt.from(params['value']! as int),
        ),
      ],
      receives: const [],
      fee: BigInt.from(fee),
      digest: sha256Hex(canonical),
      dappMessage: (params['confirm_comment'] as String?) ?? comment,
      send: DappSendDetails(
        address: address,
        addressType: type,
        isOnline: !push,
        isMine: info['is_mine'] == true,
        txComment: comment,
      ),
    );
    final exec = await _approved(request, canonical, (p) {
      return p['address'] == address &&
          BigInt.from(p['value']! as int) == request.pays.single.amount &&
          ((p['asset_id'] as int?) ?? 0) == request.pays.single.assetId &&
          BigInt.from(p['fee']! as int) == request.fee;
    });
    final r = await _call('tx_send', exec);
    await _rememberTxFrom(r);
    return r;
  }

  Future<Object?> _contract(
    DappRpcRequest req,
    Map<String, Object?> params,
  ) async {
    final DappContractSummary summary;
    try {
      summary = DappContractSummary.decode(params['data']! as List<int>);
    } on FormatException catch (e) {
      // A sheet must not summarise what it cannot fully read.
      throw DappRpcErrors.error(
        DappRpcErrors.notAllowed,
        'Campfire cannot show this contract call: ${e.message}',
      );
    } on DappContractRefused catch (e) {
      _refused(e.message);
      throw DappRpcErrors.error(DappRpcErrors.notAllowed, e.message);
    }
    final floor = BeamContractFee.minimum * BigInt.from(summary.calls.length);
    if (summary.fee < floor) {
      throw DappRpcErrors.error(
        DappRpcErrors.notAllowed,
        'contract fee below the core minimum',
      );
    }
    final canonical = canonicalJson({
      'method': 'process_invoke_data',
      'params': params,
    });
    final confirm = params['confirm_comment'] as String?;
    final request = DappConsentRequest(
      kind: DappConsentKind.contract,
      dapp: identity,
      requestId: req.id,
      pays: summary.pays,
      receives: summary.receives,
      fee: summary.fee,
      digest: sha256Hex(canonical),
      dappMessage:
          confirm ?? (summary.fullComment.isEmpty ? null : summary.fullComment),
      calls: summary.calls,
    );
    final exec = await _approved(request, canonical, (p) {
      final data = p['data'];
      if (data is! List) return false;
      try {
        return DappContractSummary.decode(data.cast<int>()).matches(request);
      } catch (_) {
        return false;
      }
    });
    final r = await _oneShaderAtATime(() => _call('process_invoke_data', exec));
    await _rememberTxFrom(r);
    return r;
  }

  Future<Object?> _signMessage(
    DappRpcRequest req,
    Map<String, Object?> params,
  ) async {
    final message = params['message']! as String;
    final key = params['key_material']! as String;
    final keyBytes = [
      for (var i = 0; i < key.length; i += 2)
        int.parse(key.substring(i, i + 2), radix: 16),
    ];
    final use = DappWalletKeys.reservedUseOfMaterial(keyBytes);
    if (use != null) {
      final why =
          'Campfire refused to sign: the key asked for controls $use. '
          'Nothing was signed.';
      _refused(why);
      throw DappRpcErrors.error(DappRpcErrors.notAllowed, why);
    }
    final canonical = canonicalJson({
      'method': 'sign_message',
      'params': params,
    });
    final request = DappConsentRequest(
      kind: DappConsentKind.signMessage,
      dapp: identity,
      requestId: req.id,
      pays: const [],
      receives: const [],
      fee: BigInt.zero,
      digest: sha256Hex(canonical),
      dappMessage: message,
      sign: DappSignDetails(message: message, keyMaterial: key.toLowerCase()),
    );
    final exec = await _approved(request, canonical, (p) {
      return p['message'] == message &&
          p['key_material'] == key &&
          p.length == 2;
    });
    return _call('sign_message', exec);
  }

  void _refused(String why) => onActivity?.call(
    DappActivity(DappActivityKind.refused, identity, detail: why),
  );

  /// Puts [request] to the user. On approval, returns the parameters to
  /// execute, re-read from [canonical] and re-checked: the digest of the
  /// whole request and, through [sameAsShown], the decoded amounts. Any
  /// difference is a rejection.
  Future<Map<String, Object?>> _approved(
    DappConsentRequest request,
    String canonical,
    bool Function(Map<String, Object?> params) sameAsShown,
  ) async {
    final ok = await consent.request(request, owner: this);
    if (!ok || _closed || request.isCancelled) {
      throw DappRpcErrors.error(DappRpcErrors.userRejected);
    }
    final whole = jsonDecode(canonical) as Map<String, Object?>;
    final params = whole['params']! as Map<String, Object?>;
    debugBeforeExecute?.call(params);
    var unchanged = false;
    try {
      unchanged =
          sha256Hex(canonicalJson(whole)) == request.digest &&
          sameAsShown(params);
    } catch (_) {
      unchanged = false;
    }
    if (!unchanged) {
      throw DappRpcErrors.error(
        DappRpcErrors.userRejected,
        'The request changed after it was approved',
      );
    }
    return params;
  }

  // ------------------------------------------------------------- scoping

  Future<DappScope> _scope() => _scopeLoad ??= _scopeStore.load();

  Future<void> _remember({String? txId, String? address}) async {
    final s = await _scope();
    var changed = false;
    if (txId != null) changed |= s.txIds.add(txId.toLowerCase());
    if (address != null) changed |= s.addresses.add(address);
    if (changed) await _scopeStore.save(s);
  }

  Future<void> _rememberTxFrom(Object? result) async {
    if (result is! Map) return;
    final id = result['txId'] ?? result['txid'];
    if (id is String && id.isNotEmpty) await _remember(txId: id);
  }

  Future<void> _requireOwnTx(Object? txId, int code, String message) async {
    if (txId is! String ||
        !(await _scope()).txIds.contains(txId.toLowerCase())) {
      throw DappRpcErrors.error(code, message);
    }
  }

  Future<Object?> _txList(Map<String, Object?> params) async {
    final count = params['count'];
    final skip = params['skip'];
    if ((count != null && (count is! int || count < 0)) ||
        (skip != null && (skip is! int || skip < 0))) {
      throw DappRpcErrors.error(DappRpcErrors.invalidParams);
    }
    final own = (await _scope()).txIds;
    if (own.isEmpty) return const <Object?>[];
    final r = await _call('tx_list', {
      for (final e in params.entries)
        if (e.key != 'count' && e.key != 'skip') e.key: e.value,
    });
    if (r is! List) return r;
    final mine = [
      for (final t in r)
        if (t is Map && own.contains('${t['txId']}'.toLowerCase())) t,
    ];
    final from = (skip as int?) ?? 0;
    final n = (count as int?) ?? 0;
    final rest = from >= mine.length ? const <Object?>[] : mine.sublist(from);
    return n == 0 || n >= rest.length ? rest : rest.sublist(0, n);
  }

  Future<void> _forwardEvent(BeamEvent e) async {
    if (_closed || !_subscribed.contains(e.name)) return;
    Map<String, Object?> data = e.data;
    if (e.name == 'ev_txs_changed' || e.name == 'ev_addrs_changed') {
      final key = e.name == 'ev_txs_changed' ? 'txs' : 'addrs';
      final scope = await _scope();
      final items = data[key];
      final kept = [
        if (items is List)
          for (final i in items)
            if (i is Map &&
                (key == 'txs'
                    ? scope.txIds.contains('${i['txId']}'.toLowerCase())
                    : scope.addresses.contains(i['address'])))
              i,
      ];
      // As the core: a reset always goes out, other changes only when
      // something of the dApp's changed (v6_1_api_notify.cpp:375-381).
      if (kept.isEmpty && data['change_str'] != 'reset') return;
      data = {...data, key: kept};
    } else if (e.name == 'ev_utxos_changed' || e.name == 'ev_assets_changed') {
      return; // never for apps
    }
    if (!_closed) _notifications.add(DappRpcResponse.event(e.name, data));
  }

  // ----------------------------------------------------------- forwarding

  Map<String, Object?> _withOwnShader(Map<String, Object?> params) {
    final contract = params['contract'];
    if (contract is List<int>) {
      _ownShader = contract;
      return params;
    }
    final own = _ownShader;
    if (own == null) {
      throw DappRpcErrors.error(
        DappRpcErrors.invalidParams,
        'Send the app shader with the first contract call',
      );
    }
    return Map.unmodifiable({...params, 'contract': own});
  }

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    onCallBusy?.call(1);
    try {
      return await transport.call(method, params);
    } finally {
      onCallBusy?.call(-1);
    }
  }

  Future<T> _oneShaderAtATime<T>(Future<T> Function() op) {
    final result = _shaderTail.then((_) => op());
    _shaderTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
