/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A wallet the desktop home should open in My Campfire (the restore
/// dialog's "Open my wallet": that dialog cannot reach My Campfire's own
/// navigator). The home clears it once handled.
final desktopOpenWalletRequestProvider = StateProvider<String?>((ref) => null);
