/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The worst the core may sign after the user approves contract data it can
// rebuild (DappRebuildTerms), checked against the core's own rule
// (`contract_transaction.cpp` IsSpendWithinLimits / IsSpendWithinLimitsUns)
// and against real DEX data built on mainnet by both pinned AMM shaders.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/contracts/common/pinned_shader.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_rebuild_terms.dart';

import '../contracts/dex/dex_fixtures.dart';
import 'dapp_invoke_builder.dart';

List<int> _fixture(String path) {
  final f = jsonDecode(File(path).readAsStringSync()) as Map;
  return base64.decode((f['result']! as Map)['raw_data_base64']! as String);
}

/// `IsSpendWithinLimitsUns(v0, v1)` without an explicit ceiling.
bool _coreUns(BigInt v0, BigInt v1) =>
    v1 <= v0 || v1 - v0 <= v0 ~/ BigInt.from(100);

/// The core's whole check (`IsSpendWithinLimits`), implicit ceiling: [ref]
/// is the approved net spend, [now] a rebuilt variant's.
bool _coreAccepts(Map<int, BigInt> ref, Map<int, BigInt> now) {
  for (final aid in {...ref.keys, ...now.keys}) {
    final v0 = ref[aid] ?? BigInt.zero;
    final v1 = now[aid] ?? BigInt.zero;
    if (v1 > BigInt.zero) {
      if (v0 <= BigInt.zero || !_coreUns(v0, v1)) return false;
    } else {
      if (v0 >= BigInt.zero) continue;
      if (!_coreUns(-v1, -v0)) return false;
    }
  }
  return true;
}

void main() {
  final pinnedTrade = BeamInvokeData.decode(
    _fixture('$dexFixtureDir/trade_built_raw_data.json'),
  );
  final dappTrade = BeamInvokeData.decode(
    _fixture('test/beam/dapps/fixtures/dex_dapp_swap_raw_data.json'),
  );

  group('the 1% rule, exactly as the core applies it', () {
    test('minReceive is the least amount the core still accepts', () {
      for (final r in [
        1,
        2,
        99,
        100,
        101,
        102,
        199,
        200,
        201,
        9999,
        10000,
        10101,
        80368764,
        1000000000,
        123456789012,
      ]) {
        final approved = BigInt.from(r);
        final min = DappRebuildTerms.minReceive(approved);
        expect(_coreUns(min, approved), isTrue, reason: '$r: $min accepted');
        if (min > BigInt.zero) {
          expect(
            _coreUns(min - BigInt.one, approved),
            isFalse,
            reason: '$r: ${min - BigInt.one} refused',
          );
        }
      }
    });

    test('the bounds are accepted, one unit past them is not', () {
      final t = DappRebuildTerms.of(pinnedTrade)!;
      final ref = pinnedTrade.spend;
      // Approved: pay 0.1 BEAM, receive 0.80368764 FOMO.
      expect(ref, {0: BigInt.from(10000000), 174: BigInt.from(-80368764)});
      expect(t.maxPays, {0: BigInt.from(10100000)});
      final minFomo = t.minReceives[174]!;
      expect(minFomo, BigInt.from(79573034));
      final worst = {0: t.maxPays[0]!, 174: -minFomo};
      expect(_coreAccepts(ref, worst), isTrue);
      expect(
        _coreAccepts(ref, {0: t.maxPays[0]! + BigInt.one, 174: -minFomo}),
        isFalse,
      );
      expect(
        _coreAccepts(ref, {0: t.maxPays[0]!, 174: -(minFomo - BigInt.one)}),
        isFalse,
      );
      // Paying an asset the approved data does not pay is never accepted.
      expect(_coreAccepts(ref, {...worst, 7: BigInt.one}), isFalse);
    });
  });

  group('whose code would rebuild it', () {
    test("a trade built by Campfire's pinned amm_app.wasm is BEAM's DEX", () {
      final t = DappRebuildTerms.of(pinnedTrade)!;
      expect(t.appCode, DappAppCode.beamDex);
      expect(
        dappVerifiedDexAppBodies[t.appCodeSha256],
        'amm_app.wasm (beam-7.5.14493)',
      );
      expect(t.explicitCeiling, isFalse);
    });

    test("the Beam DEX dApp's own swap (the one that landed in block "
        "4069717) is BEAM's DEX", () {
      final t = DappRebuildTerms.of(dappTrade)!;
      expect(t.appCode, DappAppCode.beamDex);
      expect(
        dappVerifiedDexAppBodies[t.appCodeSha256],
        'amm.wasm (Beam DEX 1.0.0)',
      );
      expect(dappTrade.spend, {
        0: BigInt.from(1009274),
        174: BigInt.from(-37600000000),
      });
      expect(dappTrade.fee, kDexCallFee);
      expect(dappTrade.appArgs!['action'], 'pool_trade');
      // The worst case the sheet showed before it was approved.
      expect(t.maxPays, {0: BigInt.from(1019366)});
      expect(t.minReceives, {174: BigInt.from(37227722773)});
    });

    test('the stored body is the compiled form, not the .wasm file', () {
      // Hashing the .wasm would never match: nothing about the file is
      // what process_invoke_data re-runs.
      expect(
        dappVerifiedDexAppBodies.containsKey(kAmmAppShaderSha256),
        isFalse,
      );
      expect(
        PinnedShader.digestOf(pinnedTrade.appShader!),
        'bdff009943b48d32af3253b7e61facd09777c8064e83934b23caa0443533dc8b',
      );
    });

    test('the pinned body with arguments for another action is unverified', () {
      // A dApp can store any arguments next to the pinned body; the rebuild
      // would then run that other action.
      final raw = _fixture('$dexFixtureDir/trade_built_raw_data.json');
      final tampered = _restoreArgs(raw, pinnedTrade, {
        ...pinnedTrade.appArgs!,
        'action': 'pool_withdraw',
      });
      final t = DappRebuildTerms.of(BeamInvokeData.decode(tampered))!;
      expect(t.appCode, DappAppCode.unverified);
    });

    test('the pinned body with arguments for another pool is unverified', () {
      final raw = _fixture('$dexFixtureDir/trade_built_raw_data.json');
      final otherPool = _restoreArgs(raw, pinnedTrade, {
        ...pinnedTrade.appArgs!,
        'aid1': '7',
      });
      final t = DappRebuildTerms.of(BeamInvokeData.decode(otherPool))!;
      expect(t.appCode, DappAppCode.unverified);
      // The 1% bound on what was approved still holds: the core enforces it
      // whatever the code builds.
      expect(t.maxPays, {0: BigInt.from(10100000)});
    });

    test('any other app body is unverified', () {
      final d = BeamInvokeData.decode(
        invokeData(
          [
            invokeEntry(
              contractId: kDexContractId,
              method: 7,
              flags: flagDependent | flagSaveAppInvoke,
              spend: {0: 50000000, 174: -1000},
            ),
          ],
          firstFlags: flagSaveAppInvoke,
          appArgs: {'action': 'pool_trade', 'cid': kDexContractId},
        ),
      );
      final t = DappRebuildTerms.of(d)!;
      expect(t.appCode, DappAppCode.unverified);
      expect(t.maxPays, {0: BigInt.from(50500000)});
      expect(t.minReceives, {174: BigInt.from(991)});
    });
  });

  group('when the core cannot rebuild, there are no terms', () {
    test('a plain call', () {
      final d = BeamInvokeData.decode(
        invokeData([
          invokeEntry(contractId: cid(0xa1), spend: {0: 50000000}),
        ]),
      );
      expect(DappRebuildTerms.of(d), isNull);
    });

    test('a dependent call with no app body to re-run', () {
      final d = BeamInvokeData.decode(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagDependent,
            spend: {0: 50000000},
          ),
        ]),
      );
      expect(d.isRebuildable, isTrue, reason: 'flagged, but CanRebuildHft no');
      expect(DappRebuildTerms.of(d), isNull);
    });

    test('a stored body without a dependent call', () {
      final d = BeamInvokeData.decode(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagSaveAppInvoke,
            spend: {0: 50000000},
          ),
        ], firstFlags: flagSaveAppInvoke),
      );
      expect(DappRebuildTerms.of(d), isNull);
    });
  });

  group('a stored spend ceiling replaces the 1% rule', () {
    test('"pay 0.5 BEAM, up to 1,000 BEAM" says 1,000 BEAM', () {
      final d = BeamInvokeData.decode(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagDependent | flagSaveAppInvoke | flagSaveSpendMax,
            spend: {0: 50000000, 174: -2000},
          ),
        ], firstFlags: flagSaveAppInvoke | flagSaveSpendMax),
      );
      final t = DappRebuildTerms.of(d)!;
      expect(t.explicitCeiling, isTrue);
      expect(t.maxPays, {0: BigInt.from(100000000000)});
      // The ceiling names no minimum for FOMO: it may not arrive at all.
      expect(t.minReceives, {174: BigInt.zero});
    });

    test('a negative ceiling is a minimum to receive', () {
      final d = BeamInvokeData.decode(
        invokeData(
          [
            invokeEntry(
              contractId: cid(0xa1),
              flags: flagDependent | flagSaveAppInvoke | flagSaveSpendMax,
              spend: {0: 50000000, 174: -2000},
            ),
          ],
          firstFlags: flagSaveAppInvoke | flagSaveSpendMax,
          spendMax: {0: 51000000, 174: -1900},
        ),
      );
      final t = DappRebuildTerms.of(d)!;
      expect(t.maxPays, {0: BigInt.from(51000000)});
      expect(t.minReceives, {174: BigInt.from(1900)});
    });
  });
}

/// [raw] with its stored app args replaced by [args] (same body, entries,
/// privilege): re-serialises the tail the way `invokeData` does.
List<int> _restoreArgs(
  List<int> raw,
  BeamInvokeData d,
  Map<String, String> args,
) {
  // The tail after the entries: app body, contract body, args, privilege.
  final body = d.appShader!;
  final bodyAt = _indexOf(raw, body);
  final head = raw.sublist(0, bodyAt - yu(body.length).length);
  return [
    ...head,
    ...yBuf(body),
    ...yBuf(const []),
    ...yu(args.length),
    for (final a in args.entries) ...[...yStr(a.key), ...yStr(a.value)],
    ...yu(d.appPrivilege!),
  ];
}

int _indexOf(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  throw StateError('not found');
}
