/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../wallet/impl/sub_wallets/beam_asset_wallet.dart';

/// The BEAM asset wallet being viewed (asset page, send, confirm), like
/// `tokenServiceStateProvider` for Ethereum tokens and
/// `solanaTokenServiceStateProvider` for Solana tokens.
final beamAssetWalletStateProvider = StateProvider<BeamAssetWallet?>(
  (ref) => null,
);

final pCurrentBeamAssetWallet = Provider<BeamAssetWallet?>(
  (ref) => ref.watch(beamAssetWalletStateProvider),
);
