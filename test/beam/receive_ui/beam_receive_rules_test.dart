/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The two rules the Receive screen rests on: when offline / max-privacy /
// public addresses may be offered, and which address Receive shows.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/widgets/beam/receive/beam_private_receive.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_model.dart';
import 'package:stackwallet/widgets/beam/receive/beam_receive_text.dart';

BeamPrivateReceive _eval({
  BeamPrivateNodeStatus? status,
  bool coreOpen = true,
  bool bodyRequests = false,
  bool nodePossible = true,
  bool nodeWanted = true,
}) => BeamPrivateReceive.evaluate(
  status: status,
  coreOpen: coreOpen,
  bodyRequests: bodyRequests,
  nodePossible: nodePossible,
  nodeWanted: nodeWanted,
);

BeamAddress _addr(
  String a, {
  int created = 1790000000,
  int duration = 0,
  bool expired = false,
  BeamAddressType type = BeamAddressType.regular,
  bool own = true,
}) => BeamAddress(
  address: a,
  type: type,
  own: own,
  expired: expired,
  comment: '',
  category: '',
  createTime: created,
  duration: duration,
  walletId: a,
);

void main() {
  group('private receive is offered only on evidence', () {
    test('own node confirmed (own_node == true): available', () {
      expect(
        _eval(
          status: const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.active,
            onPrivateNode: true,
            privateReceiveAvailable: true,
          ),
        ).available,
        isTrue,
      );
    });

    test('body requests on (restore scan): available without a node', () {
      expect(_eval(bodyRequests: true, nodePossible: false).available, isTrue);
    });

    test('on the node but the key is not confirmed: not available', () {
      final r = _eval(
        status: const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.active,
          onPrivateNode: true,
        ),
      );
      expect(r.block, BeamPrivateReceiveBlock.nodeConfirming);
    });

    test('core not connected wins over everything', () {
      expect(
        _eval(
          coreOpen: false,
          bodyRequests: true,
          status: const BeamPrivateNodeStatus(
            phase: BeamPrivateNodePhase.active,
            privateReceiveAvailable: true,
          ),
        ).block,
        BeamPrivateReceiveBlock.connecting,
      );
    });

    test('the node serving another wallet: says so, and when it unlocks', () {
      final r = _eval(
        status: const BeamPrivateNodeStatus(
          phase: BeamPrivateNodePhase.failed,
          issue: BeamPrivateNodeIssue.servingOtherWallet,
        ),
      );
      expect(r.block, BeamPrivateReceiveBlock.nodeServingOtherWallet);
      final why = BeamReceiveText.privateReason(r);
      expect(why.reason, contains('serving another of your wallets'));
      expect(why.reason, contains('when that wallet closes'));
      expect(why.showNodeSettings, isTrue);
    });

    test('every node phase maps to a reason with a next step', () {
      final expected = {
        BeamPrivateNodePhase.off: BeamPrivateReceiveBlock.nodeOff,
        BeamPrivateNodePhase.idle: BeamPrivateReceiveBlock.nodeStarting,
        BeamPrivateNodePhase.preparing: BeamPrivateReceiveBlock.nodeStarting,
        BeamPrivateNodePhase.downloading:
            BeamPrivateReceiveBlock.nodeDownloading,
        BeamPrivateNodePhase.catchingUp: BeamPrivateReceiveBlock.nodeCatchingUp,
        BeamPrivateNodePhase.switching: BeamPrivateReceiveBlock.nodeSwitching,
        BeamPrivateNodePhase.active: BeamPrivateReceiveBlock.nodeConfirming,
        BeamPrivateNodePhase.cannotVerify: BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.stuck: BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.ownNodeUnconfirmed:
            BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.failed: BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.stopped: BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.fellBehind: BeamPrivateReceiveBlock.nodeProblem,
        BeamPrivateNodePhase.walletClosed: BeamPrivateReceiveBlock.nodeProblem,
      };
      expect(expected.keys.toSet(), BeamPrivateNodePhase.values.toSet());
      for (final e in expected.entries) {
        final r = _eval(
          status: BeamPrivateNodeStatus(phase: e.key, percent: 42),
        );
        expect(r.block, e.value, reason: e.key.name);
        final why = BeamReceiveText.privateReason(r);
        expect(why.reason, isNotEmpty, reason: e.key.name);
        for (final banned in ['SBBS', 'voucher', 'Lelantus', 'shielded']) {
          expect(
            why.reason.toLowerCase(),
            isNot(contains(banned.toLowerCase())),
          );
        }
      }
      expect(
        BeamReceiveText.privateReason(
          _eval(
            status: const BeamPrivateNodeStatus(
              phase: BeamPrivateNodePhase.downloading,
              percent: 42,
            ),
          ),
        ).reason,
        contains('42% done'),
      );
    });

    test('no status yet: setting off says how to turn it on; on says it '
        'is starting; a phone says it needs a computer', () {
      expect(_eval(nodeWanted: false).block, BeamPrivateReceiveBlock.nodeOff);
      expect(
        BeamReceiveText.privateReason(_eval(nodeWanted: false)).reason,
        'Turn on your private node in Node settings — it takes about 2 '
        'hours the first time.',
      );
      expect(_eval().block, BeamPrivateReceiveBlock.nodeStarting);
      expect(
        _eval(nodePossible: false).block,
        BeamPrivateReceiveBlock.notOnThisDevice,
      );
    });
  });

  group('the address Receive shows', () {
    final now = DateTime.utc(2026, 10, 6, 12);
    final nowS = now.millisecondsSinceEpoch ~/ 1000;

    test('the newest unexpired regular address', () {
      final picked = BeamReceiveModel.pickCurrent([
        _addr('old', created: nowS - 900),
        _addr('new', created: nowS - 100),
        _addr('expired', created: nowS - 10, expired: true),
        _addr('mp', created: nowS - 5, type: BeamAddressType.maxPrivacy),
        _addr('contact', created: nowS - 1, own: false),
      ], now);
      expect(picked!.address, 'new');
    });

    test('skips one that expires within a day; none left means none', () {
      final soon = _addr('soon', created: nowS - 3600, duration: 7200);
      final week = _addr('week', created: nowS - 7200, duration: 7 * 86400);
      expect(BeamReceiveModel.pickCurrent([soon, week], now)!.address, 'week');
      expect(BeamReceiveModel.pickCurrent([soon], now), isNull);
      expect(BeamReceiveModel.pickCurrent(const [], now), isNull);
    });
  });

  test('every type is named and explained without jargon', () {
    for (final t in BeamAddressType.values) {
      final words =
          '${BeamReceiveText.typeTitle(t)} '
                  '${BeamReceiveText.typeExplainer(t)}'
              .toLowerCase();
      for (final banned in [
        'sbbs',
        'voucher',
        'lelantus',
        'shielded',
        'token',
      ]) {
        expect(words, isNot(contains(banned)), reason: t.name);
      }
    }
    expect(
      BeamReceiveText.typeExplainer(BeamAddressType.offline),
      'Works while your wallet is closed. Good for one payment.',
    );
    expect(
      BeamReceiveText.typeExplainer(BeamAddressType.maxPrivacy),
      'Hides the payment among many others; takes longer. Use it once.',
    );
  });
}
