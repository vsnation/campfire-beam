/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

//ON
import 'dart:io';

import '../../wallets/beam/host/bundled_binaries.dart';
import '../../wallets/beam/host/in_process_host.dart';
import '../../wallets/beam/host/process_host.dart';
//END_ON
import '../../wallets/beam/host/beam_host.dart';
import '../interfaces/libbeam_interface.dart';

LibBeamInterface get libBeam => _getLib();

//OFF
LibBeamInterface _getLib() => const _LibBeamInterfaceOff();

final class _LibBeamInterfaceOff extends LibBeamInterface {
  const _LibBeamInterfaceOff();

  @override
  bool get isAvailable => false;

  @override
  BeamHost createHost({required String rootDir}) =>
      throw Exception("BEAM not enabled!");
}

//END_OFF
//ON
LibBeamInterface _getLib() => const _LibBeamInterfaceImpl();

final class _LibBeamInterfaceImpl extends LibBeamInterface {
  const _LibBeamInterfaceImpl();

  @override
  bool get isAvailable => true;

  /// iOS may not start child processes: the core runs in-process there
  /// (the project notes). Everywhere else wallet-api is a child process.
  @override
  BeamHost createHost({required String rootDir}) => Platform.isIOS
      ? InProcessHost(rootDir: rootDir)
      : ProcessHost(
          rootDir: rootDir,
          ensureBinaries: () => installBundledBeamBinaries(beamRoot: rootDir),
        );
}

//END_ON
