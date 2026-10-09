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
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../../bridge/bridge_routes.dart';
import '../../../bridge/bridge_sides.dart';
import '../../api/beam_api.dart';
import '../../models/beam_call_results.dart';
import '../../models/beam_transaction.dart';
import '../../rpc/beam_connection_exception.dart';
import '../../rpc/beam_transport.dart';
import '../common/contract_args.dart';
import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import '../common/shader_output.dart';
import 'pipe_args.dart';
import 'pipe_constants.dart';
import 'pipe_output.dart';

/// The BEAM half of the bridge: one per BEAM wallet, over the wallet's
/// [BeamApi] and the two pinned pipe shaders.
///
/// Money-moving work is split in two, as in the DEX:
///
/// 1. `prepare…` builds the transaction with `create_tx: false`. Nothing
///    is sent. The `raw_data` is decoded and checked byte for byte against
///    the request (pipe, method, packed arguments, signatures, funds,
///    fee); anything else is refused with
///    [BridgeErrorCode.unexpectedTransaction].
/// 2. [execute] sends it with `process_invoke_data`, once, after the
///    controller has shown the decoded amounts and the user has passed
///    Campfire's PIN gate.
///
/// Errors: what the user or the network can cause is a [BridgeException];
/// a programming error (a route not in [kBridgeRoutes], a malformed
/// Ethereum address, a negative message id) is an [ArgumentError].
///
/// The core runs one app shader at a time and [BeamApi] already queues
/// every service's shader calls on a connection; this service also queues
/// its own, so an [execute] never overtakes a build it asked for earlier.
class BeamPipeService implements BeamPipeSide {
  BeamPipeService(
    this.api,
    ShaderSource shaders, {
    this.timeout = const Duration(minutes: 2),
  }) : _shaders = {
         for (final s in BridgeShader.values) s: pipeAppShader(s, shaders),
       };

  final BeamApi api;

  /// Per `invoke_contract` / `process_invoke_data` call.
  final Duration timeout;

  final Map<BridgeShader, PinnedShader> _shaders;

  /// The prepared calls this service built and checked, and the ones it
  /// has sent. Kept here rather than trusted from the public fields of
  /// [BeamPipePrepared], which anyone can construct or reset.
  final _checked = Expando<bool>('bridge call checked here');
  final _sent = Expando<bool>('bridge call sent');

  Future<void> _tail = Future<void>.value();

  static final _maxAmount = (BigInt.one << 63) - BigInt.one;

  // ------------------------------------------------------------------ views

  @override
  Future<Uint8List> receiveKey(BridgeRoute route) async {
    final r = _registered(route);
    final out = await _view(r, PipeArgs.getPk(cid: r.beamPipeCid));
    return PipeOutput.receiveKey(out, r.shader);
  }

  @override
  Future<int> localMessageCount(BridgeRoute route) async {
    final r = _registered(route);
    return PipeOutput.count(
      await _view(r, PipeArgs.localMsgCount(cid: r.beamPipeCid)),
    );
  }

  @override
  Future<BeamPipeLocalMessage?> localMessage(
    BridgeRoute route,
    int msgId,
  ) async {
    final r = _registered(route);
    return PipeOutput.localMessage(
      await _view(r, PipeArgs.localMsg(cid: r.beamPipeCid, msgId: msgId)),
    );
  }

  @override
  Future<BeamPipeRemoteMessage?> remoteMessage(
    BridgeRoute route,
    int msgId,
  ) async {
    final r = _registered(route);
    return PipeOutput.remoteMessage(
      await _view(r, PipeArgs.remoteMsg(cid: r.beamPipeCid, msgId: msgId)),
    );
  }

  @override
  Future<List<BeamPipeIncoming>> incoming(
    BridgeRoute route, {
    int startFrom = 0,
  }) async {
    final r = _registered(route);
    return PipeOutput.incoming(
      await _view(
        r,
        PipeArgs.viewIncoming(cid: r.beamPipeCid, startFrom: startFrom),
      ),
    );
  }

  // ---------------------------------------------------------------- prepare

  @override
  Future<BeamPipePrepared> prepareSend(
    BridgeRoute route, {
    required String ethReceiver,
    required BigInt amount,
    required BigInt fee,
  }) async {
    final r = _registered(route);
    final receiver = _ethAddress(ethReceiver);
    _checkSendAmounts(r, amount, fee);
    final args = PipeArgs.send(
      cid: r.beamPipeCid,
      amount: amount,
      receiver: receiver,
      relayerFee: fee,
    );
    final (raw, data) = await _build(r, args);
    final e = data.entries.single;
    _expect(
      e.method == r.sendMethod,
      'contract method ${e.method}, expected ${r.sendMethod} (send)',
    );
    // `SendFunds { Eth::Address m_Receiver; Amount m_Amount;
    // Amount m_RelayerFee; }`, packed, little-endian: 36 bytes.
    _expect(
      _sameBytes(e.args, [
        ..._hexBytes(receiver),
        ...BeamArgsWriter.le(amount, 8),
        ...BeamArgsWriter.le(fee, 8),
      ]),
      'send carries other arguments than receiver, amount and fee',
    );
    _expect(
      e.signatureCount == 0,
      'send asks for ${e.signatureCount} signatures, expected none',
    );
    _expect(
      _sameFunds(e.spend, {r.beamAssetId: amount + fee}),
      'send moves ${e.spend}, expected ${amount + fee} of asset '
      '${r.beamAssetId}',
    );
    _expect(
      data.fee == kBridgeSendFeeGroth,
      'send costs ${data.fee} groth, expected $kBridgeSendFeeGroth',
    );
    return _checkedCall(
      BeamPipePrepared(
        route: r,
        call: BeamPipeCall.send,
        rawData: List.unmodifiable(raw),
        networkFee: data.fee,
        amount: amount,
        relayerFee: fee,
        ethReceiver: '0x$receiver',
      ),
    );
  }

  @override
  Future<BeamPipePrepared> prepareReceive(
    BridgeRoute route, {
    required int msgId,
    required BigInt amount,
  }) async {
    final r = _registered(route);
    if (amount <= BigInt.zero || amount > _maxAmount) {
      throw BridgeException(
        BridgeErrorCode.badAmount,
        'a claim of $amount groth is not possible',
      );
    }
    final args = PipeArgs.receive(cid: r.beamPipeCid, msgId: msgId);
    final (raw, data) = await _build(r, args);
    final e = data.entries.single;
    _expect(
      e.method == r.receiveMethod,
      'contract method ${e.method}, expected ${r.receiveMethod} (receive)',
    );
    // `ReceiveFunds { uint64_t m_MsgId; }`.
    _expect(
      _sameBytes(e.args, BeamArgsWriter.le(msgId, 8)),
      'receive carries other arguments than message $msgId',
    );
    // The claim must be signed with the key `get_pk` gave the sender, and
    // with nothing else: the key whose id is the pipe's cid.
    _expect(
      e.signatureCount == 1 &&
          e.signatureKeyHashes.single == pipeKeyHash(r.beamPipeCid),
      'receive is not signed with this pipe\'s receive key alone',
    );
    _expect(
      _sameFunds(e.spend, {r.beamAssetId: -amount}),
      'receive moves ${e.spend}, expected to receive $amount of asset '
      '${r.beamAssetId}',
    );
    _expect(
      data.fee == kBridgeClaimFeeGroth,
      'receive costs ${data.fee} groth, expected $kBridgeClaimFeeGroth',
    );
    return _checkedCall(
      BeamPipePrepared(
        route: r,
        call: BeamPipeCall.receive,
        rawData: List.unmodifiable(raw),
        networkFee: data.fee,
        amount: amount,
        relayerFee: BigInt.zero,
        msgId: msgId,
      ),
    );
  }

  // ---------------------------------------------------------------- execute

  /// Sends [prepared] with `process_invoke_data` and returns the tx id.
  ///
  /// Only a call this service prepared is sent, and at most once, even if
  /// this throws: a timeout does not prove the core did not start the
  /// transaction. The controller looks the transaction up before it ever
  /// prepares the same crossing again.
  @override
  Future<String> execute(BeamPipePrepared prepared) async {
    if (_checked[prepared] != true) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'this transaction was not built and checked by this wallet',
      );
    }
    if (prepared.sent || _sent[prepared] == true) {
      throw const BridgeException(
        BridgeErrorCode.alreadySent,
        'this transaction was already sent',
      );
    }
    _sent[prepared] = true;
    prepared.sent = true;
    return _serial(
      () => _guard(
        () => api.processInvokeData(prepared.rawData, timeout: timeout),
      ),
    );
  }

  // ----------------------------------------------------------------- wallet

  @override
  Future<BeamPipeTxStatus> txStatus(String txId) async {
    final tx = await _guard(() => api.txStatus(txId));
    final height = tx.height;
    return switch (tx.status) {
      // The core records the kernel's height when it confirms; until it
      // has, the crossing's message cannot be found by height anyway.
      BeamTxStatus.completed when height != null => BeamPipeTxStatus.completed(
        height,
      ),
      BeamTxStatus.failed => BeamPipeTxStatus.failed(
        tx.failureReason ?? tx.statusString,
      ),
      BeamTxStatus.canceled => const BeamPipeTxStatus.failed('canceled'),
      _ => const BeamPipeTxStatus.pending(),
    };
  }

  @override
  Future<int> tipHeight() async =>
      (await _guard(api.walletStatus)).currentHeight;

  /// Spendable groth of [assetId], as every other BEAM screen counts it.
  @override
  Future<BigInt> available(int assetId) async {
    final s = await _guard(api.walletStatus);
    final t = s.totalsFor(assetId);
    if (t != null) return t.available;
    // A core that lists no totals reports BEAM at the top level only.
    if (assetId == 0 && s.totals.isEmpty) return s.available ?? BigInt.zero;
    return BigInt.zero;
  }

  // ---------------------------------------------------------------- helpers

  /// The `m_vSig` hash of the key a pipe pays e2b crossings to: the core
  /// signs with `SHA-256("bvm.m.key\0" ‖ id)` (`bvm2.cpp`
  /// `DeriveKeyPreimage`), and both pipe shaders use the cid as the id,
  /// for `get_pk` and for the claim's signature alike.
  static String pipeKeyHash(String cid) => crypto.sha256.convert([
    ...ascii.encode('bvm.m.key'),
    0,
    ..._hexBytes(cid),
  ]).toString();

  /// [route] as the registry has it; the registry's equality is by id
  /// only, so every field the BEAM side uses is compared.
  static BridgeRoute _registered(BridgeRoute route) {
    for (final r in kBridgeRoutes) {
      if (r.id == route.id &&
          r.beamPipeCid == route.beamPipeCid &&
          r.beamAssetId == route.beamAssetId &&
          r.shader == route.shader &&
          r.sendMethod == route.sendMethod &&
          r.receiveMethod == route.receiveMethod) {
        return r;
      }
    }
    throw ArgumentError.value(route, 'route', 'not a registered bridge route');
  }

  /// [address] (`0x` optional, any case) as 40 lowercase hex.
  static String _ethAddress(String address) {
    final hex = address.startsWith('0x') ? address.substring(2) : address;
    if (!RegExp(r'^[0-9a-fA-F]{40}$').hasMatch(hex)) {
      throw ArgumentError.value(address, 'ethReceiver', 'not an address');
    }
    final lower = hex.toLowerCase();
    // Ethereum accepts a payout to address zero: the coins would be gone.
    if (lower == '0' * 40) {
      throw ArgumentError.value(address, 'ethReceiver', 'the zero address');
    }
    return lower;
  }

  static void _checkSendAmounts(BridgeRoute r, BigInt amount, BigInt fee) {
    Never refuse(String why) =>
        throw BridgeException(BridgeErrorCode.badAmount, why);
    if (amount <= BigInt.zero) refuse('nothing to move');
    // A zero fee is never relayed: the coins would stay locked on BEAM.
    if (fee <= BigInt.zero) refuse('the bridge fee must be above zero');
    if (amount + fee > _maxAmount) refuse('the amount is too large');
    final max = r.maxGroth;
    if (max != null && (amount > max || fee > max)) {
      refuse('at most ${r.maxCoins} ${r.beamSymbol} per crossing');
    }
    if (amount % r.beamGrid != BigInt.zero || fee % r.beamGrid != BigInt.zero) {
      refuse('${r.beamSymbol} moves in steps of ${r.beamGrid} groth');
    }
  }

  BeamPipePrepared _checkedCall(BeamPipePrepared p) {
    _checked[p] = true;
    return p;
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _tail.then((_) => task());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<BeamInvokeResult> _invoke(BridgeRoute r, String args) => _serial(
    () => _guard(() async {
      final bytes = await _shaders[r.shader]!.load();
      return api.invokeContract(
        createTx: false,
        args: args,
        contractBytes: bytes,
        timeout: timeout,
      );
    }),
  );

  /// A read-only call. Building a transaction here would be a bug, so a
  /// `raw_data` or a started transaction in the answer is refused.
  Future<String> _view(BridgeRoute r, String args) async {
    final res = await _invoke(r, args);
    if (res.rawData != null || res.txId != null) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'a read-only pipe call produced a transaction',
      );
    }
    return res.output;
  }

  /// Builds [args] and runs the checks every pipe transaction shares: one
  /// call, to [r]'s pipe, built from exactly the request, at privilege 0.
  Future<(List<int>, BeamInvokeData)> _build(BridgeRoute r, String args) async {
    final res = await _invoke(r, args);
    if (res.txId != null) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'the core started a transaction while only building one',
      );
    }
    if (res.output.trim().isNotEmpty) {
      try {
        ShaderOutput.decode(res.output);
      } on BeamShaderException catch (e) {
        throw BridgeException(
          BridgeErrorCode.badPipe,
          'the pipe said "${e.message}"',
        );
      } on FormatException catch (e) {
        throw BridgeException(BridgeErrorCode.badPipe, e.message);
      }
    }
    final raw = res.rawData;
    if (raw == null || raw.isEmpty) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'the pipe built no transaction',
      );
    }
    final BeamInvokeData data;
    try {
      data = BeamInvokeData.decode(raw);
    } on FormatException catch (e) {
      throw BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'cannot read the built transaction: ${e.message}',
      );
    }
    _expect(data.entries.length == 1, 'expected one contract call');
    final cid = data.entries.single.contractId;
    _expect(
      cid == r.beamPipeCid,
      'the call targets $cid, not the ${r.beamSymbol} pipe',
    );
    final stored = data.appArgs;
    if (stored != null) {
      final asked = {
        for (final kv in args.split(','))
          kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
      };
      _expect(
        stored.length == asked.length &&
            asked.entries.every((a) => stored[a.key] == a.value),
        'the stored shader args differ from the request',
      );
    }
    _expect(
      (data.appPrivilege ?? 0) == 0,
      'the stored shader would run with wallet keys',
    );
    return (raw, data);
  }

  /// Every failure of the wallet connection as a [BridgeException].
  static Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on BridgeException {
      rethrow;
    } on PinnedShaderException catch (e) {
      throw BridgeException(BridgeErrorCode.badPipe, e.message);
    } on TimeoutException {
      throw const BridgeException(
        BridgeErrorCode.network,
        'the BEAM wallet did not answer in time',
      );
    } on BeamConnectionException catch (e) {
      throw BridgeException(BridgeErrorCode.network, e.message);
    } on BeamRpcException catch (e) {
      throw BridgeException(
        BridgeErrorCode.network,
        'the BEAM wallet refused: ${e.message} (${e.code})',
      );
    } on FormatException catch (e) {
      throw BridgeException(
        BridgeErrorCode.network,
        'the BEAM wallet answered oddly: ${e.message}',
      );
    }
  }

  static void _expect(bool ok, String what) {
    if (!ok) {
      throw BridgeException(BridgeErrorCode.unexpectedTransaction, what);
    }
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _sameFunds(Map<int, BigInt> a, Map<int, BigInt> b) =>
      a.length == b.length && b.entries.every((e) => a[e.key] == e.value);

  static List<int> _hexBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}
