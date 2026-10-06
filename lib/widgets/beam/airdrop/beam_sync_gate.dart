/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../../wallets/beam/sync/beam_sync_messages.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import 'beam_blocks.dart';

/// Rebuilds with the wallet's sync verdict. Money-moving buttons take
/// `canSpend` from here and nowhere else (project rules R5: a wallet that is
/// behind says how far behind and refuses to send).
class BeamSyncGate extends StatelessWidget {
  const BeamSyncGate({super.key, required this.sync, required this.builder});

  final ValueListenable<BeamSyncAssessment> sync;
  final Widget Function(BuildContext context, BeamSyncAssessment sync) builder;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<BeamSyncAssessment>(
        valueListenable: sync,
        builder: (context, value, _) => builder(context, value),
      );
}

/// The notice shown above a disabled money button while the wallet is not
/// up to date: what is happening and that the button waits for it. Empty
/// when spending is allowed.
class BeamSyncNotice extends StatelessWidget {
  const BeamSyncNotice({super.key, required this.sync, required this.what});

  final BeamSyncAssessment sync;

  /// What is paused, e.g. "Claiming".
  final String what;

  @override
  Widget build(BuildContext context) {
    if (sync.canSpend) return const SizedBox.shrink();
    final m = BeamSyncMessages.describe(sync);
    final waiting = sync is BeamSyncConnecting || sync is BeamSyncCatchingUp;
    final when = waiting
        ? '$what turns back on by itself once the wallet is up to date.'
        : '$what stays off until this is fixed.';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: BeamNotice(
        key: const ValueKey('beam-sync-notice'),
        kind: waiting ? BeamNoticeKind.info : BeamNoticeKind.warning,
        title: m.title,
        message: m.detail == null ? when : '${m.detail} $when',
      ),
    );
  }
}
