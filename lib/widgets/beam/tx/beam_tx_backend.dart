/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar_community/isar.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../../providers/db/main_db_provider.dart';
import '../../../providers/global/locale_provider.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../providers/global/price_provider.dart';
import '../../../providers/global/wallets_provider.dart';
import '../../../utilities/block_explorers.dart';
import '../../../utilities/util.dart';
import '../../../wallets/beam/api/beam_api.dart';
import '../../../wallets/beam/models/beam_transaction.dart';
import '../../../wallets/beam/wallet/beam_wallet_services.dart';
import '../../../wallets/wallet/impl/beam_wallet.dart';

/// What the BEAM history and details screens need from the rest of the
/// app, in one place, so the screens never reach into globals and tests
/// can hand them a fake core (`FakeTransport`) instead.
class BeamTxBackend {
  const BeamTxBackend({
    required this.api,
    required this.refresh,
    required this.forget,
    required this.watch,
    required this.explorerUri,
    required this.openUrl,
    required this.share,
    required this.skipExplorerWarning,
    required this.setSkipExplorerWarning,
  });

  /// The wallet's core API, through `BeamWalletServices` so calls follow
  /// public ↔ private node handovers. Null when this is not a BEAM wallet.
  final BeamApi? Function() api;

  /// The wallet's own refresh path (balance, addresses and history).
  final Future<void> Function() refresh;

  /// Drops Campfire's cached record of [txid] once the core deleted it.
  /// The wallet's sync only adds and updates records, so without this a
  /// deleted transaction would stay on screen.
  final Future<void> Function(String txid) forget;

  /// The cached record of a transaction as it changes; null once removed.
  final Stream<TransactionV2?> Function(String txid) watch;
  final Uri Function(String kernelId) explorerUri;
  final Future<bool> Function(Uri uri) openUrl;
  final Future<void> Function(String text) share;
  final bool Function() skipExplorerWarning;
  final void Function(bool skip) setSkipExplorerWarning;
}

/// The app's [BeamTxBackend] for [walletId].
final pBeamTxBackend = Provider.family<BeamTxBackend, String>((ref, walletId) {
  final db = ref.watch(mainDBProvider);
  final wallets = ref.watch(pWallets);
  final wallet = wallets.getWallet(walletId);
  return BeamTxBackend(
    api: () => wallet is BeamWallet ? BeamWalletServices.of(wallet).api : null,
    refresh: wallet.refresh,
    forget: (txid) async {
      await beamForgetTransaction(db.isar, walletId: walletId, txid: txid);
    },
    watch: (txid) =>
        beamWatchTransaction(db.isar, walletId: walletId, txid: txid),
    explorerUri: (kernelId) => getBlockExplorerTransactionUrlFor(
      coin: wallet.cryptoCurrency,
      txid: kernelId,
    ),
    openUrl: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
    share: (text) async {
      await SharePlus.instance.share(ShareParams(text: text));
    },
    skipExplorerWarning: () =>
        ref.read(prefsChangeNotifierProvider).hideBlockExplorerWarning,
    setSkipExplorerWarning: (skip) =>
        ref.read(prefsChangeNotifierProvider).hideBlockExplorerWarning = skip,
  );
});

/// Removes Campfire's cached record of [txid]; returns how many went.
Future<int> beamForgetTransaction(
  Isar isar, {
  required String walletId,
  required String txid,
}) => isar.writeTxn(
  () => isar.transactionV2s
      .where()
      .txidWalletIdEqualTo(txid, walletId)
      .deleteAll(),
);

/// The cached record of [txid] now and after every change; null once gone.
Stream<TransactionV2?> beamWatchTransaction(
  Isar isar, {
  required String walletId,
  required String txid,
}) => isar.transactionV2s
    .where()
    .txidWalletIdEqualTo(txid, walletId)
    .watch(fireImmediately: true)
    .map((found) => found.isEmpty ? null : found.first);

/// Desktop or phone layout. Its own provider so a test on the desktop host
/// can render the phone layout.
final pBeamTxIsDesktop = Provider<bool>((_) => Util.isDesktop);

/// BEAM's fiat price for the history, when the user allows price lookups.
typedef BeamTxFiat = ({Decimal price, String currency, String locale});

final pBeamTxFiat = Provider.family<BeamTxFiat?, String>((ref, walletId) {
  final prefs = ref.watch(prefsChangeNotifierProvider);
  if (!prefs.externalCalls) return null;
  final coin = ref.watch(pWallets).getWallet(walletId).cryptoCurrency;
  final price = ref.watch(
    priceAnd24hChangeNotifierProvider.select((p) => p.getPrice(coin)?.value),
  );
  if (price == null) return null;
  return (
    price: price,
    currency: prefs.currency,
    locale: ref.watch(
      localeServiceChangeNotifierProvider.select((l) => l.locale),
    ),
  );
});

/// Key of [pBeamContractFunds].
typedef BeamTxKey = ({String walletId, String txid});

/// The per-asset funds of a contract call, read from the core once
/// (`tx_status` → `invoke_data`). Campfire's cache keeps only the BEAM part,
/// so a swap's other side comes from here. A contract call's funds never
/// change, so a successful answer is kept for the session; a failed one
/// (core still connecting) is retried the next time the entry is shown.
final pBeamContractFunds = FutureProvider.autoDispose
    .family<List<BeamAssetAmount>?, BeamTxKey>((ref, key) async {
      final api = ref.watch(pBeamTxBackend(key.walletId)).api();
      if (api == null) return null;
      try {
        final tx = await api.txStatus(key.txid);
        ref.maintainState = true;
        return List.unmodifiable(tx.invokeData.expand((i) => i.amounts));
      } catch (_) {
        return null;
      }
    });
