/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Plain-language wording for [BeamPrivateNodeStatus], kept apart from the
/// state machine so the UI layer can replace it with localized strings.
///
/// No jargon on purpose: no "owner key", "explorer", "fast sync", "RPC" or
/// "own_node". Every message that is not good news says what the wallet is
/// doing instead and, where the user can help, names the next step.
library;

import '../sync/beam_sync_messages.dart';
import '../sync/beam_sync_state.dart' show beamMainnetHf6Height;
import 'beam_node_disk.dart';
import 'beam_private_node_coordinator.dart';

/// What the user can press, per status.
enum BeamPrivateNodeAction {
  none,

  /// [BeamPrivateNodeCoordinator.retry].
  retry,

  /// [BeamPrivateNodeCoordinator.checkNow].
  checkAgain,

  /// Turn the setting on and call [BeamPrivateNodeCoordinator.applySetting].
  turnOn,

  /// Start a node the user stopped ([BeamPrivateNodeCoordinator.retry]).
  start,
}

abstract final class BeamPrivateNodeMessages {
  static const _publicNow = 'Using a public node';
  static const _private =
      'Offline and max-privacy payments need your private node.';
  static const _autoSwitch =
      'You can use the wallet as normal. It switches over by itself when '
      "your private node is ready.";

  /// The action the UI should offer for [s].
  static BeamPrivateNodeAction actionFor(BeamPrivateNodeStatus s) =>
      switch (s.phase) {
        BeamPrivateNodePhase.off => BeamPrivateNodeAction.turnOn,
        BeamPrivateNodePhase.cannotVerify => BeamPrivateNodeAction.checkAgain,
        BeamPrivateNodePhase.stopped
            when s.issue == BeamPrivateNodeIssue.stoppedByUser =>
          BeamPrivateNodeAction.start,
        // Nothing to try: it takes the node by itself once it is free.
        BeamPrivateNodePhase.failed
            when s.issue == BeamPrivateNodeIssue.servingOtherWallet =>
          BeamPrivateNodeAction.none,
        BeamPrivateNodePhase.failed ||
        BeamPrivateNodePhase.stopped ||
        BeamPrivateNodePhase.ownNodeUnconfirmed ||
        BeamPrivateNodePhase.walletClosed => BeamPrivateNodeAction.retry,
        BeamPrivateNodePhase.stuck =>
          s.issue == BeamPrivateNodeIssue.belowHardFork
              ? BeamPrivateNodeAction.none
              : BeamPrivateNodeAction.retry,
        _ => BeamPrivateNodeAction.none,
      };

  static String? actionLabel(BeamPrivateNodeAction a) => switch (a) {
    BeamPrivateNodeAction.none => null,
    BeamPrivateNodeAction.retry => 'Try again',
    BeamPrivateNodeAction.checkAgain => 'Check again',
    BeamPrivateNodeAction.turnOn => 'Turn on private node',
    BeamPrivateNodeAction.start => 'Start private node',
  };

  static BeamSyncMessage describe(BeamPrivateNodeStatus s) {
    final m = _describe(s);
    if (!s.waitingForWallet || s.phase == BeamPrivateNodePhase.switching) {
      return m;
    }
    return BeamSyncMessage(
      title: m.title,
      detail: '${m.detail == null ? '' : '${m.detail} '}$_waitsForPayment',
      actionLabel: m.actionLabel,
    );
  }

  static const _waitsForPayment =
      'The switch waits until your payment is finished.';

  static BeamSyncMessage _describe(BeamPrivateNodeStatus s) {
    final label = actionLabel(actionFor(s));
    switch (s.phase) {
      case BeamPrivateNodePhase.off:
        return BeamSyncMessage(
          title: 'Private node is off',
          detail: 'The wallet uses public nodes. $_private',
          actionLabel: label,
        );
      case BeamPrivateNodePhase.idle:
        return const BeamSyncMessage(
          title: 'Your private node has not started yet',
        );
      case BeamPrivateNodePhase.preparing:
        return const BeamSyncMessage(
          title: 'Setting up your private node',
          detail: 'Your wallet keeps working while it starts.',
        );
      case BeamPrivateNodePhase.downloading when s.finishingPercent != null:
        return BeamSyncMessage(
          title:
              '$_publicNow — your private node is finishing setup '
              '(${s.finishingPercent}%)',
          detail: 'This last step takes 5–10 minutes. $_autoSwitch',
        );
      case BeamPrivateNodePhase.downloading:
        final pct = s.percent;
        return BeamSyncMessage(
          title: pct == null
              ? '$_publicNow — your private node is downloading'
              : '$_publicNow — your private node is downloading ($pct%)',
          detail: _autoSwitch,
        );
      case BeamPrivateNodePhase.catchingUp:
        final finishing = s.finishingPercent;
        if (finishing != null) {
          return BeamSyncMessage(
            title:
                '$_publicNow — your private node is finishing setup '
                '($finishing%)',
            detail: 'This last step takes 5–10 minutes. $_autoSwitch',
          );
        }
        return BeamSyncMessage(
          title: '$_publicNow — your private node is catching up',
          detail: '${_behind(s)}$_autoSwitch',
        );
      case BeamPrivateNodePhase.cannotVerify:
        return BeamSyncMessage(
          title: '$_publicNow — your private node looks ready',
          detail:
              "The wallet switches only after a second source confirms "
              "your node is up to date, and it couldn't reach one. It "
              'checks again by itself.',
          actionLabel: label,
        );
      case BeamPrivateNodePhase.stuck:
        if (s.issue == BeamPrivateNodeIssue.belowHardFork) {
          final at = s.nodeHeight;
          return BeamSyncMessage(
            title:
                'Your private node is stuck on an old version of the BEAM '
                'network',
            detail:
                'BEAM upgraded at block '
                '${BeamSyncMessages.number(beamMainnetHf6Height)}'
                '${at == null ? '' : ' and your node stopped at block '
                          '${BeamSyncMessages.number(at)}'}. '
                'The wallet stays on a public node.',
            actionLabel: label,
          );
        }
        return BeamSyncMessage(
          title: 'Your private node stopped receiving new blocks',
          detail: '${_behind(s)}The wallet stays on a public node.',
          actionLabel: label,
        );
      case BeamPrivateNodePhase.switching:
        return s.waitingForWallet
            ? const BeamSyncMessage(
                title: 'Your private node is ready',
                detail:
                    'The wallet switches over as soon as your payment is '
                    'finished.',
              )
            : const BeamSyncMessage(
                title: 'Switching to your private node',
                detail: 'This takes a few seconds.',
              );
      case BeamPrivateNodePhase.active:
        return s.privateReceiveAvailable
            ? const BeamSyncMessage(
                title: 'Switched to your private node',
                detail: 'Offline and max-privacy payments can now reach you.',
              )
            : const BeamSyncMessage(
                title: 'Reconnecting to your private node',
                detail:
                    'Offline and max-privacy payments are paused until it '
                    'answers.',
              );
      case BeamPrivateNodePhase.ownNodeUnconfirmed:
        return BeamSyncMessage(
          title: "Couldn't confirm your private node — back on a public node",
          detail:
              "Your node didn't recognise this wallet, so offline and "
              'max-privacy payments stay off.',
          actionLabel: label,
        );
      case BeamPrivateNodePhase.failed:
        if (s.issue == BeamPrivateNodeIssue.notEnoughDisk ||
            s.issue == BeamPrivateNodeIssue.diskFull) {
          return _disk(s, label);
        }
        return BeamSyncMessage(
          title: _failedTitle(s.issue),
          detail: _failedDetail(s.issue),
          actionLabel: label,
        );
      case BeamPrivateNodePhase.stopped:
        if (s.issue == BeamPrivateNodeIssue.stoppedByUser) {
          return BeamSyncMessage(
            title: 'Your private node is stopped',
            detail:
                'The wallet uses a public node. Your private node starts '
                'again when you press start or reopen the wallet.',
            actionLabel: label,
          );
        }
        return BeamSyncMessage(
          title: 'Your private node stopped — back on a public node',
          detail: 'Your wallet keeps working. $_private',
          actionLabel: label,
        );
      case BeamPrivateNodePhase.fellBehind:
        if (s.issue == BeamPrivateNodeIssue.notServingWallet) {
          return const BeamSyncMessage(
            title: "Your private node isn't ready yet — back on a public node",
            detail:
                'It did not answer the wallet in time, so you can keep '
                'sending on a public node. The wallet tries your node again '
                'in a few minutes.',
          );
        }
        return BeamSyncMessage(
          title: 'Your private node fell behind — back on a public node',
          detail:
              '${_behind(s)}The wallet switches back once your node '
              'catches up.',
        );
      case BeamPrivateNodePhase.walletClosed:
        return BeamSyncMessage(
          title: "Couldn't reopen your wallet",
          detail:
              'No BEAM node answered. Check your internet connection, then '
              'try again.',
          actionLabel: label,
        );
    }
  }

  /// Not enough room: say how much is needed, how much there is, and that
  /// the wallet keeps working. Never asks the user to guess a number.
  static BeamSyncMessage _disk(BeamPrivateNodeStatus s, String? label) {
    final d = s.disk;
    if (s.issue == BeamPrivateNodeIssue.diskFull) {
      final free = d == null
          ? ''
          : ' Only ${formatBeamDiskSize(d.space.freeBytes)} is free.';
      return BeamSyncMessage(
        title:
            'Your private node stopped: this computer is almost out of '
            'space',
        detail:
            'It was stopped before the disk filled up.$free Free up some '
            'space, then try again. Back on a public node — your wallet '
            'keeps working.',
        actionLabel: label,
      );
    }
    if (d == null) {
      const policy = BeamNodeDiskPolicy();
      return BeamSyncMessage(
        title: _setupTitle(policy.setupPeakBytes, policy.nodeBytes),
        detail:
            'Free up some space, then try again. Your wallet keeps working '
            'on a public node.',
        actionLabel: label,
      );
    }
    final title = d.freshNode
        ? _setupTitle(d.setupPeakBytes, d.nodeBytes)
        : "There isn't enough free space for your private node";
    return BeamSyncMessage(
      title: title,
      detail:
          'This computer has ${formatBeamDiskSize(d.space.freeBytes)} free, '
          'and Campfire leaves ${formatBeamDiskSize(d.reserveBytes)} for '
          'your other apps. Free up ${formatBeamDiskSize(d.shortfallBytes)}, '
          'then try again. Your wallet keeps working on a public node.',
      actionLabel: label,
    );
  }

  /// "Your private node needs about 12 GB free while it sets up (it
  /// shrinks to about 8 GB)".
  static String _setupTitle(int peak, int settled) =>
      'Your private node needs about ${formatBeamDiskSize(peak)} free while '
      'it sets up (it shrinks to about ${formatBeamDiskSize(settled)})';

  static String _failedTitle(BeamPrivateNodeIssue? issue) => switch (issue) {
    BeamPrivateNodeIssue.keyRejected =>
      "Your private node couldn't use this wallet's key — staying on a "
          'public node',
    BeamPrivateNodeIssue.nodeInUse =>
      'Your private node is already running in another copy of the app',
    BeamPrivateNodeIssue.servingOtherWallet =>
      'Your private node is serving another of your wallets',
    BeamPrivateNodeIssue.binaryProblem =>
      "Your private node didn't pass a safety check — staying on a public "
          'node',
    _ => "Couldn't start your private node — staying on a public node",
  };

  static String _failedDetail(BeamPrivateNodeIssue? issue) => switch (issue) {
    BeamPrivateNodeIssue.keyRejected =>
      'It was stopped rather than run without the key. Offline and '
          'max-privacy payments stay off.',
    BeamPrivateNodeIssue.nodeInUse => 'Close the other copy, then try again.',
    BeamPrivateNodeIssue.servingOtherWallet =>
      'One private node serves one wallet at a time. This wallet uses a '
          'public node meanwhile and moves to your node by itself when that '
          'wallet closes.',
    BeamPrivateNodeIssue.binaryProblem =>
      'Its program file is not the one this app was built with, so it was '
          'not run. Reinstall the app, then try again.',
    _ => 'Your wallet keeps working. $_private',
  };

  static String _behind(BeamPrivateNodeStatus s) {
    final behind = s.blocksBehind;
    if (behind == null || behind <= 0) return '';
    return '${BeamSyncMessages.behindBy(behind, const Duration(seconds: 60))}'
        '. ';
  }
}
