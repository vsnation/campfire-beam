/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../utilities/logger.dart';
import '../../../utilities/stack_file_system.dart';
import '../../../wl_gen/interfaces/libbeam_interface.dart';
import '../explorer/beam_explorer_client.dart';
import '../explorer/campfire_proxy_info.dart';
import '../host/beam_binaries.dart';
import '../host/beam_host.dart';
import '../host/process_host.dart';
import '../node/beam_node_process.dart';
import '../node/beam_private_node_coordinator.dart';
import '../sync/beam_sync_state.dart';

/// Makes a fresh private node for a coordinator (single use).
typedef BeamPrivateNodeBuilder = BeamPrivateNode Function(
  String beamRoot,
  BeamHost host,
);

/// Everything a `BeamWallet` needs from outside Campfire's own services:
/// where the BEAM files live, how the core is run, where an independent chain
/// height comes from, and the private node.
///
/// The app uses [BeamWalletEnvironment.app]; tests install their own with
/// [instance] (fake host, fake explorer, temp root, pinned test binaries).
class BeamWalletEnvironment {
  BeamWalletEnvironment({
    required this._beamRoot,
    required this._createHost,
    required this._createExplorer,
    this.createPrivateNode,
    BeamPrivateNodeSetting? privateNodeSetting,
    this.syncRules = const BeamSyncRules(),
    this.explorerPollInterval = const Duration(seconds: 30),
    this.statusPollInterval = const Duration(seconds: 60),
    this.eventDebounce = const Duration(milliseconds: 250),
    this.privateNodeStartDelay = const Duration(seconds: 20),
    void Function(String message)? log,
  }) : privateNodeSetting =
           privateNodeSetting ?? const BeamFixedPrivateNodeSetting(false),
       log = log ?? _defaultLog;

  /// The production wiring.
  ///
  /// * Files: `StackFileSystem.applicationBeamDirectory()`
  ///   (`<app data>/beam`).
  /// * Core: `libBeam.createHost` (a [ProcessHost] when the BEAM build flag
  ///   is on). Its binaries come from `BEAM_BIN_DIR` or `<root>/bin`;
  ///   bundling them is task B-BIN-2, so a build without them reports
  ///   "BEAM core not installed" instead of failing.
  /// * Independent height: [BeamExplorerClient] through Campfire's HTTP
  ///   layer, honouring the Tor setting.
  /// * Private node: [BeamNodeProcess] under the same root, on by default on
  ///   desktop (ARCHITECTURE.md §4), started only once the wallet is synced
  ///   on a public node.
  factory BeamWalletEnvironment.app() => BeamWalletEnvironment(
    beamRoot: () async =>
        (await StackFileSystem.applicationBeamDirectory()).path,
    createHost: (root) => libBeam.createHost(rootDir: root),
    createExplorer: () => BeamExplorerClient(proxyInfo: campfireProxyInfo),
    createPrivateNode: (root, host) => BeamNodeProcess(
      rootDir: root,
      binaries: host is ProcessHost
          ? host.binaries
          : BeamBinaries.locate(beamRoot: root),
      log: _defaultLog,
    ),
    privateNodeSetting: BeamFixedPrivateNodeSetting.platformDefault(),
  );

  static BeamWalletEnvironment? _instance;

  /// The environment wallets use. Defaults to [BeamWalletEnvironment.app].
  static BeamWalletEnvironment get instance =>
      _instance ??= BeamWalletEnvironment.app();

  static set instance(BeamWalletEnvironment env) => _instance = env;

  final Future<String> Function() _beamRoot;
  final BeamHost Function(String beamRoot) _createHost;
  final BeamNetworkTipSource Function() _createExplorer;

  /// Null: no private node in this environment (mobile, tests).
  final BeamPrivateNodeBuilder? createPrivateNode;

  /// "Use a private node".
  final BeamPrivateNodeSetting privateNodeSetting;

  final BeamSyncRules syncRules;

  /// How often the sync monitor asks the explorer for the tip.
  final Duration explorerPollInterval;

  /// Safety-net `wallet_status` poll; events do the real work.
  final Duration statusPollInterval;

  /// Bursts of `ev_*` pushes are folded into one refresh this long after the
  /// first.
  final Duration eventDebounce;

  /// How long after the first honest "synced" the private node may start,
  /// so its brief start-up pause stays out of the first seconds of use.
  final Duration privateNodeStartDelay;

  /// Operational log; never given a secret.
  final void Function(String message) log;

  final Map<String, BeamHost> _hosts = {};
  BeamNetworkTipSource? _explorer;

  Future<String> beamRoot() => _beamRoot();

  /// The host for this root, created once (one per app: hosts share a
  /// process-wide session registry and wallet locks).
  Future<BeamHost> host() async {
    final root = await beamRoot();
    return _hosts[root] ??= _createHost(root);
  }

  /// One explorer client for all wallets (it caches the tip).
  BeamNetworkTipSource get explorer => _explorer ??= _createExplorer();

  /// `<root>/wallets/<walletId>`, the same place [ProcessHost] uses.
  Future<String> walletDir(String walletId) async =>
      beamWalletDir(await beamRoot(), walletId);

  static void _defaultLog(String message) =>
      Logging.instance.i('BEAM: $message');
}

final RegExp _walletIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// `<beamRoot>/wallets/<walletId>`. Throws [ArgumentError] for an id that is
/// not a plain name (no path tricks reach the file system).
String beamWalletDir(String beamRoot, String walletId) {
  if (!_walletIdPattern.hasMatch(walletId)) {
    throw ArgumentError.value(walletId, 'walletId', 'not a plain id');
  }
  return p.join(beamRoot, 'wallets', walletId);
}

/// True when [walletDir] holds a `wallet.db`.
Future<bool> beamWalletFileExists(String walletDir) =>
    File(p.join(walletDir, 'wallet.db')).exists();
