/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Buying BEAM through buybeam.my, without any screen: the coins it takes,
// what an amount buys (asked again on every change, the latest question
// only), a deposit address for one buy (kept on this device before it is
// shown), and where each open buy is (asked as often as buybeam.my says,
// less often while it cannot be reached, never again once it has ended).
//
// One controller for the whole app; it lives as long as the app, so buys
// are followed after their screen closes, and the open ones are picked up
// again when the app starts.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../utilities/logger.dart';
import 'buybeam_client.dart';
import 'buybeam_order.dart';
import 'buybeam_store.dart';

/// The time the controller reads, and its timers.
abstract class BuyBeamClock {
  DateTime now();

  /// Calls [callback] once, after [after].
  Timer schedule(Duration after, void Function() callback);
}

class SystemBuyBeamClock implements BuyBeamClock {
  const SystemBuyBeamClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Timer schedule(Duration after, void Function() callback) =>
      Timer(after, callback);
}

/// What to price: [amount] of [asset], refunds to [refundAddress].
@immutable
class BuyBeamQuoteRequest {
  const BuyBeamQuoteRequest({
    required this.asset,
    required this.amount,
    required this.refundAddress,
  });

  final BuyBeamAsset asset;
  final BuyBeamAmount amount;
  final String refundAddress;

  @override
  bool operator ==(Object other) =>
      other is BuyBeamQuoteRequest &&
      other.asset == asset &&
      other.amount == amount &&
      other.refundAddress == refundAddress;

  @override
  int get hashCode => Object.hash(asset, amount, refundAddress);
}

class BuyBeamController extends ChangeNotifier {
  BuyBeamController({
    required this.client,
    required this.store,
    BuyBeamClock? clock,
    this.autoPoll = true,
    this.quoteDelay = const Duration(milliseconds: 400),
    this.defaultPoll = const Duration(seconds: 15),
    this.maxBackoff = const Duration(minutes: 5),
    this.orderRetries = 2,
  }) : clock = clock ?? const SystemBuyBeamClock();

  final BuyBeamClient client;
  final BuyBeamStore store;
  final BuyBeamClock clock;

  /// Follow open buys on timers (tests call [pollDue] themselves).
  final bool autoPoll;

  /// How long typing must pause before a price is asked for.
  final Duration quoteDelay;

  /// Between two looks at a buy, when buybeam.my does not say.
  final Duration defaultPoll;

  /// The longest wait between looks while buybeam.my cannot be reached.
  final Duration maxBackoff;

  /// Extra tries of a deposit-address request that got no answer.
  final int orderRetries;

  bool get sandbox => client.sandbox;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _quoteTimer?.cancel();
    _wake?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------- coins

  ({List<BuyBeamAsset> list, DateTime at})? _assets;
  BuyBeamLimits? _limits;

  /// The coins buybeam.my takes, in picker order (kept ten minutes).
  Future<List<BuyBeamAsset>> assets({bool refresh = false}) async {
    final cached = _assets;
    if (!refresh &&
        cached != null &&
        clock.now().difference(cached.at) < const Duration(minutes: 10)) {
      return cached.list;
    }
    final list = sortBuyBeamAssets(await client.assets());
    _assets = (list: list, at: clock.now());
    return list;
  }

  /// The smallest-buy hint last read.
  BuyBeamLimits? get limits => _limits;

  /// The smallest buy a refused price last stated, while the app runs.
  double? _refusedBelowUsd;

  /// What to say up front about the smallest buy: the figure buybeam.my
  /// last observed, else the one a refused price stated here, else
  /// buybeam.my's own floor. A hint only: a price decides.
  double? get minimumHintUsd =>
      _limits?.upstreamObservedMinimumUsd ??
      _refusedBelowUsd ??
      _limits?.ourMinimumUsd;

  /// Reads the smallest-buy hint; null (and the last one kept) when
  /// buybeam.my cannot be reached. Only a hint: [quote] decides.
  Future<BuyBeamLimits?> refreshLimits() async {
    try {
      _limits = await client.limits();
      _changed();
    } on BuyBeamError catch (_) {
      // The form says nothing about a minimum until a quote does.
    }
    return _limits;
  }

  // --------------------------------------------------------------- quotes

  BuyBeamQuoteRequest? _quoteRequest;
  BuyBeamQuote? _quote;
  BuyBeamError? _quoteError;
  bool _quoting = false;
  int _quoteSeq = 0;
  Timer? _quoteTimer;

  /// What is being priced (null: nothing).
  BuyBeamQuoteRequest? get quoteRequest => _quoteRequest;

  /// The price of [quoteRequest], once known.
  BuyBeamQuote? get quote => _quote;

  /// Why [quoteRequest] has no price.
  BuyBeamError? get quoteError => _quoteError;

  /// A price is being asked for (or about to be).
  bool get quoting => _quoting;

  /// Prices [request] once typing pauses ([quoteDelay]); the answer to any
  /// earlier request is dropped. Null clears the price.
  void requestQuote(BuyBeamQuoteRequest? request, {Duration? after}) {
    _quoteTimer?.cancel();
    final seq = ++_quoteSeq;
    _quoteRequest = request;
    _quote = null;
    _quoteError = null;
    _quoting = request != null;
    _changed();
    if (request == null) return;
    _quoteTimer = clock.schedule(
      after ?? quoteDelay,
      () => unawaited(_runQuote(seq, request)),
    );
  }

  /// Forgets the price being asked for without telling anyone (a form
  /// opening or closing, while the widget tree may not be rebuilt).
  void cancelQuote() {
    _quoteTimer?.cancel();
    _quoteSeq++;
    _quoteRequest = null;
    _quote = null;
    _quoteError = null;
    _quoting = false;
  }

  /// Asks for the same price again, now ("Try again").
  void requote() {
    final r = _quoteRequest;
    if (r != null) requestQuote(r, after: Duration.zero);
  }

  Future<void> _runQuote(int seq, BuyBeamQuoteRequest r) async {
    if (seq != _quoteSeq || _disposed) return;
    try {
      final q = await client.quote(
        assetId: r.asset.assetId,
        amount: r.amount,
        refundAddress: r.refundAddress,
      );
      if (seq != _quoteSeq || _disposed) return;
      _quote = q;
    } on BuyBeamError catch (e) {
      if (e.code == BuyBeamErrorCode.amountBelowUpstreamMinimum &&
          e.minimumUsd != null) {
        _refusedBelowUsd = e.minimumUsd;
      }
      if (seq != _quoteSeq || _disposed) return;
      _quoteError = e;
    }
    _quoting = false;
    _changed();
  }

  // --------------------------------------------------------------- orders

  final Map<String, BuyBeamOrder> _orders = {};
  final Map<String, DateTime> _dueAt = {};
  final Map<String, int> _failures = {};
  final Map<String, BuyBeamError> _pollErrors = {};
  final Set<String> _busy = {};

  /// BEAM addresses made for an order request that got no answer, by the
  /// request: asking again with them returns the same order.
  final Map<String, String> _pendingAddress = {};

  Future<void>? _resuming;
  bool _paused = false;
  Timer? _wake;

  /// Every buy (of [beamWalletId] when given), newest first.
  List<BuyBeamOrder> orders({String? beamWalletId}) =>
      _orders.values
          .where((o) => beamWalletId == null || o.beamWalletId == beamWalletId)
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  BuyBeamOrder? order(String depositAddress) => _orders[depositAddress];

  /// Why the last look at a buy got no answer (null after one that did).
  BuyBeamError? pollError(String depositAddress) => _pollErrors[depositAddress];

  /// When the next look at a buy is due (null: never, it has ended).
  @visibleForTesting
  DateTime? dueAt(String depositAddress) => _dueAt[depositAddress];

  /// Loads the buys kept on this device and follows the open ones (once;
  /// later calls wait for the first).
  Future<void> resumeAll() => _resuming ??= _resume();

  Future<void> _resume() async {
    final List<BuyBeamOrder> stored;
    try {
      stored = await store.all();
    } catch (e) {
      Logging.instance.w('buybeam: buys not read (${e.runtimeType})');
      // The next screen that opens asks again.
      _resuming = null;
      return;
    }
    final now = clock.now();
    for (final o in stored) {
      _orders.putIfAbsent(o.depositAddress, () => o);
      if (o.isOpen) _dueAt.putIfAbsent(o.depositAddress, () => now);
    }
    _changed();
    _arm();
  }

  /// A deposit address for [amount] of [asset], the BEAM going to a new
  /// address of the wallet [beamWalletId] ([newBeamAddress] makes it). The
  /// buy is on this device before this returns. A request that got no
  /// answer is sent again as it was, and buybeam.my returns the same
  /// order for it.
  Future<BuyBeamOrder> placeOrder({
    required BuyBeamAsset asset,
    required BuyBeamAmount amount,
    required String refundAddress,
    required String beamWalletId,
    required Future<String> Function() newBeamAddress,
    BuyBeamQuote? quote,
  }) async {
    await resumeAll();
    final key = [
      asset.assetId,
      amount.raw,
      refundAddress,
      beamWalletId,
    ].join('|');
    final beamAddress = _pendingAddress[key] ??= await newBeamAddress();
    BuyBeamOrderAnswer? answer;
    for (var attempt = 0; answer == null; attempt++) {
      try {
        answer = await client.order(
          assetId: asset.assetId,
          amount: amount,
          beamAddress: beamAddress,
          refundAddress: refundAddress,
        );
      } on BuyBeamError catch (e) {
        if (!e.code.unreachable || attempt >= orderRetries) rethrow;
        Logging.instance.w('buybeam: order asked again (${e.code.wire})');
      }
    }
    final existing = _orders[answer.depositAddress];
    final order =
        existing ??
        BuyBeamOrder(
          depositAddress: answer.depositAddress,
          assetId: asset.assetId,
          symbol: asset.symbol,
          chain: asset.blockchain,
          decimals: asset.decimals,
          sendAmount: amount.text,
          sendAmountRaw: amount.raw,
          beamAddress: beamAddress,
          beamWalletId: beamWalletId,
          refundAddress: refundAddress,
          createdAt: clock.now(),
          beamEstimate: answer.beamEstimate ?? quote?.beamEstimate,
          deadline: answer.deadline,
          etaSeconds: answer.etaSeconds ?? quote?.etaSeconds,
          lastState: BuyBeamState.awaitingDeposit,
          sandbox: client.sandbox,
        );
    // On disk before anything shows the address.
    await store.save(order);
    _pendingAddress.remove(key);
    _orders[order.depositAddress] = order;
    if (order.isOpen) {
      _dueAt[order.depositAddress] = clock.now().add(defaultPoll);
    }
    _changed();
    _arm();
    return order;
  }

  /// Stops following buys while the app is in the background.
  void pause() {
    _paused = true;
    _wake?.cancel();
    _wake = null;
  }

  /// Follows them again, everything that is due first.
  void resume() {
    if (!_paused) return;
    _paused = false;
    unawaited(pollDue());
  }

  /// Looks at every open buy whose turn it is.
  Future<void> pollDue() async {
    if (_disposed || _paused) return;
    final now = clock.now();
    final due = [
      for (final o in _orders.values)
        if (o.isOpen &&
            !_busy.contains(o.depositAddress) &&
            !(_dueAt[o.depositAddress]?.isAfter(now) ?? false))
          o.depositAddress,
    ];
    for (final a in due) {
      await poll(a);
    }
    _arm();
  }

  /// Looks at the buy paid at [depositAddress] once, now.
  Future<BuyBeamOrder?> poll(String depositAddress) async {
    final o = _orders[depositAddress];
    if (o == null || !o.isOpen || _disposed || !_busy.add(depositAddress)) {
      return o;
    }
    try {
      final s = await client.status(depositAddress);
      final next = o.withStatus(s, clock.now());
      _failures.remove(depositAddress);
      _pollErrors.remove(depositAddress);
      if (!next.sameAs(o)) await _saveQuietly(next);
      _orders[depositAddress] = next;
      if (next.isOpen) {
        _dueAt[depositAddress] = clock.now().add(s.pollAfter ?? defaultPoll);
      } else {
        _dueAt.remove(depositAddress);
      }
      return next;
    } on BuyBeamError catch (e) {
      _pollErrors[depositAddress] = e;
      final n = (_failures[depositAddress] ?? 0) + 1;
      _failures[depositAddress] = n;
      _dueAt[depositAddress] = clock.now().add(_backoff(n, e.retryAfter));
      return o;
    } finally {
      _busy.remove(depositAddress);
      _changed();
      _arm();
    }
  }

  /// The wait after [failures] looks in a row got no answer: twice the
  /// usual each time, at most [maxBackoff], never less than [retryAfter].
  Duration _backoff(int failures, Duration? retryAfter) {
    final factor = math.pow(2, math.min(failures, 10)).toInt();
    var wait = defaultPoll * factor;
    if (wait > maxBackoff) wait = maxBackoff;
    if (retryAfter != null && retryAfter > wait) wait = retryAfter;
    return wait;
  }

  Future<void> _saveQuietly(BuyBeamOrder o) async {
    try {
      await store.save(o);
    } catch (e) {
      Logging.instance.w('buybeam: could not save a buy (${e.runtimeType})');
    }
  }

  /// Wakes up when the next open buy is due.
  void _arm() {
    if (!autoPoll || _paused || _disposed) return;
    _wake?.cancel();
    _wake = null;
    DateTime? next;
    for (final o in _orders.values) {
      final at = _dueAt[o.depositAddress];
      if (!o.isOpen || at == null || _busy.contains(o.depositAddress)) {
        continue;
      }
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    final wait = next.difference(clock.now());
    _wake = clock.schedule(wait.isNegative ? Duration.zero : wait, () {
      _wake = null;
      unawaited(pollDue());
    });
  }
}
