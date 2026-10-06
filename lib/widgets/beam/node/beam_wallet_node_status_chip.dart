/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../pages/beam/node/beam_node_sync_view.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../wallets/beam/node/beam_node_panel_model.dart';
import '../../../wallets/beam/node/beam_node_panel_source.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import 'beam_node_widgets.dart';

/// [BeamNodeStatusChip] for one BEAM wallet, live, opening the node panel
/// when tapped. Drop it next to a balance or in an app bar:
///
/// ```dart
/// BeamWalletNodeStatusChip(walletId: walletId)
/// ```
///
/// Shows nothing for a wallet of another coin.
class BeamWalletNodeStatusChip extends ConsumerStatefulWidget {
  const BeamWalletNodeStatusChip({
    super.key,
    required this.walletId,
    this.onTap,
  });

  final String walletId;

  /// Defaults to opening the node panel.
  final VoidCallback? onTap;

  @override
  ConsumerState<BeamWalletNodeStatusChip> createState() =>
      _BeamWalletNodeStatusChipState();
}

class _BeamWalletNodeStatusChipState
    extends ConsumerState<BeamWalletNodeStatusChip> {
  BeamNodePanelSource? _source;
  StreamSubscription<BeamNodePanelSnapshot>? _sub;
  BeamNodePanelSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    final wallet = ref.read(pWallets).getWallet(widget.walletId);
    if (wallet is! BeamWallet) return;
    final source = BeamWalletNodePanelSource(
      wallet,
      pollInterval: const Duration(seconds: 2),
    );
    _source = source;
    _snapshot = source.current;
    _sub = source.changes.listen((s) {
      if (mounted) setState(() => _snapshot = s);
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _source?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _snapshot;
    if (s == null) return const SizedBox.shrink();
    return BeamNodeStatusChip.fromView(
      BeamNodePanelModel.describe(s),
      onTap:
          widget.onTap ??
          () => unawaited(showBeamNodeSync(context, walletId: widget.walletId)),
    );
  }
}
