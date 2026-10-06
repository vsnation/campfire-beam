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

import '../../api/beam_api.dart';
import '../../models/beam_call_results.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'minter_args.dart';
import 'minter_constants.dart';
import 'minter_models.dart';
import 'token_metadata.dart';

enum MinterErrorCode {
  /// Another Minter transaction is being prepared or awaits confirmation.
  busy,

  /// No token has this asset id in the Minter.
  noSuchToken,

  /// The token belongs to another wallet or contract.
  notOwner,

  /// More than the token's remaining limit.
  aboveLimit,

  /// The contract id answers nothing.
  noSuchContract,

  /// The prepared transaction is not what was asked for.
  unexpectedTransaction,

  alreadyExecuted,

  /// The prepared call was discarded or replaced; prepare it again.
  expired,

  /// Any other shader refusal.
  shaderError,
}

class BeamMinterException implements Exception {
  const BeamMinterException(this.code, this.message);

  final MinterErrorCode code;
  final String message;

  @override
  String toString() => 'BeamMinterException(${code.name}): $message';
}

enum MinterAction { createToken, mint }

/// What a prepared Minter call will do, decoded from the transaction.
@immutable
class MinterSummary {
  const MinterSummary({
    required this.action,
    required this.pays,
    required this.receives,
    required this.networkFee,
    this.metadata,
    this.limit,
    this.issueFee,
    this.assetDeposit,
    this.assetId,
  });

  final MinterAction action;

  /// Leaves the wallet, per asset, network fee excluded. For a new token:
  /// [issueFee] + [assetDeposit] in BEAM (60 BEAM on mainnet).
  final Map<int, BigInt> pays;

  /// Arrives, per asset. For a mint: the new tokens.
  final Map<int, BigInt> receives;

  /// The network fee in BEAM groth: 0.0167 BEAM to create, 0.011 to mint.
  final BigInt networkFee;

  /// [MinterAction.createToken]: the exact metadata stored on chain, the
  /// supply ceiling, and how the BEAM splits.
  final String? metadata;
  final BigInt? limit;

  /// Goes to the BEAM DAO vault. Not refundable.
  final BigInt? issueFee;

  /// Locked with the new asset. The Minter never destroys assets, so it
  /// does not come back either.
  final BigInt? assetDeposit;

  /// [MinterAction.mint]: the token minted.
  final int? assetId;

  BigInt get beamOut => (pays[0] ?? BigInt.zero) + networkFee;

  List<String> get lines => [
    switch (action) {
      MinterAction.createToken => 'Create a new token',
      MinterAction.mint =>
        'Mint ${receives[assetId]} units of asset '
            '$assetId',
    },
    if (issueFee != null) 'Issuance fee to the BEAM DAO: ${_beam(issueFee!)}',
    if (assetDeposit != null)
      'Asset deposit, never returned: ${_beam(assetDeposit!)}',
    'Network fee: ${_beam(networkFee)}',
    'Total BEAM out: ${_beam(beamOut)}',
  ];

  static String _beam(BigInt g) {
    final b = BigInt.from(100000000);
    final f = g
        .remainder(b)
        .toString()
        .padLeft(8, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return f.isEmpty ? '${g ~/ b} BEAM' : '${g ~/ b}.$f BEAM';
  }
}

class BeamPreparedMinterCall {
  BeamPreparedMinterCall._({
    required this.action,
    required this.args,
    required this.rawData,
    required this.invoke,
    required this.summary,
  });

  final MinterAction action;
  final String args;
  final List<int> rawData;
  final BeamInvokeData invoke;
  final MinterSummary summary;

  bool _executed = false;

  bool get isExecuted => _executed;
}

/// BEAM's Minter: create a Confidential Asset with a supply ceiling, list
/// the ones this wallet created, and mint them. Same prepare → verify →
/// [execute] split as the DEX, and one transaction at a time: creating a
/// token costs 60 BEAM, so a double tap must not create two.
class BeamMinterService {
  BeamMinterService(
    this.api,
    this.shader, {
    this.contractId = kMinterContractId,
    this.timeout = const Duration(minutes: 2),
  });

  final BeamApi api;
  final PinnedShader shader;
  final String contractId;
  final Duration timeout;

  Future<void> _tail = Future<void>.value();
  Object? _flow;

  bool get isBusy => _flow != null;

  // ------------------------------------------------------------------ views

  Future<MinterParams> params() async => MinterParams.fromOutput(
    await _view(MinterArgs.viewParams(cid: contractId)),
  );

  /// Tokens this wallet created.
  Future<List<MinterToken>> ownedTokens() async => MinterToken.ownedFromOutput(
    await _view(MinterArgs.viewOwned(cid: contractId)),
  );

  /// One token, or null when the Minter has none with [assetId].
  Future<MinterToken?> token(int assetId) async {
    try {
      final out = await _view(
        MinterArgs.viewToken(assetId: assetId, cid: contractId),
      );
      return MinterToken.fromJson(
        ShaderOutput.map(out['res'], 'res'),
        assetId: assetId,
      );
    } on BeamMinterException catch (e) {
      if (e.code == MinterErrorCode.noSuchToken) return null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------- prepare

  /// Builds a new token described by [metadata] whose supply can never
  /// exceed [limit] (smallest units; see [BeamTokenMetadata.supplyOf]).
  /// Nothing is minted yet: mint with [prepareMint] once it exists.
  ///
  /// The wallet pays the Minter's issuance fee (read from `view_params`,
  /// never assumed) plus the 10 BEAM asset deposit, and the network fee.
  Future<BeamPreparedMinterCall> prepareCreateToken({
    required BeamTokenMetadata metadata,
    required BigInt limit,
  }) => _flowed(() async {
    final p = await params();
    final args = MinterArgs.createToken(
      metadata: metadata,
      limit: limit,
      cid: contractId,
    );
    final text = utf8.encode(metadata.encode());
    final (:raw, :d) = await _build(
      args,
      MinterMethod.createToken,
      kMinterCreateTokenCharge,
      MinterKernelComment.createToken,
      signatures: 0,
    );
    final a = d.entries.single.args;
    final mask = (BigInt.one << 64) - BigInt.one;
    final head = [
      ..._le(0, 4),
      ..._le(limit & mask, 8),
      ..._le(limit >> 64, 8),
    ];
    final tail = [..._le(text.length, 4), ...text];
    _expect(
      a.length == head.length + 33 + tail.length &&
          _eq(a.sublist(0, head.length), head) &&
          a[head.length + 32] <= 1 &&
          _eq(a.sublist(head.length + 33), tail),
      'the token arguments differ from the request',
    );
    final pay = kMinterAssetDeposit + p.issueFee;
    _expectFunds(d, {0: pay}, 'creating the token');
    return BeamPreparedMinterCall._(
      action: MinterAction.createToken,
      args: args,
      rawData: raw,
      invoke: d,
      summary: MinterSummary(
        action: MinterAction.createToken,
        pays: d.pays,
        receives: d.receives,
        networkFee: d.fee,
        metadata: metadata.encode(),
        limit: limit,
        issueFee: p.issueFee,
        assetDeposit: kMinterAssetDeposit,
      ),
    );
  });

  /// Builds a mint of [value] units of [assetId], a token this wallet
  /// created, within its limit.
  Future<BeamPreparedMinterCall> prepareMint({
    required int assetId,
    required BigInt value,
  }) => _flowed(() async {
    final t = await token(assetId);
    if (t == null) {
      throw BeamMinterException(
        MinterErrorCode.noSuchToken,
        'Asset $assetId was not created with the Minter.',
      );
    }
    if (!t.isOwner) {
      throw const BeamMinterException(
        MinterErrorCode.notOwner,
        'Only the wallet that created this token can mint it.',
      );
    }
    if (value > t.mintable) {
      throw BeamMinterException(
        MinterErrorCode.aboveLimit,
        'At most ${t.mintable} more can be minted.',
      );
    }
    final args = MinterArgs.mint(
      assetId: assetId,
      value: value,
      cid: contractId,
    );
    final (:raw, :d) = await _build(
      args,
      MinterMethod.withdraw,
      0,
      MinterKernelComment.mint,
      signatures: 1,
    );
    _expect(
      _eq(d.entries.single.args, [..._le(assetId, 4), ..._le(value, 8)]),
      'the mint arguments differ from the request',
    );
    _expectFunds(d, {assetId: -value}, 'the mint');
    return BeamPreparedMinterCall._(
      action: MinterAction.mint,
      args: args,
      rawData: raw,
      invoke: d,
      summary: MinterSummary(
        action: MinterAction.mint,
        pays: d.pays,
        receives: d.receives,
        networkFee: d.fee,
        assetId: assetId,
      ),
    );
  });

  // ---------------------------------------------------------------- execute

  /// Sends [prepared] and returns the tx id. Sent at most once.
  Future<String> execute(BeamPreparedMinterCall prepared) async {
    if (prepared._executed) {
      throw const BeamMinterException(
        MinterErrorCode.alreadyExecuted,
        'This transaction was already sent.',
      );
    }
    if (!identical(_flow, prepared)) {
      throw const BeamMinterException(
        MinterErrorCode.expired,
        'This confirmation is no longer current. Prepare it again.',
      );
    }
    prepared._executed = true;
    try {
      return await _serial(
        () => api.processInvokeData(prepared.rawData, timeout: timeout),
      );
    } finally {
      if (identical(_flow, prepared)) _flow = null;
    }
  }

  /// Gives up [prepared] without sending it.
  void discard(BeamPreparedMinterCall prepared) {
    if (identical(_flow, prepared) && !prepared._executed) _flow = null;
  }

  // ---------------------------------------------------------------- helpers

  Future<BeamPreparedMinterCall> _flowed(
    Future<BeamPreparedMinterCall> Function() build,
  ) async {
    if (_flow != null) {
      throw const BeamMinterException(
        MinterErrorCode.busy,
        'Another token transaction is in progress. Finish or cancel it '
        'first.',
      );
    }
    final token = Object();
    _flow = token;
    try {
      final p = await build();
      if (!identical(_flow, token)) {
        throw const BeamMinterException(
          MinterErrorCode.expired,
          'This confirmation is no longer current. Prepare it again.',
        );
      }
      _flow = p;
      return p;
    } catch (_) {
      if (identical(_flow, token)) _flow = null;
      rethrow;
    }
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<BeamInvokeResult> _invoke(String args) => _serial(() async {
    final bytes = await shader.load();
    return api.invokeContract(
      createTx: false,
      args: args,
      contractBytes: bytes,
      timeout: timeout,
    );
  });

  Future<Map<String, Object?>> _view(String args) async {
    final r = await _invoke(args);
    final out = _decodeOutput(r.output);
    if (r.rawData != null) {
      throw const BeamMinterException(
        MinterErrorCode.unexpectedTransaction,
        'a read-only Minter call produced a transaction',
      );
    }
    return out;
  }

  Future<({List<int> raw, BeamInvokeData d})> _build(
    String args,
    int method,
    int charge,
    String comment, {
    required int signatures,
  }) async {
    final r = await _invoke(args);
    if (r.output.trim().isNotEmpty) _decodeOutput(r.output);
    final raw = r.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BeamMinterException(
        MinterErrorCode.unexpectedTransaction,
        'the shader built no transaction',
      );
    }
    final BeamInvokeData d;
    try {
      d = BeamInvokeData.decode(raw);
    } on FormatException catch (e) {
      throw BeamMinterException(
        MinterErrorCode.unexpectedTransaction,
        'cannot read the prepared transaction: ${e.message}',
      );
    }
    _expect(d.entries.length == 1, 'expected one contract call');
    final e = d.entries.single;
    _expect(e.contractId == contractId, 'the call is not to the Minter');
    _expect(e.method == method, 'contract method ${e.method}, not $method');
    _expect(!e.isDependent, 'a dependent call');
    _expect(e.charge == charge, 'BVM charge ${e.charge}, expected $charge');
    _expect(e.comment == comment, 'kernel comment "${e.comment}"');
    _expect(e.signatureCount == signatures, '${e.signatureCount} keys');
    return (raw: List<int>.unmodifiable(raw), d: d);
  }

  static Map<String, Object?> _decodeOutput(String output) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BeamMinterException(switch (e.message) {
        'no such token' => MinterErrorCode.noSuchToken,
        'not owner' => MinterErrorCode.notOwner,
        'no such contract' => MinterErrorCode.noSuchContract,
        _ => MinterErrorCode.shaderError,
      }, e.message);
    }
  }

  static void _expectFunds(
    BeamInvokeData d,
    Map<int, BigInt> expected,
    String what,
  ) {
    final s = d.spend;
    _expect(
      s.length == expected.length &&
          expected.entries.every((e) => s[e.key] == e.value),
      '$what moves $s, expected exactly $expected',
    );
  }

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BeamMinterException(MinterErrorCode.unexpectedTransaction, what);
    }
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// [value] (an int or a BigInt) as [n] little-endian bytes.
  static List<int> _le(Object value, int n) {
    var v = value is BigInt ? value : BigInt.from(value as int);
    final out = <int>[];
    for (var i = 0; i < n; i++) {
      out.add((v & BigInt.from(0xff)).toInt());
      v >>= 8;
    }
    return out;
  }
}
