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
import 'dart:math';

import 'package:meta/meta.dart';

import '../../api/beam_api.dart';
import '../../models/beam_call_results.dart';
import '../../models/beam_transaction.dart';
import '../../rpc/beam_transport.dart';
import '../common/contract_args.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'airdrop_args.dart';
import 'airdrop_constants.dart';
import 'airdrop_models.dart';
import 'voucher_blob.dart';
import 'voucher_code.dart';
import 'voucher_code_store.dart';

/// Why the Airdrop refused, so a screen can name the next step.
enum AirdropErrorCode {
  /// Another airdrop transaction is being prepared or sent. Finish or
  /// cancel it (see [BeamAirdropService.discard]) first.
  busy,

  /// The text has no letters or digits, or is longer than a code can be.
  invalidCode,

  /// No voucher has this code: mistyped, never created, or cancelled.
  voucherNotFound,

  /// Someone already claimed this voucher.
  alreadyRedeemed,

  /// No batch of this wallet has this id (never created, or every voucher
  /// is already claimed or cancelled).
  batchNotFound,

  /// The batch belongs to another wallet.
  notBatchCreator,

  /// Every voucher of the batch was already claimed.
  nothingToCancel,

  /// Only the contract owner can do this.
  notOwner,

  /// No creation fees were collected in this asset.
  noFees,

  /// More than the collected fees was asked for.
  insufficientFees,

  /// The contract id answers nothing: wrong network or wrong contract.
  contractNotFound,

  /// Creating a batch needs a [VoucherCodeStore]: without one the codes
  /// would exist only in memory.
  noCodeStore,

  /// The codes could not be saved, so nothing was sent.
  codesNotSaved,

  /// The prepared transaction is not what was asked for. Never shown to
  /// the user as confirmable.
  unexpectedTransaction,

  /// [BeamAirdropService.execute] was already called for this call.
  alreadyExecuted,

  /// The prepared call was discarded or replaced; prepare it again.
  expired,

  /// A saved batch can still hold funds, so it cannot be forgotten.
  stillHoldsFunds,

  /// The wallet is behind the network, so the chain cannot be trusted to
  /// say whether codes still hold funds.
  walletNotSynced,

  /// Any other shader refusal; [BeamAirdropException.message] has its text.
  shaderError,
}

class BeamAirdropException implements Exception {
  const BeamAirdropException(this.code, this.message);

  final AirdropErrorCode code;
  final String message;

  @override
  String toString() => 'BeamAirdropException(${code.name}): $message';
}

enum AirdropAction { createBatch, redeem, cancelBatch, withdrawFees }

/// What a prepared call will do, read back from the transaction the core
/// built (never from the request), for the confirmation screen.
///
/// Amounts are in each asset's smallest unit; the UI formats them with the
/// asset's own decimals. [lines] is plain text for logs and tests.
@immutable
class AirdropSummary {
  const AirdropSummary({
    required this.action,
    required this.assetId,
    required this.pays,
    required this.receives,
    required this.networkFee,
    required this.contractId,
    this.voucherCount,
    this.voucherValues,
    this.creationFee,
    this.batchId,
  });

  final AirdropAction action;

  /// The asset the vouchers (or fees) are in.
  final int assetId;

  /// What leaves the wallet, per asset, network fee excluded. For a batch:
  /// the vouchers' total plus [creationFee].
  final Map<int, BigInt> pays;

  /// What arrives, per asset.
  final Map<int, BigInt> receives;

  /// The network fee in BEAM groth, as the core will charge it. 0.121 BEAM
  /// for create / redeem / withdraw, 0.181 BEAM for cancel.
  final BigInt networkFee;
  final String contractId;

  /// [AirdropAction.createBatch]: how many vouchers, and their values.
  final int? voucherCount;
  final List<BigInt>? voucherValues;

  /// [AirdropAction.createBatch]: the 1% kept by the contract owner,
  /// included in [pays].
  final BigInt? creationFee;

  /// [AirdropAction.cancelBatch]: the batch.
  final BigInt? batchId;

  /// BEAM leaving the wallet, network fee included, in groth.
  BigInt get beamOut => (pays[0] ?? BigInt.zero) + networkFee;

  /// A claim whose BEAM value does not cover its own network fee: the
  /// wallet ends up with less BEAM than before. Worth a warning.
  bool get claimCostsMoreThanItPays =>
      action == AirdropAction.redeem &&
      receives.length == 1 &&
      receives.containsKey(0) &&
      receives[0]! <= networkFee;

  List<String> get lines => [
    _headline(),
    for (final p in pays.entries) 'You lock: ${format(p.key, p.value)}',
    if (creationFee != null)
      'Contract fee (1%, included above): ${format(assetId, creationFee!)}',
    for (final r in receives.entries) 'You receive: ${format(r.key, r.value)}',
    'Network fee: ${format(0, networkFee)}',
    'Total BEAM out: ${format(0, beamOut)}',
    if (action == AirdropAction.createBatch)
      'The codes are the only key to these funds. They are saved in this '
          'wallet before anything is sent.',
    if (claimCostsMoreThanItPays)
      'This voucher is worth less than the network fee to claim it.',
  ];

  String _headline() => switch (action) {
    AirdropAction.createBatch => _batchHeadline(),
    AirdropAction.redeem => 'Claim a voucher',
    AirdropAction.cancelBatch =>
      'Cancel batch $batchId and take back its unclaimed vouchers',
    AirdropAction.withdrawFees => 'Withdraw collected airdrop fees',
  };

  String _batchHeadline() {
    final values = voucherValues!;
    final same = values.every((v) => v == values.first);
    return same
        ? 'Create ${values.length} vouchers of '
              '${format(assetId, values.first)} each'
        : 'Create ${values.length} vouchers';
  }

  /// `1.5 BEAM` for BEAM; `150 units of asset 7` for anything else, since
  /// only the caller knows that asset's decimals.
  static String format(int assetId, BigInt amount) {
    if (assetId != 0) return '$amount units of asset $assetId';
    final g = BigInt.from(100000000);
    final whole = amount ~/ g;
    final frac = amount.remainder(g).toString().padLeft(8, '0');
    final f = frac.replaceFirst(RegExp(r'0+$'), '');
    return f.isEmpty ? '$whole BEAM' : '$whole.$f BEAM';
  }
}

/// An Airdrop transaction built by the core but not yet sent.
///
/// For [AirdropAction.createBatch], [saved] holds the new codes. They are
/// secret: show them only after the batch is sent, and never log them.
/// For [AirdropAction.redeem], [args] contains the code (it becomes public
/// on chain once the claim is mined, not before).
class BeamPreparedAirdropCall {
  BeamPreparedAirdropCall._({
    required this.action,
    required this.args,
    required this.rawData,
    required this.invoke,
    required this.summary,
    this.saved,
  });

  final AirdropAction action;
  final String args;
  final List<int> rawData;
  final BeamInvokeData invoke;
  final AirdropSummary summary;

  /// The record [BeamAirdropService.execute] saves before broadcasting.
  final AirdropSavedBatch? saved;

  bool _executed = false;

  bool get isExecuted => _executed;

  /// The new codes, formatted (create only; empty otherwise).
  List<String> get codes =>
      saved == null ? const [] : [for (final c in saved!.codes) c.code];

  @override
  String toString() => 'BeamPreparedAirdropCall(${action.name})';
}

/// The voucher Airdrop: claim with a code, create batches of codes, list
/// and cancel them, and the owner's fees. Over [BeamApi.invokeContract]
/// with the pinned Airdrop shader.
///
/// Money-moving work is split in two, as for the DEX:
///
/// 1. `prepare…` builds the transaction with `create_tx: false` and checks
///    the decoded `raw_data` byte for byte against the request: one call,
///    to [contractId], the expected method, the expected arguments (this
///    wallet's key, the exact vouchers, the exact code) and exactly the
///    expected funds. Anything else is refused.
/// 2. [execute] is the only path to `process_invoke_data`.
///
/// **One airdrop transaction at a time.** A prepare claims the service
/// synchronously, before its first `await`, and the claim lasts until the
/// prepared call is executed or [discard]ed. A second tap that arrives
/// while the first is still checking balances gets [AirdropErrorCode.busy]
/// instead of building a second batch: the bug that let LightWallet lock
/// funds twice. A screen that leaves the confirmation without sending must
/// call [discard], or the service stays busy.
class BeamAirdropService {
  BeamAirdropService(
    this.api,
    this.shader, {
    this.store,
    this.contractId = kAirdropContractId,
    this.timeout = const Duration(minutes: 2),
    Random? random,
    DateTime Function()? clock,
  }) : _random = random ?? Random.secure(),
       _clock = clock ?? DateTime.now {
    AirdropArgs.checkContractId(contractId);
  }

  final BeamApi api;

  /// The Airdrop app shader, pinned (see [airdropAppShader]).
  final PinnedShader shader;

  /// Where created codes are kept. Required to create batches.
  final VoucherCodeStore? store;
  final String contractId;

  /// Per `invoke_contract` / `process_invoke_data` call.
  final Duration timeout;

  final Random _random;
  final DateTime Function() _clock;

  Future<void> _tail = Future<void>.value();
  Object? _flow;

  /// An unconfirmed batch with no code on chain this long after it was
  /// built can no longer confirm: contract transactions are valid for a
  /// few blocks, and any transaction for at most hours.
  static const staleAfter = Duration(hours: 24);

  /// A prepare or send is in progress, or a prepared call awaits
  /// [execute] / [discard].
  bool get isBusy => _flow != null;

  // ------------------------------------------------------------------ views

  /// This wallet's key for the contract: batch creator and claimer.
  Future<String> myKey() async {
    final out = await _view(AirdropArgs.getMyKey(cid: contractId));
    final pk = ShaderOutput.string(out, 'pk');
    if (!RegExp(r'^[0-9a-f]{64}0[01]$').hasMatch(pk)) {
      throw const FormatException('get_my_key: not a public key');
    }
    return pk;
  }

  /// The voucher [code] unlocks, or null when there is none.
  Future<AirdropVoucherInfo?> checkVoucher(String code) {
    if (AirdropVoucherCode.normalise(code).isEmpty) {
      throw const BeamAirdropException(
        AirdropErrorCode.invalidCode,
        'A code has letters and digits, like ABCD-EFGH-JKLM-NPQR.',
      );
    }
    return checkVoucherHash(AirdropVoucherCode.hashHex(code));
  }

  /// The voucher stored under [hashHex], or null when there is none.
  Future<AirdropVoucherInfo?> checkVoucherHash(String hashHex) async {
    try {
      final out = await _view(
        AirdropArgs.checkVoucher(hashHex: hashHex, cid: contractId),
      );
      return AirdropVoucherInfo.fromOutput(out, hashHex);
    } on BeamAirdropException catch (e) {
      if (e.code == AirdropErrorCode.voucherNotFound) return null;
      rethrow;
    }
  }

  /// This wallet's batches that still have vouchers on record.
  Future<List<AirdropBatch>> myBatches() async => AirdropBatch.listFromOutput(
    await _view(AirdropArgs.viewMyBatches(cid: contractId)),
  );

  /// Every voucher of one of this wallet's batches.
  Future<List<AirdropBatchVoucher>> batchVouchers(BigInt batchId) async =>
      AirdropBatchVoucher.listFromOutput(
        await _view(
          AirdropArgs.viewBatchVouchers(batchId: batchId, cid: contractId),
        ),
      );

  /// Contract totals.
  Future<AirdropStats> stats() async => AirdropStats.fromOutput(
    await _view(AirdropArgs.viewStats(cid: contractId)),
  );

  /// Contract settings and whether this wallet owns the contract.
  Future<AirdropSettings> settings() async => AirdropSettings.fromOutput(
    await _view(AirdropArgs.view(cid: contractId)),
  );

  /// Creation fees collected, per asset.
  Future<List<AirdropFeePool>> fees() async => AirdropFeePool.listFromOutput(
    await _view(AirdropArgs.viewFees(cid: contractId)),
  );

  // ------------------------------------------------------------ saved codes

  /// The saved batches for this contract, newest first.
  Future<List<AirdropSavedBatch>> savedBatches() async {
    final s = _requireStore();
    final all = (await s.all()).where((b) => b.contractId == contractId);
    return List.unmodifiable(
      all.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
    );
  }

  /// Re-reads [batch] from the chain: its transaction (when the id is
  /// known) and every code with `check_voucher`, and saves the result.
  /// Never removes a code. A code found on chain proves the batch was
  /// created, whatever the transaction record says.
  Future<AirdropSavedBatch> refreshSavedBatch(AirdropSavedBatch batch) async {
    final s = _requireStore();
    // Work on the stored record, which may be newer than [batch].
    final stored = (await s.all()).where((b) => b.localId == batch.localId);
    final current = stored.isEmpty ? batch : stored.single;
    var status = current.txStatus;
    final tx = current.txId;
    if (tx != null &&
        (status == AirdropBatchTxStatus.unconfirmed ||
            status == AirdropBatchTxStatus.broadcast)) {
      try {
        final t = await api.txStatus(tx);
        status = switch (t.status) {
          BeamTxStatus.completed => AirdropBatchTxStatus.confirmed,
          BeamTxStatus.failed ||
          BeamTxStatus.canceled => AirdropBatchTxStatus.failed,
          _ => status,
        };
      } on BeamRpcException {
        // Unknown to this wallet's history: the codes below decide.
      }
    }
    final codes = <AirdropSavedCode>[];
    var anyOnChain = false;
    for (final c in current.codes) {
      final info = await checkVoucherHash(c.hashHex);
      if (info != null) anyOnChain = true;
      codes.add(
        c.withStatus(
          info == null
              ? AirdropCodeStatus.notFound
              : info.redeemed
              ? AirdropCodeStatus.claimed
              : AirdropCodeStatus.available,
        ),
      );
    }
    if (anyOnChain) status = AirdropBatchTxStatus.confirmed;
    final updated = current.copyWith(txStatus: status, codes: codes);
    await s.put(updated);
    return updated;
  }

  /// Removes a saved batch, on an explicit user request, and only when it
  /// can no longer hold funds. Checks the chain first: refused with
  /// [AirdropErrorCode.stillHoldsFunds] while any code is unclaimed on
  /// chain, or while the transaction may still confirm; and with
  /// [AirdropErrorCode.walletNotSynced] while the wallet is behind, since a
  /// wallet that has not seen the batch's block reports its codes as
  /// missing.
  Future<void> forgetSavedBatch(String localId) async {
    final s = _requireStore();
    final found = (await s.all()).where((b) => b.localId == localId);
    if (found.isEmpty) return;
    if (!(await api.walletStatus()).isInSync) {
      throw const BeamAirdropException(
        AirdropErrorCode.walletNotSynced,
        'The wallet is still catching up with the network. Try again once '
        'it is in sync.',
      );
    }
    final b = await refreshSavedBatch(found.single);
    final anyAvailable = b.codes.any(
      (c) => c.status == AirdropCodeStatus.available,
    );
    final allGone = b.codes.every(
      (c) =>
          c.status == AirdropCodeStatus.notFound ||
          c.status == AirdropCodeStatus.claimed,
    );
    final stale =
        b.txStatus == AirdropBatchTxStatus.unconfirmed &&
        _clock().toUtc().difference(b.createdAt) > staleAfter;
    final settled =
        b.txStatus == AirdropBatchTxStatus.confirmed ||
        b.txStatus == AirdropBatchTxStatus.failed ||
        stale;
    if (anyAvailable || !allGone || !settled) {
      throw const BeamAirdropException(
        AirdropErrorCode.stillHoldsFunds,
        'These codes can still unlock funds, so they stay saved. Cancel the '
        'batch first, or wait until its transaction settles.',
      );
    }
    await s.delete(localId);
  }

  // ---------------------------------------------------------------- prepare

  /// Builds a batch of vouchers of [assetId], one per entry of [values]
  /// (each in the asset's smallest unit), with fresh codes.
  ///
  /// The wallet locks the values plus the 1% creation fee
  /// ([AirdropFee.creationFee]) and pays the network fee in BEAM. The
  /// codes go into [BeamPreparedAirdropCall.saved]; [execute] stores them
  /// before it broadcasts.
  Future<BeamPreparedAirdropCall> prepareCreateBatch({
    required int assetId,
    required List<BigInt> values,
  }) => _flowed(() async {
    if (store == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.noCodeStore,
        'This wallet has nowhere safe to keep the codes, so it cannot '
        'create a batch.',
      );
    }
    if (values.isEmpty || values.length > kAirdropMaxVouchersPerBatch) {
      throw ArgumentError.value(
        values.length,
        'values',
        '1 to $kAirdropMaxVouchersPerBatch vouchers',
      );
    }
    final codes = <String>[];
    final hashes = <String>[];
    while (codes.length < values.length) {
      final c = AirdropVoucherCode.generate(_random);
      final h = AirdropVoucherCode.hashHex(c);
      if (hashes.contains(h)) continue;
      codes.add(c);
      hashes.add(h);
    }
    final entries = [
      for (var i = 0; i < values.length; i++)
        AirdropVoucherEntry(hashes[i], values[i]),
    ];
    final blob = AirdropVoucherBlob.bytes(entries);
    final total = AirdropVoucherBlob.total(entries);
    final fee = AirdropFee.creationFee(total);

    final key = await myKey();
    final args = AirdropArgs.createBatch(
      assetId: assetId,
      vouchers: entries,
      cid: contractId,
    );
    final (:raw, :d) = await _build(
      args,
      AirdropMethod.createBatch,
      AirdropCharge.createBatch,
      AirdropKernelComment.createBatch,
    );
    final e = d.entries.single;
    _expect(
      _bytesEqual(e.args, [
        ..._hex(key),
        ..._le(assetId, 4),
        ..._le(entries.length, 4),
        ...blob,
      ]),
      'the batch arguments differ from the request',
    );
    _expectFunds(d, {assetId: total + fee}, 'the batch');

    final now = _clock().toUtc();
    final saved = AirdropSavedBatch(
      localId:
          'batch_${now.microsecondsSinceEpoch}_${_random.nextInt(1 << 32)}',
      contractId: contractId,
      assetId: assetId,
      createdAt: now,
      codes: [
        for (var i = 0; i < codes.length; i++)
          AirdropSavedCode(
            code: codes[i],
            hashHex: hashes[i],
            value: values[i],
          ),
      ],
    );
    return BeamPreparedAirdropCall._(
      action: AirdropAction.createBatch,
      args: args,
      rawData: raw,
      invoke: d,
      saved: saved,
      summary: AirdropSummary(
        action: AirdropAction.createBatch,
        assetId: assetId,
        pays: d.pays,
        receives: d.receives,
        networkFee: d.fee,
        contractId: contractId,
        voucherCount: values.length,
        voucherValues: List.unmodifiable(values),
        creationFee: fee,
      ),
    );
  });

  /// Builds the claim of the voucher [code] unlocks. The code is sent as
  /// the normalised preimage; the contract hashes it.
  Future<BeamPreparedAirdropCall> prepareRedeem(String code) =>
      _flowed(() async {
        final normalised = AirdropVoucherCode.normalise(code);
        if (normalised.isEmpty) {
          throw const BeamAirdropException(
            AirdropErrorCode.invalidCode,
            'A code has letters and digits, like ABCD-EFGH-JKLM-NPQR.',
          );
        }
        final info = await checkVoucherHash(
          AirdropVoucherCode.hashHex(normalised),
        );
        if (info == null) {
          throw const BeamAirdropException(
            AirdropErrorCode.voucherNotFound,
            'No voucher has this code. Check it letter by letter; codes '
            'never contain I, O, 0 or 1.',
          );
        }
        if (info.redeemed) {
          throw const BeamAirdropException(
            AirdropErrorCode.alreadyRedeemed,
            'This voucher was already claimed.',
          );
        }
        final key = await myKey();
        final args = AirdropArgs.redeem(
          normalisedCode: normalised,
          cid: contractId,
        );
        final (:raw, :d) = await _build(
          args,
          AirdropMethod.redeem,
          AirdropCharge.redeem,
          AirdropKernelComment.redeem,
        );
        _expect(
          _bytesEqual(d.entries.single.args, [
            ..._hex(key),
            ..._le(normalised.length, 4),
            ...ascii.encode(normalised),
          ]),
          'the claim arguments differ from the request',
        );
        _expectFunds(d, {info.assetId: -info.value}, 'the claim');
        return BeamPreparedAirdropCall._(
          action: AirdropAction.redeem,
          args: args,
          rawData: raw,
          invoke: d,
          summary: AirdropSummary(
            action: AirdropAction.redeem,
            assetId: info.assetId,
            pays: d.pays,
            receives: d.receives,
            networkFee: d.fee,
            contractId: contractId,
          ),
        );
      });

  /// Builds the cancellation of every unclaimed voucher of [batchId],
  /// returning their value to this wallet. Their codes stop working.
  Future<BeamPreparedAirdropCall> prepareCancelBatch(BigInt batchId) =>
      _flowed(() async {
        final batch = (await myBatches()).where((b) => b.id == batchId);
        if (batch.isEmpty) {
          throw BeamAirdropException(
            AirdropErrorCode.batchNotFound,
            'This wallet has no batch $batchId with vouchers left.',
          );
        }
        final unclaimed = [
          for (final v in await batchVouchers(batchId))
            if (!v.redeemed) v,
        ];
        if (unclaimed.isEmpty) {
          throw const BeamAirdropException(
            AirdropErrorCode.nothingToCancel,
            'Every voucher of this batch was already claimed.',
          );
        }
        final total = unclaimed.fold(BigInt.zero, (s, v) => s + v.value);
        final key = await myKey();
        final args = AirdropArgs.cancelBatch(batchId: batchId, cid: contractId);
        final (:raw, :d) = await _build(
          args,
          AirdropMethod.cancelBatch,
          AirdropCharge.cancelBatch,
          AirdropKernelComment.cancelBatch,
        );
        final a = d.entries.single.args;
        final head = [
          ..._hex(key),
          ..._le(batchId, 8),
          ..._le(unclaimed.length, 4),
        ];
        _expect(
          a.length == head.length + 32 * unclaimed.length &&
              _bytesEqual(a.sublist(0, head.length), head),
          'the batch changed while preparing; try again',
        );
        final sent = <String>{
          for (var o = head.length; o < a.length; o += 32)
            _toHex(a.sublist(o, o + 32)),
        };
        _expect(
          sent.length == unclaimed.length &&
              unclaimed.every((v) => sent.contains(v.hashHex)),
          'the batch changed while preparing; try again',
        );
        _expectFunds(d, {batch.single.assetId: -total}, 'the cancel');
        return BeamPreparedAirdropCall._(
          action: AirdropAction.cancelBatch,
          args: args,
          rawData: raw,
          invoke: d,
          summary: AirdropSummary(
            action: AirdropAction.cancelBatch,
            assetId: batch.single.assetId,
            pays: d.pays,
            receives: d.receives,
            networkFee: d.fee,
            contractId: contractId,
            voucherCount: unclaimed.length,
            batchId: batchId,
          ),
        );
      });

  /// Builds a withdrawal of [amount] of the creation fees collected in
  /// [assetId]. Owner only.
  Future<BeamPreparedAirdropCall> prepareWithdrawFees({
    required int assetId,
    required BigInt amount,
  }) => _flowed(() async {
    final s = await settings();
    if (!s.isOwner) {
      throw const BeamAirdropException(
        AirdropErrorCode.notOwner,
        'Only the contract owner can withdraw its fees.',
      );
    }
    final pool = (await fees()).where((f) => f.assetId == assetId);
    if (pool.isEmpty) {
      throw BeamAirdropException(
        AirdropErrorCode.noFees,
        'No fees were collected in asset $assetId.',
      );
    }
    if (amount > pool.single.available) {
      throw BeamAirdropException(
        AirdropErrorCode.insufficientFees,
        'At most ${pool.single.available} can be withdrawn.',
      );
    }
    final args = AirdropArgs.withdrawFees(
      assetId: assetId,
      amount: amount,
      cid: contractId,
    );
    final (:raw, :d) = await _build(
      args,
      AirdropMethod.withdrawFees,
      AirdropCharge.withdrawFees,
      AirdropKernelComment.withdrawFees,
    );
    _expect(
      _bytesEqual(d.entries.single.args, [
        ..._hex(s.ownerKey),
        ..._le(assetId, 4),
        ..._le(amount, 8),
      ]),
      'the withdrawal arguments differ from the request',
    );
    _expectFunds(d, {assetId: -amount}, 'the withdrawal');
    return BeamPreparedAirdropCall._(
      action: AirdropAction.withdrawFees,
      args: args,
      rawData: raw,
      invoke: d,
      summary: AirdropSummary(
        action: AirdropAction.withdrawFees,
        assetId: assetId,
        pays: d.pays,
        receives: d.receives,
        networkFee: d.fee,
        contractId: contractId,
      ),
    );
  });

  // ---------------------------------------------------------------- execute

  /// Sends [prepared] with `process_invoke_data` and returns the tx id.
  ///
  /// For a new batch, the codes are written to [store] first and read back;
  /// if that fails nothing is sent ([AirdropErrorCode.codesNotSaved]).
  /// After sending, the record gets the tx id. The record is never removed,
  /// whatever happens.
  ///
  /// A prepared call is sent at most once, even if this throws: a timeout
  /// does not prove the core did not start the transaction.
  Future<String> execute(BeamPreparedAirdropCall prepared) async {
    if (prepared._executed) {
      throw const BeamAirdropException(
        AirdropErrorCode.alreadyExecuted,
        'This transaction was already sent.',
      );
    }
    if (!identical(_flow, prepared)) {
      throw const BeamAirdropException(
        AirdropErrorCode.expired,
        'This confirmation is no longer current. Prepare it again.',
      );
    }
    prepared._executed = true;
    try {
      final saved = prepared.saved;
      if (saved != null) await _saveBeforeBroadcast(saved);
      final String txId;
      try {
        txId = await _serial(
          () => api.processInvokeData(prepared.rawData, timeout: timeout),
        );
      } on BeamRpcException {
        // The core answered with a refusal: it built no transaction.
        if (saved != null) {
          await _bestEffortPut(
            saved.copyWith(txStatus: AirdropBatchTxStatus.failed),
          );
        }
        rethrow;
      }
      if (saved != null) {
        await _bestEffortPut(
          saved.copyWith(txId: txId, txStatus: AirdropBatchTxStatus.broadcast),
        );
      }
      return txId;
    } finally {
      if (identical(_flow, prepared)) _flow = null;
    }
  }

  /// Gives up [prepared] without sending it, releasing the service.
  void discard(BeamPreparedAirdropCall prepared) {
    if (identical(_flow, prepared) && !prepared._executed) _flow = null;
  }

  // ---------------------------------------------------------------- helpers

  Future<BeamPreparedAirdropCall> _flowed(
    Future<BeamPreparedAirdropCall> Function() build,
  ) async {
    // Runs synchronously up to the first await: a second tap in the same
    // frame finds the service claimed.
    if (_flow != null) {
      throw const BeamAirdropException(
        AirdropErrorCode.busy,
        'Another airdrop transaction is in progress. Finish or cancel it '
        'first.',
      );
    }
    final token = Object();
    _flow = token;
    try {
      final p = await build();
      if (!identical(_flow, token)) {
        throw const BeamAirdropException(
          AirdropErrorCode.expired,
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

  VoucherCodeStore _requireStore() {
    final s = store;
    if (s == null) {
      throw const BeamAirdropException(
        AirdropErrorCode.noCodeStore,
        'This wallet has no saved airdrop codes.',
      );
    }
    return s;
  }

  Future<void> _saveBeforeBroadcast(AirdropSavedBatch saved) async {
    final s = _requireStore();
    try {
      await s.put(saved);
      final back = (await s.all()).where((b) => b.localId == saved.localId);
      final ok =
          back.length == 1 &&
          back.single.codes.length == saved.codes.length &&
          [
            for (var i = 0; i < saved.codes.length; i++)
              back.single.codes[i].code == saved.codes[i].code &&
                  back.single.codes[i].hashHex == saved.codes[i].hashHex,
          ].every((x) => x);
      if (!ok) throw StateError('read-back mismatch');
    } catch (e) {
      throw BeamAirdropException(
        AirdropErrorCode.codesNotSaved,
        'The codes could not be saved, so nothing was sent. ($e)',
      );
    }
  }

  Future<void> _bestEffortPut(AirdropSavedBatch b) async {
    try {
      await store?.put(b);
    } catch (_) {
      // The codes were saved before sending; only the status is stale, and
      // refreshSavedBatch reconciles it from the chain.
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

  /// A read-only call. A `raw_data` in the answer is refused.
  Future<Map<String, Object?>> _view(String args) async {
    final r = await _invoke(args);
    final out = _decodeOutput(r.output);
    if (r.rawData != null) {
      throw const BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'a read-only airdrop call produced a transaction',
      );
    }
    return out;
  }

  Future<({List<int> raw, BeamInvokeData d})> _build(
    String args,
    int method,
    int charge,
    String comment,
  ) async {
    final r = await _invoke(args);
    if (r.output.trim().isNotEmpty) _decodeOutput(r.output);
    final raw = r.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'the shader built no transaction',
      );
    }
    final BeamInvokeData d;
    try {
      d = BeamInvokeData.decode(raw);
    } on FormatException catch (e) {
      throw BeamAirdropException(
        AirdropErrorCode.unexpectedTransaction,
        'cannot read the prepared transaction: ${e.message}',
      );
    }
    _expect(d.entries.length == 1, 'expected one contract call');
    final e = d.entries.single;
    _expect(
      e.contractId == contractId,
      'the call targets ${e.contractId}, not the Airdrop',
    );
    _expect(e.method == method, 'contract method ${e.method}, not $method');
    _expect(!e.isDependent, 'a dependent call');
    _expect(e.charge == charge, 'BVM charge ${e.charge}, expected $charge');
    _expect(e.comment == comment, 'kernel comment "${e.comment}"');
    _expect(e.signatureCount == 1, '${e.signatureCount} signing keys');
    final stored = d.appArgs;
    if (stored != null) {
      for (final kv in args.split(',')) {
        final i = kv.indexOf('=');
        _expect(
          stored[kv.substring(0, i)] == kv.substring(i + 1),
          'stored shader args differ from the request',
        );
      }
    }
    return (raw: List<int>.unmodifiable(raw), d: d);
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

  static Map<String, Object?> _decodeOutput(String output) {
    try {
      return ShaderOutput.decode(output);
    } on BeamShaderException catch (e) {
      throw BeamAirdropException(codeFor(e.message), e.message);
    }
  }

  /// The [AirdropErrorCode] for one of the shader's error strings.
  static AirdropErrorCode codeFor(String shaderMessage) =>
      switch (shaderMessage) {
        'Voucher not found' => AirdropErrorCode.voucherNotFound,
        'Voucher already redeemed' => AirdropErrorCode.alreadyRedeemed,
        'Batch not found' => AirdropErrorCode.batchNotFound,
        'Not batch creator' => AirdropErrorCode.notBatchCreator,
        'No unclaimed vouchers' => AirdropErrorCode.nothingToCancel,
        'Not contract owner' => AirdropErrorCode.notOwner,
        'No fees for this asset' => AirdropErrorCode.noFees,
        'Insufficient fees' => AirdropErrorCode.insufficientFees,
        'Contract not found' => AirdropErrorCode.contractNotFound,
        'Missing or invalid code' ||
        'Empty code after normalization' => AirdropErrorCode.invalidCode,
        _ => AirdropErrorCode.shaderError,
      };

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BeamAirdropException(AirdropErrorCode.unexpectedTransaction, what);
    }
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static List<int> _hex(String h) => [
    for (var i = 0; i < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ];

  static String _toHex(List<int> b) =>
      [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  /// [value] (an int or a BigInt) as [n] little-endian bytes.
  static List<int> _le(Object value, int n) => BeamArgsWriter.le(value, n);
}
