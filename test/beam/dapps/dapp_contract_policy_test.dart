/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Security review part 2, C-1 and H-1: what a dApp may submit to
// `process_invoke_data`, and how the approval shows what it does. Every
// payload here is one a malicious dApp can build by hand; each test goes
// through a real DappSession and checks that nothing reaches the core.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/airdrop/airdrop_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_constants.dart';
import 'package:stackwallet/wallets/beam/contracts/common/invoke_data.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_consent.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_wallet_keys.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';
import 'package:stackwallet/wallets/beam/rpc/fake_transport.dart';

import '../contracts/dex/dex_fixtures.dart';
import 'dapp_invoke_builder.dart';
import 'dapp_session_fixtures.dart';

const _x = 1000000000; // 10 BEAM

/// A key id hash no Campfire module uses.
final _someKey = 'c7' * 32;

void main() {
  late FakeTransport t;
  late ScriptedPolicy policy;
  late List<DappActivity> activity;
  late DappSession session;

  setUp(() {
    t = FakeTransport({
      'process_invoke_data': (Map<String, Object?> p) => {'txid': txId(1)},
    });
    policy = ScriptedPolicy();
    activity = [];
    session = testSession(t, policy, onActivity: activity.add);
  });

  /// Submits [data]; expects a refusal before any prompt or core call, and
  /// returns the error's `data` (the plain message the dApp gets).
  Future<String> refused(List<int> data) async {
    final res = await session.handle(
      rq(1, 'process_invoke_data', {'data': data}),
    );
    expect(errorCode(res), -32020, reason: 'refused as not allowed');
    expect(policy.shown, isEmpty, reason: 'never put to the user');
    expect(t.callsTo('process_invoke_data'), isEmpty, reason: 'nor the core');
    final why = errorData(res)! as String;
    expect(activity.last.kind, DappActivityKind.refused);
    expect(activity.last.detail, why, reason: 'the user is told too');
    return why;
  }

  /// Submits [data] and returns the request put to the user (left
  /// waiting).
  Future<DappConsentRequest> shown(List<int> data) async {
    final pending = session.handle(
      rq(1, 'process_invoke_data', {'data': data}),
    );
    await policy.waitShown(1);
    policy.answer(0, false);
    expect(errorCode(await pending), -32021);
    return policy.shown.single;
  }

  final plain = invokeEntry(contractId: cid(0xa1), spend: {0: 50000000});

  group('C-1: data the core could rebuild after approval is refused', () {
    test('control: the same call without the flags is shown', () async {
      final r = await shown(invokeData([plain]));
      expect(r.pays.single.amount, BigInt.from(50000000));
    });

    test('a dependent entry (HFT) with a made-up parent context', () async {
      final why = await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagDependent,
            spend: {0: 50000000},
          ),
        ]),
      );
      expect(why, contains("can't show you what would be signed"));
      expect(why, endsWith('Nothing was sent.'), reason: 'not the DEX');
    });

    test('a stored app body to re-run (SaveAppInvoke)', () async {
      await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagSaveAppInvoke,
            spend: {0: 50000000},
          ),
        ], firstFlags: flagSaveAppInvoke),
      );
    });

    test('a stored spend ceiling: "pay 0.5 BEAM, up to the whole balance" '
        '(SaveSpendMax)', () async {
      final data = invokeData([
        invokeEntry(
          contractId: cid(0xa1),
          flags: flagDependent | flagSaveAppInvoke | flagSaveSpendMax,
          spend: {0: 50000000},
        ),
      ], firstFlags: flagSaveAppInvoke | flagSaveSpendMax);
      // What the old sheet would have shown: 0.5 BEAM. The ceiling the
      // core would then honour on a rebuild: 1,000 BEAM.
      final d = BeamInvokeData.decode(data);
      expect(d.pays, {0: BigInt.from(50000000)});
      expect(d.spendMax, {0: BigInt.from(100000000000)});
      await refused(data);
    });

    test('SaveSpendMax alone', () async {
      await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagSaveSpendMax,
            spend: {0: 50000000},
          ),
        ], firstFlags: flagSaveSpendMax),
      );
    });

    test('a dependent second entry behind a plain first one', () async {
      await refused(
        invokeData([
          plain,
          invokeEntry(contractId: cid(0xa2), flags: flagDependent),
        ]),
      );
    });

    test('a stored privilege above 0 is refused for what it is', () async {
      final why = await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            flags: flagSaveAppInvoke,
            spend: {0: 50000000},
          ),
        ], firstFlags: flagSaveAppInvoke, privilege: 1),
      );
      expect(why, contains('extra privileges'));
    });

    test('real DEX data built in HFT mode is refused from a dApp', () async {
      // Built by the pinned amm_app.wasm on mainnet (Dependent +
      // SaveAppInvoke): Campfire's own Swap screen checks the stored body
      // against its pin; a dApp's data has no such check.
      final f = jsonDecode(
        File('$dexFixtureDir/trade_built_raw_data.json').readAsStringSync(),
      ) as Map;
      final raw = base64.decode(
        (f['result']! as Map)['raw_data_base64']! as String,
      );
      expect(BeamInvokeData.decode(raw).isRebuildable, isTrue);
      expect(await refused(raw), endsWith('use Swap in Campfire.'));
      activity.clear();
      await refused(rawDataVector('add_dependent'));
    });
  });

  group('H-1: what each call does, not the net', () {
    // Call 1 takes 10 BEAM out of contract A (signed with a key of the
    // wallet's), call 2 locks 10 BEAM into contract B. The wallet's
    // balance ends where it started; the 10 BEAM end up in B.
    final netting = invokeData([
      invokeEntry(
        contractId: cid(0xa1),
        method: 3,
        spend: {0: -_x},
        sigs: [_someKey],
      ),
      invokeEntry(contractId: cid(0xb2), spend: {0: _x}),
    ]);

    test('two calls that net to zero are not "fee only"', () async {
      final r = await shown(netting);
      expect(r.pays, isEmpty, reason: 'the net, as before');
      expect(r.receives, isEmpty);
      expect(r.isFeeOnly, isFalse);
      expect(r.calls[0].receives, [DappAssetAmount(0, BigInt.from(_x))]);
      expect(r.calls[0].signs, isTrue);
      expect(r.calls[1].pays, [DappAssetAmount(0, BigInt.from(_x))]);

      final m = DappApprovalModel.build(r);
      expect(m.kind, DappApprovalKind.contractCall);
      expect(m.isFeeOnly, isFalse);
      expect(m.cta, 'Approve contract calls');
      expect(m.showsCalls, isTrue);
      expect(m.calls[0].receives.single.text, '10 BEAM');
      expect(m.calls[1].pays.single.text, '10 BEAM');
      expect(m.calls[1].title, 'Call 2 · Contract b2b2b2b2…b2b2b2 · method 2');
      expect(m.passThroughWarning, contains('paid into another contract'));
      expect(m.signingWarnings.single, startsWith('Call 1 signs with your'));
    });

    test('a net "payment" made of two calls is shown as two calls', () async {
      // Takes 10 BEAM out of A, locks 11 into B: the net is "pay 1 BEAM",
      // which the old sheet showed as a 1 BEAM payment to a contract.
      final r = await shown(
        invokeData([
          invokeEntry(contractId: cid(0xa1), method: 3, spend: {0: -_x}),
          invokeEntry(contractId: cid(0xb2), spend: {0: _x + 100000000}),
        ]),
      );
      expect(r.pays, [DappAssetAmount(0, BigInt.from(100000000))]);
      final m = DappApprovalModel.build(r);
      expect(m.kind, DappApprovalKind.contractCall);
      expect(m.cta, 'Approve contract calls');
      expect(m.calls[0].receives.single.text, '10 BEAM');
      expect(m.calls[1].pays.single.text, '11 BEAM');
      expect(m.passThroughWarning, isNotNull);
    });

    test('a call that only signs is not "fee only" either', () async {
      final r = await shown(
        invokeData([
          invokeEntry(contractId: cid(0xa1), method: 3, sigs: [_someKey]),
        ]),
      );
      expect(r.isFeeOnly, isFalse);
      final m = DappApprovalModel.build(r);
      expect(m.kind, DappApprovalKind.contractCall);
      expect(m.cta, 'Approve contract call');
      expect(
        m.signingWarnings.single,
        "This call signs with your wallet's key for Contract "
        'a1a1a1a1…a1a1a1. It can change or move what you hold in that '
        'contract.',
      );
    });

    test('control: no funds and no signature is still fee only', () async {
      final r = await shown(invokeData([invokeEntry(contractId: cid(0xa1))]));
      expect(r.isFeeOnly, isTrue);
      expect(DappApprovalModel.build(r).kind, DappApprovalKind.feeOnly);
    });

    test('a call signed with the BANS key is refused', () async {
      final why = await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            method: 3,
            sigs: [DappWalletKeys.keyHash(hexBytes(kBansCid))],
          ),
        ]),
      );
      expect(why, contains('your BEAM names'));
    });

    test('calls signed with the airdrop keys are refused', () async {
      await refused(
        invokeData([
          invokeEntry(
            contractId: cid(0xa1),
            sigs: [
              DappWalletKeys.keyHash([...hexBytes(kAirdropContractId), 0]),
            ],
          ),
        ]),
      );
      activity.clear();
      await refused(
        invokeData([
          invokeEntry(
            contractId: kAirdropContractId,
            sigs: [
              DappWalletKeys.keyHash(const [0xAD, 42]),
            ],
          ),
        ]),
      );
    });

    test('any call to BANS or its Anon-Vault is refused', () async {
      final why = await refused(
        invokeData([invokeEntry(contractId: kBansCid, method: 3)]),
      );
      expect(why, contains('BEAM names (BANS)'));
      activity.clear();
      // The review's exploit: withdraw from the user's vault account.
      await refused(
        invokeData([
          invokeEntry(contractId: kVaultAnonCid, method: 3, spend: {0: -_x}),
          invokeEntry(contractId: cid(0xb2), spend: {0: _x}),
        ]),
      );
    });

    test('known contracts are named; others are not guessed', () {
      expect(dappContractName(dexCid), 'Beam DEX');
      expect(dappContractName(kBansCid), 'BEAM names (BANS)');
      expect(dappContractName(kAirdropContractId), 'Campfire airdrops');
      expect(dappContractName(cid(0xa1)), isNull);
    });
  });

  group('the key and contract facts the refusals rest on', () {
    test('the airdrop key hash is the one the airdrop shader signs with', () {
      // Recorded from mainnet: Campfire's create_batch raw_data.
      final f = jsonDecode(
        File(
          'test/beam/contracts/airdrop/fixtures/create_batch_2x0.001.json',
        ).readAsStringSync(),
      );
      List<int>? raw;
      void find(Object? o) {
        if (o is Map) {
          for (final e in o.entries) {
            if (e.key == 'raw_data' && e.value is List) {
              raw = (e.value as List).cast<int>();
            } else {
              find(e.value);
            }
          }
        } else if (o is List) {
          o.forEach(find);
        } else if (o is String && o.startsWith('{')) {
          find(jsonDecode(o));
        }
      }

      find(f);
      final d = BeamInvokeData.decode(raw!);
      final userKey = DappWalletKeys.keyHash([
        ...hexBytes(kAirdropContractId),
        0,
      ]);
      expect(d.entries.single.signatureKeyHashes, contains(userKey));
      expect(DappWalletKeys.reservedUse(userKey), 'your airdrops');
    });

    test('the Anon-Vault id is the one BANS reports', () {
      final f = jsonDecode(
        File(
          'test/beam/contracts/bans/fixtures/view_params.json',
        ).readAsStringSync(),
      ) as Map;
      final out = jsonDecode((f['result']! as Map)['output']! as String) as Map;
      expect((out['res']! as Map)['vault'], kVaultAnonCid);
      expect((out['res']! as Map)['dao-vault'], kDaoVaultCid);
    });

    test('key hash: SHA-256("bvm.m.key\\0" ‖ id)', () {
      // python3: hashlib.sha256(b"bvm.m.key\0" + bytes.fromhex(BANS)).hexdigest()
      expect(
        DappWalletKeys.keyHash(hexBytes(kBansCid)),
        '40ceff526e1f93763a4d67d995c5359e55b607217290348cc751fc35135c6d93',
      );
    });
  });
}
