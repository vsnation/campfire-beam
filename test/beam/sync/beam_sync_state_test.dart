// Table-driven tests for the honest "synced" predicate (project rules R5).
//
// Heights and times are realistic: on 2026-10-06 ~07:40 UTC the explorers
// reported height ~4067900, and HF6 froze pre-7.5.14493 nodes at 3928665
// on 2026-06-30.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_messages.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';

final _now = DateTime.utc(2026, 10, 6, 7, 40);
const _tip = 4067900;

DateTime _ago(Duration d) => _now.subtract(d);

const _s = Duration(seconds: 1);
const _min = Duration(minutes: 1);

BeamWalletSyncInput _wallet({
  int height = _tip,
  Duration age = const Duration(seconds: 45),
  bool isInSync = true,
  int? headerTip = _tip,
  bool? connected = true,
  bool? ownNode,
}) => BeamWalletSyncInput(
  currentHeight: height,
  currentStateTimestamp: _ago(age),
  isInSync: isInSync,
  headerTipHeight: headerTip,
  nodeConnected: connected,
  ownNode: ownNode,
);

/// An explorer answer received [receivedAgo] before [_now]. [clockOffset] is
/// how far the device clock was ahead of the server's when it arrived.
BeamExplorerStatus _explorer({
  int height = _tip,
  Duration tipAge = const Duration(seconds: 60),
  Duration clockOffset = Duration.zero,
  bool withDate = true,
}) => BeamExplorerStatus(
  height: height,
  timestamp: _now.subtract(clockOffset).subtract(tipAge),
  hash: 'ab' * 32,
  node: 'https://explorer.0xmx.net/api',
  receivedAt: _now,
  serverTime: withDate ? _now.subtract(clockOffset) : null,
);

BeamSyncProgress _watching(
  Duration since, {
  Duration? advancedAgo,
  double? speed,
}) => BeamSyncProgress(
  observingSince: _ago(since),
  heightLastAdvancedAt: advancedAgo == null ? null : _ago(advancedAgo),
  blocksPerSecond: speed,
);

class _Case {
  const _Case(
    this.name, {
    required this.wallet,
    required this.explorer,
    required this.expect,
    this.node = BeamNodeKind.publicNode,
    this.progress,
  });

  final String name;
  final BeamWalletSyncInput? wallet;
  final BeamExplorerStatus? explorer;
  final BeamNodeKind node;
  final BeamSyncProgress? progress;
  final void Function(BeamSyncAssessment a) expect;
}

void _isSynced(
  BeamSyncAssessment a, {
  required BeamExplorerCheck check,
  required bool verified,
}) {
  expect(a, isA<BeamSynced>());
  expect(a.canSpend, isTrue);
  expect(a.explorerCheck, check);
  expect((a as BeamSynced).verified, verified);
  expect(a.action, BeamSyncAction.none);
}

void _isStalled(
  BeamSyncAssessment a,
  BeamStallReason reason, {
  int? behind,
  BeamSyncAction? action,
}) {
  expect(a, isA<BeamSyncStalled>(), reason: '$a');
  expect(a.canSpend, isFalse);
  final s = a as BeamSyncStalled;
  expect(s.reason, reason);
  if (behind != null) expect(s.blocksBehind, behind);
  if (action != null) expect(s.action, action);
}

void _isCatchingUp(BeamSyncAssessment a, {int? behind}) {
  expect(a, isA<BeamSyncCatchingUp>(), reason: '$a');
  expect(a.canSpend, isFalse);
  expect(a.action, BeamSyncAction.wait);
  if (behind != null) expect((a as BeamSyncCatchingUp).blocksBehind, behind);
}

final _cases = <_Case>[
  // --- not ready ---------------------------------------------------------
  _Case(
    'no wallet status yet -> connecting',
    wallet: null,
    explorer: _explorer(),
    expect: (a) {
      expect(a, isA<BeamSyncConnecting>());
      expect(a.canSpend, isFalse);
      expect(a.networkHeight, _tip);
    },
  ),
  _Case(
    'height 0 (core has no chain state) -> connecting',
    wallet: _wallet(height: 0),
    explorer: _explorer(),
    expect: (a) => expect(a, isA<BeamSyncConnecting>()),
  ),
  _Case(
    'node disconnected, explorer up -> try another node',
    wallet: _wallet(connected: false),
    explorer: _explorer(),
    expect: (a) {
      expect(a, isA<BeamSyncNotConnected>());
      expect((a as BeamSyncNotConnected).networkReachable, isTrue);
      expect(a.action, BeamSyncAction.tryAnotherNode);
      expect(a.canSpend, isFalse);
    },
  ),
  _Case(
    'node disconnected, explorer down too -> check internet',
    wallet: _wallet(connected: false),
    explorer: null,
    expect: (a) {
      expect((a as BeamSyncNotConnected).networkReachable, isFalse);
      expect(a.action, BeamSyncAction.checkInternet);
    },
  ),
  _Case(
    'private node disconnected -> use a public node',
    wallet: _wallet(connected: false),
    explorer: _explorer(),
    node: BeamNodeKind.privateNode,
    expect: (a) => expect(a.action, BeamSyncAction.usePublicNode),
  ),

  // --- synced ------------------------------------------------------------
  _Case(
    'healthy and confirmed by a fresh explorer -> synced, verified',
    wallet: _wallet(height: _tip - 2, headerTip: _tip - 2),
    explorer: _explorer(),
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.agrees, verified: true),
  ),
  _Case(
    'explorer exactly 5 blocks ahead -> still synced',
    wallet: _wallet(height: _tip - 5, headerTip: _tip - 5),
    explorer: _explorer(),
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.agrees, verified: true),
  ),
  _Case(
    'header tip 1 ahead of processed (block arriving) -> still synced',
    wallet: _wallet(height: _tip - 1, headerTip: _tip),
    explorer: _explorer(),
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.agrees, verified: true),
  ),
  _Case(
    'tip exactly 10 min old -> still synced',
    wallet: _wallet(age: const Duration(minutes: 10)),
    explorer: _explorer(),
    expect: (a) => expect(a, isA<BeamSynced>()),
  ),
  _Case(
    'explorer down -> synced on the core\'s own checks, unverified',
    wallet: _wallet(),
    explorer: null,
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.unavailable, verified: false),
  ),
  _Case(
    'explorer stale (its tip 30 min old) -> synced, unverified',
    wallet: _wallet(),
    explorer: _explorer(height: _tip - 30, tipAge: const Duration(minutes: 30)),
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.stale, verified: false),
  ),
  _Case(
    'explorer fresh but lagging the wallet -> synced, unverified',
    wallet: _wallet(),
    explorer: _explorer(height: _tip - 20),
    expect: (a) =>
        _isSynced(a, check: BeamExplorerCheck.behindWallet, verified: false),
  ),
  _Case(
    'own node (core says own_node) healthy -> synced, private',
    wallet: _wallet(ownNode: true),
    explorer: _explorer(),
    expect: (a) {
      _isSynced(a, check: BeamExplorerCheck.agrees, verified: true);
      expect(a.node, BeamNodeKind.privateNode);
    },
  ),
  _Case(
    'device clock 3 min off but everything passes -> synced (clock only '
    'explains failures)',
    wallet: _wallet(),
    explorer: _explorer(clockOffset: const Duration(minutes: 3)),
    expect: (a) => expect(a, isA<BeamSynced>()),
  ),

  // --- HF6 ---------------------------------------------------------------
  _Case(
    'HF6: frozen at 3928665 since 2026-06-30, explorer at 4067900 -> '
    'stuck below hard fork',
    wallet: _wallet(
      height: 3928665,
      age: _now.difference(DateTime.utc(2026, 6, 30, 9, 12)),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: _explorer(),
    expect: (a) {
      _isStalled(
        a,
        BeamStallReason.stuckBelowHardFork,
        behind: 139235,
        action: BeamSyncAction.tryAnotherNode,
      );
      expect(a.walletHeight, 3928665);
      expect(a.networkHeight, 4067900);
      expect(a.explorerCheck, BeamExplorerCheck.aheadOfWallet);
    },
  ),
  _Case(
    'HF6 on our private node -> stuck below hard fork, use a public node',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: _explorer(),
    node: BeamNodeKind.privateNode,
    expect: (a) => _isStalled(
      a,
      BeamStallReason.stuckBelowHardFork,
      action: BeamSyncAction.usePublicNode,
    ),
  ),
  _Case(
    'HF6 even though the core still claims is_in_sync (stale flag)',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      headerTip: null,
    ),
    explorer: _explorer(),
    expect: (a) => _isStalled(a, BeamStallReason.stuckBelowHardFork),
  ),
  _Case(
    'HF6 with every explorer down -> still recognised at the fork boundary',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: null,
    expect: (a) {
      _isStalled(a, BeamStallReason.stuckBelowHardFork);
      expect(a.explorerCheck, BeamExplorerCheck.unavailable);
      expect((a as BeamSyncStalled).blocksBehind, 0);
    },
  ),
  _Case(
    'HF6 with a stale explorer (an hour old) still proves the chain moved',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: _explorer(height: 4067840, tipAge: const Duration(hours: 1)),
    expect: (a) {
      _isStalled(a, BeamStallReason.stuckBelowHardFork, behind: 139175);
      expect(a.explorerCheck, BeamExplorerCheck.stale);
    },
  ),
  _Case(
    'HF6 boundary while the monitor is still in its grace period -> stalled '
    'at once (unambiguous)',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: _explorer(),
    progress: _watching(const Duration(seconds: 20)),
    expect: (a) => _isStalled(a, BeamStallReason.stuckBelowHardFork),
  ),
  _Case(
    'old wallet below the fork whose node follows the new chain -> '
    'catching up, not "stuck"',
    wallet: _wallet(
      height: 3900000,
      age: const Duration(days: 120),
      isInSync: false,
      headerTip: _tip,
    ),
    explorer: _explorer(),
    expect: (a) => _isCatchingUp(a, behind: _tip - 3900000),
  ),
  _Case(
    'below the fork, not at the boundary, watched 10 min without moving -> '
    'stuck below hard fork',
    wallet: _wallet(
      height: 3920000,
      age: const Duration(days: 100),
      isInSync: false,
      headerTip: 3920000,
    ),
    explorer: _explorer(),
    progress: _watching(const Duration(minutes: 10)),
    expect: (a) => _isStalled(a, BeamStallReason.stuckBelowHardFork),
  ),

  // --- tip too old -------------------------------------------------------
  _Case(
    'is_in_sync true but tip 20 min old, nothing newer known -> tip too old',
    wallet: _wallet(
      height: _tip - 20,
      age: const Duration(minutes: 20),
      headerTip: _tip - 20,
    ),
    explorer: _explorer(),
    expect: (a) {
      _isStalled(
        a,
        BeamStallReason.tipTooOld,
        behind: 20,
        action: BeamSyncAction.tryAnotherNode,
      );
      expect((a as BeamSyncStalled).tipAge, const Duration(minutes: 20));
    },
  ),
  _Case(
    'tip 10 min 1 s old -> no longer synced',
    wallet: _wallet(age: const Duration(minutes: 10, seconds: 1)),
    explorer: _explorer(),
    expect: (a) => _isStalled(a, BeamStallReason.tipTooOld),
  ),
  _Case(
    'tip too old on our private node -> use a public node',
    wallet: _wallet(
      height: _tip - 20,
      age: const Duration(minutes: 20),
      headerTip: _tip - 20,
    ),
    explorer: _explorer(),
    node: BeamNodeKind.privateNode,
    expect: (a) => _isStalled(
      a,
      BeamStallReason.tipTooOld,
      action: BeamSyncAction.usePublicNode,
    ),
  ),
  _Case(
    'tip 20 min old but the monitor just started watching -> catching up',
    wallet: _wallet(
      height: _tip - 20,
      age: const Duration(minutes: 20),
      headerTip: _tip - 20,
    ),
    explorer: _explorer(),
    progress: _watching(const Duration(seconds: 30)),
    expect: (a) => _isCatchingUp(a, behind: 20),
  ),
  _Case(
    'tip 20 min old and height advancing -> catching up with an ETA',
    wallet: _wallet(
      height: _tip - 120,
      age: const Duration(minutes: 20),
      headerTip: _tip - 120,
    ),
    explorer: _explorer(),
    progress: _watching(
      const Duration(minutes: 8),
      advancedAgo: const Duration(seconds: 5),
      speed: 1.0,
    ),
    expect: (a) {
      _isCatchingUp(a, behind: 120);
      // 120 blocks at 1 block/s while the chain adds 1/60 block/s.
      expect((a as BeamSyncCatchingUp).eta, const Duration(seconds: 123));
    },
  ),
  _Case(
    'catching up slower than the chain grows -> no ETA',
    wallet: _wallet(
      height: _tip - 120,
      age: const Duration(minutes: 20),
      headerTip: _tip - 120,
    ),
    explorer: _explorer(),
    progress: _watching(
      const Duration(minutes: 8),
      advancedAgo: const Duration(seconds: 5),
      speed: 0.01,
    ),
    expect: (a) => expect((a as BeamSyncCatchingUp).eta, isNull),
  ),
  _Case(
    'tip 20 min old, watched 10 min, no progress -> tip too old',
    wallet: _wallet(
      height: _tip - 20,
      age: const Duration(minutes: 20),
      headerTip: _tip - 20,
    ),
    explorer: _explorer(),
    progress: _watching(const Duration(minutes: 10)),
    expect: (a) => _isStalled(a, BeamStallReason.tipTooOld),
  ),

  // --- header ahead of processed ------------------------------------------
  _Case(
    'headers 12 ahead of processed, snapshot -> catching up',
    wallet: _wallet(height: _tip - 12, headerTip: _tip),
    explorer: _explorer(),
    expect: (a) => _isCatchingUp(a, behind: 12),
  ),
  _Case(
    'headers 12 ahead, no explorer -> catching up (from the header tip)',
    wallet: _wallet(height: _tip - 12, headerTip: _tip),
    explorer: null,
    expect: (a) => _isCatchingUp(a, behind: 12),
  ),
  _Case(
    'headers 12 ahead and nothing applied for 8 min -> header ahead of '
    'processed',
    wallet: _wallet(height: _tip - 12, headerTip: _tip),
    explorer: _explorer(),
    progress: _watching(
      const Duration(minutes: 20),
      advancedAgo: const Duration(minutes: 8),
    ),
    expect: (a) {
      _isStalled(
        a,
        BeamStallReason.headerAheadOfProcessed,
        behind: 12,
        action: BeamSyncAction.reconnect,
      );
      expect((a as BeamSyncStalled).headerLag, 12);
    },
  ),

  // --- explorer disagrees -------------------------------------------------
  _Case(
    'core in sync with a fresh tip but explorer 6 ahead -> catching up',
    wallet: _wallet(height: _tip - 6, headerTip: _tip - 6),
    explorer: _explorer(),
    expect: (a) {
      _isCatchingUp(a, behind: 6);
      expect(a.explorerCheck, BeamExplorerCheck.aheadOfWallet);
    },
  ),
  _Case(
    'explorer 50 ahead for 10 min while the node looks current -> behind '
    'the network',
    wallet: _wallet(height: _tip - 50, headerTip: _tip - 50),
    explorer: _explorer(),
    progress: _watching(
      const Duration(minutes: 10),
      advancedAgo: const Duration(minutes: 6),
    ),
    expect: (a) => _isStalled(
      a,
      BeamStallReason.behindNetwork,
      behind: 50,
      action: BeamSyncAction.tryAnotherNode,
    ),
  ),

  // --- device clock ------------------------------------------------------
  _Case(
    'device clock 1 h ahead: tip looks old, server Date says otherwise -> '
    'device clock wrong',
    wallet: _wallet(age: const Duration(minutes: 61), isInSync: false),
    explorer: _explorer(clockOffset: const Duration(hours: 1)),
    expect: (a) {
      _isStalled(
        a,
        BeamStallReason.deviceClockWrong,
        action: BeamSyncAction.fixDeviceClock,
      );
      expect(
        (a as BeamSyncStalled).deviceClockOffset,
        const Duration(hours: 1),
      );
      expect(
        a.explorerCheck,
        BeamExplorerCheck.agrees,
        reason: 'explorer freshness is judged by the server clock',
      );
    },
  ),
  _Case(
    'HF6-frozen node on a device that is also 5 min off -> still the hard '
    'fork, not the clock',
    wallet: _wallet(
      height: 3928665,
      age: const Duration(days: 98),
      isInSync: false,
      headerTip: 3928665,
    ),
    explorer: _explorer(clockOffset: const Duration(minutes: 5)),
    expect: (a) => _isStalled(a, BeamStallReason.stuckBelowHardFork),
  ),
  _Case(
    'device clock 30 min behind: tip is in the future and the core says '
    'not in sync -> device clock wrong (no explorer needed)',
    wallet: _wallet(age: -const Duration(minutes: 30), isInSync: false),
    explorer: null,
    expect: (a) {
      _isStalled(a, BeamStallReason.deviceClockWrong);
      expect(
        (a as BeamSyncStalled).deviceClockOffset,
        -const Duration(minutes: 30),
      );
    },
  ),
];

void main() {
  group('assessBeamSync', () {
    for (final c in _cases) {
      test(c.name, () {
        final a = assessBeamSync(
          wallet: c.wallet,
          explorer: c.explorer,
          now: _now,
          node: c.node,
          progress: c.progress,
        );
        c.expect(a);
      });
    }

    test('only BeamSynced can spend, across every case above', () {
      for (final c in _cases) {
        final a = assessBeamSync(
          wallet: c.wallet,
          explorer: c.explorer,
          now: _now,
          node: c.node,
          progress: c.progress,
        );
        expect(a.canSpend, a is BeamSynced, reason: c.name);
      }
    });

    test('a hardcoded height never grants "synced"', () {
      // Way past the fork, but the core is not in sync and the tip is old.
      final a = assessBeamSync(
        wallet: _wallet(
          height: 5000000,
          age: const Duration(hours: 3),
          isInSync: false,
          headerTip: 5000000,
        ),
        explorer: null,
        now: _now,
      );
      expect(a.canSpend, isFalse);
    });

    test('same inputs, equal assessments (the monitor relies on ==)', () {
      BeamSyncAssessment run() => assessBeamSync(
        wallet: _wallet(
          height: 3928665,
          age: const Duration(days: 98),
          isInSync: false,
          headerTip: 3928665,
        ),
        explorer: _explorer(),
        now: _now,
      );
      expect(run(), run());
      expect(run().hashCode, run().hashCode);
      expect(
        run(),
        isNot(
          assessBeamSync(wallet: _wallet(), explorer: _explorer(), now: _now),
        ),
      );
    });
  });

  group('BeamSyncMessages', () {
    BeamSyncMessage describe(
      BeamWalletSyncInput? wallet,
      BeamExplorerStatus? explorer, {
      BeamNodeKind node = BeamNodeKind.publicNode,
      BeamSyncProgress? progress,
    }) => BeamSyncMessages.describe(
      assessBeamSync(
        wallet: wallet,
        explorer: explorer,
        now: _now,
        node: node,
        progress: progress,
      ),
    );

    test('HF6 stall names the old network and the numbers', () {
      final m = describe(
        _wallet(
          height: 3928665,
          age: const Duration(days: 98),
          isInSync: false,
          headerTip: 3928665,
        ),
        _explorer(),
      );
      expect(
        m.title,
        'Your node is stuck on an old version of the BEAM network',
      );
      expect(
        m.detail,
        'BEAM upgraded at block 3,928,666 and this node stopped at block '
        '3,928,665. Behind by 139,235 blocks — about 97 days. Balances are '
        'out of date. Sending is off until this is fixed.',
      );
      expect(m.actionLabel, 'Try another node');
    });

    test('catching up: blocks and time behind, and when it is done', () {
      final m = describe(
        _wallet(height: _tip - 42, headerTip: _tip),
        _explorer(),
        progress: _watching(
          const Duration(minutes: 3),
          advancedAgo: const Duration(seconds: 2),
          speed: 0.5,
        ),
      );
      expect(m.title, 'Catching up with the network');
      expect(m.detail, startsWith('Behind by 42 blocks — about 42 minutes.'));
      expect(m.detail, contains('About 1 minute left.'));
      expect(m.detail, endsWith("Sending is paused until it's done."));
      expect(m.actionLabel, isNull);
    });

    test('own node vs public node wording', () {
      final w = _wallet(height: _tip - 42, headerTip: _tip);
      expect(describe(w, _explorer()).title, 'Catching up with the network');
      expect(
        describe(w, _explorer(), node: BeamNodeKind.privateNode).title,
        'Your private node is catching up',
      );
    });

    test('not connected', () {
      expect(
        describe(_wallet(connected: false), null).title,
        "Can't reach the network",
      );
      expect(
        describe(_wallet(connected: false), null).detail,
        contains('Check your internet connection'),
      );
    });

    test('device clock', () {
      final m = describe(
        _wallet(age: const Duration(minutes: 61), isInSync: false),
        _explorer(clockOffset: const Duration(hours: 1)),
      );
      expect(m.title, "Your device's clock is wrong");
      expect(m.detail, startsWith("It's about 1 hour ahead"));
    });

    test('synced, verified and unverified', () {
      final verified = describe(_wallet(), _explorer());
      expect(verified.title, 'Up to date');
      expect(verified.detail, isNull);
      final unverified = describe(_wallet(), null);
      expect(unverified.title, 'Up to date');
      expect(unverified.detail, contains("Couldn't double-check"));
    });

    test('no jargon in any message', () {
      const banned = [
        'explorer',
        'is_in_sync',
        'header',
        'RPC',
        'wallet-api',
        'consensus',
        'HF6',
      ];
      for (final c in _cases) {
        final m = BeamSyncMessages.describe(
          assessBeamSync(
            wallet: c.wallet,
            explorer: c.explorer,
            now: _now,
            node: c.node,
            progress: c.progress,
          ),
        );
        final text = '${m.title} ${m.detail ?? ''} ${m.actionLabel ?? ''}';
        for (final word in banned) {
          expect(
            text.toLowerCase(),
            isNot(contains(word.toLowerCase())),
            reason: '${c.name}: "$text"',
          );
        }
      }
    });

    test('helpers', () {
      expect(BeamSyncMessages.number(139235), '139,235');
      expect(BeamSyncMessages.number(42), '42');
      expect(BeamSyncMessages.number(1000), '1,000');
      expect(BeamSyncMessages.approxDuration(_s * 30), 'less than a minute');
      expect(BeamSyncMessages.approxDuration(_min), 'about 1 minute');
      expect(BeamSyncMessages.approxDuration(_min * 42), 'about 42 minutes');
      expect(BeamSyncMessages.approxDuration(_min * 180), 'about 3 hours');
      expect(
        BeamSyncMessages.behindBy(42, const Duration(seconds: 60)),
        'Behind by 42 blocks — about 42 minutes',
      );
      expect(
        BeamSyncMessages.behindBy(1, const Duration(seconds: 60)),
        'Behind by 1 block — about 1 minute',
      );
    });
  });
}
