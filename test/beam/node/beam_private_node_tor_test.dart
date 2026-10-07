/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The private node and Campfire's Tor setting (owner, 2026-10-07: with Tor
// on, every request goes through Tor): the node runs with Tor on only on a
// core that routes its peers through Tor, never outside it, and the node
// panel says why it is off otherwise.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/explorer/beam_explorer_client.dart';
import 'package:stackwallet/wallets/beam/node/beam_node_panel_model.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_preference.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';

void main() {
  group('BeamPrivateNodePreference with Tor', () {
    late Directory tmp;
    late String root;
    var tor = false;
    var capable = false;

    BeamPrivateNodePreference pref({bool defaultValue = true}) =>
        BeamPrivateNodePreference(
          beamRoot: () async => root,
          defaultValue: defaultValue,
          torEnabled: () => tor,
          nodeTorCapable: () => capable,
        );

    String stored() =>
        File(p.join(root, BeamPrivateNodePreference.fileName))
            .readAsStringSync();

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('beam_pref_tor_');
      root = p.join(tmp.path, 'beam');
      tor = false;
      capable = false;
    });
    tearDown(() => tmp.delete(recursive: true));

    test('Tor on, core without Tor support: off, whatever was chosen',
        () async {
      expect(await pref().read(), isTrue, reason: 'desktop default');
      tor = true;
      expect(pref().torEnabled, isTrue);
      expect(await pref().read(), isFalse);
      await pref().write(true);
      expect(stored(), '{"enabled":true}');
      expect(await pref().read(), isFalse, reason: 'no way to run outside Tor');
      tor = false;
      expect(await pref().read(), isTrue);
    });

    test('a choice stored by an older build with "tor": true does not run it '
        'outside Tor', () async {
      await Directory(root).create(recursive: true);
      File(p.join(root, BeamPrivateNodePreference.fileName))
          .writeAsStringSync('{"enabled":true,"tor":true}');
      tor = true;
      expect(await pref().read(), isFalse);
    });

    test('Tor on, core that routes the node through Tor: the choice applies',
        () async {
      tor = true;
      capable = true;
      expect(await pref().read(), isTrue, reason: 'default');
      await pref().write(false);
      expect(await pref().read(), isFalse);
      await pref().write(true);
      expect(await pref().read(), isTrue);
    });

    test('off stays off; a damaged file is the default without Tor', () async {
      await pref().write(false);
      expect(stored(), '{"enabled":false}');
      expect(await pref().read(), isFalse);
      File(
        p.join(root, BeamPrivateNodePreference.fileName),
      ).writeAsStringSync('{not json');
      expect(await pref().read(), isTrue);
      tor = true;
      expect(await pref().read(), isFalse);
    });

    test('a coordinator reading it with Tor on never starts a node', () async {
      tor = true;
      final setting = pref();
      // The coordinator's contract: `read() == false` means it does nothing.
      expect(await (setting as BeamPrivateNodeSetting).read(), isFalse);
    });
  });

  group('node panel wording with Tor', () {
    final now = DateTime.now().toUtc();
    final synced = assessBeamSync(
      wallet: BeamWalletSyncInput(
        currentHeight: 4100000,
        currentStateTimestamp: now.subtract(const Duration(seconds: 30)),
        isInSync: true,
        headerTipHeight: 4100000,
        nodeConnected: true,
      ),
      explorer: BeamExplorerStatus(
        height: 4100000,
        timestamp: now.subtract(const Duration(seconds: 30)),
        hash: '',
        node: 'test',
        receivedAt: now,
        serverTime: now,
      ),
      now: now,
    );

    BeamNodePanelView view({
      required bool tor,
      required bool enabled,
      BeamPrivateNodeStatus? status,
    }) => BeamNodePanelModel.describe(
      BeamNodePanelSnapshot(
        assessment: synced,
        privateNodeSupported: true,
        privateNodeEnabled: enabled,
        privateNode: status,
        torEnabled: tor,
      ),
    );

    test('off because of Tor: says so and why, in plain words', () {
      final v = view(tor: true, enabled: false);
      expect(v.privateTitle, 'Off while Tor is on');
      expect(v.privateDetail, BeamNodePanelText.offForTor);
      expect(v.privateDetail, contains('internet address stays hidden'));
      expect(v.toggleValue, isFalse);
      // Without Tor, the old wording.
      expect(view(tor: false, enabled: false).privateTitle, 'Off');
    });

    test('running with Tor on: every state says it goes through Tor', () {
      for (final phase in BeamPrivateNodePhase.values) {
        if (phase == BeamPrivateNodePhase.off) continue;
        final v = view(
          tor: true,
          enabled: true,
          status: BeamPrivateNodeStatus(phase: phase, percent: 43),
        );
        expect(
          v.privateDetail,
          endsWith(BeamNodePanelText.runsThroughTor),
          reason: phase.name,
        );
        final plain = view(
          tor: false,
          enabled: true,
          status: BeamPrivateNodeStatus(phase: phase, percent: 43),
        );
        expect(
          plain.privateDetail ?? '',
          isNot(contains(BeamNodePanelText.runsThroughTor)),
          reason: phase.name,
        );
      }
    });

    test('the snapshot compares Tor too', () {
      final a = BeamNodePanelSnapshot(assessment: synced);
      expect(a.copyWith(torEnabled: true), isNot(a));
      expect(a.copyWith(torEnabled: true).torEnabled, isTrue);
      expect(a.copyWith(torEnabled: false), a);
    });
  });
}
