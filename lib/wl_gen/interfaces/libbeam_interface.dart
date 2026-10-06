/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../wallets/beam/host/beam_host.dart';

export '../generated/libbeam_interface_impl.dart';

/// White-label access to the BEAM wallet core, behind the `BEAM` build flag.
///
/// The surface is deliberately thin: everything above the host (typed
/// wallet-api calls, sync, assets) is plain Dart in `lib/wallets/beam/` and
/// compiles in every app. The flag only decides whether this build ships the
/// core. Use the generated `libBeam` getter.
abstract class LibBeamInterface {
  const LibBeamInterface();

  /// True when this build ships the BEAM core (the `BEAM` flag is on).
  bool get isAvailable;

  /// Creates the host that runs the BEAM core for wallets stored under
  /// [rootDir]. Throws when [isAvailable] is false.
  BeamHost createHost({required String rootDir});
}
