/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:meta/meta.dart';

import '../../api/beam_api.dart';
import '../common/contract_args.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'blackhole_constants.dart';

/// `args` for the BlackHole app shader. Its actions are under
/// `role=manager` (the shader's only role).
abstract final class BurnArgs {
  static final _maxU64 = (BigInt.one << 64) - BigInt.one;
  static final _cid = RegExp(r'^[0-9a-f]{64}$');

  /// `deposit`: lock [amount] of [assetId] in the BlackHole forever.
  static String deposit({
    required int assetId,
    required BigInt amount,
    String cid = kBlackHoleContractId,
  }) {
    _checkCid(cid);
    if (assetId <= 0 || assetId > 0xffffffff) {
      throw ArgumentError.value(
        assetId,
        'assetId',
        'a token id, 1..2^32-1 (burning BEAM itself is refused)',
      );
    }
    if (amount <= BigInt.zero || amount > _maxU64) {
      throw ArgumentError.value(amount, 'amount', 'must be 1..2^64-1');
    }
    return 'role=manager,action=deposit,cid=$cid,aid=$assetId,'
        'amount=$amount';
  }

  /// `view_funds`: everything ever burned, `{"res": [{aid, amount}]}`
  /// (`amount` is the low 64 bits of the 128-bit total).
  static String viewFunds({String cid = kBlackHoleContractId}) {
    _checkCid(cid);
    return 'role=manager,action=view_funds,cid=$cid';
  }

  static void _checkCid(String cid) {
    if (!_cid.hasMatch(cid)) {
      throw ArgumentError.value(cid, 'cid', '64 lowercase hex chars');
    }
  }
}

enum BurnErrorCode {
  /// Another burn is being prepared or awaits confirmation.
  busy,

  /// [BeamBurnService.execute] was called without
  /// `acknowledgedPermanentLoss: true`.
  notAcknowledged,

  /// The prepared transaction is not what was asked for.
  unexpectedTransaction,

  alreadyExecuted,

  /// The prepared call was discarded or replaced; prepare it again.
  expired,

  /// The shader refused.
  shaderError,
}

class BeamBurnException implements Exception {
  const BeamBurnException(this.code, this.message);

  final BurnErrorCode code;
  final String message;

  @override
  String toString() => 'BeamBurnException(${code.name}): $message';
}

/// What a prepared burn destroys, decoded from the transaction.
///
/// This type exists so a burn can never be confirmed through a generic
/// "send" screen: it says, in its own fields, that the tokens are gone
/// for good. [irreversible] is always true.
@immutable
class BeamBurnSummary {
  const BeamBurnSummary({
    required this.assetId,
    required this.amount,
    required this.networkFee,
    required this.contractId,
  });

  /// The token destroyed.
  final int assetId;

  /// How much is destroyed, in the asset's smallest unit.
  final BigInt amount;

  /// In BEAM groth; 0.011 BEAM.
  final BigInt networkFee;

  /// The BlackHole: it has no way to give anything back.
  final String contractId;

  bool get irreversible => true;

  /// The warning a confirmation screen must show, in full.
  String get warning =>
      'This destroys $amount units of asset $assetId forever. Nobody, '
      'including you, can ever get them back.';

  List<String> get lines => [
    'Burn (destroy forever): $amount units of asset $assetId',
    'Network fee: ${_beam(networkFee)}',
    warning,
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

class BeamPreparedBurn {
  BeamPreparedBurn._({
    required this.args,
    required this.rawData,
    required this.invoke,
    required this.summary,
  });

  final String args;
  final List<int> rawData;
  final BeamInvokeData invoke;
  final BeamBurnSummary summary;

  bool _executed = false;

  bool get isExecuted => _executed;
}

/// Burns tokens through BEAM's BlackHole contract.
///
/// [prepareBurn] builds the deposit with `create_tx: false` and checks it is
/// exactly one `Deposit` to the BlackHole that locks exactly the requested
/// amount of the requested token and nothing else. [execute] sends it only
/// when the caller passes `acknowledgedPermanentLoss: true`, which a screen
/// sets only after the user has seen [BeamBurnSummary.warning].
class BeamBurnService {
  BeamBurnService(
    this.api,
    this.shader, {
    this.contractId = kBlackHoleContractId,
    this.timeout = const Duration(minutes: 2),
  });

  final BeamApi api;
  final PinnedShader shader;
  final String contractId;
  final Duration timeout;

  Future<void> _tail = Future<void>.value();
  Object? _flow;

  bool get isBusy => _flow != null;

  /// Everything ever burned, per asset (low 64 bits of each total).
  Future<Map<int, BigInt>> burnedTotals() async {
    final r = await _serial(() async {
      final bytes = await shader.load();
      return api.invokeContract(
        createTx: false,
        args: BurnArgs.viewFunds(cid: contractId),
        contractBytes: bytes,
        timeout: timeout,
      );
    });
    if (r.rawData != null) {
      throw const BeamBurnException(
        BurnErrorCode.unexpectedTransaction,
        'a read-only BlackHole call produced a transaction',
      );
    }
    final out = _decode(r.output);
    return Map.unmodifiable({
      for (final row in ShaderOutput.list(out['res'], 'res'))
        ShaderOutput.uint32(ShaderOutput.map(row, 'res[]'), 'aid'):
            ShaderOutput.amount(ShaderOutput.map(row, 'res[]'), 'amount'),
    });
  }

  /// Builds the burn of [amount] (smallest units) of the token [assetId].
  /// BEAM itself (asset 0) is refused.
  Future<BeamPreparedBurn> prepareBurn({
    required int assetId,
    required BigInt amount,
  }) async {
    if (_flow != null) {
      throw const BeamBurnException(
        BurnErrorCode.busy,
        'Another burn is in progress. Finish or cancel it first.',
      );
    }
    final token = Object();
    _flow = token;
    try {
      final args = BurnArgs.deposit(
        assetId: assetId,
        amount: amount,
        cid: contractId,
      );
      final r = await _serial(() async {
        final bytes = await shader.load();
        return api.invokeContract(
          createTx: false,
          args: args,
          contractBytes: bytes,
          timeout: timeout,
        );
      });
      if (r.output.trim().isNotEmpty) _decode(r.output);
      final raw = r.rawData;
      if (raw == null || raw.isEmpty) {
        throw const BeamBurnException(
          BurnErrorCode.unexpectedTransaction,
          'the shader built no transaction',
        );
      }
      final BeamInvokeData d;
      try {
        d = BeamInvokeData.decode(raw);
      } on FormatException catch (e) {
        throw BeamBurnException(
          BurnErrorCode.unexpectedTransaction,
          'cannot read the prepared transaction: ${e.message}',
        );
      }
      _expect(d.entries.length == 1, 'expected one contract call');
      final e = d.entries.single;
      _expect(e.contractId == contractId, 'the call is not to the BlackHole');
      _expect(e.method == kBlackHoleDepositMethod, 'method ${e.method}');
      _expect(!e.isDependent, 'a dependent call');
      _expect(e.charge == 0, 'BVM charge ${e.charge}');
      _expect(e.comment == kBlackHoleDepositComment, 'kernel comment');
      _expect(e.signatureCount == 0, 'signing keys');
      final expectedArgs = [..._le(BigInt.from(assetId), 4), ..._le(amount, 8)];
      _expect(_eq(e.args, expectedArgs), 'the burn arguments differ');
      final s = d.spend;
      _expect(
        s.length == 1 && s[assetId] == amount,
        'the burn moves $s, expected exactly $amount of asset $assetId',
      );
      final p = BeamPreparedBurn._(
        args: args,
        rawData: List.unmodifiable(raw),
        invoke: d,
        summary: BeamBurnSummary(
          assetId: assetId,
          amount: amount,
          networkFee: d.fee,
          contractId: contractId,
        ),
      );
      if (!identical(_flow, token)) {
        throw const BeamBurnException(
          BurnErrorCode.expired,
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

  /// Sends [prepared] and returns the tx id. Refused unless
  /// [acknowledgedPermanentLoss] is true. Sent at most once.
  Future<String> execute(
    BeamPreparedBurn prepared, {
    required bool acknowledgedPermanentLoss,
  }) async {
    if (!acknowledgedPermanentLoss) {
      throw const BeamBurnException(
        BurnErrorCode.notAcknowledged,
        'Confirm that the tokens will be destroyed forever.',
      );
    }
    if (prepared._executed) {
      throw const BeamBurnException(
        BurnErrorCode.alreadyExecuted,
        'This burn was already sent.',
      );
    }
    if (!identical(_flow, prepared)) {
      throw const BeamBurnException(
        BurnErrorCode.expired,
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
  void discard(BeamPreparedBurn prepared) {
    if (identical(_flow, prepared) && !prepared._executed) _flow = null;
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static Map<String, Object?> _decode(String output) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BeamBurnException(BurnErrorCode.shaderError, e.message);
    }
  }

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BeamBurnException(BurnErrorCode.unexpectedTransaction, what);
    }
  }

  static bool _eq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _le(BigInt value, int n) => BeamArgsWriter.le(value, n);
}
