/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_payment_notice.dart';

BeamPaymentReceived _payment(int assetId, num amount) => BeamPaymentReceived(
  walletId: 'w',
  walletName: 'Savings',
  txId: 'ab' * 16,
  value: BigInt.from((amount * 100000000).round()),
  assetId: assetId,
  at: DateTime(2026, 10, 7),
);

void main() {
  test('BEAM and verified assets are named by their ticker', () {
    expect(_payment(0, 0.5).title, 'Received 0.5 BEAM');
    expect(_payment(0, 12).title, 'Received 12 BEAM');
    expect(_payment(174, 568.1297).title, 'Received 568.1297 FOMO');
  });

  test('an unverified asset is named by its number, never a ticker', () {
    expect(_payment(779, 3).title, 'Received 3 of token #779');
  });
}
