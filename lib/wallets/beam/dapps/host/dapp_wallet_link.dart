/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../models/beam_asset_info.dart';
import '../../rpc/beam_transport.dart';
import '../dapp_identity.dart';

/// What an amount of an asset is worth in BEAM groth, rounded down, by the
/// DEX's prices; null when no pool prices the asset (`BeamAssetPricer`).
typedef DappAssetValuer = BigInt? Function(int assetId, BigInt amount);

/// What the dApp host needs from one open BEAM wallet.
///
/// `BeamWalletDappLink` implements it over a `BeamWallet` and its
/// `BeamWalletServices`; tests fake it. Nothing here can spend: spending
/// only happens through a `DappSession`, after the approval sheet.
abstract class DappWalletLink {
  /// The folder this wallet's dApps are installed under. `DappInstaller`
  /// creates `<root>/dapps/...` inside it.
  Future<String> dappsRoot();

  /// The connection one dApp page load talks through. Closing it must not
  /// close the wallet's own connection.
  BeamTransport dappTransport(DappIdentity dapp);

  /// Spendable amount per asset id, in the asset's smallest unit, or null
  /// when the wallet does not know yet. Used to warn before approving
  /// something the wallet cannot pay for.
  Future<Map<int, BigInt>?> availableBalances();

  /// The on-chain metadata of [assetId], or null when unknown. Only used to
  /// name assets Campfire does not vouch for.
  Future<BeamAssetMetadata?> assetMetadata(int assetId);

  /// Values amounts of any asset in BEAM, for the approval's fiat values;
  /// null when the prices are not available.
  Future<DappAssetValuer?> assetValuer();

  /// Null when the wallet may spend now; otherwise why not, in plain words
  /// (the wallet is behind the network, or not connected). An approval is
  /// disabled while this is set (project rules R5: a wallet that is behind
  /// refuses to send).
  String? get spendBlockedReason;

  /// Marks the wallet busy while an approval is on screen, so no node
  /// switch restarts wallet-api under it (project rules R11). Returns the
  /// function that ends the hold; calling it twice is harmless.
  void Function() holdForApproval(String reason);
}
