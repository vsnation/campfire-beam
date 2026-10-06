/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The panel's wording, decided in one pure place, over every private node
// phase × issue × wallet sync state: plain words only, a title always, the
// owner's phrases where he gave them, disk numbers up front.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_model.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';

import 'node_ui_harness.dart';

const _banned = [
  'explorer',
  'owner key',
  'own_node',
  'rpc',
  'fast sync',
  'fast-sync',
  'wallet-api',
  'beam-node',
  'is_in_sync',
  'utxo',
  'fossil',
  'shader',
];

void main() {
  test('every combination has a title, plain words and at most one primary '
      'action', () {
    for (final phase in BeamPrivateNodePhase.values) {
      for (final issue in [null, ...BeamPrivateNodeIssue.values]) {
        for (final waiting in [false, true]) {
          for (final assessment in [
            syncedPublic,
            walletBehind,
            notConnected,
          ]) {
            final s = snap(
              assessment: assessment,
              privateNode: BeamPrivateNodeStatus(
                phase: phase,
                issue: issue,
                percent: 43,
                finishingPercent: phase == BeamPrivateNodePhase.catchingUp
                    ? 37
                    : null,
                nodeHeight: tip - 1700,
                networkHeight: tip,
                waitingForWallet: waiting,
                disk: issue == BeamPrivateNodeIssue.notEnoughDisk
                    ? disk(6.2)
                    : null,
              ),
            );
            final v = BeamNodePanelModel.describe(s);
            final text = [
              v.nodeTitle,
              v.syncTitle,
              v.syncDetail,
              v.privateTitle,
              v.privateDetail,
              v.diskLine,
              v.chipLabel,
            ].whereType<String>().join(' ').toLowerCase();
            for (final word in _banned) {
              expect(text, isNot(contains(word)), reason: '$s: $text');
            }
            expect(v.privateTitle, isNotEmpty);
            expect(v.chipLabel, isNotEmpty);
          }
        }
      }
    }
  });

  test("the owner's phrases", () {
    String title(BeamPrivateNodeStatus st) =>
        BeamNodePanelModel.describe(snap(privateNode: st)).privateTitle;
    expect(
      title(
        const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.downloading,
          percent: 43,
        ),
      ),
      'Downloading 43%',
    );
    expect(
      title(
        const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.catchingUp,
          nodeHeight: tip - 1700,
          networkHeight: tip,
        ),
      ),
      'Catching up 1,700 blocks',
    );
    expect(
      title(const BeamPrivateNodeStatus(phase: BeamPrivateNodePhase.switching)),
      'Ready — switching',
    );
    expect(
      title(
        const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.active,
          onPrivateNode: true,
          privateReceiveAvailable: true,
        ),
      ),
      'Your private node is in use',
    );
    expect(
      BeamNodePanelText.toggleExplainer,
      "Sees offline and max-privacy payments, and doesn't depend on someone "
      "else's node.",
    );
    expect(
      BeamNodePanelText.fallbackNote,
      contains('back on a public node — your wallet keeps working'),
    );
  });

  test('disk lines: needs before, uses after; numbers in GB', () {
    String? line(BeamNodePanelSnapshot s) =>
        BeamNodePanelModel.describe(s).diskLine;
    expect(
      line(snap(diskCheck: disk(37))),
      'Needs about 12 GB while it sets up, then about 8 GB · 37 GB free',
    );
    expect(
      line(snap(diskCheck: disk(26, nodeGiB: 3.1))),
      'Uses 3.1 GB so far (up to 12 GB while it sets up) · 26 GB free',
    );
    expect(
      line(snap(diskCheck: disk(30, nodeGiB: 7.6))),
      'Uses 7.6 GB · 30 GB free',
    );
    expect(
      line(snap()),
      'Needs about 12 GB while it sets up, then about 8 GB',
    );
    expect(line(snap(enabled: false)), isNull, reason: 'not when off');
    expect(
      line(
        snap(
          privateNode: BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.failed,
            issue: BeamPrivateNodeIssue.notEnoughDisk,
            disk: disk(6.2),
          ),
        ),
      ),
      isNull,
      reason: 'the refusal message already has the numbers',
    );
  });

  // Seen in the DMG test: "Needs about 12 GB … · 5.3 GB free" read as a
  // neutral fact, while the node could never set up in that space.
  test('too little space for a new node is a warning with the gap, said '
      'before the node tries', () {
    final short = BeamNodePanelModel.describe(snap(diskCheck: disk(5.3)));
    expect(short.diskShort, isTrue);
    expect(
      short.diskLine,
      'Not enough space. Free about 8.7 GB more to use your private node '
      '(5.3 GB free now). Your wallet keeps working on a public node '
      'meanwhile.',
    );
    final roomy = BeamNodePanelModel.describe(snap(diskCheck: disk(37)));
    expect(roomy.diskShort, isFalse);
    expect(
      BeamNodePanelModel.describe(
        snap(diskCheck: disk(5.3, nodeGiB: 7.6)),
      ).diskShort,
      isFalse,
      reason: 'a node that already set up only grows slowly',
    );
  });

  test('the sync card says which node, and offers "Use a public node" only '
      'when the private node is the one not answering', () {
    final onPrivate = BeamNodePanelModel.describe(
      snap(
        assessment: syncedPrivate,
        node: ownNode,
        privateNode: const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.active,
          onPrivateNode: true,
          privateReceiveAvailable: true,
        ),
      ),
    );
    expect(onPrivate.nodeTitle, 'Your private node');
    expect(onPrivate.nodeAddress, isNull, reason: 'no loopback port shown');
    final onPublic = BeamNodePanelModel.describe(snap());
    expect(onPublic.nodeTitle, 'Public node');
    expect(onPublic.nodeAddress, 'eu-nodes.mainnet.beam.mw:8100');
    expect(onPublic.heightLine, 'Block 4,068,266');
    expect(
      BeamNodePanelModel.describe(snap(assessment: walletBehind)).heightLine,
      'Block 4,068,224 of 4,068,266',
    );
    expect(onPublic.syncAction, isNull);
  });

  test('a core that cannot start is said plainly', () {
    final v = BeamNodePanelModel.describe(
      snap(node: null, coreProblem: 'The BEAM core is not installed.'),
    );
    expect(v.syncTitle, "Can't start the wallet");
    expect(v.syncDetail, 'The BEAM core is not installed.');
    expect(v.chipLabel, 'Not connected');
    expect(v.chipTone, BeamNodeTone.problem);
  });
}
