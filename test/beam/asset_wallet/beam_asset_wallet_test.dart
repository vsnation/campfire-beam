/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// BeamAssetWallet (a Confidential Asset as a Campfire token sub-wallet) on
// a real BeamWallet whose core is a FakeTransport answering from the
// sanitized fixtures: balance mapping, history filtering, receiving
// address, sends (fee in BEAM, refusals), the contract cache, hidden
// assets, valuation and the DEX read cache.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:stackwallet/models/isar/models/beam/beam_asset_contract.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/address.dart';
import 'package:stackwallet/models/isar/models/blockchain_data/v2/transaction_v2.dart';
import 'package:stackwallet/utilities/amount/amount.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_catalog.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_holdings.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_market_source.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_registry.dart';
import 'package:stackwallet/wallets/beam/assets/beam_asset_text.dart';
import 'package:stackwallet/wallets/beam/assets/beam_hidden_assets.dart';
import 'package:stackwallet/wallets/beam/models/beam_asset_info.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_connection_exception.dart';
import 'package:stackwallet/wallets/beam/rpc/beam_transport.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_tx_mapper.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/models/tx_data.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/impl/sub_wallets/beam_asset_wallet.dart';
import 'package:stackwallet/wallets/wallet/supporting/beam_wallet_info_extension.dart';

import 'asset_test_support.dart';

TxData _pay(String address, BigInt amount) => TxData(
  recipients: [
    TxRecipient(
      address: address,
      amount: Amount(rawValue: amount, fractionDigits: 8),
      isChange: false,
      addressType: AddressType.mimbleWimble,
    ),
  ],
);

Matcher _problem(BeamWalletProblem p, [Pattern? text]) =>
    isA<BeamWalletException>()
        .having((e) => e.problem, 'problem', p)
        .having(
          (e) => e.message,
          'message',
          text == null ? anything : contains(text),
        );

void main() {
  late Directory tmp;
  late Isar isar;

  setUpAll(() async {
    tmp = await tempRoot('beam_asset_wallet_test_');
    isar = await openAssetTestDb(Directory('${tmp.path}/isar'));
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  late AssetHarness h;
  late BeamWallet wallet;
  final opened = <BeamWallet>[];

  setUp(() async {
    final root = await Directory(
      '${tmp.path}/root-${DateTime.now().microsecondsSinceEpoch}',
    ).create(recursive: true);
    h = AssetHarness(root.path);
    wallet = await h.openWallet();
    opened.add(wallet);
  });

  tearDown(() async {
    for (final w in opened) {
      await w.exit();
    }
    opened.clear();
  });

  BeamAssetWallet assetWallet(int id) =>
      BeamAssetWallet.load(parent: wallet, asset: BeamAssetRegistry.build(id));

  group('BeamAssetContract', () {
    test('its address is the tag BeamTxMapper writes on the asset\'s '
        'transactions', () {
      expect(BeamAssetContract.addressFor(174), beamAssetTag(174));
      expect(BeamAssetContract.assetIdOf('beamAsset:174'), 174);
      expect(
        BeamAssetContract.assetIdOf(
          '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
        ),
        isNull,
      );
      expect(BeamAssetContract.assetIdOf('beamAsset:-1'), isNull);
    });

    test('every asset has 8 decimals; verified ones come from the '
        'catalogue with their bundled icon', () {
      final fomo = BeamAssetRegistry.build(174);
      expect(fomo.decimals, 8);
      expect(fomo.name, 'FOMO');
      expect(fomo.verified, isTrue);
      expect(fomo.iconAsset, 'assets/beam/icons/174.png');
      expect(fomo.isPoolShare, isFalse);
      // CROWN declares NTH_RATIO=1000; it is still shown with 8 decimals.
      expect(BeamAssetRegistry.build(4).decimals, BeamAssetInfo.beamDecimals);
    });
  });

  group('balance, history, receiving', () {
    test(
      'balance is the parent\'s cached totals, mapped like BEAM\'s',
      () async {
        h.core.receiving[174] = g(3);
        await wallet.refresh();
        final fomo = assetWallet(174);
        final available = fixtureAvailable()[174]!;
        expect(fomo.balance.spendable.raw, available);
        expect(fomo.balance.pendingSpendable.raw, g(3));
        expect(fomo.balance.total.raw, available + g(3));
        expect(fomo.balance.blockedTotal.raw, BigInt.zero);
        expect(fomo.balance.total.fractionDigits, 8);
        // An asset the wallet does not hold is zero, not an error.
        expect(assetWallet(4).balance.total.raw, BigInt.zero);
        // BEAM itself is still the parent's balance.
        expect(wallet.info.cachedBalance.spendable.raw, fixtureAvailable()[0]);
      },
    );

    test('history: each asset wallet sees only its asset; the BEAM history '
        'none of them', () async {
      Future<List<String>> ids(FilterOperation? f) async => [
        for (final t
            in await isar.transactionV2s
                // The query Campfire's generic history builds from a
                // wallet's transactionFilterOperation.
                // ignore: experimental_member_use
                .buildQuery<TransactionV2>(
                  whereClauses: [
                    IndexWhereClause.equalTo(
                      indexName: 'walletId',
                      value: [wallet.walletId],
                    ),
                  ],
                  filter: f,
                  sortBy: [
                    const SortProperty(property: 'txid', sort: Sort.asc),
                  ],
                )
                .findAll())
          t.txid,
      ];

      expect(await ids(assetWallet(174).transactionFilterOperation), [
        'a1' * 16,
        'a2' * 16,
      ]);
      expect(await ids(assetWallet(7).transactionFilterOperation), ['b1' * 16]);
      expect(await ids(wallet.transactionFilterOperation), ['c1' * 16]);
    });

    test('assets arrive at the parent\'s address', () async {
      final fomo = assetWallet(174);
      expect(fomo.walletId, wallet.walletId);
      expect(
        (await fomo.getCurrentReceivingAddress())?.value,
        (await wallet.getCurrentReceivingAddress())?.value,
      );
      expect(wallet.info.cachedReceivingAddress, testOwnAddress);
    });
  });

  group('sending', () {
    final payee = vectorAddress('regular');

    test('prepareSend prices in BEAM and never broadcasts', () async {
      final fomo = assetWallet(174);
      final tx = await fomo.prepareSend(txData: _pay(payee, g(12.5)));
      expect(tx.fee!.raw, BigInt.from(100000));
      expect(tx.recipients!.single.amount.raw, g(12.5));
      expect(jsonDecode(tx.otherData!), {
        'assetId': 174,
        'addressType': 'regular',
        'txId': 'fe' * 16,
      });
      expect(BeamAssetWallet.preparedTxId(tx), 'fe' * 16);
      expect(BeamAssetWallet.preparedAddressType(tx)?.wireName, 'regular');
      expect(h.core.calcChangeCalls.last['asset_id'], 174);
      expect(h.core.sent, isEmpty);
      expect(wallet.isBusy, isTrue, reason: 'node switch held until confirm');
      await fomo.exit();
      expect(wallet.isBusy, isFalse);
    });

    test('confirmSend sends the asset with tx_send and the BEAM fee', () async {
      final fomo = assetWallet(174);
      final tx = await fomo.prepareSend(txData: _pay(payee, g(12.5)));
      final done = await fomo.confirmSend(txData: tx);
      expect(done.txid, 'fe' * 16);
      final sent = h.core.sent.single;
      expect(sent['asset_id'], 174);
      expect(sent['value'], 1250000000);
      expect(sent['fee'], 100000);
      expect(sent['address'], payee);
      expect(sent['txId'], 'fe' * 16);
      expect(sent.containsKey('offline'), isFalse);
      expect(wallet.isBusy, isFalse);
    });

    group('one prepared payment, one payment (M-6)', () {
      test('the tx id is fixed at prepare: confirm sends that one, never '
          'a new one', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(12.5)));
        h.core.nextTxId = 'ab' * 16; // a new id would be this
        final done = await fomo.confirmSend(txData: tx);
        expect(h.core.sent.single['txId'], 'fe' * 16);
        expect(done.txid, 'fe' * 16);
      });

      test('outcome unknown: a second confirm of the same payment is looked '
          'up, never handed to tx_send again', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(12.5)));
        // The core took it, the reply was lost, and it cannot be asked.
        h.core.txSendThrows = const BeamConnectionException('reply lost');
        h.core.txStatusThrows = const BeamConnectionException('restarting');
        await expectLater(
          fomo.confirmSend(txData: tx),
          throwsA(
            _problem(
              BeamWalletProblem.sendOutcomeUnknown,
              'Check your transaction history',
            ),
          ),
        );
        expect(h.core.sent, hasLength(1));

        // Tapping Send again (or any caller retrying) while still unknown.
        h.core.txSendThrows = null;
        await expectLater(
          fomo.confirmSend(txData: tx),
          throwsA(
            _problem(
              BeamWalletProblem.sendOutcomeUnknown,
              'already handed to the wallet',
            ),
          ),
        );
        expect(h.core.sent, hasLength(1), reason: 'no second tx_send');

        // Once the core answers, the retry reports the one payment.
        h.core.txStatusThrows = null;
        final done = await fomo.confirmSend(txData: tx);
        expect(done.txid, 'fe' * 16);
        expect(h.core.sent, hasLength(1), reason: 'still one tx_send');
        expect(wallet.isBusy, isFalse);
      });

      test('a sent payment confirmed again is not sent again', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(1)));
        await fomo.confirmSend(txData: tx);
        final again = await fomo.confirmSend(txData: tx);
        expect(again.txid, 'fe' * 16);
        expect(h.core.sent, hasLength(1));
      });

      test('a plain refusal sent nothing, so the same payment may be tried '
          'again, with the same tx id', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(1)));
        h.core.txSendThrows = const BeamRpcException(-32603, 'Node busy');
        await expectLater(
          fomo.confirmSend(txData: tx),
          throwsA(_problem(BeamWalletProblem.sendRejected, 'not sent')),
        );
        h.core.txSendThrows = null;
        await fomo.confirmSend(txData: tx);
        expect(
          [for (final s in h.core.sent) s['txId']],
          ['fe' * 16, 'fe' * 16],
        );
      });

      test('the core already has the tx id (another screen sent it): '
          'reported as that payment, not as "not sent"', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(1)));
        h.core.txSendThrows = const BeamRpcException(
          -32602,
          'Provided transaction ID already exists in the wallet.',
        );
        final done = await assetWallet(174).confirmSend(txData: tx);
        expect(done.txid, 'fe' * 16);
        expect(h.core.sent, hasLength(1));
      });

      test('a payment without the prepared tx id is refused', () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(txData: _pay(payee, g(1)));
        final stripped = tx.copyWith(
          otherData: jsonEncode({'assetId': 174, 'addressType': 'regular'}),
        );
        await expectLater(
          fomo.confirmSend(txData: stripped),
          throwsA(_problem(BeamWalletProblem.other, 'not prepared')),
        );
        expect(h.core.sent, isEmpty);
      });
    });

    test(
      'an offline address: the 0.011 BEAM push fee and offline: true',
      () async {
        final fomo = assetWallet(174);
        final tx = await fomo.prepareSend(
          txData: _pay(vectorAddress('offline'), g(1)),
        );
        expect(tx.fee!.raw, BigInt.from(1100000));
        await fomo.confirmSend(txData: tx);
        expect(h.core.sent.single['offline'], isTrue);
        expect(h.core.sent.single['fee'], 1100000);
      },
    );

    test('no BEAM for the fee: refused before anything is built, with how '
        'much to add', () async {
      h.core.beamAvailable = BigInt.from(40000);
      await wallet.refresh();
      await expectLater(
        assetWallet(174).prepareSend(txData: _pay(payee, g(1))),
        throwsA(
          _problem(
            BeamWalletProblem.insufficientFunds,
            'Sending FOMO costs a 0.001 BEAM network fee, paid in BEAM. This '
            'wallet has 0.0004 BEAM available. Add at least 0.0006 BEAM '
            'first.',
          ),
        ),
      );
      expect(h.core.sent, isEmpty);
      expect(wallet.isBusy, isFalse);
    });

    test('other refusals are plain and send nothing', () async {
      final fomo = assetWallet(174);
      await expectLater(
        fomo.prepareSend(txData: _pay(payee, g(1000000))),
        throwsA(
          _problem(BeamWalletProblem.insufficientFunds, 'Not enough FOMO'),
        ),
      );
      await expectLater(
        fomo.prepareSend(txData: _pay(payee, BigInt.zero)),
        throwsA(_problem(BeamWalletProblem.invalidAmount)),
      );
      await expectLater(
        fomo.prepareSend(txData: _pay('hello', g(1))),
        throwsA(_problem(BeamWalletProblem.invalidAddress)),
      );
      // A payment prepared for FOMO cannot be sent as BeamX.
      final tx = await fomo.prepareSend(txData: _pay(payee, g(1)));
      await expectLater(
        assetWallet(7).confirmSend(txData: tx),
        throwsA(_problem(BeamWalletProblem.other, 'not prepared')),
      );
      await fomo.exit();
      // Not synced: the honest verdict says no.
      h.core.inSync = false;
      await wallet.refresh();
      await expectLater(
        fomo.prepareSend(txData: _pay(payee, g(1))),
        throwsA(_problem(BeamWalletProblem.notSynced)),
      );
      expect(h.core.sent, isEmpty);
    });

    test('a closed wallet says it is still connecting', () async {
      final fomo = assetWallet(174);
      await wallet.exit();
      await expectLater(
        fomo.prepareSend(txData: _pay(payee, g(1))),
        throwsA(_problem(BeamWalletProblem.notOpen)),
      );
    });
  });

  group('asset cache', () {
    test('names unverified assets from the chain, flags the copycat, and '
        'marks LP tokens from the DEX pools only', () async {
      final rows = await BeamAssetRegistry.sync(
        isar: isar,
        heldIds: wallet.info.beamAssetTotals.keys,
        api: wallet.coreApi,
        pools: recordedPools(),
      );
      expect(rows.containsKey(0), isFalse);
      expect(rows[pepeId]!.name, 'Pepe Coin');
      expect(rows[pepeId]!.symbol, 'PEPE');
      expect(rows[pepeId]!.verified, isFalse);
      expect(rows[pepeId]!.impersonates, isNull);
      expect(rows[fakeFomoId]!.symbol, 'FOMO');
      expect(rows[fakeFomoId]!.verified, isFalse);
      expect(rows[fakeFomoId]!.impersonates, 174);
      expect(rows[175]!.name, 'BEAM / FOMO pool share');
      expect(rows[175]!.isPoolShare, isTrue);
      expect((rows[175]!.poolAssetA, rows[175]!.poolAssetB), (0, 174));
      expect(rows[50]!.name, 'BEAM / BEAMX pool share');
      expect(rows[188]!.name, 'BEAM / CHAD pool share');
      expect(rows[174]!.verified, isTrue);
      // Icons as the BEAM desktop wallet draws them: bundled for verified
      // assets, the generic one for the id otherwise (never the creator's).
      expect(rows[174]!.iconAsset, 'assets/beam/icons/174.png');
      expect(rows[pepeId]!.iconAsset, BeamAssetCatalog.unverifiedIcon(pepeId));
      expect(rows[pepeId]!.color, BeamAssetCatalog.genericColor(pepeId));
      expect(rows[175]!.iconAsset, BeamAssetCatalog.unverifiedIcon(175));

      final cached = {
        for (final c in await isar.beamAssetContracts.where().findAll())
          c.assetId: c,
      };
      expect(cached[fakeFomoId]!.impersonates, 174);
      expect(cached[175]!.isPoolShare, isTrue);

      // Later, without the core or the DEX: what was learnt is kept.
      final again = await BeamAssetRegistry.sync(
        isar: isar,
        heldIds: wallet.info.beamAssetTotals.keys,
      );
      expect(again[pepeId]!.name, 'Pepe Coin');
      expect(again[175]!.isPoolShare, isTrue);
    });

    test('a name never makes an LP token, and a copycat pool side shows '
        'its number', () {
      final fake = BeamAssetRegistry.build(
        pepeId,
        metadata: BeamAssetInfo.fromJson({
          'asset_id': pepeId,
          'ownerId': 'dd' * 32,
          'isOwned': 0,
          'emission': 1,
          'metadata': 'STD:SCH_VER=1;N=Amm Liquidity Token 0-174-2;UN=AMML',
        }).metadata,
      );
      expect(fake.isPoolShare, isFalse);
      expect(fake.verified, isFalse);
      expect(BeamAssetRegistry.sideLabel(174, null), 'FOMO');
      expect(BeamAssetRegistry.sideLabel(pepeId, null), '#$pepeId');
    });
  });

  group('hidden assets', () {
    test('hide and show persist per wallet; BEAM is never hidden', () async {
      await BeamHiddenAssets.setHidden(
        info: wallet.info,
        isar: isar,
        assetId: pepeId,
        hidden: true,
      );
      await BeamHiddenAssets.setHidden(
        info: wallet.info,
        isar: isar,
        assetId: 0,
        hidden: true,
      );
      expect(BeamHiddenAssets.read(wallet.info), {pepeId});
      await BeamHiddenAssets.setHidden(
        info: wallet.info,
        isar: isar,
        assetId: pepeId,
        hidden: false,
      );
      expect(BeamHiddenAssets.read(wallet.info), isEmpty);
      // Totals written by the core afterwards leave the list alone.
      await BeamHiddenAssets.setHidden(
        info: wallet.info,
        isar: isar,
        assetId: fakeFomoId,
        hidden: true,
      );
      await wallet.refresh();
      expect(BeamHiddenAssets.read(wallet.info), {fakeFomoId});
    });
  });

  group('holdings and value', () {
    test('every held asset but BEAM, valued from the deepest pool, '
        'unpriced last and never zero', () {
      final market = BeamAssetMarket(recordedPools());
      final holdings = BeamAssetHoldings.build(
        totals: wallet.info.beamAssetTotals,
        contracts: const {},
        hidden: const {fakeFomoId},
        market: market,
      );
      final ids = holdings.map((e) => e.assetId).toList();
      expect(ids, isNot(contains(0)));
      expect(ids.toSet(), {
        6,
        7,
        50,
        174,
        175,
        186,
        187,
        188,
        189,
        pepeId,
        fakeFomoId,
      });
      // Priced first, by value; the two made-up assets have no pool.
      expect(ids.sublist(ids.length - 2), [pepeId, fakeFomoId]);
      final values = holdings
          .where((e) => e.priced)
          .map((e) => e.valueGroth!)
          .toList();
      expect(values, [...values]..sort((a, b) => b.compareTo(a)));
      expect(
        holdings.firstWhere((e) => e.assetId == 174).valueGroth,
        market.pricer.valueInGroth(174, fixtureAvailable()[174]!),
      );
      // LP tokens without a cached row are still recognised from the pools.
      expect(
        holdings.firstWhere((e) => e.assetId == 175).contract.isPoolShare,
        isTrue,
      );
      expect(
        holdings.firstWhere((e) => e.assetId == fakeFomoId).hidden,
        isTrue,
      );

      final portfolio = BeamAssetHoldings.portfolio(
        holdings,
        marketKnown: true,
      );
      expect(
        portfolio.unpriced,
        1,
        reason: 'the hidden copycat is not counted',
      );
      expect(portfolio.valueGroth, values.fold(BigInt.zero, (a, b) => a + b));
    });

    test('an asset with nothing left is not listed', () async {
      h.core.assets[pepeId] = BigInt.zero;
      await wallet.refresh();
      final holdings = BeamAssetHoldings.build(
        totals: wallet.info.beamAssetTotals,
        contracts: const {},
        hidden: const {},
      );
      expect(holdings.map((e) => e.assetId), isNot(contains(pepeId)));
      expect(holdings.every((e) => !e.priced), isTrue, reason: 'no market');
    });
  });

  group('DEX read cache', () {
    test(
      'one read per maxAge, forced re-read, a failure keeps the last',
      () async {
        var reads = 0;
        var fail = false;
        var now = DateTime(2026, 10, 6, 12);
        final source = BeamAssetMarketSource(() async {
          reads++;
          if (fail) throw StateError('core not connected');
          return recordedPools();
        }, now: () => now);

        final first = await source.read();
        await source.read();
        expect(reads, 1);
        now = now.add(const Duration(minutes: 3));
        await source.read();
        expect(reads, 2);
        await source.read(force: true);
        expect(reads, 3);
        fail = true;
        await expectLater(source.read(force: true), throwsStateError);
        expect(source.last, isNotNull);
        expect(source.last!.pools.length, first.pools.length);
      },
    );
  });

  group('text', () {
    test('estimates read like a person writes them, rounded down', () {
      expect(
        BeamAssetText.beamEstimate(g(1234.5678), locale: 'en_US'),
        '≈ 1,234.56 BEAM',
      );
      expect(
        BeamAssetText.beamEstimate(g(3.21499), locale: 'en_US'),
        '≈ 3.214 BEAM',
      );
      expect(
        BeamAssetText.beamEstimate(g(0.123456), locale: 'en_US'),
        '≈ 0.1234 BEAM',
      );
      expect(
        BeamAssetText.beamEstimate(BigInt.from(5), locale: 'en_US'),
        '< 0.0001 BEAM',
      );
      expect(
        BeamAssetText.beam(BigInt.from(100000), locale: 'en_US'),
        '0.001 BEAM',
      );
      final fomo = BeamAssetRegistry.build(174);
      String r(num v) => BeamAssetText.rounded(
        Amount(rawValue: g(v), fractionDigits: 8),
        fomo,
        locale: 'en_US',
      );
      expect(r(6477953.06387134), '6,477,953.06 FOMO');
      expect(r(568.12972897), '568.1297 FOMO');
      expect(r(0.46659234), '0.46659234 FOMO');
      expect(r(12.5), '12.5 FOMO');
      expect(
        BeamAssetText.exact(
          Amount(rawValue: g(12.5), fractionDigits: 8),
          fomo,
          locale: 'de_DE',
        ),
        '12,5 FOMO',
      );
      expect(
        BeamAssetText.impersonation(
          BeamAssetContract(
            address: BeamAssetContract.addressFor(fakeFomoId),
            assetId: fakeFomoId,
            name: 'FOMO',
            symbol: 'FOMO',
            decimals: 8,
            verified: false,
            metadataKnown: true,
            impersonates: 174,
          ),
        ),
        startsWith('Not the verified FOMO (#174).'),
      );
    });
  });
}
