/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The two halves of the bridge, faked from the interfaces only
// (`bridge_sides.dart`): a BEAM wallet whose pipe records messages when
// its sends are mined, and an Ethereum wallet whose locks are mined when
// the test says so. Prices and gas are the ones read on 2026-10-09 16:42
// UTC (06_beam_bridge.md, D). Every address and key here is made up.

import 'dart:async';
import 'dart:typed_data';

import 'package:stackwallet/wallets/bridge/bridge_controller.dart';
import 'package:stackwallet/wallets/bridge/bridge_fees.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

/// A made-up Ethereum address (nobody's).
const kFakeEthAddress = '0x7a3e5b1c2d4f6e8a9b0c1d2e3f4a5b6c7d8e91c4';

/// Someone else's (made up too).
const kOtherEthAddress = '0x00000000000000000000000000000000000c0ffe';

final BigInt groth = BigInt.from(100000000);
final BigInt wei = BigInt.from(10).pow(18);

BigInt beams(num v) => BigInt.from((v * 100000000).round());

/// [v] whole ETH (or DAI) in wei, exactly for up to 8 decimals.
BigInt ethUnits(num v) =>
    BigInt.from((v * 100000000).round()) * BigInt.from(10).pow(10);

final BridgeRoute beamRoute = bridgeRouteById('beam');
final BridgeRoute ethRoute = bridgeRouteById('eth');
final BridgeRoute usdtRoute = bridgeRouteById('usdt');
final BridgeRoute wbtcRoute = bridgeRouteById('wbtc');
final BridgeRoute daiRoute = bridgeRouteById('dai');

class FakeBridgeClock implements BridgeClock {
  FakeBridgeClock([DateTime? start])
    : t = start ?? DateTime.utc(2026, 10, 9, 16, 42);

  DateTime t;

  /// Sleeps never end (a wait that outlives the test).
  bool hold = false;

  @override
  DateTime now() => t;

  @override
  Future<void> sleep(Duration d) {
    if (hold) return Completer<void>().future;
    t = t.add(d);
    return Future.value();
  }

  void advance(Duration d) => t = t.add(d);
}

// ------------------------------------------------------------------- BEAM

enum FakeExecute { ok, throwAfterBroadcast, throwBeforeBroadcast }

class FakeBeamSide implements BeamPipeSide {
  FakeBeamSide({Map<int, BigInt>? available})
    : balances = available ?? {0: beams(5000), 37: beams(250), 36: beams(1)};

  final Map<int, BigInt> balances;

  /// b2e messages per route; id = index + 1.
  final Map<String, List<BeamPipeLocalMessage>> local = {};

  /// e2b messages pushed and not claimed, per route.
  final Map<String, Map<int, BeamPipeRemoteMessage>> remote = {};

  final Map<String, BeamPipeTxStatus> status = {};
  final Map<String, BeamPipePrepared> executed = {};
  final List<String> calls = [];

  /// Runs inside [execute], before anything is "sent" (tests check what
  /// the store holds at that moment).
  void Function(BeamPipePrepared p)? onExecute;

  FakeExecute executeMode = FakeExecute.ok;
  int tip = 4072800;
  int _tx = 0;
  bool keyFails = false;

  static Uint8List keyFor(BridgeRoute r) => Uint8List.fromList([
    for (var i = 0; i < 32; i++) (i * 7 + r.id.length) & 0xff,
    0x01,
  ]);

  List<BeamPipeLocalMessage> localOf(BridgeRoute r) =>
      local.putIfAbsent(r.id, () => []);

  /// A b2e message someone made (another user, or this wallet).
  void addLocal(
    BridgeRoute r, {
    String receiver = kOtherEthAddress,
    required BigInt amount,
    required BigInt fee,
    required int height,
  }) => localOf(r).add(
    BeamPipeLocalMessage(
      receiver: receiver,
      amount: amount,
      relayerFee: fee,
      height: height,
    ),
  );

  /// The relayer brings e2b message [msgId] to BEAM.
  void deliver(BridgeRoute r, int msgId, BigInt amount) =>
      remote.putIfAbsent(r.id, () => {})[msgId] = BeamPipeRemoteMessage(
        amount: amount,
        relayerFee: BigInt.zero,
        receiver: keyFor(r),
      );

  /// Mines [txId] at [height]: a send records its message, a claim takes
  /// its message away.
  void mine(String txId, int height) {
    final p = executed[txId]!;
    status[txId] = BeamPipeTxStatus.completed(height);
    if (p.call == BeamPipeCall.send) {
      addLocal(
        p.route,
        receiver: p.ethReceiver!,
        amount: p.amount,
        fee: p.relayerFee,
        height: height,
      );
    } else {
      remote[p.route.id]?.remove(p.msgId);
    }
  }

  @override
  Future<Uint8List> receiveKey(BridgeRoute route) async {
    calls.add('receiveKey ${route.id}');
    if (keyFails) {
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'The pipe gave a key that is not a point on the curve.',
      );
    }
    return keyFor(route);
  }

  @override
  Future<int> localMessageCount(BridgeRoute route) async =>
      localOf(route).length;

  @override
  Future<BeamPipeLocalMessage?> localMessage(
    BridgeRoute route,
    int msgId,
  ) async {
    calls.add('localMessage ${route.id} $msgId');
    final l = localOf(route);
    return msgId >= 1 && msgId <= l.length ? l[msgId - 1] : null;
  }

  @override
  Future<BeamPipeRemoteMessage?> remoteMessage(
    BridgeRoute route,
    int msgId,
  ) async => remote[route.id]?[msgId];

  @override
  Future<List<BeamPipeIncoming>> incoming(
    BridgeRoute route, {
    int startFrom = 0,
  }) async => [
    for (final e in (remote[route.id] ?? {}).entries)
      if (e.key >= startFrom) BeamPipeIncoming(e.key, e.value.amount),
  ];

  @override
  Future<BeamPipePrepared> prepareSend(
    BridgeRoute route, {
    required String ethReceiver,
    required BigInt amount,
    required BigInt fee,
  }) async {
    calls.add('prepareSend ${route.id} $amount $fee');
    return BeamPipePrepared(
      route: route,
      call: BeamPipeCall.send,
      rawData: const [1, 2, 3],
      networkFee: kBridgeSendFeeGroth,
      amount: amount,
      relayerFee: fee,
      ethReceiver: ethReceiver.toLowerCase(),
    );
  }

  @override
  Future<BeamPipePrepared> prepareReceive(
    BridgeRoute route, {
    required int msgId,
    required BigInt amount,
  }) async {
    calls.add('prepareReceive ${route.id} $msgId');
    if (remote[route.id]?[msgId] == null) {
      // As the pipe shader answers a claim of a message already claimed.
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'msg with current id is absent',
      );
    }
    return BeamPipePrepared(
      route: route,
      call: BeamPipeCall.receive,
      rawData: const [4, 5, 6],
      networkFee: kBridgeClaimFeeGroth,
      amount: amount,
      relayerFee: BigInt.zero,
      msgId: msgId,
    );
  }

  @override
  Future<String> execute(BeamPipePrepared prepared) async {
    if (prepared.sent) {
      throw const BridgeException(BridgeErrorCode.alreadySent, 'sent');
    }
    onExecute?.call(prepared);
    calls.add('execute ${prepared.call.name}');
    if (executeMode == FakeExecute.throwBeforeBroadcast) {
      throw const BridgeException(BridgeErrorCode.network, 'node down');
    }
    prepared.sent = true;
    final id = 'beamtx${++_tx}';
    executed[id] = prepared;
    status[id] = const BeamPipeTxStatus.pending();
    if (executeMode == FakeExecute.throwAfterBroadcast) {
      throw const BridgeException(BridgeErrorCode.network, 'no answer');
    }
    return id;
  }

  @override
  Future<BeamPipeTxStatus> txStatus(String txId) async =>
      status[txId] ?? const BeamPipeTxStatus.pending();

  @override
  Future<int> tipHeight() async => tip;

  @override
  Future<BigInt> available(int assetId) async =>
      balances[assetId] ?? BigInt.zero;
}

// --------------------------------------------------------------- Ethereum

enum FakeSend { ok, throwAfterBroadcast, throwBeforeBroadcast }

class FakeEthSide implements EthPipeSide {
  FakeEthSide({BigInt? eth, Map<String, BigInt>? tokens})
    : ethBal = eth ?? BigInt.parse('42000000000000000'), // 0.042 ETH
      tokenBal =
          tokens ??
          {
            'beam': beams(20000),
            'usdt': BigInt.from(500000000), // 500 USDT
            'wbtc': BigInt.from(100000), // 0.001 WBTC
            'dai': BigInt.parse('300000000000000000000'), // 300 DAI
          };

  BigInt ethBal;
  final Map<String, BigInt> tokenBal;

  /// The allowance each token's pipe has now.
  final Map<String, BigInt> allowance = {};

  final Map<String, List<BridgeFreeze>> frozen = {};
  bool freezeFails = false;
  bool pricesFail = false;
  Duration priceAge = Duration.zero;
  final Set<String> missingPrices = {};
  BridgeClock? clock;

  /// Approval transactions and whether each succeeded once mined (null
  /// while pending).
  final Map<String, bool?> mined = {};

  /// Locks, by hash, once mined.
  final Map<String, EthPipeLock> locks = {};
  final List<UniTxRequest> sent = [];
  final Set<int> paid = {};
  FakeSend sendMode = FakeSend.ok;

  /// Which step (0 based) [sendMode] applies to; null: every step.
  int? sendModeStep;

  /// Approvals are mined (succeeded) as soon as they are sent.
  bool approvalsMineAtOnce = true;
  bool approvalsFail = false;
  int _hash = 0;

  static final fees = UniFees(
    baseFee: BigInt.from(701400000),
    maxPriorityFeePerGas: BigInt.from(429200000),
    maxFeePerGas: BigInt.from(1832100000),
  );

  @override
  String get owner => kFakeEthAddress;

  @override
  Future<List<BridgeFreeze>> freezes(BridgeRoute route) async {
    if (freezeFails) {
      throw const BridgeException(BridgeErrorCode.network, 'no answer');
    }
    return frozen[route.id] ?? const [];
  }

  @override
  Future<BridgeRelayerGas> relayerGas() async => BridgeRelayerGas(
    baseFee: BigInt.from(701400000),
    tip: BigInt.from(429200000),
    at: (clock ?? const SystemBridgeClock()).now(),
  );

  @override
  Future<BridgePrices> prices(List<String> coingeckoIds) async {
    if (pricesFail) {
      throw const BridgeException(BridgeErrorCode.noPrice, 'no prices');
    }
    const all = {
      'ethereum': 2487.25,
      'beam': 0.00783632,
      'wrapped-bitcoin': 82567.0,
      'tether': 0.999262,
      'dai': 0.999917,
    };
    return BridgePrices({
      for (final id in coingeckoIds)
        if (all[id] != null && !missingPrices.contains(id)) id: all[id]!,
    }, (clock ?? const SystemBridgeClock()).now().subtract(priceAge));
  }

  @override
  Future<BigInt> balance(BridgeRoute route) async =>
      route.isNativeEth ? ethBal : tokenBal[route.id] ?? BigInt.zero;

  @override
  Future<BigInt> ethBalance() async => ethBal;

  UniTxRequest _tx(UniTxKind kind, String to, int gas, BigInt value) =>
      UniTxRequest(
        kind: kind,
        to: to,
        data: Uint8List(4),
        value: value,
        gasLimit: BigInt.from(gas),
        fees: fees,
      );

  @override
  Future<EthPipeLockPlan> planLock(
    BridgeRoute route, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  }) async {
    if (value <= BigInt.zero || value % route.ethGrid != BigInt.zero) {
      throw const BridgeException(BridgeErrorCode.badAmount, 'off the grid');
    }
    final need = value + fee;
    final have = allowance[route.id] ?? BigInt.zero;
    final steps = <UniTxRequest>[
      if (!route.isNativeEth && have < need) ...[
        if (have > BigInt.zero && route.id == 'usdt')
          _tx(UniTxKind.approveReset, route.ethToken!, 50000, BigInt.zero),
        _tx(UniTxKind.approve, route.ethToken!, 60000, BigInt.zero),
      ],
      _tx(
        UniTxKind.swap,
        route.ethPipe,
        route.isNativeEth ? 40000 : 75000,
        route.isNativeEth ? need : BigInt.zero,
      ),
    ];
    return EthPipeLockPlan(
      route: route,
      value: value,
      fee: fee,
      receiverKey: receiverKey,
      steps: steps,
      fees: fees,
    );
  }

  @override
  Future<String> send(UniTxRequest tx) async {
    final step = sent.length;
    final mode = sendModeStep == null || sendModeStep == step
        ? sendMode
        : FakeSend.ok;
    if (mode == FakeSend.throwBeforeBroadcast) {
      throw const BridgeException(BridgeErrorCode.network, 'rpc down');
    }
    sent.add(tx);
    final hash = '0x${(++_hash).toRadixString(16).padLeft(64, '0')}';
    if (tx.kind != UniTxKind.swap) {
      mined[hash] = approvalsMineAtOnce ? !approvalsFail : null;
    }
    if (mode == FakeSend.throwAfterBroadcast) {
      throw const BridgeException(BridgeErrorCode.network, 'no answer');
    }
    return hash;
  }

  /// Mines lock [hash] as message [msgId] (or reverted).
  void mineLock(String hash, {int msgId = 222, bool success = true}) =>
      locks[hash] = EthPipeLock(
        hash: hash,
        success: success,
        blockNumber: 26156200,
        msgId: success ? msgId : null,
      );

  @override
  Future<bool?> succeeded(String hash) async => mined[hash];

  @override
  Future<EthPipeLock?> lockResult(
    BridgeRoute route,
    String hash, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  }) async => locks[hash];

  @override
  Future<bool> isPaid(BridgeRoute route, int beamMsgId) async =>
      paid.contains(beamMsgId);
}
