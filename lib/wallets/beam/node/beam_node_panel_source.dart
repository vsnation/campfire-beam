/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../wallet/impl/beam_wallet.dart';
import '../wallet/beam_wallet_environment.dart';
import 'beam_node_disk.dart';
import 'beam_node_panel_model.dart';
import 'beam_private_node_coordinator.dart';
import 'beam_private_node_preference.dart';

/// What the "Node & sync" panel and the node status chip read and drive.
/// The app uses [BeamWalletNodePanelSource]; widget tests use a fake.
abstract class BeamNodePanelSource {
  BeamNodePanelSnapshot get current;

  /// Every change of [current]. Broadcast.
  Stream<BeamNodePanelSnapshot> get changes;

  /// "Use my own private node": stored for the next run and applied now.
  Future<void> setPrivateNodeEnabled(bool enabled);

  /// Runs one of the panel's buttons.
  Future<void> perform(BeamNodePanelAction action);

  /// Campfire's "Resync": read everything from the core again.
  Future<void> refresh();

  void dispose();
}

/// The panel source for one open [BeamWallet].
///
/// Reads only the wallet's public surface (honest sync verdict, current
/// node, private node status, core problem) and drives the wallet's private
/// node coordinator, found by wallet directory
/// ([BeamPrivateNodeCoordinator.forWalletDir]). Before a coordinator runs,
/// it measures the node's disk itself, so the panel can say up front how
/// much space the node needs.
class BeamWalletNodePanelSource implements BeamNodePanelSource {
  BeamWalletNodePanelSource(
    this.wallet, {
    BeamWalletEnvironment? environment,
    BeamPrivateNodePreference? preference,
    this._diskPolicy = const BeamNodeDiskPolicy(),
    Duration pollInterval = const Duration(seconds: 1),
    this._diskInterval = const Duration(seconds: 30),
  }) : _env = environment ?? BeamWalletEnvironment.instance {
    _preference =
        preference ?? BeamPrivateNodePreference(beamRoot: _env.beamRoot);
    _current = BeamNodePanelSnapshot(
      assessment: wallet.syncAssessment,
      node: wallet.currentNode,
      privateNodeSupported: _supported,
      privateNodeEnabled: _preference.defaultValue,
      privateNode: wallet.privateNodeStatus,
      coreProblem: wallet.coreProblem?.message,
      torEnabled: _preference.torEnabled,
    );
    _subs.add(wallet.syncAssessments.listen((_) => _rebuild()));
    _subs.add(
      BeamPrivateNodeCoordinator.registryChanges.listen((_) => _attach()),
    );
    _subs.add(
      BeamPrivateNodePreference.changes.listen((on) {
        _enabled = on;
        _rebuild();
      }),
    );
    _poll = Timer.periodic(pollInterval, (_) => _rebuild());
    unawaited(_init());
  }

  final BeamWallet wallet;
  final BeamWalletEnvironment _env;
  final BeamNodeDiskPolicy _diskPolicy;
  final Duration _diskInterval;
  late final BeamPrivateNodePreference _preference;

  final _controller = StreamController<BeamNodePanelSnapshot>.broadcast();
  final List<StreamSubscription<Object?>> _subs = [];
  StreamSubscription<BeamPrivateNodeStatus>? _statusSub;
  Timer? _poll;
  String? _walletDir;
  String? _nodeDir;
  bool? _enabled;
  BeamPrivateNodeCoordinator? _coordinator;
  BeamNodeDiskCheck? _disk;
  DateTime? _diskAt;
  bool _busy = false;
  bool _disposed = false;
  late BeamNodePanelSnapshot _current;

  bool get _supported =>
      _env.createPrivateNode != null &&
      (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  @override
  BeamNodePanelSnapshot get current => _current;

  @override
  Stream<BeamNodePanelSnapshot> get changes => _controller.stream;

  Future<void> _init() async {
    try {
      _walletDir = await _env.walletDir(wallet.walletId);
      _nodeDir = p.join(await _env.beamRoot(), 'node');
      _enabled = await _preference.read();
    } catch (_) {
      // The panel still shows the sync state.
    }
    if (_disposed) return;
    _attach();
    _rebuild();
  }

  void _attach() {
    final dir = _walletDir;
    final c = dir == null ? null : BeamPrivateNodeCoordinator.forWalletDir(dir);
    if (identical(c, _coordinator)) return;
    _coordinator = c;
    unawaited(_statusSub?.cancel());
    _statusSub = c?.statuses.listen((_) => _rebuild());
    _rebuild();
  }

  void _rebuild() {
    if (_disposed) return;
    final status = _coordinator?.status ?? wallet.privateNodeStatus;
    final enabled = _enabled ?? _preference.defaultValue;
    if (_supported && enabled && status?.disk == null) _maybeMeasureDisk();
    final next = BeamNodePanelSnapshot(
      assessment: wallet.syncAssessment,
      node: wallet.currentNode,
      privateNodeSupported: _supported,
      privateNodeEnabled: enabled,
      privateNode: status,
      disk: status?.disk ?? _disk,
      coreProblem: wallet.coreProblem?.message,
      busy: _busy,
      torEnabled: _preference.torEnabled,
    );
    if (next == _current) return;
    _current = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  void _maybeMeasureDisk() {
    final dir = _nodeDir;
    final at = _diskAt;
    if (dir == null) return;
    if (at != null && DateTime.now().difference(at) < _diskInterval) return;
    _diskAt = DateTime.now();
    unawaited(() async {
      final space = await BeamNodeDisk.probe(dir)();
      if (space == null || _disposed) return;
      _disk = _diskPolicy.check(space);
      _rebuild();
    }());
  }

  Future<void> _busyWhile(Future<void> Function() op) async {
    _busy = true;
    _rebuild();
    try {
      await op();
    } finally {
      _busy = false;
      _rebuild();
    }
  }

  @override
  Future<void> setPrivateNodeEnabled(bool enabled) => _busyWhile(() async {
    _enabled = enabled;
    _rebuild();
    await _preference.write(enabled);
    // Applied now when the node's coordinator runs; otherwise the wallet
    // reads the stored choice when it starts one.
    await _coordinator?.setEnabled(enabled);
  });

  @override
  Future<void> perform(BeamNodePanelAction action) => _busyWhile(() async {
    final c = _coordinator;
    if (c == null) return;
    switch (action) {
      case BeamNodePanelAction.retry:
      case BeamNodePanelAction.start:
        await c.retry();
      case BeamNodePanelAction.checkAgain:
        await c.checkNow();
      case BeamNodePanelAction.restart:
        await c.restart();
      case BeamNodePanelAction.stop:
      case BeamNodePanelAction.usePublicNode:
        await c.stop();
    }
  });

  @override
  Future<void> refresh() => wallet.refresh();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll?.cancel();
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_statusSub?.cancel());
    unawaited(_controller.close());
  }
}
