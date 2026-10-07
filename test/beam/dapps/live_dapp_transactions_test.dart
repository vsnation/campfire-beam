/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// LIVE, nothing sent: each bundled dApp's own money-moving call, built on
// mainnet by the dApp's own app shader (from its pinned package) with the
// arguments the dApp's code sends, then submitted with
// `process_invoke_data` the way the dApp does. Proves every one reaches
// Campfire's approval sheet (the real presenter and model, with live
// balances and prices) with decoded amounts and fee, and that a rejection
// answers -32021 with nothing reaching the core.
//
// Opt-in. Any synced wallet works; the funds are never spent:
//
//   test/beam/dapps/tool/fetch_bundled_dapps.sh
//   python3 -I scripts/beam/live/wapi.py start <label> --port 10121 --tcp
//   BEAM_LIVE_DAPPS=1 BEAM_LIVE_LABEL=<label> \
//     flutter test test/beam/dapps/live_dapp_transactions_test.dart
// ignore_for_file: avoid_print
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/wallets/beam/dapps/dapp_api_version.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_catalogue.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_identity.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_package.dart';
import 'package:stackwallet/wallets/beam/dapps/dapp_session.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_model.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_approval_presenter.dart';
import 'package:stackwallet/wallets/beam/dapps/host/dapp_watched_consent_queue.dart';

import 'live_dapp_harness.dart';

/// A made-up Ethereum address for the bridges: the call is never sent.
const _ethAddress = '00112233445566778899aabbccddeeff00112233';

/// One dApp's money-moving call, exactly as its code builds the args.
typedef _Case = ({
  String file,
  String shader,
  String action,
  String args,
  DappApprovalKind kind,
});

const List<_Case> _cases = [
  (
    file: 'dex-app.dapp',
    shader: 'app/amm.wasm',
    action: 'buy 376 FOMO',
    args:
        'action=pool_trade,aid1=174,aid2=0,kind=2,val1_buy=37600000000,'
        'bPredictOnly=0,cid=729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae'
        '69b47bcfdeef9cbf',
    kind: DappApprovalKind.swap,
  ),
  (
    file: 'accum-dapp.dapp',
    shader: 'app/app.wasm',
    action: 'lock 0.001 LP token for one period',
    args:
        'action=user_lock,cid=ec160307c43bc3fc0c3a52d3e3d3dfd8101593e8cec7a9'
        '07fc42c9f103aabbae,amountLpToken=100000,lockPeriods=1,isNph=0',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'beam-asset-minter.dapp',
    shader: 'app/app.wasm',
    action: 'create a token',
    args:
        'action=create_token,metadata="STD:SCH_VER=1;N=Campfire Test;'
        'SN=CFT;UN=CFT;NTHUN=GROTH",limit=100000000,cid=295fe749dc12c55213d1'
        'bd16ced174dc8780c020f59cb17749e900bb0c15d868',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'beam-bridge-app.dapp',
    shader: 'app/pipe_app.wasm',
    action: 'send to Ethereum',
    args:
        'role=user,action=send,cid=8af23fe6338e3e67574f4548c9acf3d269756ae9b2'
        '5ab025fd4268a07b8a3c29,amount=1000000,receiver=$_ethAddress,'
        'relayerFee=100000',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'beam-bridge-reverse-app.dapp',
    shader: 'app/pipe_app.wasm',
    action: 'send BEAM to Ethereum',
    args:
        'role=user,action=send,cid=e63bd26ca5b226558686dd191122a8e5d6861a9759'
        '7db9f40bda48aef6dbe835,amount=1000000,receiver=$_ethAddress,'
        'relayerFee=100000',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'dao-core-app.dapp',
    shader: 'app/daoCore.wasm',
    action: 'lock 0.1 BEAM for BeamX farming',
    args:
        'role=manager,action=farm_update,cid=3f3d32e38cb27ac7b5b67343f81cf2f'
        '8bc53217eb995cc6c5d78ddc5e7b0642b,bLockOrUnlock=1,amountBeam=10000000',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'dao-voting-app.dapp',
    shader: 'app/votingAppShader.wasm',
    action: 'stake 0.1 BEAMX to vote',
    args:
        'role=user,action=move_funds,amount=10000000,bLock=1,cid=64c8bbbd7c41'
        '1bd7f9f9a0fd4ca678c581350b5b5ce0b0c055033c7e8f69e555',
    kind: DappApprovalKind.contractPayment,
  ),
  (
    file: 'nft-marketplace.dapp',
    shader: 'app/galleryManager.wasm',
    action: 'buy NFT #4',
    args:
        'role=user,action=buy,id=4,cid=4390f75c95f60e6c069fb25a4c210d9b3b8a79'
        '804b1e5ddba431965ea8eb4cd9',
    kind: DappApprovalKind.contractPayment,
  ),
];

String _worst(DappApprovalModel m) {
  String lines(List<DappAssetLine> l) =>
      l.isEmpty ? '-' : l.map((x) => x.text).join(', ');
  final r = m.rebuild!;
  return '${r.appCodeLabel}, pays at most ${lines(r.maxPays)}, gets at '
      'least ${lines(r.minReceives)}, tick ${m.needsAcknowledgement}';
}

void main() {
  final enabled = Platform.environment['BEAM_LIVE_DAPPS'] == '1';
  final label = Platform.environment['BEAM_LIVE_LABEL'] ?? 'w2views';
  final cache =
      Platform.environment['CFB_DAPP_PACKAGES'] ??
      p.join(Platform.environment['HOME'] ?? '', '.cache/campfire-beam/dapps');

  for (final c in _cases) {
    test(
      '${c.file}: "${c.action}" reaches the approval sheet; rejected, '
      'nothing is sent',
      () async {
        final entry = dappBundledCatalogue.firstWhere(
          (e) => e.fileName == c.file,
        );
        final pkg = DappPackage.read(
          File(p.join(cache, c.file)).readAsBytesSync(),
        );
        final shader = pkg.files.firstWhere((f) => f.path == c.shader).bytes;
        final tcp = await liveWalletTransport(label);
        final spy = LiveSpyTransport(tcp);
        final link = LiveWalletLink(spy);
        final presenter = DappApprovalPresenter(link);
        final shown = <DappApprovalModel>[];
        presenter.attach((m) async {
          shown.add(m);
          return false;
        });
        final identity = DappIdentity.fromManifest(
          pkg.manifest,
          'http://127.0.0.1:40000',
          checkedByCampfire: true,
        );
        final session = DappSession(
          identity: identity,
          apiVersion: DappApiVersion.v7_4,
          transport: link.dappTransport(identity),
          consent: DappWatchedConsentQueue(presenter),
        );
        try {
          String rq(int id, String method, Map<String, Object?> params) =>
              jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'method': method,
                'params': params,
              });
          final built = jsonDecode(
            await session.handle(
              rq(1, 'invoke_contract', {
                'contract': shader,
                'args': c.args,
                'create_tx': false,
              }),
            ),
          ) as Map<String, Object?>;
          expect(built['error'], isNull, reason: '$built');
          final result = built['result']! as Map;
          final raw = result['raw_data'];
          expect(
            raw,
            isA<List<Object?>>(),
            reason: 'shader output: ${result['output']}',
          );
          final answer = jsonDecode(
            await session.handle(rq(2, 'process_invoke_data', {'data': raw})),
          ) as Map<String, Object?>;
          expect(shown, hasLength(1), reason: 'the sheet was shown: $answer');
          final m = shown.single;
          String lines(List<DappAssetLine> l) =>
              l.isEmpty ? '-' : l.map((x) => x.text).join(', ');
          print(
            '[evidence] ${entry.name}, ${c.action}: "${m.summary}" '
            'pays ${lines(m.pays)}; receives ${lines(m.receives)}; '
            'fee ${m.fee.text}; calls '
            '${m.calls.map((x) => x.title).join(' + ')}; '
            'CTA "${m.cta}"'
            '${m.rebuild == null ? '' : '; rebuild: ${_worst(m)}'}'
            '${m.shortfall.isEmpty ? '' : '; short ${lines(m.shortfall)}'}',
          );
          expect(m.kind, c.kind);
          expect(
            m.request.fee >= BigInt.from(1100000),
            isTrue,
            reason: 'a contract call costs at least 0.011 BEAM',
          );
          expect(
            (answer['error']! as Map)['code'],
            -32021,
            reason: 'rejected as the user rejects',
          );
          expect(spy.to('process_invoke_data'), isEmpty, reason: 'not sent');
        } finally {
          await session.close();
          await tcp.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: enabled ? false : 'set BEAM_LIVE_DAPPS=1 to run',
    );
  }
}
