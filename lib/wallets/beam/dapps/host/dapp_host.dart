/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../wallet/impl/beam_wallet.dart';
import '../dapp_installer.dart';
import 'beam_wallet_dapp_link.dart';
import 'dapp_approval_presenter.dart';
import 'dapp_package_fetcher.dart';
import 'dapp_watched_consent_queue.dart';
import 'dapp_wallet_link.dart';

/// Everything the dApp screens of one wallet share: one approval queue (so
/// only one approval is ever on screen, whichever dApp asks), the
/// installer, and the package fetcher.
class DappHost {
  DappHost({required this.wallet, required this.fetcher, this.walletId});

  static final Map<String, DappHost> _byWallet = {};

  /// The host of [beamWallet], created on first use.
  static DappHost of(BeamWallet beamWallet) =>
      _byWallet[beamWallet.walletId] ??= DappHost(
        wallet: BeamWalletDappLink(beamWallet),
        fetcher: DappPackageFetcher.campfire(),
        walletId: beamWallet.walletId,
      );

  final DappWalletLink wallet;
  final DappPackageFetcher fetcher;

  /// The Campfire wallet these dApps belong to, for its settings (the fiat
  /// currency); null in tests.
  final String? walletId;

  late final DappApprovalPresenter presenter = DappApprovalPresenter(wallet);

  late final DappWatchedConsentQueue consent = DappWatchedConsentQueue(
    presenter,
  );

  DappInstaller? _installer;

  /// The installer for this wallet's dApps.
  Future<DappInstaller> installer() async =>
      _installer ??= DappInstaller(await wallet.dappsRoot());
}
