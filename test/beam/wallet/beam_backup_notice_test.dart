/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_backup_notice.dart';

void main() {
  test('nothing is said when every wallet is in the backup', () {
    expect(beamBackupOmissionNotice(const []), isNull);
    expect(beamWalletsNotInBackup(const []), isEmpty);
  });

  test('one wallet left out is named, with what keeps it safe', () {
    final notice = beamBackupOmissionNotice(const ['alice'])!;
    expect(notice, startsWith('Not in this backup: "alice".'));
    expect(notice, contains('wallet.db file and password'));
  });

  test('several wallets left out are all named', () {
    final notice = beamBackupOmissionNotice(const ['alice', 'bob'])!;
    expect(notice, startsWith('Not in this backup: "alice", "bob".'));
    expect(notice, contains('These BEAM wallets'));
  });
}
