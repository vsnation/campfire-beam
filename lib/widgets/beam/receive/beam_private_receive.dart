/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:meta/meta.dart';

import '../../../wallets/beam/node/beam_private_node_coordinator.dart';

/// Why offline, max-privacy and public addresses cannot be made right now.
enum BeamPrivateReceiveBlock {
  /// The wallet core is not connected yet.
  connecting,

  /// This device cannot run Campfire's private node (phones).
  notOnThisDevice,

  /// "Use a private node" is off.
  nodeOff,

  /// The setting is on and the node has not started downloading yet.
  nodeStarting,

  /// The node is downloading the chain ([BeamPrivateReceive.percent]).
  nodeDownloading,

  /// The node is past the download and catching up the newest blocks.
  nodeCatchingUp,

  /// The wallet is moving onto the node.
  nodeSwitching,

  /// The wallet is on the node; the core has not confirmed the owner key.
  nodeConfirming,

  /// The node failed, stopped, fell behind or cannot be verified; the
  /// wallet is on a public node.
  nodeProblem,
}

/// Whether this wallet may offer offline, max-privacy and public addresses.
///
/// The core makes those addresses only when it can find payments to them
/// itself: on the wallet's own node holding its owner key
/// (`own_node == true`), or with block-body requests on. On a public node
/// alone it refuses (-32005), and a wallet that offered them anyway would
/// show an address whose payments it never sees (the LightWallet defect,
/// ARCHITECTURE.md §4). So this is [available] only on that evidence.
@immutable
class BeamPrivateReceive {
  const BeamPrivateReceive.available() : block = null, percent = null;

  const BeamPrivateReceive.blocked(BeamPrivateReceiveBlock this.block, {
    this.percent,
  });

  /// Decides from the wallet's state.
  ///
  /// [status]: the private node coordinator's latest status, or null when
  /// it has not started. [coreOpen]: wallet-api is up. [bodyRequests]: the
  /// session asks nodes for block bodies (a restored wallet scanning for its
  /// coins). [nodePossible]: this device can run the private node.
  /// [nodeWanted]: the "Use a private node" setting.
  factory BeamPrivateReceive.evaluate({
    required BeamPrivateNodeStatus? status,
    required bool coreOpen,
    required bool bodyRequests,
    required bool nodePossible,
    required bool nodeWanted,
  }) {
    if (!coreOpen) {
      return const BeamPrivateReceive.blocked(
        BeamPrivateReceiveBlock.connecting,
      );
    }
    if (status?.privateReceiveAvailable == true || bodyRequests) {
      return const BeamPrivateReceive.available();
    }
    if (!nodePossible) {
      return const BeamPrivateReceive.blocked(
        BeamPrivateReceiveBlock.notOnThisDevice,
      );
    }
    if (status == null) {
      return BeamPrivateReceive.blocked(
        nodeWanted
            ? BeamPrivateReceiveBlock.nodeStarting
            : BeamPrivateReceiveBlock.nodeOff,
      );
    }
    switch (status.phase) {
      case BeamPrivateNodePhase.off:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeOff,
        );
      case BeamPrivateNodePhase.idle:
      case BeamPrivateNodePhase.preparing:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeStarting,
        );
      case BeamPrivateNodePhase.downloading:
        return BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeDownloading,
          percent: status.percent,
        );
      case BeamPrivateNodePhase.catchingUp:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeCatchingUp,
        );
      case BeamPrivateNodePhase.switching:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeSwitching,
        );
      case BeamPrivateNodePhase.active:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeConfirming,
        );
      case BeamPrivateNodePhase.cannotVerify:
      case BeamPrivateNodePhase.stuck:
      case BeamPrivateNodePhase.ownNodeUnconfirmed:
      case BeamPrivateNodePhase.failed:
      case BeamPrivateNodePhase.stopped:
      case BeamPrivateNodePhase.fellBehind:
      case BeamPrivateNodePhase.walletClosed:
        return const BeamPrivateReceive.blocked(
          BeamPrivateReceiveBlock.nodeProblem,
        );
    }
  }

  /// Null when the addresses may be offered.
  final BeamPrivateReceiveBlock? block;

  /// Download progress, 0-100, for [BeamPrivateReceiveBlock.nodeDownloading].
  final int? percent;

  bool get available => block == null;

  @override
  bool operator ==(Object other) =>
      other is BeamPrivateReceive &&
      other.block == block &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(block, percent);

  @override
  String toString() => available
      ? 'BeamPrivateReceive(available)'
      : 'BeamPrivateReceive(${block!.name}'
            '${percent == null ? '' : ', $percent%'})';
}
