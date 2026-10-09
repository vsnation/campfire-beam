/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The official BeamMW bridge between BEAM and Ethereum: its five routes, in
// one registry that quoting, building, tracking and tests all import (a
// value quoted from one table and sent from another is a money bug).
//
// Each route is a pair of "pipes": a contract on BEAM and one on Ethereum.
// Going to Ethereum ("b2e"), the BEAM pipe locks or burns the coins and
// records a message; a relayer pays the user on Ethereum about 61 BEAM
// blocks later. Going to BEAM ("e2b"), the Ethereum pipe takes the coins
// with `sendFunds`; a relayer pushes the message to BEAM a few minutes
// later and the user claims it with the key the BEAM pipe derives for
// their wallet.
//
// Every value here was checked on both chains on 2026-10-09 (each Ethereum
// pipe and token has code and the stated decimals; each BEAM pipe answers
// `local_msg_count` and `view_incoming`; the asset-owner contracts beside
// them do not). The relayer constants are BeamMW's: beam-bridge-ethrelay,
// branches `mainnet` (forward, 120 000 gas) and `reverse_mainnet` (WBEAM,
// 96 000 gas, 3 000 000 BEAM cap).

/// Which BEAM app shader drives a route's pipe.
enum BridgeShader {
  /// `beam-bridge-app/pipe_app.wasm`: the four wrapped assets.
  forward,

  /// `beam-bridge-reverse-app/pipe_app.wasm`: BEAM itself.
  reverse,
}

/// One direction of a crossing.
enum BridgeDirection {
  /// BEAM wallet → the user's Ethereum address ("b2e").
  toEthereum,

  /// Ethereum wallet → the user's BEAM wallet ("e2b").
  toBeam,
}

class BridgeRoute {
  const BridgeRoute({
    required this.id,
    required this.beamSymbol,
    required this.ethSymbol,
    required this.name,
    required this.beamAssetId,
    required this.beamPipeCid,
    required this.shader,
    required this.sendMethod,
    required this.receiveMethod,
    required this.ethPipe,
    required this.ethToken,
    required this.ethDecimals,
    required this.relayGas,
    required this.processedSlot,
    required this.coingeckoId,
    this.maxCoins,
  });

  /// Stable id: `beam`, `eth`, `wbtc`, `usdt`, `dai`.
  final String id;

  /// What the BEAM wallet holds: BEAM, bETH, bWBTC, bUSDT, bDAI.
  final String beamSymbol;

  /// What the Ethereum wallet holds: WBEAM, ETH, WBTC, USDT, DAI.
  final String ethSymbol;

  /// The asset's name for people ("BEAM", "Ether", "Bitcoin", …).
  final String name;

  /// The BEAM asset id (0 for BEAM).
  final int beamAssetId;

  /// The BEAM pipe contract (never the asset-owner contract beside it: its
  /// `get_pk` gives a key nobody can ever claim with).
  final String beamPipeCid;

  final BridgeShader shader;

  /// Contract method numbers the built transaction must call: SendFunds and
  /// ReceiveFunds (3 and 4 on the forward pipes; the reverse pipe sits
  /// behind an upgradable wrapper and shifts them to 4 and 6).
  final int sendMethod;
  final int receiveMethod;

  /// The Ethereum pipe (lowercase 0x address).
  final String ethPipe;

  /// The ERC-20 token, lowercase; null for native ETH.
  final String? ethToken;

  /// The Ethereum side's decimals. The BEAM side is always 8.
  final int ethDecimals;

  /// The gas the relayer charges for paying a b2e crossing on Ethereum.
  final int relayGas;

  /// Storage slot of the Ethereum pipe's `mapping(uint64 => bool)` of
  /// paid BEAM-side messages (1 in the ETH pipe, 2 in the others).
  final int processedSlot;

  /// CoinGecko id the relayer prices the asset with.
  final String coingeckoId;

  /// The most one b2e crossing may carry, amount and fee each, in whole
  /// coins; null when the relayer sets no limit. Above it the WBEAM relayer
  /// rejects the message for good and the BEAM stays locked.
  final int? maxCoins;

  /// [maxCoins] in groth.
  BigInt? get maxGroth => maxCoins == null
      ? null
      : BigInt.from(maxCoins!) * BigInt.from(10).pow(beamDecimals);

  bool get isBeam => beamAssetId == 0;
  bool get isNativeEth => ethToken == null;

  /// BEAM-side decimals, every route.
  static const beamDecimals = 8;

  /// Ethereum units per groth when Ethereum has more decimals (ETH, DAI:
  /// 10^10), else 1. An e2b value must be a multiple of it, or the relayer
  /// truncates the rest away.
  BigInt get ethGrid =>
      BigInt.from(10).pow(ethDecimals > beamDecimals ? ethDecimals - 8 : 0);

  /// Groth per Ethereum unit when Ethereum has fewer decimals (USDT: 100),
  /// else 1. A b2e amount and fee must be multiples of it.
  BigInt get beamGrid =>
      BigInt.from(10).pow(ethDecimals < beamDecimals ? 8 - ethDecimals : 0);

  /// [ethUnits] in groth (truncated, as the relayer does).
  BigInt ethToGroth(BigInt ethUnits) =>
      ethDecimals >= beamDecimals ? ethUnits ~/ ethGrid : ethUnits * beamGrid;

  /// [groth] in Ethereum units (truncated, as the relayer does).
  BigInt grothToEth(BigInt groth) =>
      ethDecimals >= beamDecimals ? groth * ethGrid : groth ~/ beamGrid;

  @override
  String toString() => 'BridgeRoute($id)';

  @override
  bool operator ==(Object other) => other is BridgeRoute && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// keccak256("NewLocalMessage(uint64,uint256,uint256,bytes)"): the event an
/// Ethereum pipe emits on `sendFunds`. Every field is in `data`:
/// (uint64 msgId, uint256 amount, uint256 relayerFee, bytes receiver).
const kBridgeNewLocalMessageTopic =
    '0x5f52670be4e2f3d7b079180b485ab44712641a10d1c77e843355f96036608ac7';

/// `sendFunds(uint256 value, uint256 relayerFee, bytes receiverBeamPubkey)`.
const kBridgeSendFundsSignature = 'sendFunds(uint256,uint256,bytes)';

/// BEAM confirmations the b2e relayer waits for before paying.
const kBridgeBeamConfirmations = 61;

/// BEAM network fee of a b2e `send` (no contract charge): 0.011 BEAM.
final BigInt kBridgeSendFeeGroth = BigInt.from(1100000);

/// BEAM network fee of an e2b claim (`receive` declares a charge of
/// 1 200 000): 0.121 BEAM. A BEAM wallet without it cannot claim a
/// wrapped asset.
final BigInt kBridgeClaimFeeGroth = BigInt.from(12100000);

const kBridgeRoutes = <BridgeRoute>[
  BridgeRoute(
    id: 'beam',
    beamSymbol: 'BEAM',
    ethSymbol: 'WBEAM',
    name: 'BEAM',
    beamAssetId: 0,
    beamPipeCid:
        'e63bd26ca5b226558686dd191122a8e5d6861a97597db9f40bda48aef6dbe835',
    shader: BridgeShader.reverse,
    sendMethod: 4,
    receiveMethod: 6,
    ethPipe: '0x6063024646e8a1561970840a4b0e0f1082f5a670',
    ethToken: '0xe5acbb03d73267c03349c76ead672ee4d941f499',
    ethDecimals: 8,
    relayGas: 96000,
    processedSlot: 2,
    coingeckoId: 'beam',
    maxCoins: 3000000,
  ),
  BridgeRoute(
    id: 'eth',
    beamSymbol: 'bETH',
    ethSymbol: 'ETH',
    name: 'Ether',
    beamAssetId: 36,
    beamPipeCid:
        '8872509d36a8e2aa7a60839a1828c372af47c0a5309f3f6186379cddec847369',
    shader: BridgeShader.forward,
    sendMethod: 3,
    receiveMethod: 4,
    ethPipe: '0xb1d7ff9d3acaf30e282c5f6eb1f2a6503f516a96',
    ethToken: null,
    ethDecimals: 18,
    relayGas: 120000,
    processedSlot: 1,
    coingeckoId: 'ethereum',
  ),
  BridgeRoute(
    id: 'wbtc',
    beamSymbol: 'bWBTC',
    ethSymbol: 'WBTC',
    name: 'Bitcoin',
    beamAssetId: 38,
    beamPipeCid:
        '7c66181ba4625202aae6e46afe89acbf1f839523344b0b371fc7988ac2e8c056',
    shader: BridgeShader.forward,
    sendMethod: 3,
    receiveMethod: 4,
    ethPipe: '0x604422d7ec88c45b82b71851d073efeaa928dcef',
    ethToken: '0x2260fac5e5542a773aa44fbcfedf7c193bc2c599',
    ethDecimals: 8,
    relayGas: 120000,
    processedSlot: 2,
    coingeckoId: 'wrapped-bitcoin',
  ),
  BridgeRoute(
    id: 'usdt',
    beamSymbol: 'bUSDT',
    ethSymbol: 'USDT',
    name: 'Tether',
    beamAssetId: 37,
    beamPipeCid:
        '8af23fe6338e3e67574f4548c9acf3d269756ae9b25ab025fd4268a07b8a3c29',
    shader: BridgeShader.forward,
    sendMethod: 3,
    receiveMethod: 4,
    ethPipe: '0x7c3fe09e86b0d8661d261a49bfa385536b7077f9',
    ethToken: '0xdac17f958d2ee523a2206206994597c13d831ec7',
    ethDecimals: 6,
    relayGas: 120000,
    processedSlot: 2,
    coingeckoId: 'tether',
  ),
  BridgeRoute(
    id: 'dai',
    beamSymbol: 'bDAI',
    ethSymbol: 'DAI',
    name: 'Dai',
    beamAssetId: 39,
    beamPipeCid:
        '02fb908e55a59ab5acc5bf6f1707a8dcdb70a944d6f2a7bff3c7af18c8e278da',
    shader: BridgeShader.forward,
    sendMethod: 3,
    receiveMethod: 4,
    ethPipe: '0xacdc8f4559741a3c8caab0ba74c57807a9fe2d73',
    ethToken: '0x6b175474e89094c44da98b954eedeac495271d0f',
    ethDecimals: 18,
    relayGas: 120000,
    processedSlot: 2,
    coingeckoId: 'dai',
  ),
];

BridgeRoute bridgeRouteById(String id) =>
    kBridgeRoutes.firstWhere((r) => r.id == id);

/// The route whose BEAM asset is [assetId], if any.
BridgeRoute? bridgeRouteForBeamAsset(int assetId) {
  for (final r in kBridgeRoutes) {
    if (r.beamAssetId == assetId) return r;
  }
  return null;
}

/// The route whose Ethereum asset is [token] (null for ETH), if any.
BridgeRoute? bridgeRouteForEthToken(String? token) {
  final t = token?.toLowerCase();
  for (final r in kBridgeRoutes) {
    if (r.ethToken == t) return r;
  }
  return null;
}
