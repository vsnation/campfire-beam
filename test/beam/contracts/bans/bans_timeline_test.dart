// Period, expiry and status arithmetic against the contract
// (`contract.h:68-71,90-92`, `contract.cpp:71-85`, `app.cpp:535-574`) and the
// explorer's status column (`Explorer/Parser.cpp:2827-2831`).

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_timeline.dart';

void main() {
  test('constants match contract.h', () {
    expect(kBansBlocksPerPeriod, 525600);
    expect(kBansHoldBlocks, 129600);
    expect(kBansMaxPeriods, 50);
  });

  group('statusOf, evaluated at tip + 1', () {
    const e = 1000000;

    BansNameStatus at(int tip, {bool listed = false}) =>
        BansTimeline.statusOf(expireHeight: e, tipHeight: tip, listed: listed);

    test('active until the block before expiry', () {
      expect(at(e - 2), BansNameStatus.active);
      expect(at(e - 2, listed: true), BansNameStatus.forSale);
    });

    test('on hold from the expiry block for 129,600 blocks', () {
      expect(at(e - 1), BansNameStatus.onHold);
      expect(at(e - 1, listed: true), BansNameStatus.onHold);
      expect(at(e + kBansHoldBlocks - 2), BansNameStatus.onHold);
    });

    test('available again once IsExpired(h) holds', () {
      expect(at(e + kBansHoldBlocks - 1), BansNameStatus.availableAgain);
      expect(BansTimeline.isPastHold(e, e + kBansHoldBlocks), isTrue);
      expect(BansTimeline.isPastHold(e, e + kBansHoldBlocks - 1), isFalse);
    });

    test('what each status allows', () {
      expect(BansNameStatus.available.canRegister, isTrue);
      expect(BansNameStatus.availableAgain.canRegister, isTrue);
      expect(BansNameStatus.onHold.canRegister, isFalse);
      expect(BansNameStatus.onHold.canReceivePayments, isTrue);
      expect(BansNameStatus.forSale.canReceivePayments, isTrue);
      expect(BansNameStatus.availableAgain.canReceivePayments, isFalse);
      expect(BansNameStatus.available.canReceivePayments, isFalse);
    });

    test('agrees with the live explorer rows at its height', () {
      // explorer h = 4068101 (fixture); our tip is the block before it.
      const tip = 4068100;
      expect(
        BansTimeline.statusOf(expireHeight: 4918184, tipHeight: tip),
        BansNameStatus.active,
      ); // beam: ""
      expect(
        BansTimeline.statusOf(expireHeight: 3998572, tipHeight: tip),
        BansNameStatus.onHold,
      ); // beamer: "On Hold"
      expect(
        BansTimeline.statusOf(expireHeight: 2422543, tipHeight: tip),
        BansNameStatus.availableAgain,
      ); // 0xredbeard: "Expired"
    });
  });

  group('expiry and renewal limits', () {
    test('register: n periods from the next block', () {
      expect(
        BansTimeline.expiryAfterRegister(tipHeight: 100, periods: 2),
        101 + 2 * 525600,
      );
    });

    test('extend: from the later of expiry and the next block', () {
      expect(
        BansTimeline.expiryAfterExtend(
          expireHeight: 5000000,
          tipHeight: 4000000,
          periods: 1,
        ),
        5000000 + 525600,
      );
      expect(
        BansTimeline.expiryAfterExtend(
          expireHeight: 3000000,
          tipHeight: 4000000,
          periods: 1,
        ),
        4000001 + 525600,
      );
    });

    test('maxExtendPeriods mirrors app.cpp:565-574', () {
      // expired: the full 50 periods fit
      expect(
        BansTimeline.maxExtendPeriods(expireHeight: 1, tipHeight: 4000000),
        50,
      );
      // beam: expires at 4918184, tip 4068103 -> (h+50P - 4918184) / P
      const h = 4068104;
      expect(
        BansTimeline.maxExtendPeriods(expireHeight: 4918184, tipHeight: h - 1),
        (h + 50 * 525600 - 4918184) ~/ 525600,
      );
      expect(
        BansTimeline.maxExtendPeriods(
          expireHeight: h + 50 * 525600,
          tipHeight: h - 1,
        ),
        0,
      );
      expect(BansTimeline.maxRegisterPeriods, 50);
    });

    test('hold end is expiry + 90 days of blocks', () {
      expect(BansTimeline.holdEndHeight(1000), 1000 + 129600);
    });
  });

  group('BansClock', () {
    final clock = BansClock(
      tipHeight: 4068103,
      tipTime: DateTime.utc(2026, 10, 6, 8, 45),
    );

    test('one block per minute', () {
      expect(clock.dateOf(4068103 + 60), DateTime.utc(2026, 10, 6, 9, 45));
      expect(clock.dateOf(4068103 - 1440), DateTime.utc(2026, 10, 5, 8, 45));
      // one period is 365 days
      expect(
        clock.dateOf(4068103 + kBansBlocksPerPeriod),
        DateTime.utc(2027, 10, 6, 8, 45),
      );
    });

    test('heightAt is the inverse, rounding up', () {
      expect(clock.heightAt(DateTime.utc(2026, 10, 6, 9, 45)), 4068163);
      expect(clock.heightAt(DateTime.utc(2026, 10, 6, 8, 45, 1)), 4068104);
    });
  });
}
