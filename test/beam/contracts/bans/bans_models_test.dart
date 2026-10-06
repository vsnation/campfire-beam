// Parsing of recorded shader output, the error mapping, and the price
// estimate from the 5-decimal oracle median.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_models.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_name.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_timeline.dart';

import 'bans_fixtures.dart';

Matcher refused(BansRefusal r) =>
    throwsA(isA<BansShaderRefused>().having((e) => e.refusal, 'refusal', r));

void main() {
  group('view_name', () {
    test('a registered name', () {
      final d = BansOutput.viewName(
        bansOutput('view_name_beam'),
        BansName('beam'),
      )!;
      expect(d.name, 'beam');
      expect(d.ownerKey, beamOwnerKey);
      expect(d.expireHeight, 4918184);
      expect(d.salePrice, isNull);
      expect(d.statusAt(4068103), BansNameStatus.active);
    });

    test('a listed name carries its price', () {
      final d = BansOutput.viewName(
        bansOutput('view_name_listed'),
        BansName('nephrite'),
      )!;
      expect(d.salePrice, BansAmount(0, BigInt.from(10000000000000)));
      expect(d.statusAt(4068103), BansNameStatus.forSale);
    });

    test('a name on hold', () {
      final d = BansOutput.viewName(
        bansOutput('view_name_hold'),
        BansName('beamer'),
      )!;
      expect(d.statusAt(4068103), BansNameStatus.onHold);
    });

    test('an unregistered name is {} -> null, not an error', () {
      expect(
        BansOutput.viewName(bansOutput('view_name_free'), BansName('zzzzz')),
        isNull,
      );
    });

    test('the shader\'s own name errors are typed', () {
      expect(
        () =>
            BansOutput.viewName(bansOutput('view_name_upper'), BansName('abc')),
        refused(BansRefusal.nameInvalid),
      );
      expect(
        () => BansOutput.viewName(bansOutput('view_name_ab'), BansName('abc')),
        refused(BansRefusal.nameTooShort),
      );
    });
  });

  test('view_domain for one key', () {
    final names = BansOutput.viewDomain(bansOutput('view_domain_pk'));
    expect(names.map((d) => d.name), ['amir', 'beam', 'foundation']);
    expect(names.every((d) => d.ownerKey == beamOwnerKey), isTrue);
  });

  test('my_key', () {
    expect(BansOutput.myKey(bansOutput('my_key')), fakeMyKey);
  });

  group('view_params', () {
    test('contract ids, median text, activation height', () {
      final p = BansOutput.viewParams(bansOutput('view_params'));
      expect(p.vaultCid, vaultCid);
      expect(p.daoVaultCid, daoVaultCid);
      expect(
        p.oracleCid,
        '4f160f01dcc6751e61d793279b803328d5332125fe8492e93ee8f3bfe9abe13b',
      );
      expect(p.usdPerBeamText, '0.00860');
      expect(p.priceFeedLive, isTrue);
      expect(p.activationHeight, 1896111);
    });

    test('a stale feed has no price, and no estimate', () {
      final p = BansOutput.viewParams(
        '{"res": {"vault": "$vaultCid","dao-vault": "$daoVaultCid",'
        '"oracle": "$vaultCid","h0": 1896111}}',
      );
      expect(p.priceFeedLive, isFalse);
      expect(p.estimate(BansName('alice'), 1), isNull);
    });
  });

  group('price estimate', () {
    test('brackets the exact kernel amounts recorded at the same time', () {
      final p = BansOutput.viewParams(bansOutput('view_params'));
      final e5 = p.estimate(BansName(quotedName5), 1)!;
      expect(e5.usdTotal, 10);
      expect(e5.maxGroth, BigInt.from(116279069767));
      expect(e5.minGroth, BigInt.from(116144018583));
      final exact5 = BigInt.from(116213166091); // register5 kernel
      expect(exact5 >= e5.minGroth && exact5 <= e5.maxGroth, isTrue);

      final e4 = p.estimate(BansName(quotedName4), 2)!;
      expect(e4.usdTotal, 240);
      final exact4 = BigInt.from(2789115986201); // register4 kernel
      expect(exact4 >= e4.minGroth && exact4 <= e4.maxGroth, isTrue);
    });

    test('with an exact median it reproduces research/05\'s kernels', () {
      // Measured 2026-10-06 at median 0.0097620805: 102437180271 groth for
      // 5+ chars, 1229246163253 for 4 chars (research/05 §B.6).
      BansPriceEstimate at(int usd) => BansPriceEstimate.fromMedianText(
        usdPerPeriod: usd,
        periods: 1,
        medianText: '0.0097620805',
      );
      expect(at(10).maxGroth, BigInt.from(102437180271));
      expect(at(120).maxGroth, BigInt.from(1229246163253));
    });

    test('rejects a non-number', () {
      for (final t in ['', 'abc', '0.0', '-1', '1e-3']) {
        expect(
          () => BansPriceEstimate.fromMedianText(
            usdPerPeriod: 10,
            periods: 1,
            medianText: t,
          ),
          throwsFormatException,
          reason: t,
        );
      }
    });
  });

  group('user view (privilege 1; shape from app.cpp, not observed live)', () {
    test('domains, sale proceeds and anonymous payments', () {
      final inbox = BansOutput.userView(
        '{"res": {"domains": [{"name": "alice","key": "$fakeMyKey",'
        '"hExpire": 4600000}],'
        '"raw": [{"aid": 0,"amount": 50000000000}],'
        '"anon": [{"pk": "$beamOwnerKey","aid": 3,"amount": 7,'
        '"domain": "alice"}]}}',
      );
      expect(inbox.domains.single.name, 'alice');
      expect(inbox.saleProceeds.single, BansAmount(0, BigInt.from(5e10)));
      final pay = inbox.payments.single;
      expect(pay.oneTimeKey, beamOwnerKey);
      expect(pay.assetId, 3);
      expect(pay.amount, BigInt.from(7));
      expect(pay.name, 'alice');
      expect(inbox.isEmpty, isFalse);
    });
  });

  group('robust decoding', () {
    test('uint64 amounts beyond 2^63 stay exact', () {
      final d = BansOutput.viewName(
        '{"res": {"key": "$beamOwnerKey","hExpire": 4918184,'
        '"price": {"aid": 7,"amount": 18446744073709551615}}}',
        BansName('beam'),
      )!;
      expect(d.salePrice!.amount, BigInt.parse('18446744073709551615'));
    });

    test('names made of digits are left alone', () {
      final list = BansOutput.viewDomain(
        '{"domains": [{"name": "12345678901234567890","key": "$beamOwnerKey",'
        '"hExpire": 1}]}',
      );
      expect(list.single.name, '12345678901234567890');
    });

    test('bad shapes are FormatExceptions, not casts', () {
      expect(() => BansOutput.decode('nope'), throwsFormatException);
      expect(() => BansOutput.decode('[1]'), throwsFormatException);
      expect(
        () => BansOutput.viewName(
          '{"res": {"key": "zz","hExpire": 1}}',
          BansName('abc'),
        ),
        throwsFormatException,
      );
      expect(BansOutput.decode(''), isEmpty);
    });

    test('every refusal the shaders write maps to a plain message', () {
      // These three fall back to a generic message that quotes the text.
      const generic = {
        BansRefusal.unknown,
        BansRefusal.contractStateMissing,
        BansRefusal.invalidAccountKey,
      };
      for (final r in BansRefusal.values) {
        if (r == BansRefusal.unknown) continue;
        final e = BansShaderRefused(r.wire);
        expect(e.refusal, r, reason: r.wire);
        if (!generic.contains(r)) {
          expect(e.message, isNot(contains(r.wire)), reason: r.wire);
        }
      }
      final other = BansShaderRefused('something new');
      expect(other.refusal, BansRefusal.unknown);
      expect(other.message, contains('something new'));
    });

    test('recorded refusals', () {
      expect(
        () => BansOutput.decode(bansOutput('register_taken')),
        refused(BansRefusal.ownedByOther),
      );
      expect(
        () => BansOutput.decode(bansOutput('register_51')),
        refused(BansRefusal.periodTooLong),
      );
      expect(
        () => BansOutput.decode(bansOutput('extend_other')),
        refused(BansRefusal.ownedByOther),
      );
      expect(
        () => BansOutput.decode(bansOutput('buy_not_for_sale')),
        refused(BansRefusal.notForSale),
      );
      expect(
        () => BansOutput.decode(bansOutput('pay_unreg')),
        refused(BansRefusal.notRegistered),
      );
      expect(
        () => BansOutput.decode(bansOutput('pay_expired')),
        refused(BansRefusal.domainExpired),
      );
      expect(
        () => BansOutput.decode(bansOutput('pay_zero')),
        refused(BansRefusal.amountMissing),
      );
      expect(
        () => BansOutput.decode(bansOutput('receive_raw')),
        refused(BansRefusal.noFunds),
      );
    });
  });
}
