import 'package:ethereum_addresses/ethereum_addresses.dart';

import '../../../models/isar/models/blockchain_data/address.dart';
import '../../../models/node_model.dart';
import '../../../utilities/default_nodes.dart';
import '../../../utilities/enums/derive_path_type_enum.dart';
import '../../../utilities/eth_commons.dart';
import '../crypto_currency.dart';
import '../intermediate/bip39_currency.dart';

class Ethereum extends Bip39Currency {
  Ethereum(super.network) {
    _idMain = "ethereum";
    _uriScheme = "ethereum";
    switch (network) {
      case CryptoCurrencyNetwork.main:
        _id = _idMain;
        _name = "Ethereum";
        _ticker = "ETH";
      default:
        throw Exception("Unsupported network: $network");
    }
  }

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

  int get gasLimit => kEthereumMinGasLimit;

  @override
  bool get hasTokenSupport => true;

  // Campfire for BEAM: every Ethereum request follows the Tor switch, and
  // with Tor on but not connected it is not sent at all: RPC calls
  // (EthRpcHttpClient), the Stack Wallet index and prices (HTTP with Tor's
  // proxy), token icons (TorAwareNetworkImage). So no IP-leak warning.
  @override
  bool get torSupport => true;

  // Campfire for BEAM: named by who runs it, like the public RPCs below.
  // Stays the default: it is also the index payment history, fee estimates
  // and token details come from (`EthereumAPI.stackBaseServer`).
  @override
  NodeModel defaultNode({required bool isPrimary}) => NodeModel(
    host: "https://eth2.stackwallet.com",
    port: 443,
    name: "Stack Wallet",
    id: DefaultNodes.buildId(this),
    useSSL: true,
    enabled: true,
    coinName: identifier,
    isFailover: true,
    isDown: false,
    torEnabled: true,
    clearnetEnabled: true,
    isPrimary: isPrimary,
  );

  /// Campfire for BEAM: public Ethereum mainnet RPCs offered after the
  /// default, as built-in entries in Settings › Nodes (added once, never
  /// overwriting a user's change; see NodeService). Each answered chain id 1
  /// both directly and through Tor on 2026-10-09. MEV Blocker sends
  /// payments privately to block builders, so swaps cannot be front-run.
  static const List<({String name, String url})> publicRpcs = [
    (name: "PublicNode", url: "https://ethereum-rpc.publicnode.com"),
    (name: "dRPC", url: "https://eth.drpc.org"),
    (name: "MEV Blocker", url: "https://rpc.mevblocker.io"),
    (name: "Blast", url: "https://eth-mainnet.public.blastapi.io"),
  ];

  List<NodeModel> get alternateNodes => [
    if (network == CryptoCurrencyNetwork.main)
      for (final rpc in publicRpcs)
        NodeModel(
          host: rpc.url,
          port: 443,
          name: rpc.name,
          // Built in like the default: not deletable (NodeModel.isDefault).
          id: "${DefaultNodes.defaultNodeIdPrefix}ethereum_"
              "${Uri.parse(rpc.url).host}",
          useSSL: true,
          enabled: true,
          coinName: identifier,
          isFailover: true,
          isDown: false,
          torEnabled: true,
          clearnetEnabled: true,
          isPrimary: false,
        ),
  ];

  @override
  // Not used for eth
  String get genesisHash => throw UnimplementedError("Not used for eth");

  @override
  int get minConfirms => 3;

  @override
  bool validateAddress(String address) {
    return isValidEthereumAddress(address);
  }

  @override
  int get defaultSeedPhraseLength => 12;

  @override
  int get fractionDigits => 18;

  @override
  bool get hasBuySupport => true;

  @override
  bool get hasMnemonicPassphraseSupport => true;

  @override
  List<int> get possibleMnemonicLengths => [defaultSeedPhraseLength, 24];

  @override
  AddressType get defaultAddressType => defaultDerivePathType.getAddressType();

  @override
  BigInt get satsPerCoin => BigInt.from(1000000000000000000);

  @override
  int get targetBlockTimeSeconds => 15;

  @override
  DerivePathType get defaultDerivePathType => DerivePathType.eth;

  @override
  Uri defaultBlockExplorer(String txid) {
    switch (network) {
      case CryptoCurrencyNetwork.main:
        return Uri.parse("https://etherscan.io/tx/$txid");
      default:
        throw Exception(
          "Unsupported network for defaultBlockExplorer(): $network",
        );
    }
  }

  @override
  AddressType? getAddressType(String address) {
    if (validateAddress(address)) {
      return AddressType.ethereum;
    }
    return null;
  }
}
