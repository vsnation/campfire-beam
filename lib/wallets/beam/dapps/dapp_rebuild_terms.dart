/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../contracts/common/invoke_data.dart';
import '../contracts/common/pinned_shader.dart';
import '../contracts/dex/dex_constants.dart';

/// Whose app code the core re-runs when it rebuilds a contract transaction.
enum DappAppCode {
  /// BEAM's own AMM app, byte for byte one Campfire pins
  /// ([dappVerifiedDexAppBodies]), stored with arguments that ask for the
  /// same DEX action the transaction makes. A rebuild calls the same pool
  /// action again at the new price: same contract, same method, no other
  /// key, the same fee.
  beamDex,

  /// Anything else. The core still bounds the funds (see
  /// [DappRebuildTerms]), but nothing bounds what else the rebuilt
  /// transaction calls, signs or pays as a fee.
  unverified,
}

/// The AMM app bodies whose rebuilds Campfire vouches for, by SHA-256 of
/// the stored body.
///
/// The core stores the app shader in its compiled form
/// (`ShadersManager::compileAppShader`, `bvm2::Processor::Compile`), not as
/// the `.wasm` bytes a caller sends, so these are hashes of what
/// wallet-api 7.5.14493 compiles from each pinned file, read from trades it
/// built on mainnet (`test/beam/contracts/dex/fixtures/
/// trade_built_raw_data.json`, `test/beam/dapps/fixtures/
/// dex_dapp_swap_raw_data.json`):
///
/// * `amm_app.wasm` (SHA-256 [kAmmAppShaderSha256], 38,914 bytes):
///   `bvm/Shaders/amm/app.wasm` at tag `beam-7.5.14493`, the shader
///   Campfire's own Swap screen pins. Compiles to 31,396 bytes.
/// * `amm.wasm` in Beam DEX 1.0.0 (`dex-app.dapp`, pinned whole by the
///   catalogue; file SHA-256 `8b4a0616…12c3fa`, 39,852 bytes): an earlier
///   build of the same app that BEAM ships in its DEX dApp. Compiles to
///   32,903 bytes, and builds byte-identical funds to the pinned shader's
///   for the same trade.
///
/// A core whose compiler emits different bytes makes these unknown: the
/// sheet then treats the code as unverified and warns, never the reverse.
const Map<String, String> dappVerifiedDexAppBodies = {
  'bdff009943b48d32af3253b7e61facd09777c8064e83934b23caa0443533dc8b':
      'amm_app.wasm (beam-7.5.14493)',
  '578cec5ed84e3397c8756043248e00e014d37d9ca71e00dade46de55293b4ef8':
      'amm.wasm (Beam DEX 1.0.0)',
};

/// The `action` the AMM app takes for each DEX contract method
/// (`amm/app.cpp`, `Amm::Method`).
const Map<int, String> _dexActions = {
  DexMethod.poolCreate: 'pool_create',
  DexMethod.poolDestroy: 'pool_destroy',
  DexMethod.addLiquidity: 'pool_add_liquidity',
  DexMethod.withdraw: 'pool_withdraw',
  DexMethod.trade: 'pool_trade',
};

/// What the wallet core may sign after the user approves contract data it
/// can rebuild, by the core's own rule.
///
/// A dependent (HFT) call is valid in exactly one block. When it misses
/// that block (someone else traded first, the block filled up), the core
/// re-runs the stored app body with the stored arguments at the new state
/// and signs what it emits, without asking again (`RetryHft`,
/// `State::RebuildHft`, `contract_transaction.cpp:610-690, 1265-1289`). It
/// keeps doing so for up to [windowBlocks] blocks after the first attempt.
///
/// Each rebuilt variant must pass `IsSpendWithinLimits`
/// (`contract_transaction.cpp:485-522`), measured against the net funds of
/// the data the user approved, per asset:
///
/// * without a stored ceiling: an asset may be paid only if the approved
///   data pays it, at most 1% more (`v1 - v0 <= v0 / 100`, rounded down);
///   an asset the approved data receives must arrive at no less than
///   what the same 1% allows; anything else may only arrive;
/// * with a stored ceiling (`SaveSpendMax`): an asset may be paid only up
///   to its ceiling; an asset with a negative ceiling must arrive at least
///   at that amount; others are not bounded below.
///
/// [maxPays] and [minReceives] are those bounds. The network fee is not
/// part of the rule: for [DappAppCode.beamDex] it cannot change (one AMM
/// call, no BVM charge, always 0.011 BEAM), for unverified code it can.
@immutable
class DappRebuildTerms {
  const DappRebuildTerms._({
    required this.appCode,
    required this.appCodeSha256,
    required this.explicitCeiling,
    required this.maxPays,
    required this.minReceives,
  });

  /// How many blocks after the first attempt the core may still rebuild
  /// (`RetryHft`: `sTip.get_Height() >= h + 5` stops it). About five
  /// minutes.
  static const windowBlocks = 5;

  final DappAppCode appCode;

  /// SHA-256 of the stored (compiled) app body, lowercase hex.
  final String appCodeSha256;

  /// The data stores its own spend ceiling (`SaveSpendMax`).
  final bool explicitCeiling;

  /// The most a rebuilt variant may take from the wallet, per asset,
  /// excluding the network fee. Assets not listed cannot be paid at all.
  final Map<int, BigInt> maxPays;

  /// The least a rebuilt variant must give the wallet, per asset; zero
  /// means the asset may not arrive at all. Assets not listed are not
  /// bounded below (and were not received in the approved data).
  final Map<int, BigInt> minReceives;

  bool get isVerifiedDex => appCode == DappAppCode.beamDex;

  /// The terms for [data], or null when the core cannot rebuild it: no
  /// entry is dependent, or no app body is stored (`CanRebuildHft`:
  /// `m_HftSubscribed && !m_AppInvoke.m_App.empty()`). Only the first
  /// entry's flags store an app body or a ceiling
  /// (`bvm/invoke_data.h:200-204`), as [BeamInvokeData.decode] reads them.
  static DappRebuildTerms? of(BeamInvokeData data) {
    final app = data.appShader;
    final dependent = data.entries.any((e) => e.isDependent);
    if (!dependent || app == null || app.isEmpty) return null;
    final sha = PinnedShader.digestOf(app);
    final approved = data.spend;
    final pays = <int, BigInt>{};
    final receives = <int, BigInt>{};
    final ceiling = data.spendMax;
    if (ceiling != null) {
      for (final e in ceiling.entries) {
        if (e.value > BigInt.zero) pays[e.key] = e.value;
        if (e.value < BigInt.zero) receives[e.key] = -e.value;
      }
      for (final e in approved.entries) {
        if (e.value < BigInt.zero) {
          receives.putIfAbsent(e.key, () => BigInt.zero);
        }
      }
    } else {
      for (final e in approved.entries) {
        if (e.value > BigInt.zero) {
          pays[e.key] = e.value + e.value ~/ _hundred;
        } else {
          receives[e.key] = minReceive(-e.value);
        }
      }
    }
    return DappRebuildTerms._(
      appCode: _isVerifiedDex(data, sha)
          ? DappAppCode.beamDex
          : DappAppCode.unverified,
      appCodeSha256: sha,
      explicitCeiling: ceiling != null,
      maxPays: Map.unmodifiable(pays),
      minReceives: Map.unmodifiable(receives),
    );
  }

  static final _hundred = BigInt.from(100);

  /// The least a rebuilt variant may receive of an asset the approved data
  /// receives [approved] of, without a stored ceiling: the smallest `v`
  /// with `approved - v <= v / 100` (integer division), as
  /// `IsSpendWithinLimitsUns(v, approved)` accepts it.
  @visibleForTesting
  static BigInt minReceive(BigInt approved) {
    if (approved <= BigInt.zero) return BigInt.zero;
    bool ok(BigInt v) => v + v ~/ _hundred >= approved;
    var v = approved * _hundred ~/ BigInt.from(101);
    while (v > BigInt.zero && ok(v - BigInt.one)) {
      v -= BigInt.one;
    }
    while (!ok(v)) {
      v += BigInt.one;
    }
    return v;
  }

  /// A pinned AMM app, at privilege 0, with no contract body and no stored
  /// ceiling (the AMM app never sets one), rebuilding a single DEX call
  /// from arguments that name that same call on the same pool's assets.
  static bool _isVerifiedDex(BeamInvokeData data, String sha) {
    if (!dappVerifiedDexAppBodies.containsKey(sha)) return false;
    if ((data.appPrivilege ?? 0) != 0) return false;
    if ((data.contractShader?.length ?? 0) != 0) return false;
    if (data.spendMax != null) return false;
    if (data.entries.length != 1) return false;
    final e = data.entries.single;
    if (e.contractId != kDexContractId) return false;
    final args = data.appArgs;
    if (args == null) return false;
    final action = _dexActions[e.method];
    if (action == null ||
        args['action'] != action ||
        args['cid'] != kDexContractId ||
        (args['bPredictOnly'] ?? '0') != '0') {
      return false;
    }
    if (e.method == DexMethod.poolCreate || e.method == DexMethod.poolDestroy) {
      return true;
    }
    // Trade, add and withdraw move the pool's two assets (and, for add and
    // withdraw, its LP token): the stored pool must be the one the
    // approved call moves, or a rebuild would trade another pool.
    final aid1 = int.tryParse(args['aid1'] ?? '');
    final aid2 = int.tryParse(args['aid2'] ?? '');
    if (aid1 == null || aid2 == null || aid1 == aid2) return false;
    final moved = data.spend.keys.toSet();
    final others = moved.difference({aid1, aid2});
    return e.method == DexMethod.trade
        ? moved.containsAll({aid1, aid2}) && others.isEmpty
        : others.length <= 1;
  }

  @override
  bool operator ==(Object other) =>
      other is DappRebuildTerms &&
      other.appCode == appCode &&
      other.appCodeSha256 == appCodeSha256 &&
      other.explicitCeiling == explicitCeiling &&
      _sameMap(other.maxPays, maxPays) &&
      _sameMap(other.minReceives, minReceives);

  @override
  int get hashCode => Object.hash(
    appCode,
    appCodeSha256,
    explicitCeiling,
    Object.hashAllUnordered(maxPays.entries.map((e) => '${e.key}:${e.value}')),
    Object.hashAllUnordered(
      minReceives.entries.map((e) => '${e.key}:${e.value}'),
    ),
  );

  static bool _sameMap(Map<int, BigInt> a, Map<int, BigInt> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'DappRebuildTerms(${appCode.name}, pays ≤ $maxPays, '
      'receives ≥ $minReceives)';
}
