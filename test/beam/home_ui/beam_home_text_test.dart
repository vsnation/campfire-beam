/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The BEAM home's wording, without pumping anything: amounts, the name
// payments line, the portfolio estimate, the sync banner per verdict, the
// node chip, the Send-paused reason and the claim sheet.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_models.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/price/beam_asset_pricer.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_sync_tracker.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_text.dart';

import 'home_ui_support.dart';

BansPendingSummary _summary(Map<String, Map<int, BigInt>> byName) =>
    BansInboxMonitor.summarize(inboxOf(byName), DateTime(2026, 10, 6));

void main() {
  group('amounts', () {
    test('exact, grouped, trailing zeros trimmed', () {
      expect(BeamHomeText.amount(g(2.5)), '2.5');
      expect(BeamHomeText.amount(g(1000)), '1,000');
      expect(BeamHomeText.amount(BigInt.from(1)), '0.00000001');
      expect(BeamHomeText.amount(g(1234567.125)), '1,234,567.125');
    });

    test('estimates round down, never up', () {
      expect(BeamHomeText.estimate(g(22.999)), '22.99');
      expect(BeamHomeText.estimate(g(0.123456)), '0.1234');
    });

    test('BEAM first, then assets by id; unverified assets by id only', () {
      expect(
        BeamHomeText.amounts({174: g(1000), 0: g(2.5), 205: g(3)}),
        '2.5 BEAM + 1,000 FOMO + 3 #205',
      );
    });
  });

  // Seen in the DMG test: 0.01 BEAM headlined "0.00 USD".
  test('a fiat value under a cent says so, never "0.00"', () {
    final f = beamFormat(usdPerBeam: '0.0089');
    expect(f.fiatOfGroth(g(0.01)), 'under 0.01 USD');
    expect(f.fiatOfGroth(g(2.5)), '0.02 USD');
    expect(f.fiatOfGroth(BigInt.zero), '0.00 USD');
    expect(beamFormat(usdPerBeam: null).fiatOfGroth(g(2.5)), isNull);
  });

  group('name payments line', () {
    test('one name, one asset', () {
      final t = BeamHomeText.namePayments(
        _summary({
          'alice': {0: g(2.5)},
        }),
      )!;
      expect(t.line, 'Sent to your name alice.beam: 2.5 BEAM');
    });

    test('one name, several assets', () {
      final t = BeamHomeText.namePayments(
        _summary({
          'alice': {0: g(2.5), 174: g(1000)},
        }),
      )!;
      expect(t.line, 'Sent to your name alice.beam: 2.5 BEAM + 1,000 FOMO');
    });

    test('several names', () {
      final t = BeamHomeText.namePayments(
        _summary({
          'alice': {0: g(2)},
          'bob': {0: g(0.5)},
        }),
      )!;
      expect(t.line, 'Sent to your names: 2.5 BEAM');
    });

    test('nothing waiting, or a core that cannot see the inbox: no line', () {
      expect(BeamHomeText.namePayments(null), isNull);
      expect(BeamHomeText.namePayments(_summary({})), isNull);
      expect(
        BeamHomeText.namePayments(
          BansPendingSummary.empty(
            BansInboxVisibility.needsCampfireCore,
            DateTime(2026),
          ),
        ),
        isNull,
      );
    });

    test('a name the contract could not have issued is not displayed', () {
      final t = BeamHomeText.namePayments(
        _summary({
          'Evil\u202Ename': {0: g(1)},
        }),
      )!;
      expect(t.lead, 'Sent to your names');
      expect(t.line, isNot(contains('Evil')));
    });
  });

  group('portfolio', () {
    final totals = {
      0: assetTotals(0, 13),
      174: assetTotals(174, 1000),
      205: assetTotals(205, 50),
    };

    test('only BEAM: no line at all', () {
      expect(BeamHomeText.portfolio(totals: {0: assetTotals(0, 1)}), isNull);
    });

    test('before prices arrive: how many assets, no value', () {
      final p = BeamHomeText.portfolio(totals: totals)!;
      expect(p.total, 'Plus 2 assets');
      expect(p.note, isNull);
    });

    test('priced assets are added as an estimate; unpriced ones are '
        'named, never counted as zero', () {
      final pricer = BeamAssetPricer([beamPool(174, 10000, 1000000)]);
      final p = BeamHomeText.portfolio(
        totals: totals,
        pricer: pricer,
        fiat: (groth) {
          final usd = groth.toDouble() / 1e8 * 0.0089;
          return '\$${usd.toStringAsFixed(2)}';
        },
      )!;
      // 13 BEAM + 1,000 FOMO at 0.01 BEAM each = 23 BEAM.
      expect(p.total, r'With assets ≈ 23 BEAM · $0.20 (estimate)');
      expect(p.note, '1 asset has no price');
    });

    test('hidden assets are neither counted nor valued (M-4)', () {
      // A spam airdrop with its own deep pool, hidden by the user, and the
      // unpriced #205, hidden too.
      final withSpam = {...totals, 999: assetTotals(999, 1)};
      final pricer = BeamAssetPricer([
        beamPool(174, 10000, 1000000),
        beamPool(999, 5000, 0.00000001, lp: 901),
      ]);
      final visible = BeamHomeText.portfolio(
        totals: withSpam,
        pricer: pricer,
        hidden: {999, 205},
      )!;
      expect(visible.total, 'With assets ≈ 23 BEAM (estimate)');
      expect(visible.note, isNull);

      // Everything hidden but BEAM: the line goes, as for a BEAM-only
      // wallet.
      expect(
        BeamHomeText.portfolio(
          totals: withSpam,
          pricer: pricer,
          hidden: {174, 205, 999},
        ),
        isNull,
      );
    });
  });

  group('sync banner', () {
    test('synced: nothing', () {
      expect(BeamHomeText.syncBanner(assessment: synced()), isNull);
    });

    test('catching up: blocks and time behind, progress, sending paused', () {
      final b = BeamHomeText.syncBanner(
        assessment: catchingUp(42),
        maxBlocksBehind: 84,
      )!;
      expect(b.title, 'Catching up: 42 blocks behind (about 42 minutes)');
      expect(b.detail, contains('Sending is paused'));
      expect(b.progress, 0.5);
      expect(b.urgent, isFalse);
      expect(b.mood, BeamBannerMood.syncing);
    });

    test('stalled at the HF6 boundary: says so, names the fix, at once', () {
      final b = BeamHomeText.syncBanner(assessment: stalledAtHf6())!;
      expect(b.title, contains('stuck on an old version'));
      expect(b.detail, contains('3,928,666'));
      expect(b.detail, contains('Sending is off'));
      expect(b.actionLabel, 'Try another node');
      expect(b.action, BeamHomeAction.nodeSettings);
      expect(b.urgent, isTrue);
      expect(b.tone, BeamBannerTone.problem);
    });

    test('restore scan: never a bare zero, with progress', () {
      final b = BeamHomeText.syncBanner(
        assessment: synced(),
        scanning: true,
        scan: const BeamScanProgress(430, 1000),
      )!;
      expect(b.title, 'Scanning for your coins… 43%');
      expect(b.progress, 0.43);
      expect(b.urgent, isTrue);
    });

    test('restore scan: the headline says it is scanning, not 0', () {
      expect(
        BeamHomeText.scanningHeadline(const BeamScanProgress(430, 1000)),
        'Scanning… 43%',
      );
      // Rounded down: 99.9% is not "100%" while the scan still runs.
      expect(
        BeamHomeText.scanningHeadline(const BeamScanProgress(999, 1000)),
        'Scanning… 99%',
      );
      expect(BeamHomeText.scanningHeadline(null), 'Scanning…');
      expect(
        BeamHomeText.scanningHeadline(const BeamScanProgress(0, 0)),
        'Scanning…',
      );
      expect(BeamHomeText.scanPercent(const BeamScanProgress(1, 3)), 33);
      expect(BeamHomeText.foundSoFar, 'Found so far');
    });

    test('restore scan: "nothing found yet" until any coin turns up', () {
      bool nothing({
        bool scanning = true,
        BigInt? beam,
        Map<int, num> assets = const {},
      }) => beamNothingFoundYet(
        scanning: scanning,
        beamTotal: beam ?? BigInt.zero,
        totals: {
          for (final e in assets.entries) e.key: assetTotals(e.key, e.value),
        },
      );

      expect(nothing(), isTrue);
      expect(nothing(assets: {0: 0, 174: 0}), isTrue);
      // Not scanning: a 0 is just a 0.
      expect(nothing(scanning: false), isFalse);
      // BEAM found, or arriving (the cached total includes what arrives).
      expect(nothing(beam: BigInt.one), isFalse);
      // Only an asset found so far.
      expect(nothing(assets: {174: 5}), isFalse);
    });

    test('a stuck node outranks the restore scan', () {
      final b = BeamHomeText.syncBanner(
        assessment: stalledAtHf6(),
        scanning: true,
      )!;
      expect(b.title, contains('stuck'));
    });

    test('core not installed: the plain message, no button to nowhere', () {
      final b = BeamHomeText.syncBanner(
        assessment: connecting,
        problem: const BeamWalletException(
          BeamWalletProblem.coreNotInstalled,
          BeamWalletMessages.coreNotInstalled,
        ),
      )!;
      expect(b.title, 'BEAM core not installed');
      expect(b.detail, contains('Nothing was lost'));
      expect(b.action, BeamHomeAction.none);
      expect(b.mood, BeamBannerMood.broken);
    });

    test('an unreachable node offers another node', () {
      final b = BeamHomeText.syncBanner(
        assessment: connecting,
        problem: BeamWalletException(
          BeamWalletProblem.nodeUnreachable,
          BeamWalletMessages.nodeUnreachable('node.example:8100'),
        ),
      )!;
      expect(b.action, BeamHomeAction.nodeSettings);
      expect(b.mood, BeamBannerMood.behind);
    });

    test('connecting waits its grace period', () {
      final b = BeamHomeText.syncBanner(assessment: connecting)!;
      expect(b.urgent, isFalse);
      expect(b.detail, contains('Sending is paused'));
    });
  });

  group('send paused reason', () {
    test('null when synced', () {
      expect(BeamHomeText.sendPaused(assessment: synced()), isNull);
    });

    test('catching up and stalled say why', () {
      expect(
        BeamHomeText.sendPaused(assessment: catchingUp(42)),
        'Sending is paused while the wallet catches up (42 blocks behind).',
      );
      expect(
        BeamHomeText.sendPaused(assessment: stalledAtHf6()),
        startsWith('Sending is off: Your node is stuck'),
      );
    });
  });

  group('node chip', () {
    test('public, syncing, private', () {
      expect(BeamHomeText.nodeChip(null), 'Public node');
      expect(
        BeamHomeText.nodeChip(
          const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.downloading,
            percent: 43,
          ),
        ),
        'Private node syncing 43%',
      );
      expect(
        BeamHomeText.nodeChip(
          const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.active,
            onPrivateNode: true,
          ),
        ),
        'Private node',
      );
      expect(
        BeamHomeText.nodeChip(
          const BeamPrivateNodeStatus(phase: BeamPrivateNodePhase.failed),
        ),
        'Public node',
      );
    });
  });

  group('claim sheet text', () {
    test('BEAM waiting pays its own fee', () {
      final s = _summary({
        'alice': {0: g(2.5)},
      });
      final t = BeamHomeText.claim(
        summary: s,
        advice: s.advise(beamAvailable: BigInt.zero),
        canSpend: true,
      );
      expect(t.receive, ['2.5 BEAM']);
      expect(t.fee, '0.011 BEAM');
      expect(t.feeNote, startsWith('Pays its own fee'));
      expect(t.blocker, isNull);
      expect(t.warning, isNull);
      expect(t.cta, 'Claim 2.5 BEAM');
    });

    test('tokens only with an empty wallet: needs the fee first', () {
      final s = _summary({
        'alice': {174: g(1000)},
      });
      final t = BeamHomeText.claim(
        summary: s,
        advice: s.advise(beamAvailable: BigInt.zero),
        canSpend: true,
      );
      expect(t.blocker, contains('You need 0.011 BEAM in this wallet'));
    });

    test('BEAM-only worth no more than the fee: warned, not forbidden', () {
      final s = _summary({
        'alice': {0: g(0.005)},
      });
      final advice = s.advise(beamAvailable: g(1));
      final t = BeamHomeText.claim(summary: s, advice: advice, canSpend: true);
      expect(advice.canClaim, isTrue);
      expect(t.warning, contains('gains you nothing'));
      expect(t.blocker, isNull);
    });

    test('the built transaction, not the estimate, sets fee and amounts', () {
      final s = _summary({
        'alice': {0: g(2.5)},
      });
      final built = claimFor(
        inboxOf({
          'alice': {0: g(2.5)},
        }),
        fee: BigInt.from(1250000),
      ).summary;
      final t = BeamHomeText.claim(
        summary: s,
        advice: s.advise(beamAvailable: BigInt.zero),
        canSpend: true,
        built: built,
      );
      expect(t.fee, '0.0125 BEAM');
    });

    test('not synced: claiming is paused', () {
      final s = _summary({
        'alice': {0: g(2.5)},
      });
      final t = BeamHomeText.claim(
        summary: s,
        advice: s.advise(beamAvailable: BigInt.zero),
        canSpend: false,
      );
      expect(t.blocker, startsWith('Claiming is paused'));
    });

    test('more than 30 payments: says it takes several claims', () {
      final many = BansInboxMonitor.summarize(
        BansInbox(
          domains: const [],
          saleProceeds: const [],
          payments: [
            for (var i = 0; i < 45; i++)
              BansIncomingPayment(
                oneTimeKey: 'k$i',
                assetId: 0,
                amount: g(1),
                name: 'alice',
              ),
          ],
        ),
        DateTime(2026),
      );
      final t = BeamHomeText.claim(
        summary: many,
        advice: many.advise(beamAvailable: BigInt.zero),
        canSpend: true,
      );
      expect(t.batches, contains('2 claims'));
    });
  });
}
