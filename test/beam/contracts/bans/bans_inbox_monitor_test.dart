/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_models.dart';

const _g = BigInt.from;
final _beam = _g(100000000);

BansIncomingPayment _pay(int aid, int amount, [String? name]) =>
    BansIncomingPayment(
      oneTimeKey: 'k$aid$amount',
      assetId: aid,
      amount: _g(amount),
      name: name,
    );

BansInbox _inbox({
  List<BansIncomingPayment> payments = const [],
  List<BansAmount> proceeds = const [],
}) => BansInbox(domains: const [], saleProceeds: proceeds, payments: payments);

void main() {
  final t0 = DateTime.utc(2026, 10, 6, 12);

  group('summary', () {
    test('totals per asset across payments and sale proceeds', () {
      final s = BansInboxMonitor.summarize(
        _inbox(
          payments: [
            _pay(0, 150000000, 'alice'),
            _pay(0, 100000000, 'alice'),
            _pay(174, 5000, 'bob'),
          ],
          proceeds: [BansAmount(0, _g(50000000))],
        ),
        t0,
      );
      expect(s.visibility, BansInboxVisibility.visible);
      expect(s.totalsByAsset, {0: _g(300000000), 174: _g(5000)});
      expect(s.entryCount, 4);
      expect(s.names, ['alice', 'bob']);
      expect(s.isEmpty, isFalse);
    });

    test('an empty inbox is empty, not an error', () {
      final s = BansInboxMonitor.summarize(_inbox(), t0);
      expect(s.isEmpty, isTrue);
      expect(
        s.advise(beamAvailable: _beam).reason,
        BansClaimBlocker.nothingToClaim,
      );
    });
  });

  group('claim advice', () {
    BansPendingSummary summary(List<BansIncomingPayment> p) =>
        BansInboxMonitor.summarize(_inbox(payments: p), t0);

    test('BEAM waiting pays its own fee, even from an empty wallet', () {
      final a = summary([_pay(0, 250000000)]).advise(beamAvailable: _g(0));
      expect(a.canClaim, isTrue);
      expect(a.transactions, 1);
      expect(a.feeGroth, kBansClaimFeeGroth);
      expect(a.beamCostsMoreThanItReturns, isFalse);
    });

    test('tokens only: the fee must already be in the wallet', () {
      final s = summary([_pay(174, 5000)]);
      final broke = s.advise(beamAvailable: _g(1000000));
      expect(broke.canClaim, isFalse);
      expect(broke.reason, BansClaimBlocker.needsBeamForFee);
      expect(s.advise(beamAvailable: kBansClaimFeeGroth).canClaim, isTrue);
    });

    test('BEAM worth less than the fee is flagged, not forbidden', () {
      final a = summary([_pay(0, 1000000)]).advise(beamAvailable: _beam);
      expect(a.canClaim, isTrue);
      expect(a.beamCostsMoreThanItReturns, isTrue);
    });

    test('more than 30 entries need more than one transaction', () {
      final a = summary([
        for (var i = 1; i <= 61; i++) _pay(0, 100000000 + i),
      ]).advise(beamAvailable: _g(0));
      expect(a.transactions, 3);
      expect(a.feeGroth, kBansClaimFeeGroth * _g(3));
    });

    test('a stock core cannot claim and says why', () {
      final a = BansPendingSummary.empty(
        BansInboxVisibility.needsCampfireCore,
        t0,
      ).advise(beamAvailable: _beam);
      expect(a.canClaim, isFalse);
      expect(a.reason, BansClaimBlocker.needsCampfireCore);
    });
  });

  group('monitor', () {
    test('concurrent refreshes share one read', () async {
      var reads = 0;
      final gate = Completer<BansInbox>();
      final m = BansInboxMonitor(() {
        reads++;
        return gate.future;
      });
      final a = m.refresh();
      final b = m.refresh(force: true);
      gate.complete(_inbox(payments: [_pay(0, 5)]));
      await Future.wait([a, b]);
      expect(reads, 1);
      expect(m.latest!.entryCount, 1);
      await m.dispose();
    });

    test('reads are throttled unless forced', () async {
      var now = t0;
      var reads = 0;
      final m = BansInboxMonitor(
        () async {
          reads++;
          return _inbox();
        },
        minInterval: const Duration(seconds: 20),
        now: () => now,
      );
      await m.refresh();
      now = now.add(const Duration(seconds: 5));
      await m.refresh();
      expect(reads, 1);
      await m.refresh(force: true);
      expect(reads, 2);
      now = now.add(const Duration(seconds: 21));
      await m.refresh();
      expect(reads, 3);
      await m.dispose();
    });

    test('a failed read keeps the last good summary', () async {
      var fail = false;
      final m = BansInboxMonitor(() async {
        if (fail) throw StateError('connection lost');
        return _inbox(payments: [_pay(0, 250000000, 'alice')]);
      });
      final seen = <BansPendingSummary>[];
      final sub = m.summaries.listen(seen.add);
      await m.refresh();
      fail = true;
      await m.refresh(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      expect(m.latest!.totalsByAsset, {0: _g(250000000)});
      expect(m.lastError, isA<StateError>());
      await sub.cancel();
      await m.dispose();
    });

    test('a core without privilege 1 is reported, not shown as zero', () async {
      final m = BansInboxMonitor(
        () async => throw const BansClaimUnsupported('get_PkEx'),
      );
      await m.refresh();
      expect(m.latest!.visibility, BansInboxVisibility.needsCampfireCore);
      expect(m.latest!.isEmpty, isTrue);
      await m.dispose();
    });
  });
}
