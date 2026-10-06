// BeamSyncMonitor: wallet stream in, assessments out, with a fake explorer,
// a fake clock and a hand-cranked timer.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_monitor.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';

const _tip = 4067900;

class _FakeTimer implements Timer {
  _FakeTimer(this.period, this.onTick);

  final Duration period;
  final void Function(Timer) onTick;
  bool _active = true;
  int _ticks = 0;

  void fire() {
    if (!_active) throw StateError('tick on a cancelled timer');
    _ticks++;
    onTick(this);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

class _FakeExplorer implements BeamNetworkTipSource {
  _FakeExplorer(this.clock);

  final DateTime Function() clock;
  int height = _tip;
  Duration tipAge = const Duration(seconds: 30);
  bool down = false;
  int calls = 0;
  final forced = <bool>[];

  @override
  Future<BeamExplorerStatus> status({bool forceRefresh = false}) async {
    calls++;
    forced.add(forceRefresh);
    if (down) throw BeamExplorerException('down');
    final now = clock();
    return BeamExplorerStatus(
      height: height,
      timestamp: now.subtract(tipAge),
      hash: 'ab' * 32,
      node: 'fake',
      receivedAt: now,
      serverTime: now,
    );
  }
}

void main() {
  late DateTime now;
  late _FakeExplorer explorer;
  late StreamController<BeamWalletSyncInput> wallet;
  late List<_FakeTimer> timers;
  late BeamSyncMonitor monitor;
  late List<BeamSyncAssessment> seen;

  BeamWalletSyncInput status(
    int height, {
    Duration age = const Duration(seconds: 30),
    bool isInSync = true,
    int? headerTip,
    bool? connected = true,
  }) => BeamWalletSyncInput(
    currentHeight: height,
    currentStateTimestamp: now.subtract(age),
    isInSync: isInSync,
    headerTipHeight: headerTip ?? height,
    nodeConnected: connected,
  );

  /// Lets queued microtasks (stream events, explorer futures) run.
  Future<void> settle() => pumpEventQueue();

  setUp(() {
    now = DateTime.utc(2026, 10, 6, 7, 40);
    explorer = _FakeExplorer(() => now);
    wallet = StreamController<BeamWalletSyncInput>();
    timers = [];
    seen = [];
    monitor = BeamSyncMonitor(
      explorer: explorer,
      walletStatus: wallet.stream,
      now: () => now,
      timerFactory: (period, onTick) {
        final t = _FakeTimer(period, onTick);
        timers.add(t);
        return t;
      },
    );
    monitor.assessments.listen(seen.add);
  });

  tearDown(() async {
    await monitor.dispose();
    // close() on a single-subscription controller nobody listened to never
    // completes, so do not wait for it.
    unawaited(wallet.close());
  });

  test(
    'starts as connecting; first wallet status plus explorer -> synced',
    () async {
      expect(monitor.current, isA<BeamSyncConnecting>());
      monitor.start();
      await settle();
      expect(explorer.calls, 1, reason: 'polls once on start');
      expect(timers.single.period, const Duration(seconds: 30));

      wallet.add(status(_tip));
      await settle();
      expect(monitor.current, isA<BeamSynced>());
      expect((monitor.current as BeamSynced).verified, isTrue);
      expect(monitor.current.canSpend, isTrue);
      expect(seen.last, monitor.current);
    },
  );

  test('identical updates emit once', () async {
    monitor.start();
    await settle();
    wallet
      ..add(status(_tip))
      ..add(status(_tip))
      ..add(status(_tip));
    await settle();
    expect(seen.whereType<BeamSynced>(), hasLength(1));
  });

  test(
    'a tip that silently ages turns synced into stalled on a tick',
    () async {
      monitor.start();
      await settle();
      wallet.add(status(_tip));
      await settle();
      expect(monitor.current, isA<BeamSynced>());

      // The core goes quiet. 11 minutes later the timer fires.
      now = now.add(const Duration(minutes: 11));
      explorer.height = _tip + 11;
      timers.single.fire();
      await settle();
      final a = monitor.current;
      expect(a, isA<BeamSyncStalled>());
      expect((a as BeamSyncStalled).reason, BeamStallReason.tipTooOld);
      expect(a.blocksBehind, 11);
      expect(a.canSpend, isFalse);
    },
  );

  test('advancing heights -> catching up with an ETA, then synced', () async {
    monitor.start();
    await settle();
    // 600 blocks behind, processing 5 blocks/s.
    var h = _tip - 600;
    wallet.add(
      status(
        h,
        age: const Duration(hours: 10),
        isInSync: false,
        headerTip: _tip,
      ),
    );
    await settle();
    for (var i = 0; i < 4; i++) {
      now = now.add(const Duration(seconds: 10));
      h += 50;
      wallet.add(
        status(
          h,
          age: const Duration(hours: 9),
          isInSync: false,
          headerTip: _tip,
        ),
      );
      await settle();
    }
    final a = monitor.current;
    expect(a, isA<BeamSyncCatchingUp>());
    final c = a as BeamSyncCatchingUp;
    expect(c.blocksBehind, 400);
    expect(c.eta, isNotNull);
    expect(c.eta!.inSeconds, inInclusiveRange(75, 90));

    now = now.add(const Duration(seconds: 80));
    wallet.add(status(_tip));
    await settle();
    expect(monitor.current, isA<BeamSynced>());
  });

  test('stuck for longer than the grace period -> stalled', () async {
    monitor.start();
    await settle();
    wallet.add(status(_tip - 20, age: const Duration(minutes: 20)));
    await settle();
    expect(
      monitor.current,
      isA<BeamSyncCatchingUp>(),
      reason: 'just started watching',
    );

    now = now.add(const Duration(minutes: 6));
    timers.single.fire();
    await settle();
    expect(monitor.current, isA<BeamSyncStalled>());
  });

  test('HF6-frozen wallet is reported at once', () async {
    monitor.start();
    await settle();
    wallet.add(status(3928665, age: const Duration(days: 98), isInSync: false));
    await settle();
    final a = monitor.current as BeamSyncStalled;
    expect(a.reason, BeamStallReason.stuckBelowHardFork);
    expect(a.blocksBehind, _tip - 3928665);
  });

  test('background stops polling; foreground resumes and refreshes', () async {
    monitor.start();
    await settle();
    expect(monitor.isPolling, isTrue);
    final first = timers.single;

    monitor.setForeground(false);
    expect(first.isActive, isFalse);
    expect(monitor.isPolling, isFalse);
    final callsWhileHidden = explorer.calls;
    // Wallet updates are still assessed (no network needed).
    wallet.add(status(_tip));
    await settle();
    expect(monitor.current, isA<BeamSynced>());
    expect(explorer.calls, callsWhileHidden);

    monitor.setForeground(true);
    await settle();
    expect(explorer.calls, callsWhileHidden + 1, reason: 'refresh at once');
    expect(timers, hasLength(2));
    expect(timers.last.isActive, isTrue);
  });

  test(
    'explorer outage: last answer reused briefly, then unverified',
    () async {
      monitor.start();
      await settle();
      wallet.add(status(_tip));
      await settle();
      expect((monitor.current as BeamSynced).verified, isTrue);

      explorer.down = true;
      now = now.add(const Duration(minutes: 1));
      wallet.add(status(_tip + 1));
      timers.single.fire();
      await settle();
      expect(
        (monitor.current as BeamSynced).verified,
        isTrue,
        reason: 'a 1-minute-old answer is still used',
      );

      now = now.add(const Duration(minutes: 3));
      wallet.add(status(_tip + 4));
      timers.single.fire();
      await settle();
      final a = monitor.current as BeamSynced;
      expect(a.verified, isFalse);
      expect(a.explorerCheck, BeamExplorerCheck.unavailable);
      expect(a.canSpend, isTrue, reason: 'core checks still pass');
    },
  );

  test('refresh() forces a fresh explorer answer', () async {
    monitor.start();
    await settle();
    await monitor.refresh();
    expect(explorer.forced.last, isTrue);
  });

  test('switching node restarts the grace period', () async {
    monitor.start();
    await settle();
    wallet.add(status(_tip - 20, age: const Duration(minutes: 20)));
    await settle();
    now = now.add(const Duration(minutes: 6));
    timers.single.fire();
    await settle();
    expect(monitor.current, isA<BeamSyncStalled>());

    monitor.setNode(BeamNodeKind.privateNode);
    await settle();
    expect(monitor.current, isA<BeamSyncCatchingUp>());
    expect(monitor.current.node, BeamNodeKind.privateNode);
  });

  // Security review finding 3: after a (re)open or node switch, the last
  // chain state may be fresh while the new wallet-api has not reached any
  // node. The old session's `node_connected` must not carry over.
  test('a new session forgets the old node connection: not synced until '
      'the new core reports node_connected', () async {
    monitor.start();
    await settle();
    wallet.add(status(_tip));
    await settle();
    expect(monitor.current, isA<BeamSynced>());

    monitor.setNode(BeamNodeKind.publicNode);
    await settle();
    expect(monitor.current, isA<BeamSyncConnecting>());
    expect(monitor.current.canSpend, isFalse);
    expect(monitor.current.walletHeight, _tip);

    // The explorer keeps agreeing; still no spend without the node.
    timers.single.fire();
    await settle();
    expect(monitor.current.canSpend, isFalse);

    // The new core's first status, connection not reported yet.
    wallet.add(status(_tip, connected: null));
    await settle();
    expect(monitor.current, isA<BeamSyncConnecting>());

    // ev_connection_changed: node_connected == true.
    wallet.add(status(_tip));
    await settle();
    expect(monitor.current, isA<BeamSynced>());
    expect(monitor.current.canSpend, isTrue);
  });

  test('a wallet stream error does not kill the monitor', () async {
    monitor.start();
    await settle();
    wallet.addError(StateError('rpc gone'));
    wallet.add(status(_tip));
    await settle();
    expect(monitor.current, isA<BeamSynced>());
  });

  test(
    'dispose cancels the timer and the subscription, closes the stream',
    () async {
      final done = Completer<void>();
      monitor.assessments.listen(null, onDone: done.complete);
      monitor.start();
      await settle();
      await monitor.dispose();
      expect(timers.single.isActive, isFalse);
      expect(wallet.hasListener, isFalse);
      await done.future.timeout(const Duration(seconds: 1));
      // Late events after dispose are ignored, not thrown.
      monitor
        ..setForeground(false)
        ..setForeground(true)
        ..setNode(BeamNodeKind.publicNode);
      await monitor.refresh();
    },
  );

  test('an explorer answer arriving after dispose is dropped', () async {
    final gate = Completer<void>();
    final slow = _SlowExplorer(gate.future, () => now);
    final m = BeamSyncMonitor(
      explorer: slow,
      walletStatus: const Stream.empty(),
      now: () => now,
      timerFactory: (p, t) => _FakeTimer(p, t),
    )..start();
    await settle();
    await m.dispose();
    gate.complete();
    await settle();
    expect(m.current, isA<BeamSyncConnecting>());
  });
}

class _SlowExplorer implements BeamNetworkTipSource {
  _SlowExplorer(this.gate, this.clock);

  final Future<void> gate;
  final DateTime Function() clock;

  @override
  Future<BeamExplorerStatus> status({bool forceRefresh = false}) async {
    await gate;
    return BeamExplorerStatus(
      height: _tip,
      timestamp: clock(),
      hash: '',
      node: 'slow',
      receivedAt: clock(),
    );
  }
}
