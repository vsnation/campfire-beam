/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge controller over fake halves (bridge_fakes.dart): every rule a
// quote follows, both directions end to end, finding the BEAM message a
// send made, a wallet that throws after it may have sent (never sent
// again), a restart in the middle, one message per crossing, and the slow
// ways a crossing can go (waiting for gas, not delivered yet, a claim that
// did not go out).
//
//   scripts/beam/host_test.sh --no-analyze test/beam/bridge

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_controller.dart';
import 'package:stackwallet/wallets/bridge/bridge_crossing.dart';
import 'package:stackwallet/wallets/bridge/bridge_fees.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/bridge/bridge_store.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_service.dart';

import 'bridge_fakes.dart';

const toEth = BridgeDirection.toEthereum;
const toBeam = BridgeDirection.toBeam;

class Rig {
  Rig({FakeBeamSide? beam, FakeEthSide? eth, BridgeStore? store})
    : beam = beam ?? FakeBeamSide(),
      eth = eth ?? FakeEthSide(),
      store = store ?? MemoryBridgeStore() {
    this.eth.clock = clock;
  }

  final FakeBridgeClock clock = FakeBridgeClock();
  final FakeBeamSide beam;
  final FakeEthSide eth;
  final BridgeStore store;

  late BridgeController c = controller();

  BridgeController controller() => BridgeController(
    beam: beam,
    eth: eth,
    store: store,
    beamWalletId: 'beam-wallet',
    ethWalletId: 'eth-wallet',
    clock: clock,
    autoPoll: false,
  );

  Future<BridgeQuote> quote(BridgeRoute r, BridgeDirection d, BigInt a) =>
      c.quote(r, d, a);

  /// Quote, prepare and start [a] of [r] going [d].
  Future<BridgeCrossing> move(
    BridgeRoute r,
    BridgeDirection d,
    BigInt a, {
    bool autoClaim = false,
  }) async {
    final q = await quote(r, d, a);
    expect(q.block, isNull, reason: '${q.block}');
    final p = await c.prepare(q);
    final crossing = await c.start(p, autoClaim: autoClaim);
    await pumpEventQueue();
    return c.crossing(crossing.id)!;
  }

  /// Advances the clock by [d] and polls whatever is due.
  Future<BridgeCrossing> after(Duration d, String id) async {
    clock.advance(d);
    await c.pollDue();
    await pumpEventQueue();
    return c.crossing(id)!;
  }
}

BigInt b2eFee(BridgeRoute r) {
  final gas = BridgeRelayerGas(
    baseFee: BigInt.from(701400000),
    tip: BigInt.from(429200000),
    at: DateTime.utc(2026),
  );
  final prices = BridgePrices(const {
    'ethereum': 2487.25,
    'beam': 0.00783632,
    'wrapped-bitcoin': 82567.0,
    'tether': 0.999262,
    'dai': 0.999917,
  }, DateTime.utc(2026));
  return b2eRelayerFeeGroth(r, gas, prices)!;
}

void main() {
  group('quote, to Ethereum', () {
    test(
      'the BEAM fee follows the relayer: 96,000 gas, ×1.3, ~72.57 BEAM',
      () async {
        final rig = Rig();
        final q = await rig.quote(beamRoute, toEth, beams(1000));
        expect(q.block, isNull);
        expect(q.fee, b2eFee(beamRoute));
        expect(q.fee! ~/ BigInt.from(1000000), BigInt.from(7256)); // 72.56…
        expect(q.amount, beams(1000));
        expect(q.receives, beams(1000)); // WBEAM: 8 decimals both sides
        expect(q.beamNetworkFee, kBridgeSendFeeGroth);
        expect(q.ethAddress, kFakeEthAddress);
        expect(q.totalSource, beams(1000) + q.fee! + kBridgeSendFeeGroth);
        expect(q.warnings, isEmpty);
      },
    );

    test('an amount is floored to the route grid (USDT: 100 groth)', () async {
      final rig = Rig();
      final q = await rig.quote(usdtRoute, toEth, BigInt.from(1234567891));
      expect(q.amount, BigInt.from(1234567800));
      expect(q.receives, BigInt.from(12345678)); // 12.345678 USDT
      expect(q.fee! % BigInt.from(100), BigInt.zero);
    });

    test('the bridge fee as large as the amount blocks it', () async {
      final rig = Rig();
      final q = await rig.quote(beamRoute, toEth, beams(50));
      expect(q.block?.code, BridgeBlockCode.belowFee);
      expect(q.block!.title, 'The bridge fee is more than the amount');
      expect(q.canMove, isFalse);
    });

    test('above a tenth of the amount the fee is pointed out', () async {
      final rig = Rig();
      final q = await rig.quote(beamRoute, toEth, beams(500));
      expect(q.block, isNull);
      expect(q.warnings.single.code, BridgeWarningCode.highFee);
      expect(q.warnings.single.title, startsWith('The bridge fee is 15%'));
    });

    test('more than 3,000,000 BEAM in one move is refused', () async {
      final rig = Rig(beam: FakeBeamSide(available: {0: beams(4000000)}));
      final q = await rig.quote(beamRoute, toEth, beams(3000001));
      expect(q.block?.code, BridgeBlockCode.aboveMax);
      expect(q.block!.title, 'At most 3,000,000 BEAM per move');
      final ok = await rig.quote(beamRoute, toEth, beams(2999000));
      expect(ok.block, isNull);
    });

    test('BEAM: amount + fee + 0.011 must be in the wallet', () async {
      final rig = Rig(beam: FakeBeamSide(available: {0: beams(1072.5)}));
      final q = await rig.quote(beamRoute, toEth, beams(1000));
      expect(q.block?.code, BridgeBlockCode.notEnough);
      expect(q.block!.detail, contains('Your wallet has 1,072.5 BEAM'));
    });

    test('a wrapped asset needs 0.011 BEAM besides it', () async {
      final rig = Rig(
        beam: FakeBeamSide(available: {0: BigInt.zero, 37: beams(250)}),
      );
      final q = await rig.quote(usdtRoute, toEth, beams(100));
      expect(q.block?.code, BridgeBlockCode.noBeamForFee);
      final short = await Rig(
        beam: FakeBeamSide(available: {0: beams(1), 37: beams(100)}),
      ).quote(usdtRoute, toEth, beams(100));
      expect(short.block?.code, BridgeBlockCode.notEnough);
    });

    test('a frozen route says why, and a freeze that cannot be read '
        'blocks too', () async {
      final rig = Rig();
      rig.eth.frozen['beam'] = const [
        BridgeFreeze('WBEAM is paused by its issuer'),
      ];
      final q = await rig.quote(beamRoute, toEth, beams(1000));
      expect(q.block?.code, BridgeBlockCode.frozen);
      expect(q.block!.detail, 'WBEAM is paused by its issuer');

      final unsure = Rig()..eth.freezeFails = true;
      final u = await unsure.quote(usdtRoute, toEth, beams(100));
      expect(u.block?.code, BridgeBlockCode.network);
    });

    test('no price, a missing price or a stale one: no quote', () async {
      final none = Rig()..eth.pricesFail = true;
      expect(
        (await none.quote(beamRoute, toEth, beams(1000))).block?.code,
        BridgeBlockCode.noPrice,
      );
      final missing = Rig()..eth.missingPrices.add('tether');
      expect(
        (await missing.quote(usdtRoute, toEth, beams(100))).block?.code,
        BridgeBlockCode.noPrice,
      );
      final stale = Rig()..eth.priceAge = const Duration(minutes: 11);
      expect(
        (await stale.quote(beamRoute, toEth, beams(1000))).block?.code,
        BridgeBlockCode.noPrice,
      );
      final fresh = Rig()..eth.priceAge = const Duration(minutes: 9);
      expect((await fresh.quote(beamRoute, toEth, beams(1000))).block, isNull);
    });

    test('Max keeps the fee and the network fee back', () async {
      final rig = Rig(beam: FakeBeamSide(available: {0: beams(1000)}));
      final max = await rig.c.maxAmount(beamRoute, toEth);
      expect(max, beams(1000) - b2eFee(beamRoute) - kBridgeSendFeeGroth);
      final q = await rig.quote(beamRoute, toEth, max);
      expect(q.block, isNull);
    });
  });

  group('quote, to BEAM', () {
    test('ETH: floored to 10^10 wei, 0.02 BEAM worth of fee, one '
        'transaction', () async {
      final rig = Rig();
      final q = await rig.quote(
        ethRoute,
        toBeam,
        BigInt.parse('1234567891234567'),
      );
      expect(q.block, isNull);
      expect(q.amount, BigInt.parse('1234560000000000')); // 0.00123456 ETH
      expect(q.receives, BigInt.from(123456)); // groth of bETH
      final prices = await rig.eth.prices(['ethereum', 'beam']);
      expect(q.fee, e2bRelayerFee(ethRoute, prices));
      expect(q.fee! % ethRoute.ethGrid, BigInt.zero);
      expect(q.plan!.steps, hasLength(1));
      expect(q.beamNetworkFee, kBridgeClaimFeeGroth);
      expect(q.receiveKey, FakeBeamSide.keyFor(ethRoute));
    });

    test('value + fee must be in the wallet', () async {
      final rig = Rig();
      final q = await rig.quote(usdtRoute, toBeam, BigInt.from(500000000));
      expect(q.block?.code, BridgeBlockCode.notEnough);
    });

    test('ETH for the network fee: on the ETH route with the value', () async {
      final rig = Rig(eth: FakeEthSide(eth: ethUnits(0.01005)));
      // 0.01 ETH + fee + 40,000 gas × 1.8321 gwei > 0.01005 ETH.
      final q = await rig.quote(ethRoute, toBeam, ethUnits(0.01));
      expect(q.block?.code, BridgeBlockCode.noEthForGas);
      expect(q.block!.title, 'Not enough ETH');
    });

    test('ETH for the network fee of a token: approval and lock', () async {
      final rig = Rig(eth: FakeEthSide(eth: BigInt.from(100000000000000)));
      final q = await rig.quote(usdtRoute, toBeam, BigInt.from(100000000));
      expect(q.block?.code, BridgeBlockCode.noEthForGas);
      expect(q.block!.title, 'Not enough ETH for the Ethereum network fee');
    });

    test('a BEAM wallet without 0.121 BEAM cannot collect: blocked, with '
        'the next step', () async {
      final rig = Rig(beam: FakeBeamSide(available: {0: beams(0.12)}));
      final q = await rig.quote(usdtRoute, toBeam, BigInt.from(100000000));
      expect(q.block?.code, BridgeBlockCode.noClaimFee);
      expect(q.block!.title, contains('0.121 BEAM'));
      expect(q.block!.detail, contains('Receive a little BEAM first'));
    });

    test('a frozen token blocks the way back too', () async {
      final rig = Rig();
      rig.eth.frozen['usdt'] = const [
        BridgeFreeze("Tether has frozen the bridge's USDT"),
      ];
      final q = await rig.quote(usdtRoute, toBeam, BigInt.from(100000000));
      expect(q.block?.code, BridgeBlockCode.frozen);
    });

    test('WBEAM to BEAM needs no price (its fee is 0.02 WBEAM)', () async {
      final rig = Rig()..eth.pricesFail = true;
      final q = await rig.quote(beamRoute, toBeam, beams(100));
      expect(q.block, isNull);
      expect(q.fee, BigInt.from(2000000));
      expect(q.prices, isNull);
    });

    test('a token without allowance plans an exact approval first, USDT '
        'resets a stale one', () async {
      final rig = Rig();
      final q = await rig.quote(daiRoute, toBeam, ethUnits(10));
      expect(q.plan!.steps.map((s) => s.kind), [
        UniTxKind.approve,
        UniTxKind.swap,
      ]);
      rig.eth.allowance['usdt'] = BigInt.from(5);
      final u = await rig.quote(usdtRoute, toBeam, BigInt.from(100000000));
      expect(u.plan!.steps.map((s) => s.kind), [
        UniTxKind.approveReset,
        UniTxKind.approve,
        UniTxKind.swap,
      ]);
    });
  });

  group('to Ethereum, end to end', () {
    test('send → mined → its message → 61 blocks → paid', () async {
      final rig = Rig();
      // Someone else's crossing already in the pipe.
      rig.beam.addLocal(
        beamRoute,
        amount: beams(10),
        fee: beams(70),
        height: 4072700,
      );
      String? storedAtSend;
      rig.beam.onExecute = (_) async {
        final all = await rig.store.all();
        storedAtSend = all.single.state.name;
      };
      var x = await rig.move(beamRoute, toEth, beams(1000));
      expect(storedAtSend, 'sending', reason: 'written before sending');
      expect(x.state, BridgeCrossingState.sent);
      expect(x.countBefore, 1);
      expect(x.beamTxId, 'beamtx1');
      expect(x.beamNetworkFee, kBridgeSendFeeGroth);
      expect((await rig.store.byId(x.id))!.beamTxId, 'beamtx1');

      // Not mined yet.
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.sent);

      rig.beam.mine('beamtx1', 4072810);
      rig.beam.tip = 4072810;
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      expect(x.msgId, 2);
      expect(x.height, 4072810);
      expect(rig.c.blocksLeft(x), 61);

      rig.beam.tip = 4072840;
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(rig.c.blocksLeft(x), 31);
      expect(x.dueAt, isNull);

      rig.beam.tip = 4072871;
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      expect(x.dueAt, isNotNull);

      rig.eth.paid.add(2);
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.paid);
      expect(x.finishedAt, isNotNull);
      expect((await rig.store.byId(x.id))!.state, BridgeCrossingState.paid);
      expect(
        rig.beam.calls.where((c) => c.startsWith('execute')),
        hasLength(1),
      );
    });

    test('its message is the one with this receiver, amount, fee and '
        'block, among several', () async {
      final rig = Rig();
      final fee = b2eFee(beamRoute);
      final x = await rig.move(beamRoute, toEth, beams(1000));
      expect(x.countBefore, 0);
      // Before ours is mined, other messages land, one almost like it.
      rig.beam
        ..addLocal(beamRoute, amount: beams(1000), fee: fee, height: 4072811)
        ..addLocal(
          beamRoute,
          receiver: kFakeEthAddress,
          amount: beams(999),
          fee: fee,
          height: 4072811,
        )
        ..addLocal(
          beamRoute,
          receiver: kFakeEthAddress,
          amount: beams(1000),
          fee: fee,
          height: 4072790, // same everything, another block
        );
      rig.beam.mine('beamtx1', 4072811); // ours: message 4
      rig.beam.addLocal(beamRoute, amount: beams(5), fee: fee, height: 4072812);
      final found = await rig.after(const Duration(seconds: 20), x.id);
      expect(found.msgId, 4);
      // Scanned from the top (5) down to countBefore + 1, no further.
      expect(rig.beam.calls.where((c) => c.startsWith('localMessage')), [
        for (var i = 5; i >= 1; i--) 'localMessage beam $i',
      ]);
    });

    test('its message is stamped one block below the transaction, as on '
        'mainnet; two below is not it', () async {
      final rig = Rig();
      final fee = b2eFee(beamRoute);
      var x = await rig.move(beamRoute, toEth, beams(1000));
      rig.beam.status['beamtx1'] = const BeamPipeTxStatus.completed(4072998);
      rig.beam.addLocal(
        beamRoute,
        receiver: kFakeEthAddress,
        amount: beams(1000),
        fee: fee,
        height: 4072996,
      );
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.sent);
      expect(x.msgId, isNull);
      rig.beam.addLocal(
        beamRoute,
        receiver: kFakeEthAddress,
        amount: beams(1000),
        fee: fee,
        height: 4072997,
      );
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      expect(x.msgId, 2);
      expect(x.height, 4072998);
    });

    test(
      'a failed BEAM transaction: failed, nothing left the wallet',
      () async {
        final rig = Rig();
        var x = await rig.move(usdtRoute, toEth, beams(100));
        rig.beam.status['beamtx1'] = const BeamPipeTxStatus.failed('rejected');
        x = await rig.after(const Duration(seconds: 20), x.id);
        expect(x.state, BridgeCrossingState.failed);
        expect(x.lastError, 'rejected');
        expect(x.isOpen, isFalse);
      },
    );

    test('not paid 30 minutes after it was due: waiting for gas, then '
        'paid', () async {
      final rig = Rig();
      var x = await rig.move(beamRoute, toEth, beams(1000));
      rig.beam.mine('beamtx1', 4072810);
      rig.beam.tip = 4072871;
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      x = await rig.after(const Duration(minutes: 29), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      x = await rig.after(const Duration(minutes: 2), x.id);
      expect(x.state, BridgeCrossingState.waitingForGas);
      rig.eth.paid.add(x.msgId!);
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.paid);
    });

    test('the wallet throws after it may have sent: unknown, never sent '
        'again, found by its message', () async {
      final rig = Rig();
      rig.beam.executeMode = FakeExecute.throwAfterBroadcast;
      var x = await rig.move(beamRoute, toEth, beams(1000));
      expect(x.state, BridgeCrossingState.unknown);
      expect(x.beamTxId, isNull);
      expect(x.lastError, 'no answer');

      // Nothing on BEAM yet: still unknown, and nothing is sent again.
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.unknown);

      rig.beam.mine('beamtx1', 4072815);
      rig.beam.tip = 4072820;
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.confirmed);
      expect(x.msgId, 1);
      expect(x.height, 4072815);
      expect(
        rig.beam.calls.where((c) => c.startsWith('execute')),
        hasLength(1),
      );
    });

    test('a prepared send is sent at most once', () async {
      final rig = Rig();
      final q = await rig.quote(beamRoute, toEth, beams(1000));
      final p = await rig.c.prepare(q);
      await rig.c.start(p);
      await expectLater(
        rig.c.start(p),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.code,
            'code',
            BridgeErrorCode.alreadySent,
          ),
        ),
      );
    });

    test('a review left for 16 minutes is checked again first', () async {
      final rig = Rig();
      final p = await rig.c.prepare(
        await rig.quote(beamRoute, toEth, beams(1000)),
      );
      rig.clock.advance(const Duration(minutes: 16));
      await expectLater(rig.c.start(p), throwsA(isA<BridgeReviewExpired>()));
      expect(rig.beam.calls.where((c) => c.startsWith('execute')), isEmpty);
    });
  });

  group('to BEAM, end to end', () {
    test('ETH: lock → mined → delivered → collect after the PIN', () async {
      final rig = Rig();
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      expect(x.state, BridgeCrossingState.locking);
      expect(x.lockHash, isNotNull);
      expect(rig.eth.sent.single.value, x.amount + x.relayerFee);
      expect(x.beamReceiveKey, hasLength(66));

      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.locking);

      rig.eth.mineLock(x.lockHash!, msgId: 128);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.locked);
      expect(x.msgId, 128);

      rig.beam.deliver(ethRoute, 128, x.receives);
      x = await rig.after(const Duration(seconds: 30), x.id);
      expect(x.state, BridgeCrossingState.delivered);
      // Not collected without the user.
      x = await rig.after(const Duration(seconds: 30), x.id);
      expect(x.state, BridgeCrossingState.delivered);

      final claim = await rig.c.prepareClaim(x.id);
      expect(claim.networkFee, kBridgeClaimFeeGroth);
      x = await rig.c.claim(x.id, claim);
      expect(x.state, BridgeCrossingState.claiming);
      expect(x.claimTxId, 'beamtx1');

      rig.beam.mine('beamtx1', 4072830);
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.claimed);
      expect(x.isOpen, isFalse);
    });

    test('USDT: the approval is mined before the lock is sent, and each '
        'hash is written as it comes', () async {
      final rig = Rig();
      var x = await rig.move(usdtRoute, toBeam, BigInt.from(100000000));
      expect(rig.eth.sent.map((t) => t.kind), [
        UniTxKind.approve,
        UniTxKind.swap,
      ]);
      expect(x.approveHashes, hasLength(1));
      expect(x.lockHash, isNotNull);
      final states = [
        for (final w in (rig.store as MemoryBridgeStore).writes)
          if (w.id == x.id) w.state.name,
      ];
      expect(states.first, 'approving');
      expect(states, contains('locking'));
      rig.eth.mineLock(x.lockHash!, msgId: 109);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.locked);
    });

    test(
      'an approval that fails ends it: nothing locked, no lock sent',
      () async {
        final rig = Rig()..eth.approvalsFail = true;
        final x = await rig.move(daiRoute, toBeam, ethUnits(10));
        expect(x.state, BridgeCrossingState.lockFailed);
        expect(x.lastError, contains('nothing was moved'));
        expect(rig.eth.sent.map((t) => t.kind), [UniTxKind.approve]);
      },
    );

    test('an approval not mined in 30 minutes ends it too', () async {
      final rig = Rig()..eth.approvalsMineAtOnce = false;
      final x = await rig.move(daiRoute, toBeam, ethUnits(10));
      expect(x.state, BridgeCrossingState.lockFailed);
      expect(x.lastError, contains('30 minutes'));
    });

    test('a lock Ethereum refused: nothing locked', () async {
      final rig = Rig();
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      rig.eth.mineLock(x.lockHash!, success: false);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.lockFailed);
    });

    test('collect automatically, while the app is open', () async {
      final rig = Rig();
      var x = await rig.move(beamRoute, toBeam, beams(100), autoClaim: true);
      rig.eth.mineLock(x.lockHash!, msgId: 222);
      rig.beam.deliver(beamRoute, 222, x.receives);
      rig.c.pause();
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.locking, reason: 'paused');
      // Looked at by hand (the screen's own refresh): not collected.
      await rig.c.poll(x.id);
      x = rig.c.crossing(x.id)!;
      expect(x.state, BridgeCrossingState.delivered, reason: 'in background');
      rig.c.resume();
      await pumpEventQueue();
      x = await rig.after(const Duration(seconds: 30), x.id);
      expect(x.state, BridgeCrossingState.claiming);
      expect(rig.beam.calls, contains('prepareReceive beam 222'));
      rig.beam.mine(x.claimTxId!, 4072900);
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.claimed);
    });

    test('the lock throws after it may have gone out: unknown, never sent '
        'again, found on BEAM', () async {
      final rig = Rig()..eth.sendMode = FakeSend.throwAfterBroadcast;
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      expect(x.state, BridgeCrossingState.unknown);
      expect(x.lockHash, isNull);
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.unknown);
      // Someone else's arrives first, another amount.
      rig.beam.deliver(ethRoute, 300, BigInt.from(77));
      rig.beam.deliver(ethRoute, 301, x.receives);
      x = await rig.after(const Duration(minutes: 1), x.id);
      expect(x.state, BridgeCrossingState.delivered);
      expect(x.msgId, 301);
      expect(rig.eth.sent, hasLength(1));
    });

    test('an approval that throws: nothing locked, and the lock is not '
        'sent', () async {
      final rig = Rig()
        ..eth.sendMode = FakeSend.throwBeforeBroadcast
        ..eth.sendModeStep = 0;
      final x = await rig.move(wbtcRoute, toBeam, BigInt.from(10000));
      expect(x.state, BridgeCrossingState.lockFailed);
      expect(rig.eth.sent, isEmpty);
    });

    test('not on BEAM 30 minutes after the lock: says so, keeps '
        'looking', () async {
      final rig = Rig();
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      rig.eth.mineLock(x.lockHash!, msgId: 129);
      x = await rig.after(const Duration(seconds: 15), x.id);
      x = await rig.after(const Duration(minutes: 31), x.id);
      expect(x.state, BridgeCrossingState.notDeliveredYet);
      rig.beam.deliver(ethRoute, 129, x.receives);
      x = await rig.after(const Duration(seconds: 30), x.id);
      expect(x.state, BridgeCrossingState.delivered);
    });

    test('a different amount on BEAM is not collected', () async {
      final rig = Rig();
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01), autoClaim: true);
      rig.eth.mineLock(x.lockHash!, msgId: 130);
      rig.beam.deliver(ethRoute, 130, x.receives - BigInt.one);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.unknown);
      expect(x.autoClaim, isFalse);
      expect(
        rig.beam.calls.any((c) => c.startsWith('prepareReceive')),
        isFalse,
      );
    });

    test('a claim that failed goes back to "collect", and only the user '
        'starts it again', () async {
      final rig = Rig();
      var x = await rig.move(beamRoute, toBeam, beams(100), autoClaim: true);
      rig.eth.mineLock(x.lockHash!, msgId: 223);
      rig.beam.deliver(beamRoute, 223, x.receives);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.claiming);
      rig.beam.status[x.claimTxId!] = const BeamPipeTxStatus.failed('expired');
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.delivered);
      expect(x.autoClaim, isFalse);
      expect(x.lastError, contains('Nothing was lost'));
      x = await rig.after(const Duration(minutes: 5), x.id);
      expect(x.state, BridgeCrossingState.delivered);
      expect(
        rig.beam.calls.where((c) => c.startsWith('execute')),
        hasLength(1),
      );
    });

    test('a claim that threw: claimed once the message is gone', () async {
      final rig = Rig();
      var x = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      rig.eth.mineLock(x.lockHash!, msgId: 131);
      rig.beam.deliver(ethRoute, 131, x.receives);
      x = await rig.after(const Duration(seconds: 15), x.id);
      rig.beam.executeMode = FakeExecute.throwAfterBroadcast;
      x = await rig.c.claim(x.id, await rig.c.prepareClaim(x.id));
      expect(x.state, BridgeCrossingState.claiming);
      expect(x.claimTxId, isNull);
      rig.beam.mine('beamtx1', 4072900);
      x = await rig.after(const Duration(seconds: 20), x.id);
      expect(x.state, BridgeCrossingState.claimed);
    });

    test('collected elsewhere first: no claim is sent, it says so', () async {
      final rig = Rig();
      var x = await rig.move(daiRoute, toBeam, ethUnits(10));
      rig.eth.mineLock(x.lockHash!, msgId: 0); // Ethereum ids start at 0
      rig.beam.deliver(daiRoute, 0, x.receives);
      x = await rig.after(const Duration(seconds: 15), x.id);
      expect(x.state, BridgeCrossingState.delivered);
      expect(x.msgId, 0);
      // The same wallet on another device collects it.
      rig.beam.remote[daiRoute.id]!.remove(0);
      await expectLater(
        rig.c.prepareClaim(x.id),
        throwsA(
          isA<BridgeException>().having(
            (e) => e.message,
            'message',
            contains('already collected'),
          ),
        ),
      );
      x = rig.c.crossing(x.id)!;
      expect(x.state, BridgeCrossingState.claimed);
      expect(x.lastError, contains('outside this screen'));
      expect(rig.beam.calls.any((c) => c.startsWith('execute')), isFalse);
    });

    test('a receive key Campfire does not trust: no quote', () async {
      final rig = Rig()..beam.keyFails = true;
      final q = await rig.quote(ethRoute, toBeam, ethUnits(0.01));
      expect(q.block?.code, BridgeBlockCode.network);
      expect(q.block!.title, "Couldn't check the bridge from these wallets");
      expect(q.plan, isNull);
    });

    test(
      'collecting needs 0.121 BEAM in the BEAM wallet at that time',
      () async {
        final rig = Rig();
        var x = await rig.move(usdtRoute, toBeam, BigInt.from(100000000));
        rig.eth.mineLock(x.lockHash!, msgId: 110);
        rig.beam.deliver(usdtRoute, 110, x.receives);
        x = await rig.after(const Duration(seconds: 15), x.id);
        rig.beam.balances[0] = beams(0.1);
        await expectLater(
          rig.c.prepareClaim(x.id),
          throwsA(
            isA<BridgeException>().having(
              (e) => e.message,
              'message',
              contains('0.121 BEAM'),
            ),
          ),
        );
      },
    );
  });

  group('restart and uniqueness', () {
    test('a restart mid-crossing resumes from the store', () async {
      final store = MemoryBridgeStore();
      final beam = FakeBeamSide();
      final eth = FakeEthSide();
      final first = Rig(beam: beam, eth: eth, store: store);
      final x = await first.move(beamRoute, toEth, beams(1000));
      first.c.dispose();

      beam.mine('beamtx1', 4072810);
      beam.tip = 4072900;
      eth.paid.add(1);
      final second = Rig(beam: beam, eth: eth, store: store);
      expect(second.c.crossings, isEmpty);
      await second.c.resumeAll();
      expect(second.c.crossings.single.state, BridgeCrossingState.sent);
      await second.c.pollDue();
      final y = second.c.crossing(x.id)!;
      expect(y.state, BridgeCrossingState.paid);
      expect(y.msgId, 1);
      expect(beam.calls.where((c) => c.startsWith('execute')), hasLength(1));
    });

    test(
      'closed between the approval and the lock: nothing was locked',
      () async {
        final store = MemoryBridgeStore();
        final eth = FakeEthSide()..approvalsMineAtOnce = false;
        final first = Rig(eth: eth, store: store);
        first.clock.hold = true; // the approval wait never ends
        final q = await first.quote(daiRoute, toBeam, ethUnits(10));
        final x = await first.c.start(await first.c.prepare(q));
        await pumpEventQueue(times: 3);
        first.c.dispose();
        expect((await store.byId(x.id))!.state, BridgeCrossingState.approving);

        final second = Rig(eth: eth, store: store);
        await second.c.resumeAll();
        final y = second.c.crossing(x.id)!;
        expect(y.state, BridgeCrossingState.lockFailed);
        expect(y.lastError, contains('nothing was moved'));
        expect(eth.sent.map((t) => t.kind), [UniTxKind.approve]);
      },
    );

    test('closed while sending to Ethereum: unknown, then found', () async {
      final store = MemoryBridgeStore();
      final now = DateTime.utc(2026, 10, 9, 16, 42);
      await store.save(
        BridgeCrossing(
          id: 'x1',
          routeId: 'usdt',
          direction: toEth,
          state: BridgeCrossingState.sending,
          amount: beams(100),
          receives: BigInt.from(100000000),
          relayerFee: beams(0.7),
          beamNetworkFee: kBridgeSendFeeGroth,
          beamWalletId: 'beam-wallet',
          ethWalletId: 'eth-wallet',
          ethAddress: kFakeEthAddress,
          countBefore: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      final rig = Rig(store: store);
      rig.beam.addLocal(
        usdtRoute,
        receiver: kFakeEthAddress,
        amount: beams(100),
        fee: beams(0.7),
        height: 4072805,
      );
      await rig.c.resumeAll();
      expect(rig.c.crossing('x1')!.state, BridgeCrossingState.unknown);
      await rig.c.pollDue();
      expect(rig.c.crossing('x1')!.state, BridgeCrossingState.confirmed);
      expect(rig.c.crossing('x1')!.msgId, 1);
    });

    test('two identical sends in one block take one message each', () async {
      final rig = Rig();
      final a = await rig.move(beamRoute, toEth, beams(1000));
      final b = await rig.move(beamRoute, toEth, beams(1000));
      rig.beam
        ..mine('beamtx1', 4072810)
        ..mine('beamtx2', 4072810);
      await rig.after(const Duration(seconds: 20), a.id);
      final ids = {rig.c.crossing(a.id)!.msgId, rig.c.crossing(b.id)!.msgId};
      expect(ids, {1, 2});
    });

    test('the store refuses a second crossing with the same message', () async {
      final store = MemoryBridgeStore();
      final now = DateTime.utc(2026);
      BridgeCrossing make(String id, BridgeDirection d) => BridgeCrossing(
        id: id,
        routeId: 'eth',
        direction: d,
        state: BridgeCrossingState.locked,
        amount: BigInt.one,
        receives: BigInt.one,
        relayerFee: BigInt.one,
        beamNetworkFee: BigInt.one,
        beamWalletId: 'b',
        ethWalletId: 'e',
        ethAddress: kFakeEthAddress,
        msgId: 7,
        createdAt: now,
        updatedAt: now,
      );
      await store.save(make('a', toBeam));
      await store.save(make('a', toBeam)); // the same crossing again
      await store.save(make('c', toEth)); // the other direction's 7
      await expectLater(
        store.save(make('b', toBeam)),
        throwsA(isA<BridgeStoreConflict>()),
      );
    });

    test('a lock naming a message another crossing has is not '
        'collected', () async {
      final rig = Rig();
      var a = await rig.move(ethRoute, toBeam, ethUnits(0.01));
      var b = await rig.move(ethRoute, toBeam, ethUnits(0.02));
      rig.eth
        ..mineLock(a.lockHash!, msgId: 140)
        ..mineLock(b.lockHash!, msgId: 140);
      a = await rig.after(const Duration(seconds: 15), a.id);
      b = rig.c.crossing(b.id)!;
      expect(a.state, BridgeCrossingState.locked);
      expect(b.state, BridgeCrossingState.unknown);
      expect(b.msgId, isNull);
      expect(b.autoClaim, isFalse);
    });
  });
}
