/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Which wallet the side menu's Swap page acts on. Unlike the other BEAM
// pages it also takes Ethereum wallets: a BEAM wallet swaps on BEAM's DEX,
// an Ethereum wallet on Uniswap (owner, 2026-10-09: "When selected ETH
// wallet, you show DEX that is from uniswap").
//
// The rule is the BEAM pages' rule (`resolveBeamSidebarWallet`): the
// wallet open in My Campfire or picked here (remembered between runs);
// else the only one; else the only one running; else the page asks.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../db/hive/db.dart';
import '../../../providers/global/active_wallet_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../utilities/logger.dart';
import '../../../wallets/isar/providers/all_wallets_info_provider.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';
import '../../../wallets/wallet/impl/ethereum_wallet.dart';
import '../../../wallets/wallet/wallet.dart';
import 'beam_sidebar.dart';

/// BEAM wallets (as the BEAM pages list them), then Ethereum wallets in
/// My Campfire's order.
final pSwapSidebarWallets = Provider<List<Wallet>>((ref) {
  final beam = ref.watch(pBeamSidebarWallets);
  final infos = ref.watch(pAllWalletsInfo);
  final eth = {
    for (final w in ref.watch(pWallets).wallets)
      if (w is EthereumWallet) w.walletId: w,
  };
  return [
    ...beam,
    for (final info in infos)
      if (eth[info.walletId] case final EthereumWallet w) w,
  ];
});

/// With no Ethereum wallet the Swap page is the BEAM DEX exactly as before
/// (its own wallet chip, picker and memory).
final pSwapHasEthereum = Provider<bool>(
  (ref) => ref.watch(pSwapSidebarWallets).any((w) => w is EthereumWallet),
);

class SwapSidebarWalletChoice extends StateNotifier<String?> {
  SwapSidebarWalletChoice() : super(_read());

  static const key = 'swapSidebarWalletId';

  static String? _read() {
    try {
      final v = DB.instance.get<dynamic>(boxName: DB.boxNamePrefs, key: key);
      return v is String ? v : null;
    } catch (_) {
      return null;
    }
  }

  void choose(String walletId) {
    if (state == walletId) return;
    state = walletId;
    unawaited(() async {
      try {
        await DB.instance.put<dynamic>(
          boxName: DB.boxNamePrefs,
          key: key,
          value: walletId,
        );
      } catch (e) {
        Logging.instance.w('Swap page: could not remember the wallet: $e');
      }
    }());
  }
}

final pSwapSidebarWalletChoice =
    StateNotifierProvider<SwapSidebarWalletChoice, String?>((ref) {
      final choice = SwapSidebarWalletChoice();
      ref.listen<String?>(currentWalletIdProvider, (_, id) {
        if (id != null &&
            ref.read(pSwapSidebarWallets).any((w) => w.walletId == id)) {
          choice.choose(id);
        }
      }, fireImmediately: true);
      return choice;
    });

class SwapSidebarWalletContext {
  const SwapSidebarWalletContext({required this.wallets, this.wallet});

  final List<Wallet> wallets;
  final Wallet? wallet;

  bool get hasWallets => wallets.isNotEmpty;
  bool get canSwitch => wallets.length > 1;
}

final pSwapSidebarWallet = Provider<SwapSidebarWalletContext>((ref) {
  final wallets = ref.watch(pSwapSidebarWallets);
  final chosen =
      ref.watch(pSwapSidebarWalletChoice) ??
      ref.watch(pBeamSidebarWalletChoice);
  return SwapSidebarWalletContext(
    wallets: wallets,
    wallet:
        resolveBeamSidebarWallet<Wallet>(
          wallets: wallets,
          idOf: (w) => w.walletId,
          isOpen: (w) => w is BeamWallet ? w.isOpen : false,
          chosenId: chosen,
        ) ??
        (wallets.isEmpty ? null : wallets.first),
  );
});

/// Picks [walletId] on the Swap page; a BEAM wallet becomes the BEAM pages'
/// wallet too.
void chooseSwapSidebarWallet(WidgetRef ref, String walletId) {
  ref.read(pSwapSidebarWalletChoice.notifier).choose(walletId);
  if (ref.read(pBeamSidebarWallets).any((w) => w.walletId == walletId)) {
    ref.read(pBeamSidebarWalletChoice.notifier).choose(walletId);
  }
}
