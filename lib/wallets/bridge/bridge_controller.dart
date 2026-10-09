/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge between one BEAM wallet and one Ethereum wallet of the same
// user: what a crossing costs and whether it can go (quote), the checked
// transactions it needs (prepare), sending them after the user's PIN
// (start), and following each crossing to the end, also after a restart
// (resumeAll), from records written before every step that cannot be
// undone (`bridge_store.dart`).
//
// To Ethereum: the BEAM pipe locks amount + fee and records a message; the
// bridge pays the Ethereum wallet about 61 BEAM blocks later. Campfire
// finds the message the send created (the only one above the count read
// before sending with this receiver, amount, fee and block), waits out
// the blocks, then reads the Ethereum pipe's "paid" flag.
//
// To BEAM: the Ethereum pipe takes value + fee (after an exact approval
// for a token); the bridge brings the message to BEAM in a few minutes;
// the BEAM wallet claims it with its own key.
//
// The rule from the BEAM DEX confirmation holds everywhere: a transaction
// that may have reached the network is never sent again by Campfire. When
// a wallet throws after it may have broadcast, the crossing is "unknown"
// and Campfire keeps looking for it on both chains.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'bridge_crossing.dart';
import 'bridge_fees.dart';
import 'bridge_routes.dart';
import 'bridge_sides.dart';
import 'bridge_quote.dart';
import 'bridge_store.dart';

export 'bridge_quote.dart';

/// The time the controller reads, and how it waits.
abstract class BridgeClock {
  DateTime now();
  Future<void> sleep(Duration d);
}

class SystemBridgeClock implements BridgeClock {
  const SystemBridgeClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> sleep(Duration d) => Future<void>.delayed(d);
}

/// How often each kind of crossing is looked at.
class BridgePolling {
  const BridgePolling({
    this.beamTx = const Duration(seconds: 20),
    this.blocks = const Duration(seconds: 60),
    this.paid = const Duration(seconds: 60),
    this.toBeam = const Duration(seconds: 30),
    this.ethReceipt = const Duration(seconds: 15),
    this.tick = const Duration(seconds: 5),
  });

  /// A BEAM transaction (send or claim) until it is mined.
  final Duration beamTx;

  /// The 61 confirmations before the bridge pays.
  final Duration blocks;

  /// The Ethereum pipe's "paid" flag.
  final Duration paid;

  /// A crossing to BEAM, until it can be claimed.
  final Duration toBeam;

  /// An Ethereum transaction until it is mined.
  final Duration ethReceipt;

  /// How often the controller checks what is due.
  final Duration tick;
}

/// The largest amount either chain's pipe adds safely (BEAM's u64).
final BigInt _u63 = BigInt.one << 63;

// ------------------------------------------------------------- controller

class BridgeController extends ChangeNotifier {
  BridgeController({
    required this.beam,
    required this.eth,
    required this.store,
    required this.beamWalletId,
    required this.ethWalletId,
    BridgeClock? clock,
    this.polling = const BridgePolling(),
    this.autoPoll = true,
  }) : clock = clock ?? const SystemBridgeClock();

  final BeamPipeSide beam;
  final EthPipeSide eth;
  final BridgeStore store;
  final String beamWalletId;
  final String ethWalletId;
  final BridgeClock clock;
  final BridgePolling polling;

  /// Poll on a timer after [resumeAll] (tests call [pollDue] themselves).
  final bool autoPoll;

  final Map<String, BridgeCrossing> _records = {};
  final Map<String, DateTime> _dueAt = {};
  final Set<String> _busy = {};
  final Map<String, ({BridgeConditions c, DateTime at})> _conditions = {};
  final Map<String, Uint8List> _keys = {};
  Timer? _timer;
  bool _resumed = false;
  bool _paused = false;
  bool _disposed = false;
  int? _tip;

  static final _random = math.Random.secure();

  /// The BEAM chain tip last read, for "blocks left".
  int? get tipHeight => _tip;

  /// Whether polling is paused (the app is in the background).
  bool get paused => _paused;

  /// This wallet pair's crossings: open ones first, newest first.
  List<BridgeCrossing> get crossings {
    final list = _records.values.toList()
      ..sort((a, b) {
        if (a.isOpen != b.isOpen) return a.isOpen ? -1 : 1;
        return b.createdAt.compareTo(a.createdAt);
      });
    return list;
  }

  BridgeCrossing? crossing(String id) => _records[id];

  /// BEAM blocks left before the bridge pays [c] (to Ethereum), when the
  /// tip is known.
  int? blocksLeft(BridgeCrossing c) {
    final h = c.height;
    final tip = _tip;
    if (h == null || tip == null) return null;
    final left = h + kBridgeBeamConfirmations - tip;
    return left < 0 ? 0 : left;
  }

  bool _mine(BridgeCrossing c) =>
      c.beamWalletId == beamWalletId && c.ethWalletId == ethWalletId;

  // ------------------------------------------------------------- reading

  /// Freezes, the bridge fee and its prices for [route] going [direction],
  /// read at most once a minute unless [refresh].
  Future<BridgeConditions> conditions(
    BridgeRoute route,
    BridgeDirection direction, {
    bool refresh = false,
  }) async {
    final key = '${route.id}-${direction.name}';
    final cached = _conditions[key];
    final now = clock.now();
    if (!refresh &&
        cached != null &&
        now.difference(cached.at) < const Duration(minutes: 1)) {
      return cached.c;
    }
    final c = await _readConditions(route, direction);
    _conditions[key] = (c: c, at: now);
    return c;
  }

  Future<BridgeConditions> _readConditions(
    BridgeRoute route,
    BridgeDirection direction,
  ) async {
    final now = clock.now();
    BridgeConditions blocked(BridgeBlock b, {List<BridgeFreeze>? f}) =>
        BridgeConditions(
          route: route,
          direction: direction,
          at: now,
          freezes: f ?? const [],
          block: b,
        );

    final List<BridgeFreeze> freezes;
    try {
      freezes = await eth.freezes(route);
    } catch (_) {
      // Fail closed: a payout that cannot be made would strand the coins.
      return blocked(
        BridgeBlock(
          BridgeBlockCode.network,
          "Couldn't check that ${route.ethSymbol} can be moved right now",
          'Campfire asks Ethereum before every crossing whether '
              '${route.ethSymbol} is paused. Your Ethereum node did not '
              'answer. Nothing was sent; try again in a minute.',
        ),
      );
    }
    if (freezes.isNotEmpty) {
      return blocked(
        BridgeBlock(
          BridgeBlockCode.frozen,
          '${route.name} cannot be moved right now',
          freezes.map((f) => f.reason).join('\n'),
        ),
        f: freezes,
      );
    }

    final toEthereum = direction == BridgeDirection.toEthereum;
    BridgePrices? prices;
    BridgeRelayerGas? gas;
    try {
      prices = await eth.prices(
        {'ethereum', 'beam', route.coingeckoId}.toList(),
      );
      if (toEthereum) gas = await eth.relayerGas();
    } catch (_) {
      // WBEAM to BEAM pays a fixed 0.02 WBEAM: no price needed.
      if (toEthereum || !route.isBeam) return blocked(_noPrice);
    }
    final maxAge = toEthereum
        ? kBridgeToEthereumPriceAge
        : kBridgeToBeamPriceAge;
    if (prices != null && now.difference(prices.at) > maxAge) {
      if (toEthereum || !route.isBeam) return blocked(_noPrice);
      prices = null;
    }
    final fee = toEthereum
        ? b2eRelayerFeeGroth(route, gas!, prices!)
        : e2bRelayerFee(route, prices ?? BridgePrices(const {}, now));
    return BridgeConditions(
      route: route,
      direction: direction,
      at: now,
      fee: fee,
      feeNow: toEthereum
          ? b2eRelayerFeeGroth(route, gas!, prices!, margin: 1)
          : null,
      prices: prices,
      gas: gas,
      block: fee == null ? _noPrice : null,
    );
  }

  static const _noPrice = BridgeBlock(
    BridgeBlockCode.noPrice,
    'Prices are unavailable right now',
    'The bridge fee follows the price of the coin and of Ethereum gas, '
        'and Campfire could not read them. Nothing was sent; try again '
        'in a minute.',
  );

  /// What [route] going [direction] can draw on.
  Future<BridgeBalances> balances(
    BridgeRoute route,
    BridgeDirection direction,
  ) async {
    if (direction == BridgeDirection.toEthereum) {
      final beamBal = await beam.available(0);
      return BridgeBalances(
        source: route.isBeam
            ? beamBal
            : await beam.available(route.beamAssetId),
        beam: beamBal,
        eth: null,
      );
    }
    final r = await Future.wait([
      eth.balance(route),
      eth.ethBalance(),
      beam.available(0),
    ]);
    return BridgeBalances(source: r[0], beam: r[2], eth: r[1]);
  }

  Future<Uint8List> _receiveKey(BridgeRoute route) async =>
      _keys[route.id] ??= await beam.receiveKey(route);

  // --------------------------------------------------------------- quote

  /// What moving [amount] (source units) of [route] going [direction]
  /// does, and whether it can go. Never throws for a reason the user can
  /// act on: that is in [BridgeQuote.block].
  Future<BridgeQuote> quote(
    BridgeRoute route,
    BridgeDirection direction,
    BigInt amount,
  ) async {
    final cond = await conditions(route, direction);
    BridgeBalances bal;
    try {
      bal = await balances(route, direction);
    } catch (_) {
      bal = BridgeBalances(
        source: BigInt.zero,
        beam: BigInt.zero,
        eth: BigInt.zero,
      );
      return _quoteOf(
        route,
        direction,
        amount,
        cond,
        bal,
        block: const BridgeBlock(
          BridgeBlockCode.network,
          "Couldn't read your balances",
          'One of your wallets did not answer. Nothing was sent; try again '
              'in a minute.',
        ),
      );
    }
    return direction == BridgeDirection.toEthereum
        ? _quoteToEthereum(route, amount, cond, bal)
        : _quoteToBeam(route, amount, cond, bal);
  }

  BridgeQuote _quoteOf(
    BridgeRoute route,
    BridgeDirection direction,
    BigInt amount,
    BridgeConditions cond,
    BridgeBalances bal, {
    BridgeBlock? block,
    BigInt? receives,
    BigInt? beamNetworkFee,
    EthPipeLockPlan? plan,
    Uint8List? key,
    List<BridgeWarning> warnings = const [],
  }) => BridgeQuote(
    route: route,
    direction: direction,
    amount: amount,
    fee: cond.fee,
    feeNow: cond.feeNow,
    receives:
        receives ??
        (direction == BridgeDirection.toEthereum
            ? route.grothToEth(amount)
            : route.ethToGroth(amount)),
    beamNetworkFee:
        beamNetworkFee ??
        (direction == BridgeDirection.toEthereum
            ? kBridgeSendFeeGroth
            : kBridgeClaimFeeGroth),
    plan: plan,
    receiveKey: key,
    ethAddress: eth.owner,
    balances: bal,
    prices: cond.prices,
    warnings: warnings,
    block: block,
    at: clock.now(),
  );

  BridgeQuote _quoteToEthereum(
    BridgeRoute route,
    BigInt raw,
    BridgeConditions cond,
    BridgeBalances bal,
  ) {
    final amount = floorToGrid(raw, route.beamGrid);
    final fee = cond.fee;
    final sym = route.beamSymbol;
    final warnings = <BridgeWarning>[
      if (fee != null &&
          amount > fee &&
          _share(fee, amount) > kBridgeFeeWarnShare)
        BridgeWarning(
          BridgeWarningCode.highFee,
          'The bridge fee is ${_percent(_share(fee, amount))} of what you '
              'move',
          'It pays for the bridge operator\'s Ethereum transaction, which '
              'costs the same for any amount. Moving more at once costs '
              'less per coin.',
        ),
    ];
    BridgeBlock? block = cond.block;
    if (block == null && amount <= BigInt.zero) {
      block = BridgeBlock(
        BridgeBlockCode.noAmount,
        'Enter how much $sym to move.',
      );
    }
    if (block == null && amount <= fee!) {
      block = BridgeBlock(
        BridgeBlockCode.belowFee,
        'The bridge fee is more than the amount',
        'The bridge fee is ${_coin(fee, 8)} $sym right now. Move more '
            'than that.',
      );
    }
    final max = route.maxGroth;
    if (block == null && max != null && (amount > max || fee! > max)) {
      block = BridgeBlock(
        BridgeBlockCode.aboveMax,
        'At most ${_coin(max, 8)} $sym per move',
        'The bridge refuses anything larger for good, and the $sym would '
            'stay locked. Split it into several moves.',
      );
    }
    if (block == null && amount + fee! >= _u63) {
      block = const BridgeBlock(
        BridgeBlockCode.aboveMax,
        'That amount is too large to move',
      );
    }
    if (block == null) {
      final f = fee!;
      if (route.isBeam) {
        final need = amount + f + kBridgeSendFeeGroth;
        if (need > bal.source) {
          block = BridgeBlock(
            BridgeBlockCode.notEnough,
            'Not enough BEAM',
            'With the fees this needs ${_coin(need, 8)} BEAM. Your wallet '
                'has ${_coin(bal.source, 8)} BEAM.',
          );
        }
      } else if (amount + f > bal.source) {
        block = BridgeBlock(
          BridgeBlockCode.notEnough,
          'Not enough $sym',
          'With the bridge fee this needs ${_coin(amount + f, 8)} $sym. '
              'Your wallet has ${_coin(bal.source, 8)} $sym.',
        );
      } else if (kBridgeSendFeeGroth > bal.beam) {
        block = BridgeBlock(
          BridgeBlockCode.noBeamForFee,
          'Your BEAM wallet needs ${_coin(kBridgeSendFeeGroth, 8)} BEAM for '
              'the network fee',
          'It has ${_coin(bal.beam, 8)} BEAM. Receive a little BEAM first.',
        );
      }
    }
    return _quoteOf(
      route,
      BridgeDirection.toEthereum,
      amount,
      cond,
      bal,
      block: block,
      warnings: warnings,
    );
  }

  Future<BridgeQuote> _quoteToBeam(
    BridgeRoute route,
    BigInt raw,
    BridgeConditions cond,
    BridgeBalances bal,
  ) async {
    final value = floorToGrid(raw, route.ethGrid);
    final fee = cond.fee;
    final sym = route.ethSymbol;
    final dec = route.ethDecimals;
    final receives = route.ethToGroth(value);
    BridgeBlock? block = cond.block;
    if (block == null && value <= BigInt.zero) {
      block = BridgeBlock(
        BridgeBlockCode.noAmount,
        'Enter how much $sym to move.',
      );
    }
    if (block == null && receives <= BigInt.zero) {
      block = BridgeBlock(
        BridgeBlockCode.badAmount,
        'Too small to arrive on BEAM',
        'BEAM counts ${route.beamSymbol} in 8 decimals. Move at least '
            '${_coin(route.ethGrid, dec)} $sym.',
      );
    }
    if (block == null && value + fee! > bal.source) {
      block = BridgeBlock(
        BridgeBlockCode.notEnough,
        'Not enough $sym',
        'With the bridge fee this needs ${_coin(value + fee, dec)} $sym. '
            'Your wallet has ${_coin(bal.source, dec)} $sym.',
      );
    }
    EthPipeLockPlan? plan;
    Uint8List? key;
    if (block == null) {
      try {
        key = await _receiveKey(route);
        plan = await eth.planLock(
          route,
          value: value,
          fee: fee!,
          receiverKey: key,
        );
      } on BridgeException catch (e) {
        block = switch (e.code) {
          BridgeErrorCode.badAmount => BridgeBlock(
            BridgeBlockCode.badAmount,
            "This amount can't be moved",
            e.message,
          ),
          BridgeErrorCode.network => BridgeBlock(
            BridgeBlockCode.network,
            "Couldn't price the Ethereum network fee",
            e.message,
          ),
          // A key or an answer Campfire does not trust: refuse, say so.
          _ => BridgeBlock(
            BridgeBlockCode.network,
            "Couldn't check the bridge from these wallets",
            '${e.message} Nothing was sent.',
          ),
        };
      } catch (_) {
        block = const BridgeBlock(
          BridgeBlockCode.network,
          "Couldn't price the Ethereum network fee",
          'Your Ethereum node or your BEAM wallet did not answer. Nothing '
              'was sent; try again in a minute.',
        );
      }
    }
    if (block == null && plan != null) {
      final gas = plan.maxGasCost;
      final need = gas + (route.isNativeEth ? value + fee! : BigInt.zero);
      if (need > bal.eth!) {
        block = BridgeBlock(
          BridgeBlockCode.noEthForGas,
          route.isNativeEth
              ? 'Not enough ETH'
              : 'Not enough ETH for the Ethereum network fee',
          route.isNativeEth
              ? 'With the fees this needs up to ${_coin(need, 18)} ETH. '
                    'Your wallet has ${_coin(bal.eth!, 18)} ETH.'
              : 'It can cost up to ${_coin(gas, 18)} ETH. Your Ethereum '
                    'wallet has ${_coin(bal.eth!, 18)} ETH.',
        );
      }
    }
    if (block == null && bal.beam < kBridgeClaimFeeGroth) {
      block = BridgeBlock(
        BridgeBlockCode.noClaimFee,
        'Your BEAM wallet needs ${_coin(kBridgeClaimFeeGroth, 8)} BEAM to '
            'collect it',
        'Coins moved to BEAM are collected with a BEAM transaction, and its '
            'network fee is ${_coin(kBridgeClaimFeeGroth, 8)} BEAM. Your BEAM '
            'wallet has ${_coin(bal.beam, 8)} BEAM. Receive a little BEAM '
            'first, then move.',
      );
    }
    return _quoteOf(
      route,
      BridgeDirection.toBeam,
      value,
      cond,
      bal,
      block: block,
      receives: receives,
      plan: plan,
      key: key,
    );
  }

  /// The most of [route] that can leave going [direction], with every fee
  /// kept back; zero when nothing can (or the fee is unknown).
  Future<BigInt> maxAmount(BridgeRoute route, BridgeDirection direction) async {
    final cond = await conditions(route, direction);
    final fee = cond.fee;
    if (fee == null) return BigInt.zero;
    final bal = await balances(route, direction);
    var max = bal.source - fee;
    if (direction == BridgeDirection.toEthereum) {
      if (route.isBeam) max -= kBridgeSendFeeGroth;
      final cap = route.maxGroth;
      if (cap != null && max > cap) max = cap;
    } else if (route.isNativeEth) {
      // Keep the network fee of the lock itself (priced on a tiny value).
      try {
        final plan = await eth.planLock(
          route,
          value: route.ethGrid,
          fee: fee,
          receiverKey: await _receiveKey(route),
        );
        max -= plan.maxGasCost;
      } catch (_) {
        return BigInt.zero;
      }
    }
    if (max <= BigInt.zero) return BigInt.zero;
    return floorToGrid(max, route.sourceGrid(direction));
  }

  // -------------------------------------------------------------- prepare

  /// Builds and checks what [q] sends: to Ethereum, the BEAM transaction
  /// (its network fee decoded from it); to BEAM, the key read again and
  /// the Ethereum transactions priced again. Nothing is sent.
  Future<BridgePrepared> prepare(BridgeQuote q) async {
    final block = q.block;
    if (block != null) {
      throw BridgeException(BridgeErrorCode.badAmount, block.title);
    }
    final route = q.route;
    final fee = q.fee!;
    if (q.toEthereum) {
      final p = await beam.prepareSend(
        route,
        ethReceiver: eth.owner,
        amount: q.amount,
        fee: fee,
      );
      if (p.route != route ||
          p.call != BeamPipeCall.send ||
          p.amount != q.amount ||
          p.relayerFee != fee ||
          p.ethReceiver?.toLowerCase() != eth.owner.toLowerCase()) {
        throw const BridgeException(
          BridgeErrorCode.unexpectedTransaction,
          'The BEAM wallet built a transaction that is not the one asked '
          'for. Nothing was sent.',
        );
      }
      return BridgePrepared(quote: q, send: p, at: clock.now());
    }
    final key = await beam.receiveKey(route);
    _keys[route.id] = key;
    if (q.receiveKey != null && !_sameBytes(key, q.receiveKey!)) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'Your BEAM wallet gave a different key than a moment ago. Nothing '
        'was sent.',
      );
    }
    final plan = await eth.planLock(
      route,
      value: q.amount,
      fee: fee,
      receiverKey: key,
    );
    if (plan.route != route ||
        plan.value != q.amount ||
        plan.fee != fee ||
        !_sameBytes(plan.receiverKey, key) ||
        plan.steps.isEmpty) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'The Ethereum transactions are not the ones asked for. Nothing was '
        'sent.',
      );
    }
    final ethBal = await eth.ethBalance();
    final need =
        plan.maxGasCost + (route.isNativeEth ? q.amount + fee : BigInt.zero);
    if (need > ethBal) {
      throw BridgeException(
        BridgeErrorCode.badAmount,
        'The Ethereum network fee went up: this now needs up to '
        '${_coin(need, 18)} ETH and your wallet has ${_coin(ethBal, 18)} '
        'ETH. Nothing was sent.',
      );
    }
    return BridgePrepared(
      quote: q,
      receiveKey: key,
      plan: plan,
      at: clock.now(),
    );
  }

  // ---------------------------------------------------------------- start

  /// Sends [p] (after the user's PIN) and returns its crossing, which
  /// Campfire then follows. To Ethereum the BEAM transaction is handed to
  /// the wallet before this returns; to BEAM the Ethereum transactions go
  /// out one by one after it returns (the crossing says which).
  ///
  /// Throws only when nothing was sent.
  Future<BridgeCrossing> start(
    BridgePrepared p, {
    bool autoClaim = false,
  }) async {
    if (_disposed) throw StateError('BridgeController disposed');
    if (clock.now().difference(p.at) > kBridgeReviewAge) {
      throw const BridgeReviewExpired();
    }
    // Every known message id of this pair, before any new one is taken.
    await resumeAll();
    final q = p.quote;
    final now = clock.now();
    if (q.toEthereum) {
      final send = p.send!;
      if (send.sent) {
        throw const BridgeException(
          BridgeErrorCode.alreadySent,
          'This crossing was already sent.',
        );
      }
      // Read before sending: the send's message is above it.
      final countBefore = await beam.localMessageCount(q.route);
      var c = BridgeCrossing(
        id: _newId(now),
        routeId: q.route.id,
        direction: BridgeDirection.toEthereum,
        state: BridgeCrossingState.sending,
        amount: q.amount,
        receives: q.receives,
        relayerFee: q.fee!,
        beamNetworkFee: send.networkFee,
        beamWalletId: beamWalletId,
        ethWalletId: ethWalletId,
        ethAddress: eth.owner,
        countBefore: countBefore,
        createdAt: now,
        updatedAt: now,
      );
      await _save(c);
      try {
        final txId = await beam.execute(send);
        c = c.copyWith(
          state: BridgeCrossingState.sent,
          beamTxId: txId,
          updatedAt: clock.now(),
        );
      } catch (e) {
        c = c.copyWith(
          state: BridgeCrossingState.unknown,
          lastError: _plain(e),
          updatedAt: clock.now(),
        );
      }
      await _saveQuietly(c);
      _schedule(c, polling.beamTx);
      return c;
    }

    final plan = p.plan!;
    final c = BridgeCrossing(
      id: _newId(now),
      routeId: q.route.id,
      direction: BridgeDirection.toBeam,
      state: plan.steps.length > 1
          ? BridgeCrossingState.approving
          : BridgeCrossingState.locking,
      amount: q.amount,
      receives: q.receives,
      relayerFee: q.fee!,
      beamNetworkFee: kBridgeClaimFeeGroth,
      ethNetworkFee: plan.maxGasCost,
      beamWalletId: beamWalletId,
      ethWalletId: ethWalletId,
      ethAddress: eth.owner,
      beamReceiveKey: _hex(p.receiveKey!),
      autoClaim: autoClaim,
      createdAt: now,
      updatedAt: now,
    );
    await _save(c);
    unawaited(
      _sendLockSteps(c, plan).catchError((Object e) {
        // Every step records its own failure; this is a bug's last net.
        debugPrint('Bridge: lock steps of ${c.id} stopped: $e');
      }),
    );
    return c;
  }

  /// The approvals (waiting for each to be mined), then the lock.
  Future<void> _sendLockSteps(
    BridgeCrossing start,
    EthPipeLockPlan plan,
  ) async {
    var c = start;
    final steps = plan.steps;
    for (var i = 0; i < steps.length; i++) {
      if (_disposed) return; // still "approving": ends as nothing locked
      final isLock = i == steps.length - 1;
      if (isLock && c.state != BridgeCrossingState.locking) {
        c = c.copyWith(
          state: BridgeCrossingState.locking,
          updatedAt: clock.now(),
        );
        if (!await _saveQuietly(c)) {
          // Not written, so not sent.
          c = c.copyWith(
            state: BridgeCrossingState.lockFailed,
            lastError:
                'Campfire could not write to this device\'s storage, so it '
                'did not send your ${c.route.ethSymbol}. Nothing was moved.',
            finishedAt: clock.now(),
          );
          _records[c.id] = c;
          notifyListeners();
          return;
        }
      }
      final String hash;
      try {
        hash = await eth.send(steps[i]);
      } catch (e) {
        c = isLock
            ? c.copyWith(
                state: BridgeCrossingState.unknown,
                lastError: _plain(e),
                updatedAt: clock.now(),
              )
            : c.copyWith(
                state: BridgeCrossingState.lockFailed,
                lastError:
                    'Letting the bridge take ${c.route.ethSymbol} did not go '
                    'through, so nothing was moved. (${_plain(e)})',
                updatedAt: clock.now(),
                finishedAt: clock.now(),
              );
        await _saveQuietly(c);
        if (isLock) _schedule(c, polling.toBeam);
        return;
      }
      if (isLock) {
        c = c.copyWith(lockHash: hash, updatedAt: clock.now());
        await _saveQuietly(c);
        _schedule(c, polling.ethReceipt);
        return;
      }
      c = c.copyWith(
        approveHashes: [...c.approveHashes, hash],
        updatedAt: clock.now(),
      );
      if (!await _saveQuietly(c)) return;
      final until = clock.now().add(BridgeTiming.approveWait);
      bool? ok;
      while (true) {
        ok = await eth
            .succeeded(hash)
            .then<bool?>((v) => v, onError: (Object _) => null);
        if (ok != null || _disposed) break;
        if (clock.now().isAfter(until)) break;
        await clock.sleep(polling.ethReceipt);
      }
      if (_disposed) return;
      if (ok != true) {
        c = c.copyWith(
          state: BridgeCrossingState.lockFailed,
          lastError: ok == false
              ? 'Letting the bridge take ${c.route.ethSymbol} failed on '
                    'Ethereum, so nothing was moved. Only its network fee '
                    'was spent.'
              : 'Letting the bridge take ${c.route.ethSymbol} was not '
                    'confirmed within 30 minutes, so nothing was moved.',
          updatedAt: clock.now(),
          finishedAt: clock.now(),
        );
        await _saveQuietly(c);
        return;
      }
    }
  }

  // ---------------------------------------------------------------- claim

  /// Builds the claim of [id] (delivered to BEAM) and checks it. Nothing is
  /// sent; [claim] sends it after the user's PIN.
  Future<BeamPipePrepared> prepareClaim(String id) =>
      _prepareClaim(_records[id]);

  Future<BeamPipePrepared> _prepareClaim(BridgeCrossing? c) async {
    if (c == null || c.state != BridgeCrossingState.delivered) {
      throw const BridgeException(
        BridgeErrorCode.badAmount,
        'There is nothing to collect for this crossing right now.',
      );
    }
    final have = await beam.available(0);
    if (have < kBridgeClaimFeeGroth) {
      throw BridgeException(
        BridgeErrorCode.badAmount,
        'Your BEAM wallet needs ${_coin(kBridgeClaimFeeGroth, 8)} BEAM for '
        'the network fee of collecting it, and has ${_coin(have, 8)} BEAM. '
        'Receive a little BEAM first.',
      );
    }
    final BeamPipePrepared p;
    try {
      p = await beam.prepareReceive(
        c.route,
        msgId: c.msgId!,
        amount: c.receives,
      );
    } on BridgeException catch (e) {
      // The pipe no longer has it: it was collected, by us or elsewhere.
      if (e.code != BridgeErrorCode.badPipe ||
          await beam.remoteMessage(c.route, c.msgId!) != null) {
        rethrow;
      }
      final ours =
          c.claimTxId != null &&
          (await beam.txStatus(c.claimTxId!)).state ==
              BeamPipeTxState.completed;
      await _saveQuietly(
        c.copyWith(
          state: BridgeCrossingState.claimed,
          lastError: ours
              ? null
              : 'Collected outside this screen (on another device with '
                    'the same wallet, perhaps).',
          clearError: ours,
          updatedAt: clock.now(),
          finishedAt: clock.now(),
        ),
      );
      throw const BridgeException(
        BridgeErrorCode.alreadySent,
        'It was already collected: it is in your BEAM wallet.',
      );
    }
    if (p.route != c.route ||
        p.call != BeamPipeCall.receive ||
        p.msgId != c.msgId ||
        p.amount != c.receives) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'The BEAM wallet built a claim that is not the one asked for. '
        'Nothing was sent.',
      );
    }
    return p;
  }

  /// Sends the claim [p] of [id] (after the user's PIN, or by itself when
  /// the user chose to collect automatically).
  Future<BridgeCrossing> claim(String id, BeamPipePrepared p) =>
      _claim(_records[id]!, p);

  Future<BridgeCrossing> _claim(BridgeCrossing from, BeamPipePrepared p) async {
    var c = from;
    if (c.state != BridgeCrossingState.delivered || p.sent) {
      throw const BridgeException(
        BridgeErrorCode.alreadySent,
        'This claim was already sent.',
      );
    }
    c = c.copyWith(
      state: BridgeCrossingState.claiming,
      claimStartedAt: clock.now(),
      updatedAt: clock.now(),
      beamNetworkFee: p.networkFee,
      clearError: true,
    );
    await _save(c);
    try {
      final txId = await beam.execute(p);
      c = c.copyWith(claimTxId: txId, updatedAt: clock.now());
    } catch (e) {
      // It may have gone out: Campfire watches the message instead.
      c = c.copyWith(lastError: _plain(e), updatedAt: clock.now());
    }
    await _saveQuietly(c);
    _schedule(c, polling.beamTx);
    return c;
  }

  // ------------------------------------------------------------- tracking

  /// Loads this wallet pair's crossings and follows the open ones. A
  /// crossing caught between steps by a restart is settled first: one
  /// that was about to approve sent nothing; one that was sending may
  /// have sent, and is looked for.
  Future<void> resumeAll() async {
    if (_resumed || _disposed) return;
    _resumed = true;
    for (final stored in await store.all()) {
      if (!_mine(stored)) continue;
      var c = stored;
      if (c.isOpen) {
        c = _afterRestart(c);
        if (!identical(c, stored)) await _saveQuietly(c);
        _dueAt[c.id] = clock.now();
      }
      _records[c.id] = c;
    }
    _startTimer();
    notifyListeners();
    if (autoPoll && !_paused) unawaited(pollDue());
  }

  BridgeCrossing _afterRestart(BridgeCrossing c) {
    final now = clock.now();
    switch (c.state) {
      case BridgeCrossingState.approving:
        // The lock is only sent after this record says "locking".
        return c.copyWith(
          state: BridgeCrossingState.lockFailed,
          lastError:
              'Campfire was closed before your ${c.route.ethSymbol} was '
              'sent, so nothing was moved. Start again: the permission you '
              'gave is kept, so it is one step this time.',
          updatedAt: now,
          finishedAt: now,
        );
      case BridgeCrossingState.sending:
        return c.copyWith(
          state: BridgeCrossingState.unknown,
          lastError: 'Campfire was closed while sending.',
          updatedAt: now,
        );
      case BridgeCrossingState.locking when c.lockHash == null:
        return c.copyWith(
          state: BridgeCrossingState.unknown,
          lastError: 'Campfire was closed while sending.',
          updatedAt: now,
        );
      default:
        return c;
    }
  }

  /// Stops polling while the app is in the background.
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// Polls again, everything that is due first.
  void resume() {
    if (!_paused) return;
    _paused = false;
    _startTimer();
    unawaited(pollDue());
  }

  void _startTimer() {
    if (!autoPoll || _paused || _disposed || _timer != null) return;
    _timer = Timer.periodic(polling.tick, (_) => unawaited(pollDue()));
  }

  void _schedule(BridgeCrossing c, Duration after) {
    _dueAt[c.id] = clock.now().add(after);
    _startTimer();
  }

  /// Looks at every open crossing whose turn it is.
  Future<void> pollDue() async {
    if (_disposed || _paused) return;
    final now = clock.now();
    final due = [
      for (final c in _records.values)
        if (c.isOpen &&
            !_busy.contains(c.id) &&
            !(_dueAt[c.id]?.isAfter(now) ?? false))
          c.id,
    ];
    for (final id in due) {
      await poll(id);
    }
  }

  /// Looks at crossing [id] once, now, and schedules the next look.
  Future<BridgeCrossing?> poll(String id) async {
    final c = _records[id];
    if (c == null || !c.isOpen || _disposed || !_busy.add(id)) return c;
    try {
      final (next, wait) = c.toEthereum
          ? await _stepToEthereum(c)
          : await _stepToBeam(c);
      if (!_sameRecord(next, c)) await _saveQuietly(next);
      if (next.isOpen) _dueAt[id] = clock.now().add(wait);
      return next;
    } catch (_) {
      // A node that did not answer: the same question next time.
      _dueAt[id] = clock.now().add(polling.blocks);
      return c;
    } finally {
      _busy.remove(id);
    }
  }

  Future<(BridgeCrossing, Duration)> _stepToEthereum(BridgeCrossing c) async {
    final route = c.route;
    switch (c.state) {
      case BridgeCrossingState.sent:
        final status = await beam.txStatus(c.beamTxId!);
        switch (status.state) {
          case BeamPipeTxState.pending:
            return (c, polling.beamTx);
          case BeamPipeTxState.failed:
            return (
              c.copyWith(
                state: BridgeCrossingState.failed,
                lastError: status.reason ?? 'The BEAM transaction failed.',
                updatedAt: clock.now(),
                finishedAt: clock.now(),
              ),
              polling.beamTx,
            );
          case BeamPipeTxState.completed:
            final h = status.height!;
            final msgId = await _findLocalMessage(c, height: h);
            if (msgId == null) {
              return (c.copyWith(height: h), polling.beamTx);
            }
            final found = c.copyWith(
              state: BridgeCrossingState.confirmed,
              msgId: msgId,
              height: h,
              updatedAt: clock.now(),
              clearError: true,
            );
            return _stepToEthereum(found);
        }
      case BridgeCrossingState.unknown:
      case BridgeCrossingState.sending:
        if (c.beamTxId != null) {
          return _stepToEthereum(c.copyWith(state: BridgeCrossingState.sent));
        }
        // No transaction id: look for the message it would have made.
        final found = await _findLocalMessageAnyHeight(c);
        if (found == null) return (c, polling.blocks);
        return _stepToEthereum(
          c.copyWith(
            state: BridgeCrossingState.confirmed,
            msgId: found.$1,
            height: found.$2,
            updatedAt: clock.now(),
            clearError: true,
          ),
        );
      case BridgeCrossingState.confirmed:
      case BridgeCrossingState.waitingForGas:
        final tip = await beam.tipHeight();
        _tip = tip;
        final due = c.height! + kBridgeBeamConfirmations;
        if (tip < due) {
          notifyListeners(); // blocks left changed
          return (c, polling.blocks);
        }
        final dueAt = c.dueAt ?? clock.now();
        var next = c.dueAt == null ? c.copyWith(dueAt: dueAt) : c;
        if (await eth.isPaid(route, c.msgId!)) {
          return (
            next.copyWith(
              state: BridgeCrossingState.paid,
              updatedAt: clock.now(),
              finishedAt: clock.now(),
              clearError: true,
            ),
            polling.paid,
          );
        }
        if (next.state == BridgeCrossingState.confirmed &&
            clock.now().difference(dueAt) >= BridgeTiming.gasWait) {
          next = next.copyWith(
            state: BridgeCrossingState.waitingForGas,
            updatedAt: clock.now(),
          );
        }
        return (next, polling.paid);
      default:
        return (c, polling.blocks);
    }
  }

  /// The message the send of [c] made: above [BridgeCrossing.countBefore],
  /// to [BridgeCrossing.ethAddress], with its amount and fee, mined at
  /// [height], and not already another crossing's.
  Future<int?> _findLocalMessage(
    BridgeCrossing c, {
    required int height,
  }) async {
    final matches = await _localMatches(c, height: height);
    return matches.isEmpty ? null : matches.first.$1;
  }

  Future<(int, int)?> _findLocalMessageAnyHeight(BridgeCrossing c) async {
    final matches = await _localMatches(c);
    return matches.isEmpty ? null : matches.first;
  }

  /// Every match, lowest id first: two identical sends in one block pay
  /// the same address the same amount, so either may be either.
  Future<List<(int, int)>> _localMatches(
    BridgeCrossing c, {
    int? height,
  }) async {
    final route = c.route;
    final count = await beam.localMessageCount(route);
    final floor = c.countBefore ?? 0;
    final taken = {
      for (final o in _records.values)
        if (o.id != c.id &&
            o.routeId == c.routeId &&
            o.direction == c.direction &&
            o.msgId != null)
          o.msgId!,
    };
    final out = <(int, int)>[];
    for (var id = count; id > floor; id--) {
      if (taken.contains(id)) continue;
      final m = await beam.localMessage(route, id);
      if (m == null) continue;
      if (m.receiver.toLowerCase() == c.ethAddress.toLowerCase() &&
          m.amount == c.amount &&
          m.relayerFee == c.relayerFee &&
          (height == null || m.height == height)) {
        out.add((id, m.height));
      }
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  Future<(BridgeCrossing, Duration)> _stepToBeam(BridgeCrossing c) async {
    final route = c.route;
    switch (c.state) {
      case BridgeCrossingState.approving:
        // The steps are being sent by [_sendLockSteps].
        return (c, polling.ethReceipt);
      case BridgeCrossingState.locking:
        if (c.lockHash == null) return (c, polling.ethReceipt);
        final EthPipeLock? lock;
        try {
          lock = await eth.lockResult(
            route,
            c.lockHash!,
            value: c.amount,
            fee: c.relayerFee,
            receiverKey: _unhex(c.beamReceiveKey!),
          );
        } on BridgeException catch (e) {
          if (e.code != BridgeErrorCode.unexpectedTransaction) rethrow;
          return (
            c.copyWith(
              state: BridgeCrossingState.unknown,
              lastError:
                  'The lock on Ethereum does not say what Campfire sent. '
                  'Campfire will not collect anything for it.',
              autoClaim: false,
              updatedAt: clock.now(),
            ),
            polling.toBeam,
          );
        }
        if (lock == null) return (c, polling.ethReceipt);
        if (!lock.success) {
          return (
            c.copyWith(
              state: BridgeCrossingState.lockFailed,
              lastError:
                  'Ethereum refused the lock, so nothing was locked. Only '
                  'its network fee was spent.',
              height: lock.blockNumber,
              updatedAt: clock.now(),
              finishedAt: clock.now(),
            ),
            polling.toBeam,
          );
        }
        final locked = c.copyWith(
          state: BridgeCrossingState.locked,
          msgId: lock.msgId,
          height: lock.blockNumber,
          lockedAt: clock.now(),
          updatedAt: clock.now(),
          clearError: true,
        );
        try {
          checkBridgeUnique(locked, _records.values);
        } on BridgeStoreConflict {
          return (
            c.copyWith(
              state: BridgeCrossingState.unknown,
              height: lock.blockNumber,
              lastError:
                  'Ethereum names a bridge message another crossing already '
                  'has. Campfire will not collect anything for this one.',
              autoClaim: false,
              updatedAt: clock.now(),
            ),
            polling.toBeam,
          );
        }
        return _stepToBeam(locked);
      case BridgeCrossingState.unknown:
        if (c.lockHash != null && c.msgId == null) {
          return _stepToBeam(c.copyWith(state: BridgeCrossingState.locking));
        }
        if (c.msgId != null) return (c, polling.toBeam);
        // No hash: look on BEAM for what the lock would have brought.
        final taken = {
          for (final o in _records.values)
            if (o.routeId == c.routeId &&
                o.direction == c.direction &&
                o.msgId != null)
              o.msgId!,
        };
        final waiting = await beam.incoming(route);
        for (final m in waiting) {
          if (m.amount == c.receives && !taken.contains(m.msgId)) {
            return _stepToBeam(
              c.copyWith(
                state: BridgeCrossingState.delivered,
                msgId: m.msgId,
                deliveredAt: clock.now(),
                updatedAt: clock.now(),
                clearError: true,
              ),
            );
          }
        }
        return (c, polling.toBeam);
      case BridgeCrossingState.locked:
      case BridgeCrossingState.notDeliveredYet:
        final m = await beam.remoteMessage(route, c.msgId!);
        if (m == null) {
          final since = c.lockedAt ?? c.updatedAt;
          if (c.state == BridgeCrossingState.locked &&
              clock.now().difference(since) >= BridgeTiming.deliveryWait) {
            return (
              c.copyWith(
                state: BridgeCrossingState.notDeliveredYet,
                updatedAt: clock.now(),
              ),
              polling.toBeam,
            );
          }
          return (c, polling.toBeam);
        }
        if (m.amount != c.receives) {
          return (
            c.copyWith(
              state: BridgeCrossingState.unknown,
              lastError:
                  'It arrived on BEAM with a different amount '
                  '(${_coin(m.amount, 8)} ${route.beamSymbol}). Campfire '
                  'will not collect it by itself.',
              autoClaim: false,
              updatedAt: clock.now(),
            ),
            polling.toBeam,
          );
        }
        return _stepToBeam(
          c.copyWith(
            state: BridgeCrossingState.delivered,
            deliveredAt: clock.now(),
            updatedAt: clock.now(),
          ),
        );
      case BridgeCrossingState.delivered:
        if (c.autoClaim && !_paused && c.lastError == null) {
          final claimed = await _autoClaim(c);
          return (claimed, polling.beamTx);
        }
        // Still there? It may have been collected on another device.
        final m = await beam.remoteMessage(route, c.msgId!);
        if (m == null) {
          return (
            c.copyWith(
              state: BridgeCrossingState.claimed,
              lastError:
                  'Collected outside this screen (on another device with '
                  'the same wallet, perhaps).',
              updatedAt: clock.now(),
              finishedAt: clock.now(),
            ),
            polling.toBeam,
          );
        }
        return (c, polling.toBeam);
      case BridgeCrossingState.claiming:
        final txId = c.claimTxId;
        if (txId != null) {
          final s = await beam.txStatus(txId);
          switch (s.state) {
            case BeamPipeTxState.pending:
              return (c, polling.beamTx);
            case BeamPipeTxState.completed:
              return (
                c.copyWith(
                  state: BridgeCrossingState.claimed,
                  updatedAt: clock.now(),
                  finishedAt: clock.now(),
                  clearError: true,
                ),
                polling.beamTx,
              );
            case BeamPipeTxState.failed:
              return (
                _claimDidNotGo(c, s.reason ?? 'The claim failed on BEAM.'),
                polling.toBeam,
              );
          }
        }
        // The claim threw while sending: the message tells.
        final m = await beam.remoteMessage(route, c.msgId!);
        if (m == null) {
          return (
            c.copyWith(
              state: BridgeCrossingState.claimed,
              updatedAt: clock.now(),
              finishedAt: clock.now(),
              clearError: true,
            ),
            polling.beamTx,
          );
        }
        final since = c.claimStartedAt ?? c.updatedAt;
        if (clock.now().difference(since) >= BridgeTiming.claimWait) {
          return (
            _claimDidNotGo(c, 'The claim did not reach BEAM.'),
            polling.toBeam,
          );
        }
        return (c, polling.beamTx);
      default:
        return (c, polling.toBeam);
    }
  }

  BridgeCrossing _claimDidNotGo(BridgeCrossing c, String why) => c.copyWith(
    state: BridgeCrossingState.delivered,
    lastError:
        '$why Nothing was lost: it is still waiting for you to '
        'collect it.',
    // Only the user starts it again.
    autoClaim: false,
    updatedAt: clock.now(),
  );

  Future<BridgeCrossing> _autoClaim(BridgeCrossing c) async {
    final BeamPipePrepared p;
    try {
      p = await _prepareClaim(c);
    } catch (e) {
      return c.copyWith(
        lastError: _plain(e),
        autoClaim: false,
        updatedAt: clock.now(),
      );
    }
    // [_claim] writes the record before and after sending.
    return _claim(c, p);
  }

  // -------------------------------------------------------------- helpers

  Future<void> _save(BridgeCrossing c) async {
    await store.save(c);
    _records[c.id] = c;
    if (!_disposed) notifyListeners();
  }

  /// [_save] for a step already taken: the record in memory follows even
  /// if the disk does not (the next save writes it).
  Future<bool> _saveQuietly(BridgeCrossing c) async {
    try {
      await _save(c);
      return true;
    } catch (_) {
      _records[c.id] = c;
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  static bool _sameRecord(BridgeCrossing a, BridgeCrossing b) =>
      identical(a, b) ||
      (a.state == b.state &&
          a.msgId == b.msgId &&
          a.height == b.height &&
          a.dueAt == b.dueAt &&
          a.lastError == b.lastError &&
          a.claimTxId == b.claimTxId &&
          a.autoClaim == b.autoClaim);

  String _newId(DateTime now) {
    final r = List.generate(
      4,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'x${now.toUtc().microsecondsSinceEpoch}$r';
  }

  static String _plain(Object e) => switch (e) {
    BridgeException(:final message) => message,
    _ => '$e',
  };

  static double _share(BigInt part, BigInt whole) =>
      whole == BigInt.zero ? 0 : part.toDouble() / whole.toDouble();

  static String _percent(double f) {
    final p = f * 100;
    return '${p >= 10 ? p.toStringAsFixed(0) : p.toStringAsFixed(1)}%';
  }

  /// Every digit, trailing zeros trimmed, thousands grouped.
  static String _coin(BigInt v, int decimals) {
    final unit = BigInt.from(10).pow(decimals);
    final whole = (v ~/ unit).toString();
    final frac = (v % unit)
        .toString()
        .padLeft(decimals, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    final b = StringBuffer();
    for (var i = 0; i < whole.length; i++) {
      if (i > 0 && (whole.length - i) % 3 == 0) b.write(',');
      b.write(whole[i]);
    }
    return frac.isEmpty ? '$b' : '$b.$frac';
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _unhex(String h) => Uint8List.fromList([
    for (var i = 0; i + 1 < h.length; i += 2)
      int.parse(h.substring(i, i + 2), radix: 16),
  ]);

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
