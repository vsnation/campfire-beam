/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../common/invoke_data.dart';
import '../common/pinned_shader.dart';
import 'beam_ratio.dart';

/// The BEAM AMM (DEX) contract on mainnet.
const kDexContractId =
    '729fe098d9fd2b57705db1a05a74103dd4b891f535aef2ae69b47bcfdeef9cbf';

/// `bvm/Shaders/amm/app.wasm` at tag `beam-7.5.14493`, byte-identical to the
/// `amm_app.wasm` LightWallet ships. Bundled as `assets/beam/shaders/`.
const kAmmAppShaderName = 'amm_app.wasm';
const kAmmAppShaderSha256 =
    '42d0f6f20237dd4a2e9fbcd912e82110a0602d3e147140fb179c3dc6bdab01ba';
const kAmmAppShaderSize = 38914;

/// The pinned AMM app shader, read from [source].
PinnedShader ammAppShader(ShaderSource source) => PinnedShader(
  name: kAmmAppShaderName,
  sha256: kAmmAppShaderSha256,
  size: kAmmAppShaderSize,
  source: source,
);

/// Contract methods (`bvm/Shaders/amm/contract.h`, `Amm::Method`). A decoded
/// `raw_data` entry for the DEX must name one of these.
abstract final class DexMethod {
  static const poolCreate = 3;
  static const poolDestroy = 4;
  static const addLiquidity = 5;
  static const withdraw = 6;
  static const trade = 7;
}

/// Network fee of a trade, an add or a withdraw: 1,100,000 groth =
/// 0.011 BEAM. These calls declare no BVM charge, so the core's minimum
/// applies (`BeamContractFee`); measured on mainnet for trades.
final kDexCallFee = BeamContractFee.minimum;

/// BVM charge `pool_create` declares (`amm/app.cpp` `On_pool_create`):
/// CallFar 10,000 + AssetManage 100,000 + SaveVar_For(61-byte Pool) 26,100
/// + 200 cycles × 5 = 137,100 units (`bvm/bvm2_cost.h`).
const kDexPoolCreateCharge = 137100;

/// Network fee of `pool_create`, derived from [kDexPoolCreateCharge]:
/// 100,000 + 10 × 137,100 = 1,471,000 groth (0.01471 BEAM). Derived from
/// source, not yet measured on mainnet; the confirmation screen shows the
/// fee decoded from the prepared `raw_data` instead.
final kDexPoolCreateFee = BeamContractFee.forEntry(
  argsBytes: 42, // sizeof(Amm::Method::PoolCreate): Pool::ID 9 + PubKey 33
  dataBytes: 0,
  spendAssets: const [0],
  charge: kDexPoolCreateCharge,
);

/// `pool_create` locks 10 BEAM in the contract (`FundsChange{aid 0,
/// consume, 10 BEAM}`). `pool_destroy` returns it to the creator once the
/// pool is empty.
final kDexPoolCreateDeposit = BigInt.from(10 * 100000000);

/// The AMM's fee tiers (`Amm::FeeSettings`, `amm/contract.h`).
///
/// Measured on mainnet with `bPredictOnly=1` (2026-10-06, height 4068104):
/// kind 0 charged 49,976 on a raw 99,950,015 (0.05%), kind 1 charged
/// 299,101 on 99,700,899 (0.3%), kind 2 charged 99,010 on 9,900,990 (1%).
/// LightWallet's `poolFeeLabel` has kinds 0 and 1 the other way round.
enum BeamPoolKind {
  /// 0.05%. The shader calls this "low volatility".
  low(0, 1, 2000),

  /// 0.3%. "Mid volatility".
  mid(1, 3, 1000),

  /// 1%. "High volatility"; most BEAM pools use it.
  high(2, 1, 100);

  const BeamPoolKind(this.wire, this._feeNum, this._feeDen);

  /// The `kind` the shader takes and prints.
  final int wire;
  final int _feeNum;
  final int _feeDen;

  static BeamPoolKind fromWire(int kind) => switch (kind) {
    0 => low,
    1 => mid,
    2 => high,
    _ => throw FormatException('unknown pool kind $kind'),
  };

  /// The nominal trading fee as a fraction of the raw price.
  BeamRatio get feeRate =>
      BeamRatio(BigInt.from(_feeNum), BigInt.from(_feeDen));

  /// `0.05%`, `0.3%` or `1%`.
  String get feePercent => switch (this) {
    low => '0.05%',
    mid => '0.3%',
    high => '1%',
  };

  /// The exact fee the contract adds to a raw price of [rawPay], all in the
  /// paid asset (`FeeSettings::Get`): the nominal rate rounded down, plus
  /// one groth; 30% of it goes to the DAO vault and the rest to the pool.
  ({BigInt pool, BigInt dao}) tradeFee(BigInt rawPay) {
    final BigInt total;
    switch (this) {
      case low:
        total = rawPay ~/ BigInt.from(2000) + BigInt.one;
      case mid:
        // The contract divides before multiplying, to avoid overflow.
        total = rawPay ~/ BigInt.from(1000) * BigInt.from(3) + BigInt.one;
      case high:
        total = rawPay ~/ BigInt.from(100) + BigInt.one;
    }
    final dao = total * BigInt.from(3) ~/ BigInt.from(10);
    return (pool: total - dao, dao: dao);
  }
}
