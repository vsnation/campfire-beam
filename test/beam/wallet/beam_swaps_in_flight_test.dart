/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Which transactions count as "a swap still being confirmed" (the quit
// guard and the node-switch gate read this). Transaction IDs and contract
// IDs other than the DEX's are synthetic.

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/dex/dex_constants.dart';
import 'package:stackwallet/wallets/beam/models/beam_transaction.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_swaps_in_flight.dart';

import 'beam_wallet_test_support.dart';

BeamTransaction _tx({
  required String id,
  required int status,
  int txType = 12,
  String? contract = kDexContractId,
}) => BeamTransaction.fromJson(
  txJson(
    txId: id,
    status: status,
    txType: txType,
    invokeData: contract == null
        ? null
        : [
            {
              'contract_id': contract,
              'amounts': [
                {'asset_id': 0, 'amount': 2000000},
              ],
            },
          ],
  ),
);

void main() {
  test('unsettled = a DEX contract call that is pending, in progress, '
      'registering or confirming', () {
    for (final s in [0, 1, 5, 6]) {
      expect(
        BeamSwapsInFlight.isUnsettledDexTx(_tx(id: 'a1' * 16, status: s)),
        isTrue,
        reason: 'status $s',
      );
    }
    for (final s in [2, 3, 4, 99]) {
      expect(
        BeamSwapsInFlight.isUnsettledDexTx(_tx(id: 'a1' * 16, status: s)),
        isFalse,
        reason: 'status $s',
      );
    }
  });

  test('other contracts and plain sends are not tracked (a restart re-sends '
      'the same transaction)', () {
    expect(
      BeamSwapsInFlight.isUnsettledDexTx(
        _tx(id: 'a1' * 16, status: 1, contract: 'cd' * 32),
      ),
      isFalse,
    );
    expect(
      BeamSwapsInFlight.isUnsettledDexTx(
        _tx(id: 'a1' * 16, status: 1, txType: 0, contract: null),
      ),
      isFalse,
    );
    expect(
      BeamSwapsInFlight.isUnsettledDexTx(
        _tx(id: 'a1' * 16, status: 1, contract: kDexContractId.toUpperCase()),
      ),
      isTrue,
    );
  });

  test('update / forget per wallet; changes fire only on a change', () {
    final s = BeamSwapsInFlight();
    var fired = 0;
    s.changes.listen((_) => fired++);
    expect(s.isEmpty, isTrue);

    s.update('w1', [
      _tx(id: 'a1' * 16, status: 1),
      _tx(id: 'b2' * 16, status: 3),
    ]);
    s.update('w2', [_tx(id: 'c3' * 16, status: 5)]);
    expect(s.count, 2);
    expect(s.of('w1'), {'a1' * 16});
    expect(fired, 2);

    s.update('w1', [_tx(id: 'a1' * 16, status: 1)]);
    expect(fired, 2, reason: 'same set, no event');

    s.update('w1', [_tx(id: 'a1' * 16, status: 3)]);
    expect(s.of('w1'), isEmpty);
    expect(s.count, 1);
    expect(fired, 3);

    s.forget('w2');
    expect(s.isEmpty, isTrue);
    expect(fired, 4);
    s.forget('w2');
    expect(fired, 4);
  });
}
