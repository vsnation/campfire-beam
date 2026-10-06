/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Fixed facts about BEAM's BlackHole contract, which burns tokens by
/// locking them where nothing can ever unlock them
/// (`bvm/Shaders/blackhole/{app.cpp,contract.cpp}` at `beam-7.5.14493`).
library;

import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';

/// The BlackHole on mainnet (explorer kind `BlackHole`).
///
/// Its contract has exactly one method, `Method_2(Deposit)`, which does
/// `FundsLock(aid, amount)` and nothing else; there is no method that
/// unlocks, and its `Dtor` is empty. Funds sent here are gone for good.
const kBlackHoleContractId =
    '5ab408982b148210e88f180114f10222a2235eafeede0a3a224fda0e523e17b7';

/// `bvm/Shaders/blackhole/app.wasm` at tag `beam-7.5.14493`, byte-identical
/// to LightWallet's `shaders/blackhole_app.wasm`.
const kBlackHoleAppShaderName = 'blackhole_app.wasm';
const kBlackHoleAppShaderSha256 =
    '98ee89c899026b1481be4202da1a26636925ffdcef8068ce18ba58eedc927e31';
const kBlackHoleAppShaderSize = 3271;

/// The pinned BlackHole app shader, read from [source].
PinnedShader blackHoleAppShader(ShaderSource source) => PinnedShader(
  name: kBlackHoleAppShaderName,
  sha256: kBlackHoleAppShaderSha256,
  size: kBlackHoleAppShaderSize,
  source: source,
);

/// `BlackHole::Method::Deposit`.
const kBlackHoleDepositMethod = 2;

/// The kernel comment `deposit` writes.
const kBlackHoleDepositComment = 'Send to Black hole contract';

/// A burn declares no BVM charge: the 0.011 BEAM minimum.
final kBurnFee = BeamContractFee.minimum;
