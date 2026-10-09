/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/node_model.dart';
import '../../../utilities/default_nodes.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../beam/address/beam_address_format.dart';
import '../../beam/host/beam_host.dart';
import '../../beam/models/beam_address.dart';
import '../crypto_currency.dart';
import '../intermediate/bip39_currency.dart';

/// BEAM Privacy (Mimblewimble with Confidential Assets). Asset 0 is BEAM;
/// the other assets live inside the same wallet.
class Beam extends Bip39Currency {
  Beam(super.network) {
    _idMain = "beam";
    _uriScheme = "beam";
    switch (network) {
      case CryptoCurrencyNetwork.main:
        _id = _idMain;
        _name = "Beam";
        _ticker = "BEAM";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

  /// BEAM's public mainnet nodes: the two round-robin names of the core's
  /// `getDefaultPeers` (`wallet/core/default_peers.cpp`), then each machine
  /// behind them (all ten resolve and answer on 8100 as of 2026-10-07; the
  /// `ap-node*` names no longer resolve). The first is the default node; the
  /// rest are failover alternates, and all are listed in Settings › Nodes.
  static const List<BeamNodeEndpoint> mainnetNodes = [
    BeamNodeEndpoint("eu-nodes.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("us-nodes.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("eu-node01.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("eu-node02.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("eu-node03.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("eu-node04.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("us-node01.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("us-node02.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("us-node03.mainnet.beam.mw", 8100),
    BeamNodeEndpoint("us-node04.mainnet.beam.mw", 8100),
  ];

  /// The public nodes after the default, as Campfire node entries, so the
  /// node list offers every one of them (the default is [defaultNode]).
  List<NodeModel> get alternateNodes => [
    if (network == CryptoCurrencyNetwork.main)
      for (final n in mainnetNodes.skip(1))
        NodeModel(
          host: n.host,
          port: n.port,
          name: n.host.split('.').first,
          // Built in, like the default: neutral in the node list and not
          // deletable (NodeModel.isDefault).
          id: '${DefaultNodes.defaultNodeIdPrefix}beam_${n.host}',
          useSSL: false,
          enabled: true,
          coinName: identifier,
          isFailover: true,
          isDown: false,
          torEnabled: false,
          clearnetEnabled: true,
          isPrimary: false,
        ),
  ];

  static const String _mainnetExplorer = "https://explorer.beam.mw";

  late final String _id;
  @override
  String get identifier => _id;

  late final String _idMain;
  @override
  String get mainNetId => _idMain;

  late final String _name;
  @override
  String get prettyName => _name;

  late final String _uriScheme;
  @override
  String get uriScheme => _uriScheme;

  late final String _ticker;
  @override
  String get ticker => _ticker;

  // With Tor on, BEAM connects through Tor or not at all (BeamNodeRouter;
  // a core without proxy support is never started under Tor), so Campfire's
  // "not compatible with Tor, leaks your IP" warning would be false. It
  // shows on My Campfire's coin list once the build has a second coin.
  @override
  bool get torSupport => true;

  @override
  String get genesisHash => "not used in beam";

  // One block. Regular outputs mature at once (Rules::Maturity.Std is 0), and
  // the core marks a transaction completed as soon as its kernel is in a
  // block. Waiting longer would show "confirming" for a payment the core
  // already lets the user spend.
  @override
  int get minConfirms => 1;

  // Rules::Maturity.Coinbase (core/block_crypt.cpp).
  @override
  int get minCoinbaseConfirms => 240;

  /// Format check only, for every address type: regular (hex SBBS),
  /// regular_new, offline, max-privacy and public-offline (base58 tokens).
  /// Needs no wallet or core; see [BeamAddressFormat]. The authoritative
  /// `validate_address` call runs in `prepareSend`.
  @override
  bool validateAddress(String address) => BeamAddressFormat.isValid(address);

  /// The BEAM address type of [address], or null if it is not well formed.
  BeamAddressType? beamAddressType(String address) =>
      BeamAddressFormat.typeOf(address);

  @override
  AddressType? getAddressType(String address) =>
      validateAddress(address) ? AddressType.mimbleWimble : null;

  @override
  NodeModel defaultNode({required bool isPrimary}) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        final node = mainnetNodes.first;
        return NodeModel(
          host: node.host,
          port: node.port,
          // Named by its host like the other public nodes ("eu-nodes"),
          // not "Campfire Default": the list shows where each one is.
          name: node.host.split('.').first,
          id: DefaultNodes.buildId(this),
          // BEAM's node protocol is its own TCP protocol, not HTTP(S).
          useSSL: false,
          enabled: true,
          coinName: identifier,
          isFailover: true,
          isDown: false,
          torEnabled: false,
          clearnetEnabled: true,
          isPrimary: isPrimary,
        );

      default:
        throw UnimplementedError();
    }
  }

  @override
  int get defaultSeedPhraseLength => 12;

  @override
  int get fractionDigits => 8;

  @override
  bool get hasBuySupport => false;

  @override
  bool get hasMnemonicPassphraseSupport => false;

  @override
  List<int> get possibleMnemonicLengths => [defaultSeedPhraseLength];

  @override
  AddressType get defaultAddressType => AddressType.mimbleWimble;

  /// Groth per BEAM.
  @override
  BigInt get satsPerCoin => BigInt.from(100000000);

  @override
  int get targetBlockTimeSeconds => 60;

  @override
  DerivePathType get defaultDerivePathType => throw UnsupportedError(
    "$runtimeType does not use bitcoin style derivation paths",
  );

  /// BEAM's explorer finds a transaction by its kernel id, not by the
  /// wallet's internal tx id, so [txid] must be the kernel id. The link format
  /// is the BEAM desktop wallet's (`TxTable.qml`).
  @override
  Uri defaultBlockExplorer(String txid) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return Uri.parse("$_mainnetExplorer/block?kernel_id=$txid");
      default:
        throw Exception(
          "Unsupported network for defaultBlockExplorer(): $network",
        );
    }
  }
}
