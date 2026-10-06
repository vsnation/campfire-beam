/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/theme_providers.dart';
import 'beam_tx_view.dart';

/// Campfire's send / receive icon (from the active theme, like `TxIcon`),
/// chosen from the BEAM status: `TxIcon` decides "pending" by block height,
/// which would show a failed or cancelled BEAM payment as still pending.
class BeamTxIcon extends ConsumerWidget {
  const BeamTxIcon({super.key, required this.view});

  final BeamTxView view;

  static const Size size = Size(32, 32);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(themeAssetsProvider);
    final stopped = view.isFailed || view.isCancelled;
    final waiting = view.isInFlight;
    final String name;
    if (view.isIncoming) {
      name = stopped
          ? assets.receiveCancelled
          : waiting
          ? assets.receivePending
          : assets.receive;
    } else {
      name = stopped
          ? assets.sendCancelled
          : waiting
          ? assets.sendPending
          : assets.send;
    }
    return SizedBox(
      width: size.width,
      height: size.height,
      child: Center(
        child: name.startsWith('assets')
            ? SvgPicture.asset(name, width: size.width, height: size.height)
            : SvgPicture.file(
                File(name),
                width: size.width,
                height: size.height,
              ),
      ),
    );
  }
}
