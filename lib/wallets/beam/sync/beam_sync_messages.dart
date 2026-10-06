/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

/// Plain-language wording for [BeamSyncAssessment]s, kept apart from the
/// rules so the UI layer can replace it with localized strings.
///
/// No jargon on purpose: no "explorer", "header", "is_in_sync" or "RPC".
/// Every message that blocks sending says so and names the next step.
library;

import 'beam_sync_state.dart';

/// What to show for one assessment.
class BeamSyncMessage {
  const BeamSyncMessage({required this.title, this.detail, this.actionLabel});

  /// One line, suitable for a banner or badge.
  final String title;

  /// Supporting sentence(s), or null when the title says it all.
  final String? detail;

  /// Label for the button that performs [BeamSyncAssessment.action], or null
  /// when there is nothing to press.
  final String? actionLabel;

  @override
  String toString() =>
      '$title${detail == null ? '' : ' | $detail'}'
      '${actionLabel == null ? '' : ' [$actionLabel]'}';
}

abstract final class BeamSyncMessages {
  static const _sendingPaused = "Sending is paused until it's done.";
  static const _sendingOff = 'Sending is off until this is fixed.';

  static BeamSyncMessage describe(BeamSyncAssessment a) {
    final private = a.node == BeamNodeKind.privateNode;
    final label = actionLabel(a.action);
    return switch (a) {
      BeamSyncConnecting() => BeamSyncMessage(
        title: private
            ? 'Connecting to your private node'
            : 'Connecting to the BEAM network',
        detail: 'This usually takes a few seconds.',
        actionLabel: label,
      ),
      BeamSyncNotConnected(:final networkReachable) => BeamSyncMessage(
        title: private
            ? "Can't reach your private node"
            : "Can't reach the network",
        detail: private
            ? 'It isn\'t answering. Switch to a public node to keep using '
                  'the wallet. $_sendingOff'
            : networkReachable
            ? "The BEAM node you're using isn't answering. $_sendingOff"
            : 'Check your internet connection. The wallet keeps trying on '
                  'its own.',
        actionLabel: label,
      ),
      BeamSyncCatchingUp() => BeamSyncMessage(
        title: private
            ? 'Your private node is catching up'
            : 'Catching up with the network',
        detail: _catchingUpDetail(a),
        actionLabel: label,
      ),
      BeamSyncStalled() => _stalled(a, private, label),
      BeamSynced(:final verified) => BeamSyncMessage(
        title: 'Up to date',
        detail: verified
            ? null
            : "Couldn't double-check with a second source right now.",
        actionLabel: label,
      ),
    };
  }

  /// Button text per action; null when the user has nothing to press.
  static String? actionLabel(BeamSyncAction action) => switch (action) {
    BeamSyncAction.none || BeamSyncAction.wait => null,
    BeamSyncAction.tryAnotherNode => 'Try another node',
    BeamSyncAction.usePublicNode => 'Use a public node',
    BeamSyncAction.checkInternet => 'Try again',
    BeamSyncAction.reconnect => 'Reconnect',
    BeamSyncAction.fixDeviceClock => 'Check again',
  };

  static String _catchingUpDetail(BeamSyncCatchingUp a) {
    final parts = <String>[];
    final behind = a.blocksBehind;
    if (behind != null && behind > 0) {
      parts.add('${behindBy(behind, a.blockInterval)}.');
    } else {
      parts.add('Getting the latest blocks.');
    }
    final eta = a.eta;
    if (eta != null) parts.add('${_capitalize(approxDuration(eta))} left.');
    parts.add(_sendingPaused);
    return parts.join(' ');
  }

  static BeamSyncMessage _stalled(
    BeamSyncStalled a,
    bool private,
    String? label,
  ) {
    final behind = a.blocksBehind;
    final behindText = behind != null && behind > 0
        ? ' ${behindBy(behind, a.blockInterval)}.'
        : '';
    final who = private ? 'Your private node' : 'Your node';
    switch (a.reason) {
      case BeamStallReason.stuckBelowHardFork:
        final at = a.walletHeight;
        final stoppedAt = at == null
            ? ''
            : ' and this node stopped at block ${number(at)}';
        return BeamSyncMessage(
          title: '$who is stuck on an old version of the BEAM network',
          detail:
              'BEAM upgraded at block ${number(a.forkHeight)}$stoppedAt.'
              '$behindText Balances are out of date. $_sendingOff',
          actionLabel: label,
        );
      case BeamStallReason.tipTooOld:
        final age = a.tipAge;
        final newest = age == null
            ? 'Its newest block is old'
            : 'Its newest block is ${approxDuration(age)} old';
        return BeamSyncMessage(
          title: '$who stopped receiving new blocks',
          detail:
              '$newest.$behindText Balances may be out of date. '
              '$_sendingOff',
          actionLabel: label,
        );
      case BeamStallReason.headerAheadOfProcessed:
        final lag = a.headerLag;
        final known = lag == null
            ? 'It knows about newer blocks'
            : "It knows about ${_blocks(lag)} it hasn't processed";
        return BeamSyncMessage(
          title: "The wallet isn't processing new blocks",
          detail: '$known. Balances may be out of date. $_sendingOff',
          actionLabel: label,
        );
      case BeamStallReason.behindNetwork:
        return BeamSyncMessage(
          title: '$who disagrees with the rest of the network',
          detail:
              'It looks up to date, but other BEAM nodes are further '
              'ahead.$behindText $_sendingOff',
          actionLabel: label,
        );
      case BeamStallReason.deviceClockWrong:
        final offset = a.deviceClockOffset;
        final direction = offset == null
            ? 'wrong'
            : '${approxDuration(offset.abs())} '
                  '${offset.isNegative ? 'behind' : 'ahead'}';
        return BeamSyncMessage(
          title: "Your device's clock is wrong",
          detail:
              "It's $direction, so the wallet can't tell whether it's up "
              'to date. Set the date and time to update automatically, '
              'then check again. $_sendingOff',
          actionLabel: label,
        );
    }
  }

  /// "Behind by 42 blocks — about 42 minutes".
  static String behindBy(int blocks, Duration blockInterval) =>
      'Behind by ${_blocks(blocks)} — '
      '${approxDuration(blockInterval * blocks)}';

  /// "less than a minute", "about 1 minute", "about 42 minutes",
  /// "about 1 hour", "about 3 hours", "about 97 days".
  static String approxDuration(Duration d) {
    final minutes = d.inSeconds.abs() / 60;
    if (minutes < 1) return 'less than a minute';
    if (minutes.round() < 60) {
      return 'about ${_unit(minutes.round(), 'minute')}';
    }
    final hours = minutes / 60;
    if (hours.round() < 36) return 'about ${_unit(hours.round(), 'hour')}';
    return 'about ${_unit((hours / 24).round(), 'day')}';
  }

  /// 139235 -> "139,235".
  static String number(int n) {
    final digits = n.abs().toString();
    final out = StringBuffer(n < 0 ? '-' : '');
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  static String _blocks(int n) => n == 1 ? '1 block' : '${number(n)} blocks';

  static String _unit(int n, String unit) =>
      n == 1 ? '1 $unit' : '${number(n)} ${unit}s';

  static String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}
