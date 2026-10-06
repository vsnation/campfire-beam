/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// The voucher Airdrop: claim tokens with a code, create batches of codes,
/// cancel them, and the owner's fees. Pure logic, no UI.
///
/// Start at `BeamAirdropService`; the app supplies a `VoucherCodeStore` on
/// secure storage.
library;

export 'airdrop_args.dart';
export 'airdrop_constants.dart';
export 'airdrop_models.dart';
export 'beam_airdrop_service.dart';
export 'voucher_blob.dart';
export 'voucher_code.dart';
export 'voucher_code_store.dart';
