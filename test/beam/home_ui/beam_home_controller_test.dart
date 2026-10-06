/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// When the BEAM home re-reads the BANS inbox and the DEX prices, and what
// it does with a core that cannot see the inbox.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_inbox_monitor.dart';
import 'package:stackwallet/wallets/beam/sync/beam_sync_state.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_controller.dart';
import 'package:stackwallet/widgets/beam/wallet_home/beam_home_text.dart';

import 'home_ui_support.dart';

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 30));

BeamSynced _at(int height) => BeamSynced(
  node: BeamNodeKind.publicNode,
  explorerCheck: BeamExplorerCheck.agrees,
  walletHeight: height,
  networkHeight: height,
);

void main() {
  test('reads the inbox on open, on each new block and when the history '
      'changes; never two reads at once', () async {
    final source = FakeHomeSource(
      assessment: _at(100),
      inbox: inboxOf({
        'alice': {0: g(1)},
      }),
      inboxMinInterval: Duration.zero,
    );
    final c = BeamHomeController(source, log: (_) {})..start();
    addTearDown(c.dispose);
    await _settle();
    expect(source.inboxReads, 1);
    expect(BeamHomeText.namePayments(c.namePayments)!.amounts, '1 BEAM');

    source.assessment = _at(101); // a new block
    await _settle();
    expect(source.inboxReads, 2);

    source.assessment = _at(101); // same block: nothing new to read
    await _settle();
    expect(source.inboxReads, 2);

    source.fireTransactionsChanged();
    await _settle();
    expect(source.inboxReads, 3);

    // Overlapping triggers share one read.
    final gate = Completer<void>();
    var calls = 0;
    final slow = BansInboxMonitor(() async {
      calls++;
      await gate.future;
      return inboxOf({});
    });
    unawaited(slow.refresh());
    unawaited(slow.refresh(force: true));
    gate.complete();
    await _settle();
    expect(calls, 1);
  });

  test('nothing is read before the core is up; the first read after it '
      'comes up skips the throttle', () async {
    final source = FakeHomeSource(isOpen: false, inbox: inboxOf({}));
    final c = BeamHomeController(
      source,
      pollInterval: const Duration(milliseconds: 20),
      log: (_) {},
    )..start();
    addTearDown(c.dispose);
    c.setHeldAssets({0, 174});
    await _settle();
    expect(source.inboxReads, 0);
    expect(source.pricerCalls, 0);

    source.isOpen = true;
    source.fireEvent();
    await _settle();
    expect(source.inboxReads, 1);
    expect(source.pricerCalls, 1);
  });

  test('a core that cannot see the inbox: nothing on the home, logged '
      'once', () async {
    final logs = <String>[];
    final source = FakeHomeSource(inboxMinInterval: Duration.zero)
      ..inboxError = const BansClaimUnsupported();
    final c = BeamHomeController(source, log: logs.add)..start();
    addTearDown(c.dispose);
    await _settle();
    expect(c.namePayments!.visibility, BansInboxVisibility.needsCampfireCore);
    expect(BeamHomeText.namePayments(c.namePayments), isNull);
    source.fireTransactionsChanged();
    await _settle();
    expect(logs.where((l) => l.contains('BANS')), hasLength(1));
  });

  test('a failed read keeps the last good summary on screen', () async {
    final source = FakeHomeSource(
      inbox: inboxOf({
        'alice': {0: g(2.5)},
      }),
      inboxMinInterval: Duration.zero,
    );
    final c = BeamHomeController(source, log: (_) {})..start();
    addTearDown(c.dispose);
    await _settle();
    source.inboxError = StateError('node hiccup');
    source.fireTransactionsChanged();
    await _settle();
    expect(BeamHomeText.namePayments(c.namePayments)!.amounts, '2.5 BEAM');
  });

  test('prices only when the wallet holds something besides BEAM', () async {
    final source = FakeHomeSource(pools: [beamPool(174, 10000, 1000000)]);
    final c = BeamHomeController(source, log: (_) {})..start();
    addTearDown(c.dispose);
    c.setHeldAssets({0});
    await _settle();
    expect(source.pricerCalls, 0);
    c.setHeldAssets({0, 174});
    await _settle();
    expect(source.pricerCalls, 1);
    expect(c.pricer, isNotNull);
  });

  test('the Send-paused reason follows the verdict', () async {
    final source = FakeHomeSource(assessment: catchingUp(5));
    final c = BeamHomeController(source, log: (_) {})..start();
    addTearDown(c.dispose);
    expect(c.sendPausedReason, contains('catches up'));
    source.assessment = synced();
    await _settle();
    expect(c.sendPausedReason, isNull);
  });
}
