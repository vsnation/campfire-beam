/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about the mainnet BANS (Beam Anonymous Name Service)
/// contract, with the source line each one comes from. See
/// `the project notes`.
///
/// No BEAM price lives here. Names are priced in USD and paid in BEAM at the
/// Oracle2 median, so every BEAM amount is read from the chain at quote time.
library;

import '../common/pinned_shader.dart';

/// Mainnet BANS contract (`kind: "Bans v0"`, deployed at 1,890,525).
const String kBansCid =
    'af4550f1f8a6051ffeffea06e0cb978f8076fdfc2101d2273d4e62c86540bc5e';

/// The app shader Campfire ships: `bvm/Shaders/bans/app.wasm` at tag
/// `beam-7.5.14493`, byte-identical to `src/wasm/bansAppShader.wasm` in
/// github.com/BeamMW/bans @ 25f31a9.
const String kBansShaderSha256 =
    '99eb1dfb023d30c338e3c4a4c536b7695b48ca25e27f9ce5f659b6567241736d';

/// Size of the pinned app shader in bytes.
const int kBansShaderSize = 34666;

/// The app shader's file name under `assets/beam/shaders/`.
const String kBansShaderName = 'bans_app.wasm';

/// Where the pinned app shader is bundled.
const String kBansShaderAsset = 'assets/beam/shaders/$kBansShaderName';

/// The pinned BANS app shader, read from [source].
PinnedShader bansAppShader(ShaderSource source) => PinnedShader(
  name: kBansShaderName,
  sha256: kBansShaderSha256,
  size: kBansShaderSize,
  source: source,
);

/// `Domain::s_MinLen` / `s_MaxLen` (`contract.h:38-39`).
const int kBansNameMinLength = 3;
const int kBansNameMaxLength = 64;

/// One registration period: `s_PeriodValidity = 1440 * 365` blocks
/// (`contract.h:90`), about 365 days at the 60 s target block time.
const int kBansBlocksPerPeriod = 1440 * 365;

/// Names can be paid for at most this many periods past the current height
/// (`s_PeriodValidityMax`, `contract.h:91`).
const int kBansMaxPeriods = 50;

/// After expiry the owner keeps the name for `s_PeriodHold = 1440 * 90`
/// blocks (`contract.h:92`): they can renew, transfer or list it, payments
/// still reach them, and nobody else can register it.
const int kBansHoldBlocks = 1440 * 90;

/// BEAM's target block interval (`core/block_crypt.cpp:2215`). Dates derived
/// from heights are estimates on this basis.
const Duration kBeamTargetBlockTime = Duration(seconds: 60);

/// The price per period in whole US dollars, by name length
/// (`Domain::get_PriceTok`, `contract.h:73-83`: 320 / 120 / 10, scaled by
/// `g_Beam2Groth`, then divided by the oracle's USD-per-BEAM median).
int bansUsdPerPeriod(int nameLength) {
  if (nameLength <= 3) return 320;
  if (nameLength <= 4) return 120;
  return 10;
}

/// Kernel comments the BANS app shader writes (`app.cpp`, `vault_anon/
/// app_impl.h`). Transaction history maps them to labels.
abstract final class BansKernelComment {
  static const register = 'BANS: registering domain';
  static const extend = 'BANS: extending the domain registration period';
  static const setOwner = 'BANS: setting the domain owner';
  static const setPrice = 'BANS: setting the domain price';
  static const buy = 'BANS: buying the domain';
  static const pay = 'vault_anon send anon';
  static const receiveAnon = 'vault_anon receive';
  static const receiveRaw = 'vault_anon receive raw';
}

/// Contract method numbers (`contract.h:97-149`, `vault_anon/contract.h`).
abstract final class BansMethod {
  static const setOwner = 3;
  static const extend = 4;
  static const setPrice = 5;
  static const buy = 6;
  static const register = 7;

  /// `VaultAnon::Method::Deposit`, which `pay` calls on the Anon-Vault.
  static const vaultDeposit = 2;

  /// `VaultAnon::Method::Withdraw`, which claims call on the Anon-Vault.
  static const vaultWithdraw = 3;
}
