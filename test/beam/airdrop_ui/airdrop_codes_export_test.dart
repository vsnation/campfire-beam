/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Exported airdrop codes are bearer secrets: the file holding them is
// readable by this user only (L-10).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/widgets/beam/airdrop/airdrop_codes_export.dart';

// Dart has no octal literals: 0x1ff = 0777, 0x180 = 0600, 0x1a4 = 0644.
int _mode(String path) => File(path).statSync().mode & 0x1ff;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('airdrop_codes_export_');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  const csv = 'code,value\nABCD-EFGH-JKLM-NPQR,1.5 BEAM\n';

  test('a new file is 0600 and holds exactly the codes', () async {
    final path = '${dir.path}/airdrop-codes.csv';
    await writePrivateCsv(path, csv);
    expect(File(path).readAsStringSync(), csv);
    if (!Platform.isWindows) expect(_mode(path), 0x180);
  }, skip: Platform.isWindows);

  test('an existing world-readable file the user picked is locked down '
      'before the codes go in', () async {
    final path = '${dir.path}/picked.csv';
    File(path).writeAsStringSync('old contents');
    await Process.run('chmod', ['644', path]);
    expect(_mode(path), 0x1a4);
    await writePrivateCsv(path, csv);
    expect(_mode(path), 0x180);
    expect(File(path).readAsStringSync(), csv);
  }, skip: Platform.isWindows);
}
