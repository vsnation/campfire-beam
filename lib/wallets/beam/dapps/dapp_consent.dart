/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../contracts/common/invoke_data.dart';
import 'dapp_errors.dart';
import 'dapp_identity.dart';

/// What a dApp asks the user to approve.
enum DappConsentKind {
  /// `tx_send`: a payment to an address.
  send,

  /// `process_invoke_data`: a contract transaction the dApp prepared with
  /// `invoke_contract`.
  contract,
}

/// An amount of one asset, in its smallest unit. Always positive: the
/// direction is the list it is in.
@immutable
class DappAssetAmount {
  const DappAssetAmount(this.assetId, this.amount);

  final int assetId;
  final BigInt amount;

  @override
  bool operator ==(Object other) =>
      other is DappAssetAmount &&
      other.assetId == assetId &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(assetId, amount);

  @override
  String toString() => '$amount of asset $assetId';
}

/// One contract call inside a contract transaction.
@immutable
class DappContractCall {
  const DappContractCall({
    required this.contractId,
    required this.method,
    required this.shaderComment,
  });

  /// Lowercase hex, or null when the call deploys a new contract.
  final String? contractId;

  /// The contract method number (0 = deploy).
  final int method;

  /// The app shader's description of the call. The app shader comes from
  /// the dApp, so this is dApp text too.
  final String shaderComment;

  bool get deploys => contractId == null;

  @override
  bool operator ==(Object other) =>
      other is DappContractCall &&
      other.contractId == contractId &&
      other.method == method &&
      other.shaderComment == shaderComment;

  @override
  int get hashCode => Object.hash(contractId, method, shaderComment);
}

/// The payment half of a `tx_send` approval.
@immutable
class DappSendDetails {
  const DappSendDetails({
    required this.address,
    required this.addressType,
    required this.isOnline,
    this.isMine = false,
    this.txComment,
  });

  /// The recipient token, exactly as it will be sent.
  final String address;

  /// What the core says the token is (`validate_address`): `regular`,
  /// `regular_new`, `offline`, `max_privacy`, `public_offline`, `unknown`.
  final String addressType;

  /// True for an interactive payment: the recipient's wallet must come
  /// online within about 12 hours (`kDefaultTxResponseTime`), as the Qt
  /// wallet warns (`send_confirm.qml:391`). An offline token without
  /// `offline: true` is paid this way too.
  final bool isOnline;

  /// The recipient is one of this wallet's own addresses.
  final bool isMine;

  /// The comment stored with the transaction. Written by the dApp.
  final String? txComment;
}

/// A request for the user's approval, built by `DappSession` from the exact
/// parameters it will execute.
///
/// Every amount and the fee come from what will execute: for a contract,
/// the `raw_data` bytes decoded by [BeamInvokeData] (the same numbers
/// wallet-api derives, `v6_api_parse.cpp:900-951`), never from the dApp's
/// own description. [dappMessage] is the text the Qt wallet shows as the
/// comment (`confirm_comment`, else the shader's or the payment's
/// comment); it is written by the dApp and must be presented as such
/// ("Message from <dApp> — not verified by your wallet").
///
/// [digest] binds the approval to the request: after approval the session
/// re-reads the parameters it kept, recomputes the digest and the decoded
/// amounts, and refuses to execute if anything differs.
class DappConsentRequest {
  DappConsentRequest({
    required this.kind,
    required this.dapp,
    required this.requestId,
    required List<DappAssetAmount> pays,
    required List<DappAssetAmount> receives,
    required this.fee,
    required this.digest,
    this.dappMessage,
    List<DappContractCall> calls = const [],
    this.send,
  }) : pays = List.unmodifiable(pays),
       receives = List.unmodifiable(receives),
       calls = List.unmodifiable(calls);

  final DappConsentKind kind;

  /// Who is asking.
  final DappIdentity dapp;

  /// The JSON-RPC id the dApp gave the request.
  final Object requestId;

  /// What leaves the wallet, per asset, excluding the fee.
  final List<DappAssetAmount> pays;

  /// What arrives in the wallet, per asset.
  final List<DappAssetAmount> receives;

  /// The network fee in BEAM groth. At least 0.011 BEAM for a contract
  /// call, 0.001 BEAM for a regular payment, 0.011 BEAM for an offline or
  /// max-privacy one.
  final BigInt fee;

  /// Text written by the dApp; may be null.
  final String? dappMessage;

  /// The contract calls, for [DappConsentKind.contract].
  final List<DappContractCall> calls;

  /// The payment, for [DappConsentKind.send].
  final DappSendDetails? send;

  /// SHA-256 of the canonical request that will execute.
  final String digest;

  final _cancelled = Completer<void>();

  /// Completes when the request is withdrawn (the dApp was closed or
  /// reloaded) so the UI can close its sheet. Approving afterwards has no
  /// effect.
  Future<void> get cancelled => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// No funds move; only the fee is paid.
  bool get isFeeOnly => pays.isEmpty && receives.isEmpty;

  /// The contract ids involved, in call order, without repeats.
  List<String> get contractIds => [
    ...{
      for (final c in calls)
        if (c.contractId != null) c.contractId!,
    },
  ];

  /// What the wallet must hold for this to go through: [pays] plus the fee
  /// in BEAM (asset 0).
  Map<int, BigInt> get required {
    final out = <int, BigInt>{};
    for (final a in pays) {
      out[a.assetId] = (out[a.assetId] ?? BigInt.zero) + a.amount;
    }
    out[0] = (out[0] ?? BigInt.zero) + fee;
    return Map.unmodifiable(out);
  }

  /// How much of each asset is missing given [available] balances; empty
  /// when the wallet holds enough. The sheet disables approval and offers a
  /// way to get funds when this is not empty.
  Map<int, BigInt> shortfall(Map<int, BigInt> available) => Map.unmodifiable({
    for (final e in required.entries)
      if ((available[e.key] ?? BigInt.zero) < e.value)
        e.key: e.value - (available[e.key] ?? BigInt.zero),
  });

  @override
  String toString() =>
      'DappConsentRequest(${kind.name} from ${dapp.name}, '
      'pays $pays, receives $receives, fee $fee)';
}

/// Implemented by the UI: shows a [DappConsentRequest] and answers.
///
/// Called for one request at a time. Complete with `true` only when the
/// user explicitly approved; anything else (closing the sheet, a timeout,
/// an error, [DappConsentRequest.cancelled]) is a rejection.
abstract class DappConsentPolicy {
  Future<bool> approve(DappConsentRequest request);
}

/// Puts consent requests in front of the user one at a time.
///
/// Requests from every dApp share one queue (one sheet on screen); each
/// dApp may have at most [maxPendingPerDapp] waiting, beyond which the
/// request is refused with `-32014` (research/04 §7.4.8). Nothing is ever
/// approved without [DappConsentPolicy.approve] completing with `true`,
/// and a request withdrawn before or while it is shown is rejected however
/// the policy answers.
class DappConsentQueue {
  DappConsentQueue(this.policy, {this.maxPendingPerDapp = 5});

  final DappConsentPolicy policy;
  final int maxPendingPerDapp;

  final _waiting = Queue<_Pending>();
  _Pending? _showing;

  /// Requests waiting or on screen.
  int get pendingCount => _waiting.length + (_showing == null ? 0 : 1);

  int _pendingFor(String dappKey) =>
      _waiting.where((p) => p.dappKey == dappKey).length +
      (_showing?.dappKey == dappKey ? 1 : 0);

  /// Completes with true only when the user approved [request]. [owner]
  /// (a session) lets [cancel] withdraw exactly its own requests.
  Future<bool> request(DappConsentRequest request, {Object? owner}) {
    final key = request.dapp.guid;
    if (_pendingFor(key) >= maxPendingPerDapp) {
      return Future.error(
        DappRpcErrors.error(
          DappRpcErrors.throttle,
          'Too many approvals waiting for this dApp',
        ),
      );
    }
    final p = _Pending(key, owner, request);
    _waiting.add(p);
    _pump();
    return p.result.future;
  }

  /// Rejects every request [owner] made, waiting or on screen.
  void cancel(Object owner) => _cancelWhere((p) => identical(p.owner, owner));

  /// Rejects every request from the dApp [dappGuid], waiting or on screen.
  void cancelAll(String dappGuid) => _cancelWhere((p) => p.dappKey == dappGuid);

  void _cancelWhere(bool Function(_Pending) test) {
    final drop = _waiting.where(test).toList();
    for (final p in drop) {
      _waiting.remove(p);
      p.request._cancel();
      p.finish(false);
    }
    final s = _showing;
    if (s != null && test(s)) {
      s.request._cancel(); // its answer will be ignored
    }
  }

  void _pump() {
    if (_showing != null || _waiting.isEmpty) return;
    final p = _showing = _waiting.removeFirst();
    unawaited(_show(p));
  }

  Future<void> _show(_Pending p) async {
    var approved = false;
    try {
      // A withdrawn request frees the queue even if the UI never answers.
      final answer = await Future.any<bool>([
        policy.approve(p.request),
        p.request.cancelled.then((_) => false),
      ]);
      approved = identical(answer, true);
    } catch (_) {
      approved = false;
    }
    if (p.request.isCancelled) approved = false;
    p.finish(approved);
    _showing = null;
    _pump();
  }
}

class _Pending {
  _Pending(this.dappKey, this.owner, this.request);

  final String dappKey;
  final Object? owner;
  final DappConsentRequest request;
  final result = Completer<bool>();

  void finish(bool approved) {
    if (!result.isCompleted) result.complete(approved);
  }
}

/// Summary of a decoded contract transaction, for building and re-checking
/// a [DappConsentRequest].
@immutable
class DappContractSummary {
  const DappContractSummary({
    required this.pays,
    required this.receives,
    required this.fee,
    required this.calls,
    required this.fullComment,
  });

  /// Throws [FormatException] for invoke data it cannot fully read.
  factory DappContractSummary.decode(List<int> rawData) {
    final d = BeamInvokeData.decode(rawData);
    if (d.entries.isEmpty) {
      throw const FormatException('raw_data: no contract calls');
    }
    return DappContractSummary(
      pays: _sorted(d.pays),
      receives: _sorted(d.receives),
      fee: d.fee,
      calls: [
        for (final e in d.entries)
          DappContractCall(
            contractId: e.contractId,
            method: e.method,
            shaderComment: e.comment,
          ),
      ],
      // ContractInvokeDataBase::get_FullComment (bvm/invoke_data.cpp:299).
      fullComment: d.entries.map((e) => e.comment).join('; '),
    );
  }

  final List<DappAssetAmount> pays;
  final List<DappAssetAmount> receives;
  final BigInt fee;
  final List<DappContractCall> calls;
  final String fullComment;

  static List<DappAssetAmount> _sorted(Map<int, BigInt> m) => [
    for (final k in m.keys.toList()..sort()) DappAssetAmount(k, m[k]!),
  ];

  /// True when [request] shows exactly these amounts, fee and calls.
  bool matches(DappConsentRequest request) =>
      _sameList(pays, request.pays) &&
      _sameList(receives, request.receives) &&
      fee == request.fee &&
      _sameList(calls, request.calls);

  static bool _sameList(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
