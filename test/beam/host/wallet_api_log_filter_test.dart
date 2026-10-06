/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What of wallet-api's console reaches the wallet's log file (security
// review finding 6). The lines are shaped like BEAM 7.5.14493's output
// (`I <yyyy-mm-dd.hh:mm:ss.mmm> <message>`); every address, endpoint and
// transaction ID below is a synthetic repeated pattern, never a real one.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/host/wallet_api_log_filter.dart';

const _ts = '2026-10-06.12:00:00.000';
final _addr = '${'e0' * 33}f'; // 67 hex, the regular address shape
final _ep = 'Ep' * 22; // 44 base58 characters, an endpoint's shape
final _txid = '7a' * 16;

void main() {
  List<String> run(List<String> lines) {
    final f = BeamWalletApiLogFilter();
    return [
      for (final l in lines)
        if (f.fileLine(l) case final kept?) kept,
    ];
  }

  test('the wallet history never reaches the file', () {
    final history = [
      'I $_ts WalletID $_addr subscribes to BBS channel 7',
      'I $_ts WalletID $_addr',
      'I $_ts New Wallet address generated: $_addr',
      'I $_ts Endpoint = $_ep',
      'I $_ts Generated regular old style address: $_addr',
      'I $_ts Generated offline address: $_ep$_ep',
      'I $_ts Generated max privacy address: $_ep$_ep',
      'I $_ts $_txid Sending 0.1 BEAM (fee: 0.001 BEAM), my EP $_ep, '
          'peer EP $_ep',
      'I $_ts $_txid Receiving 2.5 BEAM (fee: 0.001 BEAM), asset ID: 174',
      'I $_ts CoinID: Regular, 10000000 BEAM Maturity=4068280 Confirmed, '
          'Height=4068280',
      'I $_ts Shielded output, ID: 12345 Confirmed, Height=4068280',
      'I $_ts \t (aid, amount): (0, 10000000)',
      'D $_ts anything at debug level',
      'V $_ts anything at verbose level',
      'I $_ts $_txid Get proof for kernel: $_addr',
      // Even at warning level, a line about a send is dropped.
      'W $_ts $_txid Sending 0.1 BEAM, my EP $_ep',
      '',
      '\tcontinuation of something else',
    ];
    expect(run(history), isEmpty);
  });

  test('startup markers, heights, the rules and warnings are kept', () {
    final kept = run([
      'I $_ts Wallet API config read from: /home/x/beam/run/.s-1a2b.cfg',
      'I $_ts Beam Wallet API 7.5.14493 (beam-7.5.14493-campfire)',
      'I $_ts Rules signature: network=mainnet',
      '\t0-ed91a717313c6eb0',
      '\t3928666-96df3f33ee02ad9e',
      'I $_ts ACL file successfully loaded',
      'I $_ts wallet successfully opened...',
      'I $_ts Start server on 127.0.0.1:40001',
      'I $_ts Sync up to 4100000-0123456789abcdef',
      'I $_ts Synchronizing with node: 100% (1/1)',
      'I $_ts Current state is 4100000-0123456789abcdef',
      'I $_ts It seems that last known blockchain tip is not up to date',
      'W $_ts Unable to resolve node address: eu-nodes.mainnet.beam.mw:8100',
      'E $_ts cannot start server: bind failed',
      'Reading config from /home/x/beam/run/.s-1a2b.cfg',
      'Wallet not opened. File is not a database',
    ]);
    expect(kept, hasLength(16));
    expect(kept, contains('\t3928666-96df3f33ee02ad9e'));
    expect(kept.last, 'Wallet not opened. File is not a database');
  });

  test('long tokens are replaced in every kept line', () {
    final kept = run([
      'E $_ts Transaction $_txid was not imported. Invalid address parameter',
      'W $_ts Received vouchers for unknown address: $_addr',
      'EXCEPTION: something about $_ep',
    ]);
    expect(kept, hasLength(3));
    for (final line in kept) {
      expect(line, isNot(matches(RegExp(r'[A-Za-z0-9]{32,}'))));
      expect(line, contains('[redacted]'));
    }
  });

  test('a header with (func, file:line) is understood', () {
    expect(
      run(['I $_ts (Foo, wallet.cpp:12) WalletID $_addr']),
      isEmpty,
    );
    expect(
      run(['I $_ts (Foo, api_cli.cpp:290) Start server on 127.0.0.1:1']),
      hasLength(1),
    );
  });
}
