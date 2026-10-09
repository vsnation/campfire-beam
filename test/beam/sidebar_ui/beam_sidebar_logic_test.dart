/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The side menu's rules without widgets: which wallet the BEAM pages use,
// what the node chip says, what the Assets total says, and the menu order.

import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_assets_page.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_hub_page.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar_node_chip.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_wallet_home.dart'
    show BeamHomeFormat;
import 'package:stackwallet/widgets/beam/wiring/beam_features.dart';

typedef W = ({String id, bool open});

W? _resolve(List<W> wallets, String? chosen) => resolveBeamSidebarWallet<W>(
  wallets: wallets,
  idOf: (w) => w.id,
  isOpen: (w) => w.open,
  chosenId: chosen,
);

const _a = (id: 'a', open: false);
const _b = (id: 'b', open: true);
const _c = (id: 'c', open: false);

const _connecting = BeamSyncConnecting(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
);
const _synced = BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: 100,
  networkHeight: 100,
);
const _catchingUp = BeamSyncCatchingUp(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  blockInterval: Duration(minutes: 1),
  blocksBehind: 42,
);
const _stalled = BeamSyncStalled(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  reason: BeamStallReason.tipTooOld,
  blockInterval: Duration(minutes: 1),
  forkHeight: 3928666,
);
const _notConnected = BeamSyncNotConnected(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.unavailable,
  networkReachable: false,
);

BeamHomeFormat _format({Decimal? price}) => BeamHomeFormat(
  formatBeam: (a) => '${a.decimal} BEAM',
  pricesOn: price != null,
  price: price,
  currency: 'USD',
);

BigInt _g(num beam) => BigInt.from((beam * 100000000).round());

void main() {
  group('which wallet the BEAM pages use', () {
    test('none without BEAM wallets', () {
      expect(_resolve([], 'a'), isNull);
    });

    test('the chosen one (open in My Campfire, or picked) wins', () {
      expect(_resolve([_a, _b, _c], 'c'), _c);
      expect(_resolve([_a, _b], 'a'), _a, reason: 'even when b is running');
    });

    test('a chosen wallet that is gone is ignored', () {
      expect(_resolve([_a], 'gone'), _a);
      expect(_resolve([_a, _c], 'gone'), isNull);
    });

    test('the only wallet, chosen or not', () {
      expect(_resolve([_a], null), _a);
    });

    test('several and none chosen: the only one running', () {
      expect(_resolve([_a, _b, _c], null), _b);
    });

    test('several, none chosen, none or several running: ask', () {
      expect(_resolve([_a, _c], null), isNull);
      expect(_resolve([_b, (id: 'd', open: true)], null), isNull);
    });
  });

  group('the node chip says only what the core reports', () {
    BeamSidebarNodeState s(
      BeamSyncAssessment? a, {
      bool hasWallet = true,
      bool isOpen = true,
      BeamPrivateNodeStatus? node,
      bool problem = false,
    }) => beamSidebarNodeState(
      hasWallet: hasWallet,
      isOpen: isOpen,
      assessment: a,
      privateNode: node,
      coreProblem: problem,
    );

    test('synced on a public node / on the private node', () {
      expect(s(_synced), BeamSidebarNodeState.publicNode);
      expect(s(_synced).label, 'Public node');
      expect(
        s(
          _synced,
          node: const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.active,
            onPrivateNode: true,
          ),
        ),
        BeamSidebarNodeState.privateNode,
      );
      // A private node still downloading does not make the wallet private.
      expect(
        s(
          _synced,
          node: const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.downloading,
            percent: 40,
          ),
        ),
        BeamSidebarNodeState.publicNode,
      );
    });

    test('behind, stopped, connecting, not connected', () {
      expect(s(_catchingUp).label, 'Catching up');
      expect(s(_stalled).label, 'Not syncing');
      expect(s(_connecting).label, 'Connecting');
      expect(s(_notConnected).label, 'Not connected');
    });

    test('never "connected" without a running core or a wallet', () {
      expect(s(_synced, isOpen: false).label, 'Not connected');
      expect(s(_synced, problem: true).label, 'Not connected');
      expect(s(null, hasWallet: false).label, 'Not connected');
      for (final st in BeamSidebarNodeState.values) {
        if (st.healthy) {
          expect(st.label, anyOf('Public node', 'Private node'));
        }
      }
    });
  });

  group('the Assets total says what it counts', () {
    test('fiat first, BEAM under it, with what it leaves out', () {
      final t = BeamSidebarAssetsTotal.build(
        beamSpendable: _g(12.5),
        portfolio: BeamAssetPortfolio(
          valueGroth: _g(7.5),
          unpriced: 2,
          marketKnown: true,
        ),
        holdsAssets: true,
        format: _format(price: Decimal.parse('0.5')),
      );
      expect(t.primary, '10.00 USD');
      expect(t.secondary, '≈ 20 BEAM');
      expect(t.note, contains('2 assets have no price and are not counted'));
    });

    test('in BEAM, saying so, when price lookups are off', () {
      final t = BeamSidebarAssetsTotal.build(
        beamSpendable: _g(1),
        portfolio: BeamAssetPortfolio(
          valueGroth: BigInt.zero,
          unpriced: 0,
          marketKnown: false,
        ),
        holdsAssets: true,
        format: _format(),
      );
      expect(t.primary, '≈ 1 BEAM');
      expect(t.secondary, isNull);
      expect(
        t.note,
        contains('asset prices load once the wallet is connected'),
      );
      expect(t.note, contains('Price lookups are off in Settings'));
    });
  });

  group('the menu', () {
    test('BEAM items in their order, each with its own menu id', () {
      expect(BeamSidebarDestination.values.map((d) => d.label).toList(), [
        'Buy BEAM',
        'Swap',
        'Bridge',
        'Assets',
        'Names',
        'dApps',
        'Airdrops',
        'Tokens',
      ]);
      expect(
        BeamSidebarDestination.values.map((d) => d.menuId).toSet().length,
        BeamSidebarDestination.values.length,
      );
      // Upstream ids keep their indexes (DesktopHomeView's IndexedStack
      // treats index 0, My Campfire, specially).
      expect(DesktopMenuItemId.myStack.index, 0);
      expect(DesktopMenuItemId.about.index, 8);
      for (final d in BeamSidebarDestination.values) {
        expect(d.menuId.index, greaterThan(DesktopMenuItemId.about.index));
        expect(BeamSidebarDestination.ofMenuId(d.menuId), d);
        expect(BeamSidebarDestination.ofFeature(d.feature), d);
      }
      expect(BeamSidebarDestination.ofFeature(BeamFeature.node), isNull);
    });

    test('Airdrops and Tokens list the wallet screen\'s three tasks', () {
      expect(
        BeamSidebarTask.of(BeamSidebarDestination.airdrops)
            .map((t) => (t.key, t.title))
            .toList(),
        [
          (const Key('beamAirdropClaim'), 'Claim a code'),
          (const Key('beamAirdropMine'), 'My airdrops'),
          (const Key('beamAirdropCreate'), 'Create codes'),
        ],
      );
      expect(
        BeamSidebarTask.of(BeamSidebarDestination.tokens)
            .map((t) => (t.key, t.title))
            .toList(),
        [
          (const Key('beamTokensCreate'), 'Create a token'),
          (const Key('beamTokensMine'), 'My tokens'),
          (const Key('beamTokensBurn'), 'Burn tokens'),
        ],
      );
    });

    test('amounts in the total use Campfire\'s Amount', () {
      // Guards the groth arithmetic the total relies on.
      expect(
        Amount(rawValue: _g(20), fractionDigits: 8).decimal,
        Decimal.fromInt(20),
      );
    });
  });
}
