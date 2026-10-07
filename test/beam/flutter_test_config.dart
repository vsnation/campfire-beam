/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// The BEAM suites' golden images are rendered on macOS (scripts/beam/
/// host_test.sh), where they are compared pixel for pixel. Linux and Windows
/// draw text a few percent differently, so on those hosts (the CI runners) a
/// golden check renders the screen but does not compare it against the macOS
/// pixels; every other expectation in the test still runs.
/// `CFB_GOLDENS=strict` compares everywhere; `CFB_GOLDENS=render-only`
/// skips the comparison on macOS too.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final mode = Platform.environment['CFB_GOLDENS'];
  final strict =
      mode == 'strict' || (Platform.isMacOS && mode != 'render-only');
  final current = goldenFileComparator;
  if (!strict && current is LocalFileComparator) {
    goldenFileComparator = _RenderOnly(current.basedir);
  }
  await testMain();
}

class _RenderOnly extends LocalFileComparator {
  _RenderOnly(Uri basedir) : super(basedir.resolve('flutter_test_config.dart'));

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;
}
