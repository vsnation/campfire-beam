/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/app_config.dart';
import 'package:stackwallet/pages/settings_views/global_settings_view/stack_backup_views/helpers/restore_create_backup.dart';

void main() {
  test('nodes of shipped coins are restored', () {
    for (final coin in AppConfig.coins) {
      expect(
        SWB.isNodeForConfiguredCoin({'coinName': coin.prettyName}),
        isTrue,
        reason: coin.prettyName,
      );
    }
  });

  test('nodes of coins this build does not ship are skipped', () {
    // A stock Campfire backup carries Firo nodes; restoring them into a
    // build without Firo made a cancelled restore hang.
    final shipsFiro = AppConfig.coins.any((c) => c.prettyName == 'Firo');
    if (!shipsFiro) {
      expect(SWB.isNodeForConfiguredCoin({'coinName': 'Firo'}), isFalse);
    }
    expect(SWB.isNodeForConfiguredCoin({'coinName': 'Not A Coin'}), isFalse);
    expect(SWB.isNodeForConfiguredCoin({}), isFalse);
    expect(SWB.isNodeForConfiguredCoin({'coinName': 42}), isFalse);
  });
}
