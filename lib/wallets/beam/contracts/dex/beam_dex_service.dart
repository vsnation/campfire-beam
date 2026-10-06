/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../api/beam_api.dart';
import '../../models/beam_call_results.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'beam_dex_quotes.dart';
import 'beam_pool.dart';
import 'dex_args.dart';
import 'dex_constants.dart';

/// Why the DEX refused, so a screen can name the next step.
enum BeamDexErrorCode {
  /// No pool trades this pair (at this fee tier). Offer to create one.
  noPool,

  /// The pool exists but holds no liquidity. Offer to add some.
  poolEmpty,

  /// `pool_create` for a pool that exists.
  poolExists,

  /// The amount is too small to receive anything.
  amountTooSmall,

  /// An exact-receive amount the pool cannot fill.
  amountTooLarge,

  /// Both deposit amounts given, and their ratio is off the pool's.
  ratioMismatch,

  /// The prepared transaction is not what was asked for. Never shown to
  /// the user as confirmable.
  unexpectedTransaction,

  /// [BeamDexService.execute] was already called for this prepared call.
  alreadyExecuted,

  /// Any other shader refusal; [BeamDexException.message] has its text.
  shaderError,
}

class BeamDexException implements Exception {
  const BeamDexException(this.code, this.message);

  final BeamDexErrorCode code;
  final String message;

  @override
  String toString() => 'BeamDexException(${code.name}): $message';
}

enum BeamDexAction { swap, addLiquidity, withdraw, createPool }

/// A DEX transaction built by the wallet core but not yet sent.
///
/// [pays], [receives] and [fee] are decoded from [rawData], the exact bytes
/// [BeamDexService.execute] hands to `process_invoke_data`; they are what
/// the confirmation screen shows. [quote] is the earlier prediction, for
/// noticing that the price moved in between.
class BeamPreparedDexCall {
  BeamPreparedDexCall._({
    required this.action,
    required this.args,
    required this.rawData,
    required this.invoke,
    this.quote,
  });

  final BeamDexAction action;

  /// The shader args the call was built from.
  final String args;
  final List<int> rawData;
  final BeamInvokeData invoke;

  /// The prediction this call was prepared from, when there was one
  /// ([BeamSwapQuote], [BeamLiquidityQuote] or [BeamWithdrawQuote]).
  final Object? quote;

  bool _executed = false;

  bool get isExecuted => _executed;

  /// Per asset, what leaves the wallet (excluding the network fee).
  Map<int, BigInt> get pays => invoke.pays;

  /// Per asset, what arrives.
  Map<int, BigInt> get receives => invoke.receives;

  /// Network fee in BEAM groth.
  BigInt get fee => invoke.fee;

  String get contractId => invoke.entries.single.contractId!;
}

/// The BEAM AMM: pools, quotes, and swap / liquidity / pool-creation
/// transactions, over [BeamApi.invokeContract] with the pinned AMM shader.
///
/// Money-moving work is split in two:
///
/// 1. `prepare…` builds the transaction with `create_tx: false`. Nothing
///    is sent. The result's `raw_data` is decoded and checked against the
///    request (contract, method, assets, amounts); anything unexpected is
///    refused with [BeamDexErrorCode.unexpectedTransaction].
/// 2. [execute] sends it with `process_invoke_data`, after the UI has shown
///    the decoded amounts and fee and the user has passed Campfire's PIN
///    gate.
///
/// wallet-api runs one shader at a time and fails an overlapping
/// `invoke_contract` ("Previous shader call is still in progress"), so this
/// service queues its own calls. Other services on the same wallet-api need
/// the same discipline.
class BeamDexService {
  BeamDexService(
    this.api,
    this.shader, {
    this.contractId = kDexContractId,
    this.timeout = const Duration(minutes: 2),
  });

  final BeamApi api;

  /// The AMM app shader, pinned (see [ammAppShader]).
  final PinnedShader shader;
  final String contractId;

  /// Per `invoke_contract` / `process_invoke_data` call.
  final Duration timeout;

  Future<void> _tail = Future<void>.value();

  // ------------------------------------------------------------------ views

  /// Every pool; empty ones only when [includeEmpty].
  Future<List<BeamPool>> listPools({bool includeEmpty = false}) async {
    final out = await _view(DexArgs.poolsView(cid: contractId));
    final pools = [
      for (final row in ShaderOutput.list(out['res'], 'res'))
        BeamPool.fromJson(ShaderOutput.map(row, 'res[]')),
    ];
    return List.unmodifiable(
      includeEmpty ? pools : pools.where((p) => !p.isEmpty),
    );
  }

  /// One pool, fresh from the chain.
  Future<BeamPool> getPool({
    required int aidA,
    required int aidB,
    required BeamPoolKind kind,
  }) async {
    final out = await _view(
      DexArgs.poolView(aidA: aidA, aidB: aidB, kind: kind, cid: contractId),
    );
    return BeamPool.fromPoolView(
      ShaderOutput.map(out['res'], 'res'),
      aidA: aidA,
      aidB: aidB,
      kind: kind,
    );
  }

  // ----------------------------------------------------------------- quotes

  /// The best predicted swap of [payAmount] of [payAsset] into
  /// [receiveAsset]: every non-empty pool of the pair (or only [kind]) is
  /// asked, and the one that delivers the most wins.
  ///
  /// [pools] reuses a recent [listPools] result.
  Future<BeamSwapQuote> quote({
    required int payAsset,
    required BigInt payAmount,
    required int receiveAsset,
    BeamPoolKind? kind,
    List<BeamPool>? pools,
  }) async {
    final all = pools ?? await listPools(includeEmpty: true);
    final pair = all
        .where(
          (p) =>
              p.pairs(payAsset, receiveAsset) &&
              (kind == null || p.kind == kind),
        )
        .toList();
    if (pair.isEmpty) {
      throw BeamDexException(
        BeamDexErrorCode.noPool,
        'no pool for $payAsset/$receiveAsset',
      );
    }
    final live = pair.where((p) => !p.isEmpty).toList();
    if (live.isEmpty) {
      throw BeamDexException(
        BeamDexErrorCode.poolEmpty,
        'the $payAsset/$receiveAsset pool has no liquidity',
      );
    }
    BeamSwapQuote? best;
    for (final p in live) {
      final q = await quotePool(
        pool: p,
        payAsset: payAsset,
        payAmount: payAmount,
      );
      if (best == null ||
          q.receive > best.receive ||
          (q.receive == best.receive && q.pay < best.pay)) {
        best = q;
      }
    }
    if (best!.receivesNothing) {
      throw const BeamDexException(
        BeamDexErrorCode.amountTooSmall,
        'the amount is too small to receive anything',
      );
    }
    return best;
  }

  /// A predicted swap of at most [payAmount] in one [pool].
  Future<BeamSwapQuote> quotePool({
    required BeamPool pool,
    required int payAsset,
    required BigInt payAmount,
  }) async {
    final receiveAsset = pool.otherAsset(payAsset);
    final out = await _view(
      DexArgs.trade(
        payAsset: payAsset,
        receiveAsset: receiveAsset,
        kind: pool.kind,
        payAmount: payAmount,
        predictOnly: true,
        cid: contractId,
      ),
    );
    final q = BeamSwapQuote.fromPrediction(
      ShaderOutput.map(out['res'], 'res'),
      pool: pool,
      payAsset: payAsset,
      receiveAsset: receiveAsset,
    );
    if (q.pay > payAmount) {
      throw BeamDexException(
        BeamDexErrorCode.unexpectedTransaction,
        'predicted pay ${q.pay} exceeds the requested $payAmount',
      );
    }
    return q;
  }

  /// A predicted swap that receives exactly [receiveAmount] from [pool].
  Future<BeamSwapQuote> quoteReceive({
    required BeamPool pool,
    required int receiveAsset,
    required BigInt receiveAmount,
  }) async {
    final payAsset = pool.otherAsset(receiveAsset);
    final out = await _view(
      DexArgs.trade(
        payAsset: payAsset,
        receiveAsset: receiveAsset,
        kind: pool.kind,
        receiveAmount: receiveAmount,
        predictOnly: true,
        cid: contractId,
      ),
    );
    final q = BeamSwapQuote.fromPrediction(
      ShaderOutput.map(out['res'], 'res'),
      pool: pool,
      payAsset: payAsset,
      receiveAsset: receiveAsset,
    );
    // The shader quietly caps val1_buy at the reserve minus one.
    if (q.receive != receiveAmount) {
      throw BeamDexException(
        BeamDexErrorCode.amountTooLarge,
        'the pool can deliver at most ${q.receive}',
      );
    }
    return q;
  }

  /// Predicted deposit into [pool]. Give one side and the shader computes
  /// the other from the reserves; an empty pool needs both.
  Future<BeamLiquidityQuote> quoteAddLiquidity({
    required BeamPool pool,
    BigInt? amount1,
    BigInt? amount2,
  }) async {
    final out = await _view(
      DexArgs.addLiquidity(
        aid1: pool.aid1,
        aid2: pool.aid2,
        kind: pool.kind,
        amount1: amount1,
        amount2: amount2,
        predictOnly: true,
        cid: contractId,
      ),
    );
    return BeamLiquidityQuote.fromPrediction(
      ShaderOutput.map(out['res'], 'res'),
      pool: pool,
    );
  }

  /// Predicted return for burning [lpAmount] LP tokens of [pool].
  Future<BeamWithdrawQuote> quoteWithdraw({
    required BeamPool pool,
    required BigInt lpAmount,
  }) async {
    final out = await _view(
      DexArgs.withdraw(
        aid1: pool.aid1,
        aid2: pool.aid2,
        kind: pool.kind,
        ctl: lpAmount,
        predictOnly: true,
        cid: contractId,
      ),
    );
    return BeamWithdrawQuote.fromPrediction(
      ShaderOutput.map(out['res'], 'res'),
      pool: pool,
    );
  }

  // ---------------------------------------------------------------- prepare

  /// Builds the swap [quote] describes, paying at most [BeamSwapQuote.pay].
  /// The pool is re-read by the core, so the decoded receive can be lower
  /// than the quote's if the price moved.
  Future<BeamPreparedDexCall> prepareSwap(BeamSwapQuote quote) async {
    final args = DexArgs.trade(
      payAsset: quote.payAsset,
      receiveAsset: quote.receiveAsset,
      kind: quote.kind,
      payAmount: quote.pay,
      predictOnly: false,
      cid: contractId,
    );
    return _prepare(BeamDexAction.swap, args, quote, (d) {
      final pay = d.pays[quote.payAsset];
      final receive = d.receives[quote.receiveAsset];
      _expect(
        d.pays.length == 1 && pay != null && pay <= quote.pay,
        'swap pays ${d.pays}, expected at most ${quote.pay} of '
        'asset ${quote.payAsset}',
      );
      _expect(
        d.receives.length == 1 && receive != null,
        'swap receives ${d.receives}, expected asset ${quote.receiveAsset}',
      );
      return DexMethod.trade;
    });
  }

  /// Builds a deposit into [pool]. Amounts as in [quoteAddLiquidity].
  Future<BeamPreparedDexCall> prepareAddLiquidity({
    required BeamPool pool,
    BigInt? amount1,
    BigInt? amount2,
    BeamLiquidityQuote? quote,
  }) async {
    final args = DexArgs.addLiquidity(
      aid1: pool.aid1,
      aid2: pool.aid2,
      kind: pool.kind,
      amount1: amount1,
      amount2: amount2,
      predictOnly: false,
      cid: contractId,
    );
    return _prepare(BeamDexAction.addLiquidity, args, quote, (d) {
      final p1 = d.pays[pool.aid1];
      final p2 = d.pays[pool.aid2];
      _expect(
        d.pays.length == 2 && p1 != null && p2 != null,
        'deposit pays ${d.pays}, expected assets ${pool.aid1} and '
        '${pool.aid2}',
      );
      _expect(
        (amount1 == null || p1 == amount1) &&
            (amount2 == null || p2 == amount2),
        'deposit pays ${d.pays}, asked for $amount1 / $amount2',
      );
      _expect(
        d.receives.length == 1 && d.receives[pool.lpToken] != null,
        'deposit receives ${d.receives}, expected LP token '
        '${pool.lpToken}',
      );
      return DexMethod.addLiquidity;
    });
  }

  /// Builds a withdrawal burning [lpAmount] LP tokens of [pool].
  Future<BeamPreparedDexCall> prepareWithdraw({
    required BeamPool pool,
    required BigInt lpAmount,
    BeamWithdrawQuote? quote,
  }) async {
    final args = DexArgs.withdraw(
      aid1: pool.aid1,
      aid2: pool.aid2,
      kind: pool.kind,
      ctl: lpAmount,
      predictOnly: false,
      cid: contractId,
    );
    return _prepare(BeamDexAction.withdraw, args, quote, (d) {
      _expect(
        d.pays.length == 1 && d.pays[pool.lpToken] == lpAmount,
        'withdraw pays ${d.pays}, expected $lpAmount of LP token '
        '${pool.lpToken}',
      );
      _expect(
        d.receives.isNotEmpty &&
            d.receives.keys.every((a) => a == pool.aid1 || a == pool.aid2),
        'withdraw receives ${d.receives}, expected assets ${pool.aid1} '
        'and ${pool.aid2}',
      );
      return DexMethod.withdraw;
    });
  }

  /// Builds a new, empty pool. It locks [kDexPoolCreateDeposit] (10 BEAM,
  /// returned by `pool_destroy` once the pool is empty) on top of the fee.
  /// Add liquidity separately once the creation is confirmed on chain.
  Future<BeamPreparedDexCall> prepareCreatePool({
    required int aidA,
    required int aidB,
    required BeamPoolKind kind,
  }) async {
    final args = DexArgs.createPool(
      aidA: aidA,
      aidB: aidB,
      kind: kind,
      cid: contractId,
    );
    return _prepare(BeamDexAction.createPool, args, null, (d) {
      _expect(
        d.pays.length == 1 && d.pays[0] == kDexPoolCreateDeposit,
        'pool creation pays ${d.pays}, expected the 10 BEAM deposit',
      );
      _expect(
        d.receives.isEmpty,
        'pool creation receives ${d.receives}, expected nothing',
      );
      return DexMethod.poolCreate;
    });
  }

  // ---------------------------------------------------------------- execute

  /// Sends [prepared] with `process_invoke_data` and returns the tx id.
  ///
  /// A prepared call is sent at most once, even if this throws: a timeout
  /// does not prove the core did not start the transaction. Prepare again
  /// after checking the transaction list.
  Future<String> execute(BeamPreparedDexCall prepared) {
    if (prepared._executed) {
      throw const BeamDexException(
        BeamDexErrorCode.alreadyExecuted,
        'this transaction was already sent',
      );
    }
    prepared._executed = true;
    return _serial(
      () => api.processInvokeData(prepared.rawData, timeout: timeout),
    );
  }

  // ---------------------------------------------------------------- helpers

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

  /// A read-only call: predictions and views. Building a transaction here
  /// would be a bug, so a `raw_data` in the answer is refused.
  Future<Map<String, Object?>> _view(String args) async {
    final r = await _invoke(args);
    final out = _decodeOutput(r.output);
    if (r.rawData != null) {
      throw const BeamDexException(
        BeamDexErrorCode.unexpectedTransaction,
        'a read-only DEX call produced a transaction',
      );
    }
    return out;
  }

  Future<BeamPreparedDexCall> _prepare(
    BeamDexAction action,
    String args,
    Object? quote,
    int Function(BeamInvokeData data) check,
  ) async {
    final r = await _invoke(args);
    if (r.output.trim().isNotEmpty) _decodeOutput(r.output);
    final raw = r.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BeamDexException(
        BeamDexErrorCode.unexpectedTransaction,
        'the shader built no transaction',
      );
    }
    final BeamInvokeData data;
    try {
      data = BeamInvokeData.decode(raw);
    } on FormatException catch (e) {
      throw BeamDexException(
        BeamDexErrorCode.unexpectedTransaction,
        'cannot read the prepared transaction: ${e.message}',
      );
    }
    _expect(data.entries.length == 1, 'expected one contract call');
    final entry = data.entries.single;
    _expect(
      entry.contractId == contractId,
      'the call targets ${entry.contractId}, not the DEX',
    );
    final method = check(data);
    _expect(
      entry.method == method,
      'contract method ${entry.method}, expected $method',
    );
    final stored = data.appArgs;
    if (stored != null) {
      for (final kv in args.split(',')) {
        final i = kv.indexOf('=');
        final key = kv.substring(0, i);
        _expect(
          stored[key] == kv.substring(i + 1),
          'stored shader arg $key differs from the request',
        );
      }
    }
    return BeamPreparedDexCall._(
      action: action,
      args: args,
      rawData: List.unmodifiable(raw),
      invoke: data,
      quote: quote,
    );
  }

  static Map<String, Object?> _decodeOutput(String output) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BeamDexException(_codeFor(e.message), e.message);
    }
  }

  static BeamDexErrorCode _codeFor(String shaderMessage) =>
      switch (shaderMessage) {
        'no such pool' => BeamDexErrorCode.noPool,
        'no liquidity' => BeamDexErrorCode.poolEmpty,
        'pool already exists' => BeamDexErrorCode.poolExists,
        'val1 too large' || 'val2 too large' => BeamDexErrorCode.ratioMismatch,
        _ => BeamDexErrorCode.shaderError,
      };

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BeamDexException(BeamDexErrorCode.unexpectedTransaction, what);
    }
  }
}
