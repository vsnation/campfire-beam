/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about the voucher Airdrop contract on mainnet, with where
/// each one comes from. Sources: LightWallet `contracts/airdrop/{app.cpp,
/// contract.h, contract.cpp}` (gitignored there; read from disk) and the
/// mainnet explorer.
library;

import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';

/// The live Airdrop contract (deployed at height 3,729,281).
///
/// **The shader and the CID are a matched pair.** Checked 2026-10-06 against
/// the explorer's call history of this CID (67 calls, heights 3,729,281 to
/// 3,986,872): every `CreateBatch` argument is 41 + 40·n bytes with n equal
/// to its count field, every `RedeemVoucher` is 37 + its preimage-length
/// field, every `CancelBatch` is 45 + 32·n with n equal to its count field.
/// That is the argument layout [kAirdropAppShaderSha256] emits. The same
/// check fails on every call of the dead v3 contract.
const kAirdropContractId =
    '8737e0d39575d7015fdea259fa091e41fc293e6c3d54e80d529033c349b5b18e';

/// Contracts this module must never call. `00c0dc81…` is the v3 build with
/// a different ABI (`RedeemVoucher` took a 32-byte hash, other headers
/// differ). The pinned shader would build structurally wrong calls for it,
/// and its views silently read nothing. LightWallet's standalone .dapp
/// pointed there until 2026-08-04 and every operation failed quietly.
const kAirdropDeadContractIds = {
  '00c0dc81e42908805d8beeb05f08eab0445e1793813fa10f37bafed6795d5ef9',
};

/// LightWallet's `shaders/airdrop_app.wasm`, byte-identical to its
/// `contracts/airdrop/app.wasm` and its `airdrop-shader.js`. It exports the
/// roles below and nothing else: no gas-pool actions.
const kAirdropAppShaderName = 'airdrop_app.wasm';
const kAirdropAppShaderSha256 =
    'cddf4a6301f01f2045312f90e977951feaba04d1174744d768dde1c214e55c20';
const kAirdropAppShaderSize = 12821;

/// The pinned Airdrop app shader, read from [source].
PinnedShader airdropAppShader(ShaderSource source) => PinnedShader(
  name: kAirdropAppShaderName,
  sha256: kAirdropAppShaderSha256,
  size: kAirdropAppShaderSize,
  source: source,
);

/// Gasless claims (a sponsored-gas pool, contract methods 7-9) are built in
/// LightWallet's v2 shaders but **not deployed**: the live contract has no
/// `Method_7` and the pinned app shader has no `sponsor_gas` / `view_gas`.
/// Deploying v2 mints a new CID and strands the old one's vouchers.
const kAirdropGasSupported = false;

/// Contract methods (`contract.h`, `Airdrop::Method`). A decoded `raw_data`
/// entry for the Airdrop must name one of these.
abstract final class AirdropMethod {
  static const createBatch = 2;
  static const redeem = 3;
  static const cancelBatch = 4;
  static const setPaused = 5;
  static const withdrawFees = 6;
}

/// BVM charge units the app shader declares in `GenerateKernel`
/// (`app.cpp`). The network fee is 100,000 + 10 groth per unit
/// ([BeamContractFee]), so these calls are **not** the 0.011 BEAM of a
/// plain contract call.
abstract final class AirdropCharge {
  static const createBatch = 1200000;
  static const redeem = 1200000;
  static const cancelBatch = 1800000;
  static const withdrawFees = 1200000;
}

/// 0.121 BEAM (12,100,000 groth): the network fee of `create_batch`,
/// `redeem` and `withdraw_fees`. Measured on mainnet: the kernels of the
/// `CreateBatch` at height 3,980,470 and the `RedeemVoucher` at 3,980,484
/// each paid 12,100,000 groth.
final kAirdropCallFee = BeamContractFee.forEntry(
  argsBytes: 0,
  dataBytes: 0,
  spendAssets: const [0],
  charge: AirdropCharge.createBatch,
);

/// 0.181 BEAM (18,100,000 groth): the network fee of `cancel_batch`.
/// The `CancelBatch` at height 3,986,872 paid 18,100,000 groth.
final kAirdropCancelFee = BeamContractFee.forEntry(
  argsBytes: 0,
  dataBytes: 0,
  spendAssets: const [0],
  charge: AirdropCharge.cancelBatch,
);

/// Kernel comments the app shader writes. History screens map them to
/// labels; the prepare checks compare against them.
abstract final class AirdropKernelComment {
  static const createBatch = 'Create airdrop batch';
  static const redeem = 'Redeem airdrop voucher';
  static const cancelBatch = 'Cancel airdrop batch';
  static const withdrawFees = 'Withdraw airdrop fees';
}

/// `create_batch` takes 1 to 100 vouchers (`app.cpp` and `Method_2`).
const kAirdropMaxVouchersPerBatch = 100;

/// The creation fee: `FEE_BPS / BPS_TOTAL` = 100 / 10,000 = 1%
/// (`contract.h`).
const kAirdropFeeBps = 100;
const kAirdropBpsTotal = 10000;

/// `RedeemVoucher` refuses a preimage longer than this (`Method_3`), and
/// the app shader stops normalising at the same length.
const kAirdropMaxCodeLength = 64;
