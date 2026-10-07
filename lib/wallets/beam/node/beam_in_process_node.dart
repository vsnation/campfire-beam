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

import '../host/beam_core_library.dart';
import '../host/beam_core_node_status.dart';
import '../host/beam_host.dart';
import '../host/beam_host_exception.dart';
import '../host/secret_file.dart';
import '../net/beam_node_route.dart';
import 'beam_node_process.dart';
import 'beam_node_progress.dart';

/// The private node as a thread of the app (`libbeam_core`'s
/// `beam_node_start`), as BEAM's own desktop wallet runs its integrated
/// node: no `beam-node` program. Same storage as the child-process node
/// (`<root>/node/node.db`), so a node synced before is reused.
///
/// * With Tor on, every peer name is resolved through Tor and the node
///   connects to its peers only through Tor's SOCKS5 proxy
///   ([BeamNodeRouter]); a peer Tor cannot resolve is left out, and with
///   none left the node does not start (never a direct connection).
/// * The owner key and password go straight into native memory, wiped after
///   the call; they are not kept here.
/// * Progress is the library's status, polled every [pollInterval] — no log
///   parsing.
///
/// One node per process: a second start while one runs is refused.
class BeamInProcessNode implements BeamPrivateNode, BeamNodeStorage {
  BeamInProcessNode({
    required String rootDir,
    required this.core,
    BeamNodeRouter? router,
    this.peers = kBeamMainnetNodePeers,
    this.pollInterval = const Duration(seconds: 1),
    this.startupWindow = const Duration(seconds: 60),
    this.stopGrace = kBeamNodeStopGrace,
    void Function(String message)? log,
  }) : rootDir = p.normalize(p.absolute(rootDir)),
       router = router ?? BeamNodeRouter.campfire(),
       _log = log ?? _noLog;

  final String rootDir;
  final BeamCoreIntegrated core;
  final BeamNodeRouter router;

  /// `host:port` peers to start from.
  final List<String> peers;
  final Duration pollInterval;

  /// How long [start] waits for the node to open its database and know its
  /// owned account.
  final Duration startupWindow;

  /// How long [stop] waits for the node to close its database. A long step
  /// ("Raising Fossil") cannot be interrupted; the stop finishes after it.
  final Duration stopGrace;

  final void Function(String message) _log;

  @override
  String get nodeDir => p.join(rootDir, 'node');

  String get dbPath => p.join(nodeDir, BeamNodeProcess.storageName);

  final _controller = StreamController<BeamNodeProgress>.broadcast();
  BeamNodeProgress _progress = const BeamNodeProgress();
  Timer? _poll;
  int? _port;
  bool _started = false;
  bool _stopRequested = false;

  @override
  int? get port => _port;

  @override
  BeamNodeProgress get progress => _progress;

  @override
  Stream<BeamNodeProgress> get progressStream => _controller.stream;

  @override
  Future<void> start({
    required String ownerKey,
    required String password,
  }) async {
    if (_started) throw StateError('BeamInProcessNode is single-use');
    _started = true;
    if (ownerKey.isEmpty || password.isEmpty) {
      throw const BeamNodeException(
        BeamNodeError.ownerKeyRejected,
        'A private node needs the owner key and the wallet password',
      );
    }
    final current = core.nodeStatus();
    if (current.state == BeamCoreNodeState.starting ||
        current.state == BeamCoreNodeState.running ||
        current.state == BeamCoreNodeState.stopping) {
      throw const BeamNodeException(
        BeamNodeError.nodeInUse,
        'A private node already runs in this app',
      );
    }
    await ensurePrivateDir(nodeDir);

    // Tor: names resolved through Tor, IPv4 only, the proxy for every peer.
    final resolved = <String>[];
    String? proxy;
    for (final peer in peers) {
      final BeamNodeEndpoint endpoint;
      try {
        endpoint = BeamNodeEndpoint.parse(peer);
      } on FormatException {
        continue;
      }
      try {
        final route = await router.route(endpoint);
        resolved.add('${route.address}');
        proxy ??= route.socksProxy;
      } on BeamHostException catch (e) {
        _log('Peer $peer left out: ${e.message}');
      }
    }
    if (resolved.isEmpty) {
      throw const BeamHostException(
        BeamHostError.torNotReady,
        'No peer for the private node could be reached through Tor',
      );
    }

    final port = await _freeLoopbackPort();
    final rc = await core.startNode(
      nodeDbPath: dbPath,
      port: port,
      peers: resolved,
      ownerKey: ownerKey,
      password: password,
      socksProxy: proxy,
    );
    if (rc != BeamCoreNodeError.ok) {
      throw BeamNodeException(switch (rc) {
        BeamCoreNodeError.badOwnerKey => BeamNodeError.ownerKeyRejected,
        BeamCoreNodeError.alreadyRunning => BeamNodeError.nodeInUse,
        _ => BeamNodeError.exited,
      }, 'The private node did not start (core result $rc)');
    }
    _port = port;
    _live.add(this);
    _log(
      'Private node started in-process on 127.0.0.1:$port'
      '${proxy == null ? '' : ' through Tor'}',
    );
    _poll = Timer.periodic(pollInterval, (_) => _refresh());
    _refresh();

    // Wait until the database is open and the owned account is known, or
    // the node fails.
    final deadline = DateTime.now().add(startupWindow);
    while (true) {
      final s = core.nodeStatus();
      if (s.state == BeamCoreNodeState.failed) {
        _refresh();
        throw BeamNodeException(
          beamNodeErrorFrom(s.error),
          s.errorDetail.isEmpty ? 'The private node stopped' : s.errorDetail,
        );
      }
      if (s.state == BeamCoreNodeState.running && s.ownerAccounts >= 0) {
        _refresh();
        if (s.ownerAccounts == 0) {
          await stop();
          throw const BeamNodeException(
            BeamNodeError.ownerKeyRejected,
            'The private node runs without the owner key; stopped',
          );
        }
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        _refresh();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _refresh() {
    final next = beamNodeProgressFrom(
      core.nodeStatus(),
      _progress,
      stopRequested: _stopRequested,
    );
    if (next != _progress) {
      _progress = next;
      if (!_controller.isClosed) _controller.add(next);
    }
    if (next.isEnded) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Nodes started by this process and not stopped yet.
  static final Set<BeamInProcessNode> _live = {};

  /// Stops every node of this process (the app's quit path). A node in a
  /// long step stops when the step ends.
  /// How far a running node of this process is through one of its long
  /// maintenance steps (0-100), or null when none runs one. A node stopped
  /// by quitting the app mid-step starts that step over on its next start.
  static int? get finishingPercentNow {
    for (final n in _live) {
      final p = n._progress.finishingPercent;
      if (p != null) return p;
    }
    return null;
  }

  static Future<void> stopAll() =>
      Future.wait([for (final n in List.of(_live)) n.stop()]);

  @override
  Future<void> stop() async {
    if (!_started || _stopRequested) return;
    _stopRequested = true;
    _live.remove(this);
    core.stopNode();
    final deadline = DateTime.now().add(stopGrace);
    while (!core.nodeStatus().isEnded) {
      if (DateTime.now().isAfter(deadline)) {
        _log(
          'The private node is still finishing a long step; it stops when '
          'that step ends',
        );
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _refresh();
    _poll?.cancel();
    _poll = null;
    if (!_progress.isEnded) {
      _progress = _progress.copyWith(phase: BeamNodePhase.stopped);
      if (!_controller.isClosed) _controller.add(_progress);
    }
  }

  static Future<int> _freeLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}

void _noLog(String _) {}
