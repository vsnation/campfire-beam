/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Spec (USER_PSYCHOLOGY §1):
// 1. ONE job: stop a desktop quit that would interrupt a swap the chain is
//    still confirming, and say what quitting would do.
// 2. Primary CTA: "Wait" (keeps Campfire open). Secondary: "Quit anyway".
// 3. Taps: shown only when quitting with a swap in flight; one tap either
//    way. If the swap settles while it is open, the quit goes ahead by
//    itself: the reason to stop it is gone.
//
// Why: DEX trades are BEAM "dependent" transactions that the core rebuilds
// when they miss a block. A core without patches/0006 forgets after a
// restart which variant it already sent; on 2026-10-07 one swap ran twice
// after the app was quit while it was "In progress".

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/node/beam_in_process_node.dart';
import '../../../wallets/beam/wallet/beam_shutdown.dart';
import '../../../wallets/beam/wallet/beam_swaps_in_flight.dart';
import '../../desktop/desktop_dialog.dart';
import '../../desktop/primary_button.dart';
import '../../desktop/secondary_button.dart';

/// True where the pinned core is built with patches/0006 (an interrupted
/// swap then completes or is cancelled, never runs twice): macOS, Android
/// and iOS since 2026-10-07, Linux and Windows since their CI-built cores
/// (beam-core.yml, pre-release beam-core-7.5.14493-cf1). The dialog text
/// follows.
bool get kBeamCoreSwapRestartSafe =>
    Platform.isMacOS ||
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isLinux ||
    Platform.isWindows;

abstract final class BeamQuitText {
  static String title(int count) => count == 1
      ? 'A swap is still being confirmed'
      : '$count swaps are still being confirmed';

  static String body(int count) {
    final it = count == 1 ? 'it' : 'them';
    return kBeamCoreSwapRestartSafe
        ? 'This usually takes under a minute. If you quit now, BEAM may '
              'cancel $it instead. Nothing is lost if it does.'
        : 'This usually takes under a minute. Quitting now can make $it '
              'run again.';
  }

  static const nodeTitle = 'Your private node is finishing a step';

  static String nodeBody(int percent) =>
      'It is tidying its data after syncing ($percent% done). If you quit '
      'now, it starts this step over the next time BEAM Campfire opens, '
      'which can take a while. Your wallet is not affected.';

  static const wait = 'Wait';
  static const quitAnyway = 'Quit anyway';
}

Future<bool>? _asking;

/// How far the app's private node is through a long maintenance step, or
/// null when it runs none ([BeamInProcessNode.finishingPercentNow]).
int? beamNodeFinishingStep() => BeamInProcessNode.finishingPercentNow;

/// Whether the app may quit now. Asks only while a swap is in flight;
/// without a context to ask through it never holds quitting hostage. A
/// second quit request while the question is open gets the same answer.
Future<bool> confirmBeamQuit(
  BuildContext? context, {
  BeamSwapsInFlight? swaps,
  int? Function()? nodeFinishing,
}) {
  final s = swaps ?? BeamSwapsInFlight.instance;
  final finishing = nodeFinishing ?? beamNodeFinishingStep;
  if (s.isEmpty && finishing() == null) return Future.value(true);
  if (context == null || !context.mounted) return Future.value(true);
  return _asking ??= () async {
    try {
      final quit = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BeamQuitDialog(swaps: s, nodeFinishing: finishing),
      );
      return quit ?? false; // Esc: stay
    } finally {
      _asking = null;
    }
  }();
}

/// The desktop Exit menu items: the same guarded, graceful path as the
/// window's close button and Cmd-Q (`didRequestAppExit` in main.dart).
Future<void> beamDesktopExit(BuildContext context) async {
  if (!await confirmBeamQuit(context)) return;
  await shutdownBeamChildren();
  exit(0);
}

class BeamQuitDialog extends StatefulWidget {
  const BeamQuitDialog({super.key, required this.swaps, this.nodeFinishing});

  final BeamSwapsInFlight swaps;

  /// The private node's long step, if one runs ([beamNodeFinishingStep]).
  final int? Function()? nodeFinishing;

  @override
  State<BeamQuitDialog> createState() => _BeamQuitDialogState();
}

class _BeamQuitDialogState extends State<BeamQuitDialog> {
  StreamSubscription<void>? _sub;
  Timer? _nodePoll;
  late int _count = widget.swaps.count;
  late int? _finishing = widget.nodeFinishing?.call();
  bool _closed = false;

  void _close(bool quit) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(quit);
  }

  @override
  void initState() {
    super.initState();
    _sub = widget.swaps.changes.listen((_) => _onChange());
    final finishing = widget.nodeFinishing;
    if (finishing != null && _finishing != null) {
      _nodePoll = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _closed) return;
        final f = finishing();
        if (f == _finishing) return;
        _finishing = f;
        _onChange(force: true);
      });
    }
    // settled between the check and this dialog
    if (widget.swaps.isEmpty && _finishing == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
    }
  }

  void _onChange({bool force = false}) {
    if (!mounted || _closed) return;
    final n = widget.swaps.count;
    if (n == 0 && _finishing == null) {
      _close(true);
    } else if (n != _count || force) {
      setState(() => _count = n);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _nodePoll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DesktopDialog(
      maxWidth: 520,
      maxHeight: null,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _count > 0
                  ? BeamQuitText.title(_count)
                  : BeamQuitText.nodeTitle,
              key: const Key('beamQuitTitle'),
              style: STextStyles.desktopH3(context),
            ),
            const SizedBox(height: 16),
            Text(
              [
                if (_count > 0) BeamQuitText.body(_count),
                if (_finishing != null) BeamQuitText.nodeBody(_finishing!),
              ].join('\n\n'),
              key: const Key('beamQuitBody'),
              style: STextStyles.desktopTextSmall(context),
            ),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: SecondaryButton(
                    key: const Key('beamQuitAnyway'),
                    label: BeamQuitText.quitAnyway,
                    onPressed: () => _close(true),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: PrimaryButton(
                    key: const Key('beamQuitWait'),
                    label: BeamQuitText.wait,
                    onPressed: () => _close(false),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
