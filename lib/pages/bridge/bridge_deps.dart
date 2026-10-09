/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// What the bridge screens need from the app, in one object, so they can
// be tested with fakes: the user's BEAM and Ethereum wallets (which pair
// is in use), the controller for that pair, Campfire's PIN / password
// gate, explorer links, and where to send the user when a wallet or a
// little BEAM is missing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../utilities/util.dart';
import '../../wallets/bridge/bridge_controller.dart';
import '../../widgets/beam/dex/dex_widgets.dart';

typedef BridgeAuthGate = Future<bool?> Function(
  BuildContext context, {
  required String reason,
});

/// One of the user's wallets, as the bridge lists it.
class BridgeWalletOption {
  const BridgeWalletOption({
    required this.id,
    required this.name,
    this.address,
  });

  final String id;

  /// The wallet's own name ("My BEAM", "Savings").
  final String name;

  /// An Ethereum wallet's address, `0x` + 40 hex.
  final String? address;
}

class BridgeDeps implements DexLayout {
  BridgeDeps({
    required this.beamWallets,
    required this.ethWallets,
    required this.controllerFor,
    required this.authenticate,
    required this.ethExplorerTx,
    required this.ethExplorerAddress,
    String? beamWalletId,
    String? ethWalletId,
    this.onAddEthereumWallet,
    this.onAddBeamWallet,
    this.onGetBeam,
    this.beamCanSpend,
    this.isDesktop,
    this.onChoose,
    this.onDispose,
  }) : _beamId =
           beamWalletId ?? (beamWallets.isEmpty ? null : beamWallets.first.id),
       _ethId =
           ethWalletId ?? (ethWallets.isEmpty ? null : ethWallets.first.id);

  final List<BridgeWalletOption> beamWallets;
  final List<BridgeWalletOption> ethWallets;

  /// The controller of one wallet pair, created (and resumed) once.
  final Future<BridgeController> Function(String beamId, String ethId)
  controllerFor;

  final BridgeAuthGate authenticate;

  /// Etherscan (or the user's explorer) for a transaction, an address.
  final Uri Function(String hash) ethExplorerTx;
  final Uri Function(String address) ethExplorerAddress;

  /// Where to go when a wallet is missing; null hides the button.
  final VoidCallback? onAddEthereumWallet;
  final VoidCallback? onAddBeamWallet;

  /// Opens the BEAM wallet's Receive, for the network fees.
  final VoidCallback? onGetBeam;

  /// Whether the BEAM wallet is up to date enough to send; null: always.
  final ValueListenable<bool>? beamCanSpend;

  /// Told when the user picks another wallet (remembered by the app).
  final void Function(String beamId, String ethId)? onChoose;

  final bool? isDesktop;

  /// Releases what the app attached for these deps.
  final VoidCallback? onDispose;

  @override
  bool get desktop => isDesktop ?? Util.isDesktop;

  String? _beamId;
  String? _ethId;

  /// Ticks when the wallet pair changes.
  final ValueNotifier<int> changes = ValueNotifier(0);

  String? get beamWalletId => _beamId;
  String? get ethWalletId => _ethId;

  BridgeWalletOption? get beamWallet => _find(beamWallets, _beamId);
  BridgeWalletOption? get ethWallet => _find(ethWallets, _ethId);

  bool get hasPair => _beamId != null && _ethId != null;

  static BridgeWalletOption? _find(List<BridgeWalletOption> l, String? id) {
    for (final w in l) {
      if (w.id == id) return w;
    }
    return null;
  }

  Future<BridgeController>? _controller;
  String? _controllerKey;

  /// The controller of the wallets in use; null without a pair.
  Future<BridgeController>? get controller {
    final b = _beamId;
    final e = _ethId;
    if (b == null || e == null) return null;
    final key = '$b/$e';
    if (_controllerKey != key) {
      _controllerKey = key;
      _controller = controllerFor(b, e);
    }
    return _controller;
  }

  void chooseBeam(String id) {
    if (id == _beamId) return;
    _beamId = id;
    _chosen();
  }

  void chooseEth(String id) {
    if (id == _ethId) return;
    _ethId = id;
    _chosen();
  }

  void _chosen() {
    final b = _beamId;
    final e = _ethId;
    if (b != null && e != null) onChoose?.call(b, e);
    changes.value++;
  }

  void dispose() {
    changes.dispose();
    onDispose?.call();
  }
}
