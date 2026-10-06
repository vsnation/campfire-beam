/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about BEAM's Minter contract (create your own Confidential
/// Asset and mint it), from `bvm/Shaders/minter/{app.cpp,contract.cpp,
/// contract.h}` at tag `beam-7.5.14493` and the mainnet explorer.
library;

import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';

/// The Minter on mainnet (explorer kind `Minter`).
const kMinterContractId =
    '295fe749dc12c55213d1bd16ced174dc8780c020f59cb17749e900bb0c15d868';

/// `bvm/Shaders/minter/app.wasm` at tag `beam-7.5.14493`, byte-identical to
/// LightWallet's `shaders/minter_app.wasm`.
const kMinterAppShaderName = 'minter_app.wasm';
const kMinterAppShaderSha256 =
    '95b37fc5708fbad7b323d52ef32e02c40d572433251d8ab6d1e88c80ba4b0fe1';
const kMinterAppShaderSize = 7430;

/// The pinned Minter app shader, read from [source].
PinnedShader minterAppShader(ShaderSource source) => PinnedShader(
  name: kMinterAppShaderName,
  sha256: kMinterAppShaderSha256,
  size: kMinterAppShaderSize,
  source: source,
);

/// Contract methods (`minter/contract.h`, `Minter::Method`).
abstract final class MinterMethod {
  static const view = 2;
  static const createToken = 3;
  static const withdraw = 4;
}

/// What `create_token` locks besides the issuance fee: the deposit every
/// Confidential Asset holds while it exists (`g_Beam2Groth * 10` in
/// `On_create_token`). The Minter has no method that destroys an asset, so
/// this deposit does not come back.
final kMinterAssetDeposit = BigInt.from(10 * 100000000);

/// BVM charge `create_token` declares (`On_create_token`): CallFar × 2
/// (20,000) + FundsLock (2,000) + LoadVar_For(40-byte Settings) (7,000) +
/// SaveVar_For(65-byte Token) (26,500) + AssetManage (100,000) + 300
/// cycles (1,500) = 157,000 units (`bvm/bvm2_cost.h`).
const kMinterCreateTokenCharge = 157000;

/// Network fee of `create_token`: 100,000 + 10 × 157,000 = 1,670,000 groth
/// (0.0167 BEAM). The confirmation shows the fee decoded from `raw_data`.
final kMinterCreateTokenFee = BeamContractFee.forEntry(
  argsBytes: 0,
  dataBytes: 0,
  spendAssets: const [0],
  charge: kMinterCreateTokenCharge,
);

/// `withdraw` (mint) declares no charge, so it costs the 0.011 BEAM minimum.
final kMinterMintFee = BeamContractFee.minimum;

/// Kernel comments the shader writes.
abstract final class MinterKernelComment {
  static const createToken = 'Creating asset';
  static const mint = 'Minting asset';
}
