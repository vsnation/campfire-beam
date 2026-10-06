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
import 'package:isar_community/isar.dart';

import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../providers/db/main_db_provider.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/constants.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/isar/providers/wallet_info_provider.dart';
import '../../../wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import '../../wallet_view/transaction_views/tx_v2/transaction_v2_list_item.dart';
import 'beam_asset_layout.dart';

/// One asset's history: the parent wallet's transactions tagged with the
/// asset (`BeamAssetWallet.transactionFilterOperation`), newest first, in
/// Campfire's own transaction rows. Reads the cache synchronously so the
/// list is there on the first frame (R11) and follows it as it changes.
class BeamAssetTransactionsList extends ConsumerStatefulWidget {
  const BeamAssetTransactionsList({
    super.key,
    required this.walletId,
    required this.assetWallet,
  });

  final String walletId;
  final BeamAssetWallet assetWallet;

  @override
  ConsumerState<BeamAssetTransactionsList> createState() => _State();
}

class _State extends ConsumerState<BeamAssetTransactionsList> {
  late final Query<TransactionV2> _query;
  late List<TransactionV2> _txs;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    // Same rows as BeamAssetWallet.transactionFilterOperation.
    _query = ref
        .read(mainDBProvider)
        .isar
        .transactionV2s
        .where()
        .walletIdEqualTo(widget.walletId)
        .filter()
        .contractAddressEqualTo(widget.assetWallet.tokenAddress)
        .sortByTimestampDesc()
        .build();
    _txs = _query.findAllSync();
    _sub = _query.watchLazy().listen((_) {
      if (!mounted) return;
      setState(() => _txs = _query.findAllSync());
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final coin = ref.watch(pWalletCoin(widget.walletId));
    if (_txs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No ${widget.assetWallet.tokenSymbol} payments yet. What you send '
          'or receive shows here.',
          key: const Key('beamAssetNoTransactions'),
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle(context),
        ),
      );
    }
    final r = Radius.circular(Constants.size.circularBorderRadius);
    BorderRadius? radius(int i) {
      if (_txs.length == 1) return BorderRadius.all(r);
      if (i == 0) return BorderRadius.only(topLeft: r, topRight: r);
      if (i == _txs.length - 1) {
        return BorderRadius.only(bottomLeft: r, bottomRight: r);
      }
      return null;
    }

    return RefreshIndicator(
      onRefresh: () async {
        if (!widget.assetWallet.refreshMutex.isLocked) {
          unawaited(widget.assetWallet.refresh());
        }
      },
      child: ListView.separated(
        itemCount: _txs.length,
        separatorBuilder: (context, _) => BeamAssetLayout.isDesktop(context)
            ? Container(
                height: 2,
                color: Theme.of(context).extension<StackColors>()!.background,
              )
            : const SizedBox.shrink(),
        itemBuilder: (context, i) =>
            TxListItem(tx: _txs[i], coin: coin, radius: radius(i)),
      ),
    );
  }
}
