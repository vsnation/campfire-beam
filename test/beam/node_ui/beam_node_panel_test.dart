/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The "Node & sync" panel in every state the private node goes through, on
// a phone and in the desktop dialog, plus the status chip. Goldens in
// goldens/ (copied to docs/beam/screenshots/B-NODE-UI/).
//
//   scripts/beam/host_test.sh --no-analyze --copy-goldens --update-goldens \
//     test/beam/node_ui

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages/beam/node/beam_node_sync_view.dart';
import 'package:stackwallet/pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_model.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/widgets/beam/node/beam_node_widgets.dart';
import 'package:stackwallet/widgets/custom_buttons/draggable_switch_button.dart';

import 'node_ui_harness.dart';

typedef Phase = BeamPrivateNodePhase;
typedef Issue = BeamPrivateNodeIssue;

/// The states the owner asked to see, by golden name.
final Map<String, BeamNodePanelSnapshot> states = {
  'downloading': snap(
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.downloading,
      percent: 43,
      disk: disk(37, nodeGiB: 3.1),
    ),
  ),
  'finishing_setup': snap(
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.catchingUp,
      finishingPercent: 37,
      disk: disk(26, nodeGiB: 11.2),
    ),
  ),
  'catching_up': snap(
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.catchingUp,
      nodeHeight: tip - 1700,
      networkHeight: tip,
      disk: disk(30, nodeGiB: 7.4),
    ),
  ),
  'ready_waiting_for_payment': snap(
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.switching,
      waitingForWallet: true,
      nodeHeight: tip,
      networkHeight: tip,
      disk: disk(30, nodeGiB: 7.6),
    ),
  ),
  'in_use': snap(
    assessment: syncedPrivate,
    node: ownNode,
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.active,
      onPrivateNode: true,
      privateReceiveAvailable: true,
      nodeHeight: tip,
      networkHeight: tip,
      disk: disk(30, nodeGiB: 7.6),
    ),
  ),
  'not_enough_disk': snap(
    privateNode: BeamPrivateNodeStatus(
      phase: Phase.failed,
      issue: Issue.notEnoughDisk,
      disk: disk(6.2),
    ),
  ),
  'fell_back_to_public': snap(
    privateNode: const BeamPrivateNodeStatus(
      phase: Phase.stopped,
      issue: Issue.nodeExited,
    ),
    diskCheck: disk(30, nodeGiB: 7.6),
  ),
  'off': snap(enabled: false),
  'wallet_catching_up': snap(
    assessment: walletBehind,
    diskCheck: disk(37),
  ),
  'phone_without_private_node': snap(supported: false, enabled: false),
};

/// What each state must say (the owner's wording where there is one).
final Map<String, List<String>> mustSay = {
  'downloading': ['Downloading 43%', 'eu-nodes.mainnet.beam.mw:8100'],
  'finishing_setup': ['Finishing setup (37%)', '5–10 minutes'],
  'catching_up': ['Catching up 1,700 blocks'],
  'ready_waiting_for_payment': ['Ready — switching after your payment'],
  'in_use': ['Your private node is in use', 'Your private node'],
  'not_enough_disk': [
    'Your private node needs about 12 GB free while it sets up (it '
        'shrinks to about 8 GB)',
    'Try again',
  ],
  'fell_back_to_public': [
    'Your private node stopped — back on a public node',
    'Try again',
  ],
  'off': [BeamNodePanelText.toggleLabel, BeamNodePanelText.toggleExplainer],
  'wallet_catching_up': ['Catching up with the network', 'Starting soon'],
  'phone_without_private_node': [BeamNodePanelText.notOnThisDevice],
};

Future<FakeNodePanelSource> pumpPhone(
  WidgetTester tester,
  BeamNodePanelSnapshot s, {
  Size size = phone,
}) async {
  final source = FakeNodePanelSource(s);
  await pumpNodeUi(
    tester,
    BeamNodeSyncView(source: source),
    size: size,
    desktop: false,
  );
  return source;
}

Future<FakeNodePanelSource> pumpDesktop(
  WidgetTester tester,
  BeamNodePanelSnapshot s,
) async {
  final source = FakeNodePanelSource(s);
  await pumpNodeUi(
    tester,
    Builder(
      builder: (context) => Scaffold(
        backgroundColor: Theme.of(context)
            .extension<StackColors>()!
            .background,
        // Centred, as the dialog route shows it.
        body: Center(child: DesktopBeamNodeSyncDialog(source: source)),
      ),
    ),
    size: desktopWindow,
    pixelRatio: 1,
    desktop: true,
  );
  return source;
}

void main() {
  group('phone', () {
    for (final e in states.entries) {
      testWidgets('panel: ${e.key}', (tester) async {
        await pumpPhone(tester, e.value);
        for (final text in mustSay[e.key]!) {
          expect(
            find.textContaining(text, findRichText: true),
            findsWidgets,
            reason: text,
          );
        }
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/panel_${e.key}.png'),
        );
      });
    }
  });

  group('desktop dialog', () {
    for (final name in ['downloading', 'in_use', 'not_enough_disk']) {
      testWidgets('dialog: $name', (tester) async {
        await pumpDesktop(tester, states[name]!);
        for (final text in mustSay[name]!) {
          expect(find.textContaining(text), findsWidgets, reason: text);
        }
        await expectLater(
          find.byKey(goldenKey),
          matchesGoldenFile('goldens/desktop_dialog_$name.png'),
        );
      });
    }
  });

  group('behaviour', () {
    testWidgets('the fix for a refusal is on a 375×667 phone without '
        'scrolling; it calls the node', (tester) async {
      final source = await pumpPhone(
        tester,
        states['not_enough_disk']!,
        size: smallPhone,
      );
      expectOnScreen(
        tester,
        const Key('beamPrivateNodePrimary'),
        smallPhone,
      );
      await tester.tap(find.byKey(const Key('beamPrivateNodePrimary')));
      await tester.pump();
      expect(source.actions, [BeamNodePanelAction.retry]);
    });

    testWidgets('one primary button at most, none while all is well',
        (tester) async {
      for (final e in states.entries) {
        await pumpPhone(tester, e.value);
        expect(
          find.byKey(const Key('beamPrivateNodePrimary')).evaluate().length,
          lessThanOrEqualTo(1),
          reason: e.key,
        );
      }
      await pumpPhone(tester, states['in_use']!);
      expect(find.byKey(const Key('beamPrivateNodePrimary')), findsNothing);
    });

    testWidgets('switch, restart, stop and resync reach the source',
        (tester) async {
      final source = await pumpPhone(tester, states['in_use']!);
      await tester.tap(find.byKey(const Key('beamPrivateNode-restart')));
      await tester.tap(find.byKey(const Key('beamPrivateNode-stop')));
      await tester.tap(find.byKey(const Key('beamNodeResync')));
      await tester.pump();
      expect(source.actions, [
        BeamNodePanelAction.restart,
        BeamNodePanelAction.stop,
      ]);
      expect(source.refreshes, 1);

      await tester.tap(find.byType(DraggableSwitchButton));
      await tester.pump(const Duration(milliseconds: 300));
      // The stream update lands after the first frame.
      await tester.pump();
      expect(source.toggles, [false]);
      // Turned off: the status block goes, the switch stays.
      expect(find.byKey(const Key('beamPrivateNodeTitle')), findsNothing);
      expect(find.text(BeamNodePanelText.toggleLabel), findsOneWidget);
    });

    testWidgets('live updates: downloading → in use without rebuilding the '
        'page', (tester) async {
      final source = await pumpPhone(tester, states['downloading']!);
      expect(find.text('Downloading 43%'), findsOneWidget);
      source.set(states['in_use']!);
      await tester.pump();
      await tester.pump();
      expect(find.text('Your private node is in use'), findsOneWidget);
      expect(find.text('Downloading 43%'), findsNothing);
    });
  });

  testWidgets('status chips', (tester) async {
    BeamNodePanelView v(BeamNodePanelSnapshot s) =>
        BeamNodePanelModel.describe(s);
    await pumpNodeUi(
      tester,
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: Theme.of(context)
              .extension<StackColors>()!
              .background,
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final s in [
                  states['in_use']!,
                  states['downloading']!,
                  states['finishing_setup']!,
                  states['off']!,
                  states['wallet_catching_up']!,
                  snap(assessment: notConnected),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: BeamNodeStatusChip.fromView(v(s), onTap: () {}),
                  ),
              ],
            ),
          ),
        ),
      ),
      size: const Size(375, 320),
      desktop: false,
    );
    for (final label in [
      'Private node',
      'Public node · private 43%',
      'Public node · private 37%',
      'Public node',
      'Catching up',
      'Not connected',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/status_chips.png'),
    );
  });
}
