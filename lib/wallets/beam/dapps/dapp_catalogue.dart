/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import 'dapp_server.dart';

/// A dApp package the Qt wallet ships for mainnet, pinned by SHA-256.
///
/// The packages are not in this repository: they bundle third-party fonts
/// (SF Pro, Proxima Nova) whose licences do not clearly allow
/// redistribution. `test/beam/dapps/tool/fetch_bundled_dapps.sh` downloads
/// them from [url] and refuses any whose hash differs.
@immutable
class DappCatalogueEntry {
  const DappCatalogueEntry({
    required this.fileName,
    required this.name,
    required this.guid,
    required this.version,
    required this.apiVersion,
    required this.minApiVersion,
    required this.sha256,
    required this.size,
    this.needsEval = true,
    this.remoteOrigins = const [],
    this.connectsInWebShape = true,
  });

  final String fileName;
  final String name;
  final String guid;
  final String version;
  final String apiVersion;
  final String minApiVersion;
  final String sha256;
  final int size;

  /// Whether the bundle needs `'unsafe-eval'` (see [DappCsp]).
  final bool needsEval;

  /// https origins the bundle's code fetches from at runtime, found by
  /// reading it: price (`api.coingecko.com`) and bridge rate/gas
  /// (`explorer-api.beam.mw`) endpoints. Granting them is the UI's
  /// decision; they reveal the user's IP address to those hosts.
  final List<String> remoteOrigins;

  /// Whether the dApp connects through the web-extension shape when it is
  /// the top-level page. All 9 connect through the Qt and mobile shapes
  /// (see `DappBridgeShape`).
  final bool connectsInWebShape;

  /// beam-ui tag `beam-7.5.14493.5867` (the release matching core
  /// 7.5.14493); the files are unchanged on master `1cc4d1a`.
  static const sourceCommit = '2f36c21ed010dee350c052ffce9097b23f69ecfb';

  String get url =>
      'https://raw.githubusercontent.com/BeamMW/beam-ui/$sourceCommit/'
      'ui/apps/mainnet/$fileName';

  DappCsp get csp =>
      DappCsp(allowEval: needsEval, remoteOrigins: remoteOrigins);
}

const _coingecko = 'https://api.coingecko.com';
const _beamExplorerApi = 'https://explorer-api.beam.mw';

/// The 9 mainnet packages beam-ui bundles (`ui/apps/mainnet/*.dapp`).
const List<DappCatalogueEntry> dappBundledCatalogue = [
  DappCatalogueEntry(
    fileName: 'accum-dapp.dapp',
    name: 'Liquidity Accumulator',
    guid: '7e9c916bc3444aadbd10232713be4525',
    version: '1.2.7',
    apiVersion: '7.0',
    minApiVersion: '6.0',
    sha256: '65a5a4cd633b247803078a9a8a0ff7c59ecba4afe4559b9136002f3461742f94',
    size: 4200960,
    connectsInWebShape: false,
  ),
  // An inline SVG in its loader carries an SVGator animation <script>,
  // which the CSP blocks (one console error; the animation does not play).
  DappCatalogueEntry(
    fileName: 'bans.dapp',
    name: 'Beam Anonymous Name Service',
    guid: 'a0b387971c9c4b0eaefa34f4deb888e4',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: 'eef3b49944aa1ba1271d3f85805d3241b05e7eb2dd1cea35bbf9396d4e5d4651',
    size: 5038009,
  ),
  DappCatalogueEntry(
    fileName: 'beam-asset-minter.dapp',
    name: 'Beam Asset Minter',
    guid: '6e5151edf286458da42d11f3aef4969d',
    version: '1.0.29',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: '7d11c4ad243ec7a82ab092aba0124556b2ba768a5d66c218f343befeac891dbe',
    size: 2498315,
    remoteOrigins: [_coingecko, _beamExplorerApi],
  ),
  DappCatalogueEntry(
    fileName: 'beam-bridge-app.dapp',
    name: 'Bridges app',
    guid: '9811fa65e16b44b585ee22e227b0e2ee',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: 'e5ec2e38effb8f446a7ab70192f365aee01192b65b82011baf039d56c805fb73',
    size: 2266568,
    remoteOrigins: [_coingecko, _beamExplorerApi],
  ),
  DappCatalogueEntry(
    fileName: 'beam-bridge-reverse-app.dapp',
    name: 'Beam to Ethereum bridge',
    guid: '43d08c209df04c169005446d7eff51ab',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: '80bd1220ab35363ae683faaf766026387dead285817de3ac8fdc7906914f8092',
    size: 2265469,
    remoteOrigins: [_coingecko, _beamExplorerApi],
  ),
  DappCatalogueEntry(
    fileName: 'dao-core-app.dapp',
    name: 'BeamX DAO',
    guid: 'abcc470e12c6422291f360f83d79355e',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: '137ea5f23b973a6d083d47ea5506bdf46288e921c91d2511564ec0f8cd120625',
    size: 198455,
    needsEval: false,
    remoteOrigins: [_coingecko],
  ),
  DappCatalogueEntry(
    fileName: 'dao-voting-app.dapp',
    name: 'BeamX DAO Voting',
    guid: 'c26538f5ce9e410b89c1fd0dff783f97',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: 'ead5ae4454726a220322a41f486dceb7b287149a13c5105ffb85e2bf357f7b93',
    size: 2911424,
    remoteOrigins: [_coingecko],
  ),
  DappCatalogueEntry(
    fileName: 'dex-app.dapp',
    name: 'Beam DEX',
    guid: 'db851322f6674a6da3e84e9953db2ffd',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: '8f6d1b7dd6a694111cd645c559792b10d9ef9ecb87d340fce45adf0044bb088a',
    size: 5295745,
    connectsInWebShape: false,
  ),
  DappCatalogueEntry(
    fileName: 'nft-marketplace.dapp',
    name: 'BEAM NFT Gallery',
    guid: 'ffbec734a0bb4f88a7104357a2680d20',
    version: '1.0.0',
    apiVersion: '7.0',
    minApiVersion: '7.0',
    sha256: 'd450b1798c0bb97e1c13c525848263370267f259a523592c4319ef88ef1ad4e0',
    size: 2633723,
    connectsInWebShape: false,
  ),
];
