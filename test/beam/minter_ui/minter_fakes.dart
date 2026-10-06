/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Fake Minter and BlackHole app shaders for the UI tests, answering the
// way the pinned shaders do. The Minter's view_params / view_token answers
// and the BlackHole's view_funds are the recorded mainnet fixtures under
// test/beam/contracts/{minter,burn}/fixtures; the built transactions are
// serialized with the same writer the service tests use.

import 'dart:convert';
import 'dart:io';

import 'package:stackwallet/wallets/beam/contracts/burn/burn.dart';
import 'package:stackwallet/wallets/beam/contracts/minter/minter.dart';

import '../contracts/airdrop/invoke_data_writer.dart';

const _minterDir = 'test/beam/contracts/minter/fixtures';
const _fakeKey =
    '5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a00';

Map<String, Object?> _fixture(String path) =>
    ((jsonDecode(File(path).readAsStringSync()) as Map)['result']! as Map)
        .cast<String, Object?>();

Map<String, Object?> _built(FakeInvokeEntry e) => {
  'output': '{}',
  'raw_data': InvokeDataWriter.write([e]),
  'txid': '00000000000000000000000000000000',
};

/// A token this wallet created: (minted, limit, metadata).
typedef FakeToken = (BigInt, BigInt, String);

class FakeMinterShader {
  /// Tokens this wallet owns, by asset id.
  final owned = <int, FakeToken>{};

  /// Every `args` seen.
  final seen = <String>[];

  Map<String, Object?> call(Map<String, Object?> p) {
    if (p['create_tx'] != false) throw StateError('create_tx must be false');
    final args = p['args']! as String;
    seen.add(args);
    final a = parseArgs(args);
    switch (a['action']) {
      case 'view_params':
        return _fixture('$_minterDir/view_params.json');
      case 'view_owned':
        return {
          'output': jsonEncode({
            'res': [
              for (final o in owned.entries)
                {
                  'aid': o.key,
                  'mintedLo': o.value.$1.toInt(),
                  'mintedHi': 0,
                  'limitLo': o.value.$2.toInt(),
                  'limitHi': 0,
                  'owner_pk': _fakeKey,
                  'metadata': o.value.$3,
                },
            ],
          }),
        };
      case 'view_token':
        final aid = int.parse(a['aid']!);
        if (aid == 44) return _fixture('$_minterDir/view_token_44.json');
        final o = owned[aid];
        if (o == null) return _fixture('$_minterDir/view_token_missing.json');
        return {
          'output': jsonEncode({
            'res': {
              'mintedLo': o.$1.toInt(),
              'mintedHi': 0,
              'limitLo': o.$2.toInt(),
              'limitHi': 0,
              'owner_pk': _fakeKey,
              'is_owner': 1,
            },
          }),
        };
      case 'create_token':
        final meta = utf8.encode(a['metadata']!);
        return _built(
          FakeInvokeEntry(
            method: MinterMethod.createToken,
            cid: kMinterContractId,
            args: [
              ...InvokeDataWriter.le(BigInt.zero, 4),
              ...InvokeDataWriter.le(BigInt.parse(a['limit']!), 8),
              ...InvokeDataWriter.le(BigInt.parse(a['limitHi']!), 8),
              ...InvokeDataWriter.hexBytes(_fakeKey),
              ...InvokeDataWriter.le(BigInt.from(meta.length), 4),
              ...meta,
            ],
            funds: {0: BigInt.from(6000000000)},
            comment: MinterKernelComment.createToken,
            charge: kMinterCreateTokenCharge,
          ),
        );
      case 'withdraw':
        final aid = int.parse(a['aid']!);
        final v = BigInt.parse(a['value']!);
        return _built(
          FakeInvokeEntry(
            method: MinterMethod.withdraw,
            cid: kMinterContractId,
            args: [
              ...InvokeDataWriter.le(BigInt.from(aid), 4),
              ...InvokeDataWriter.le(v, 8),
            ],
            funds: {aid: -v},
            comment: MinterKernelComment.mint,
            sigs: [List.filled(32, 7)],
          ),
        );
    }
    return {'output': '{"error": "unknown action"}'};
  }
}

/// The BlackHole's `deposit`, as `On_manager_deposit` builds it.
class FakeBurnShader {
  final seen = <String>[];

  Map<String, Object?> call(Map<String, Object?> p) {
    if (p['create_tx'] != false) throw StateError('create_tx must be false');
    final args = p['args']! as String;
    seen.add(args);
    final a = parseArgs(args);
    if (a['action'] == 'view_funds') {
      return _fixture('test/beam/contracts/burn/fixtures/view_funds.json');
    }
    final aid = int.parse(a['aid']!);
    final amount = BigInt.parse(a['amount']!);
    return _built(
      FakeInvokeEntry(
        method: kBlackHoleDepositMethod,
        cid: a['cid']!,
        args: [
          ...InvokeDataWriter.le(BigInt.from(aid), 4),
          ...InvokeDataWriter.le(amount, 8),
        ],
        funds: {aid: amount},
        comment: kBlackHoleDepositComment,
      ),
    );
  }
}
