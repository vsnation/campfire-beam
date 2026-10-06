/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The Send screen's model and its production backend over a REAL
// BeamWallet: a fake host whose sessions run on FakeTransport, a fake
// explorer, fake secure storage and a real Isar (beam_wallet_test_support).
// Proves, at the wallet-api level, that preparing never broadcasts
// (no tx_send, no process_invoke_data) and that sending happens once.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:isar_community/isar.dart';
import 'package:path/path.dart' as p;
import 'package:stackwallet/db/isar/main_db.dart';
import 'package:stackwallet/utilities/flutter_secure_storage_interface.dart';
import 'package:stackwallet/wallets/beam/api/beam_api.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_recipient.dart';
import 'package:stackwallet/wallets/beam/node/beam_private_node_coordinator.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_environment.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_errors.dart';
import 'package:stackwallet/wallets/beam/wallet/beam_wallet_services.dart';
import 'package:stackwallet/wallets/crypto_currency/crypto_currency.dart';
import 'package:stackwallet/wallets/isar/models/wallet_info.dart';
import 'package:stackwallet/wallets/wallet/impl/beam_wallet.dart';
import 'package:stackwallet/wallets/wallet/wallet.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_backend.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_model.dart';
import 'package:stackwallet/widgets/beam/send/beam_send_review.dart';

import '../contracts/bans/bans_fixtures.dart';
import '../core/fixtures.dart';
import '../wallet/beam_wallet_test_support.dart';
import 'send_ui_support.dart'
    show syncRepoShader, vectorAddress, g, kTip, openTestMainDbShared;

const _myAddr =
    '1111111111111111111111111111111111111111111111111111111111111111aa';

class _Core {
  Map<String, Object?> status = statusJson(
    height: kTip,
    available: g(0.05),
    extraTotals: [totalsJson(174, available: g(7))],
  );

  /// `view_name` answers by name; a fixture name or an output string.
  final Map<String, String> names = {'beam': 'view_name_beam'};

  Map<String, Object?> replies() => {
    'ev_subunsub': true,
    'wallet_status': (Map<String, Object?> _) => status,
    'addr_list': (Map<String, Object?> _) => [ownAddressJson(_myAddr)],
    'tx_list': (Map<String, Object?> _) => <Object?>[],
    'validate_address': (Map<String, Object?> params) => {
      'is_valid': true,
      'is_mine': false,
      'type': 'regular',
    },
    'calc_change': fixtureEnvelope('calc_change'),
    'generate_tx_id': (Map<String, Object?> _) => 'fe' * 16,
    'tx_send': (Map<String, Object?> params) => {'txId': params['txId']},
    'invoke_contract': (Map<String, Object?> params) {
      final args = params['args']! as String;
      final action = RegExp(r'action=([a-z_]+)').firstMatch(args)!.group(1)!;
      final name = RegExp(r'name=([^,]*)').firstMatch(args)?.group(1);
      return switch (action) {
        'view_params' => bansEnvelope('view_params'),
        'pay' => bansEnvelope('pay_beam'),
        'view_name' => bansEnvelope(names[name] ?? 'view_name_free'),
        _ => throw StateError('no fixture for $args'),
      };
    },
    'process_invoke_data': (Map<String, Object?> _) => {'txid': 'ee' * 16},
  };
}

void main() {
  late Directory tmp;
  late Isar isar;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('beam_send_backend_test_');
    isar = await openTestMainDbShared(
      Directory(p.join(tmp.path, 'isar'))..createSync(recursive: true),
    );
  });

  tearDownAll(() async {
    await isar.close(deleteFromDisk: true);
    await tmp.delete(recursive: true);
  });

  late _Core core;
  late FakeBeamHost host;
  late FakeExplorer explorer;
  final created = <BeamWallet>[];

  setUp(() async {
    final root = (await Directory(
      p.join(tmp.path, 'root-${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true)).path;
    core = _Core();
    host = FakeBeamHost(replies: core.replies);
    explorer = FakeExplorer(kTip);
    BeamWalletEnvironment.instance = BeamWalletEnvironment(
      beamRoot: () async => root,
      createHost: (_) => host,
      createExplorer: () => explorer,
      privateNodeSetting: const BeamFixedPrivateNodeSetting(false),
      explorerPollInterval: const Duration(milliseconds: 200),
      statusPollInterval: const Duration(hours: 1),
      eventDebounce: const Duration(milliseconds: 20),
      privateNodeStartDelay: Duration.zero,
      log: (_) {},
    );
  });

  tearDown(() async {
    for (final w in created) {
      await w.exit();
    }
    created.clear();
  });

  Future<BeamWallet> ready() async {
    final info = WalletInfo.createNew(
      coin: Beam(CryptoCurrencyNetwork.main),
      name: 'beam send test',
    );
    final wallet = await Wallet.create(
      walletInfo: info,
      mainDB: MainDB.instance,
      secureStorageInterface: FakeSecureStorage(),
      nodeService: FakeNodeService(
        beamTestNode('eu-nodes.mainnet.beam.mw', 8100),
      ),
      prefs: FakePrefs(),
      mnemonic: bip39.generateMnemonic(),
      mnemonicPassphrase: '',
    ) as BeamWallet;
    created.add(wallet);
    await wallet.init();
    await wallet.open();
    await wallet.whenCanSend.timeout(const Duration(seconds: 5));
    await wallet.whenLive.timeout(const Duration(seconds: 5));
    return wallet;
  }

  /// The production backend, with the BANS service the app builds
  /// (BeamWalletServices: the wallet's current transport) but the pinned
  /// shader read from the repo instead of the app bundle.
  BeamWalletSendBackend backendFor(BeamWallet w) => BeamWalletSendBackend(
    w,
    bans: BeamBansService(
      BeamApi(BeamWalletTransport(() => w.coreApi)),
      null,
      shader: syncRepoShader(),
    ),
  );

  Future<void> resolved(BeamSendModel m) =>
      waitFor(() => m.nameState is BansRecipientPayable, what: 'the name card');

  test('balances come from the wallet cache, BEAM and assets', () async {
    final w = await ready();
    final b = backendFor(w);
    expect(b.spendable(), {0: g(0.05), 174: g(7)});
    expect(b.asset(174).symbol, 'FOMO');
    expect(b.syncAssessment.canSpend, isTrue);
  });

  test('to an address: prepare validates and prices, never broadcasts; '
      'send goes out once', () async {
    final w = await ready();
    final m = BeamSendModel(backendFor(w), nameDebounce: Duration.zero);
    addTearDown(m.dispose);
    m.setRecipient(vectorAddress('regular'));
    m.setAmountText('0.01', 'en_US');
    m.comment = 'for lunch';
    expect(m.canReview, isTrue);

    final review = await m.prepare(w.cryptoCurrency);
    final t = host.lastTransport!;
    expect(t.callsTo('validate_address'), hasLength(1));
    expect(t.callsTo('tx_send'), isEmpty, reason: 'prepare never sends');
    expect(review.amount, g(0.01));
    expect(review.fee, BigInt.from(100000));
    expect(w.isBusy, isTrue, reason: 'the node switch waits for confirm');

    final txId = await review.send();
    expect(txId, 'fe' * 16);
    expect(t.callsTo('tx_send'), hasLength(1));
    final sent = t.lastParams('tx_send');
    expect(sent['value'], g(0.01).toInt());
    expect(sent['fee'], 100000);
    expect(sent['comment'], 'for lunch');
    expect(w.isBusy, isFalse);

    await expectLater(review.send(), throwsA(isA<BeamWalletException>()));
    expect(t.callsTo('tx_send'), hasLength(1), reason: 'never twice');
  });

  test('to a name: built and decoded without broadcasting; executed once, '
      'after resolving once more', () async {
    final w = await ready();
    final m = BeamSendModel(backendFor(w), nameDebounce: Duration.zero);
    addTearDown(m.dispose);
    m.setRecipient('beam');
    await resolved(m);
    m.setAmountText('0.00012345', 'en_US');
    expect(m.canReview, isTrue);

    final review = await m.prepare(w.cryptoCurrency);
    final t = host.lastTransport!;
    expect(t.callsTo('process_invoke_data'), isEmpty);
    expect(t.callsTo('tx_send'), isEmpty);
    expect(review.kind, BeamSendKind.name);
    expect(review.amount, BigInt.from(12345));
    expect(review.fee, BigInt.from(1100000), reason: 'decoded from pay_beam');
    expect(review.ownerKey, beamOwnerKey);
    expect(w.isBusy, isTrue, reason: 'held while the payment is on screen');

    expect(await review.send(), 'ee' * 16);
    expect(t.callsTo('process_invoke_data'), hasLength(1));
    expect(t.lastParams('process_invoke_data')['data'], bansRaw('pay_beam'));
    expect(w.isBusy, isFalse);
  });

  test('the name changes owner before signing: refused, nothing sent, the '
      'hold released', () async {
    final w = await ready();
    final m = BeamSendModel(backendFor(w), nameDebounce: Duration.zero);
    addTearDown(m.dispose);
    m.setRecipient('beam');
    await resolved(m);
    m.setAmountText('0.00012345', 'en_US');
    final review = await m.prepare(w.cryptoCurrency);

    core.names['beam'] = 'view_name_listed';
    await expectLater(review.send(), throwsA(isA<BansOwnerChanged>()));
    final t = host.lastTransport!;
    expect(t.callsTo('process_invoke_data'), isEmpty);
    expect(review.canRetry, isTrue, reason: 'nothing went out');
    review.dispose();
    expect(w.isBusy, isFalse);
  });

  test('the owner changes between the card and building: refused before '
      'anything is built', () async {
    final w = await ready();
    final m = BeamSendModel(backendFor(w), nameDebounce: Duration.zero);
    addTearDown(m.dispose);
    m.setRecipient('beam');
    await resolved(m);
    m.setAmountText('0.00012345', 'en_US');
    core.names['beam'] = 'view_name_listed';
    await expectLater(
      m.prepare(w.cryptoCurrency),
      throwsA(isA<BansOwnerChanged>()),
    );
    final actions = [
      for (final c in host.lastTransport!.callsTo('invoke_contract'))
        RegExp(r'action=([a-z_]+)')
            .firstMatch(c.params['args']! as String)!
            .group(1),
    ];
    expect(actions, isNot(contains('pay')));
    expect(w.isBusy, isFalse);
    expect(
      BeamSendModel.describeError(BansOwnerChanged('beam', 'a', 'b')),
      contains('beam.beam changed owner just now, so nothing was sent'),
    );
  });

  test('a wallet that falls behind cannot send what it prepared', () async {
    final w = await ready();
    final b = backendFor(w);
    final m = BeamSendModel(b, nameDebounce: Duration.zero);
    addTearDown(m.dispose);
    m.setRecipient(vectorAddress('regular'));
    m.setAmountText('0.01', 'en_US');
    final review = await m.prepare(w.cryptoCurrency);

    explorer.height = kTip + 100;
    await waitFor(() => !w.canSpend, what: 'falls behind');
    expect(m.canReview, isFalse);
    expect(m.syncMessage, isNotNull);
    await expectLater(
      review.send(),
      throwsA(
        isA<BeamWalletException>().having(
          (e) => e.problem,
          'problem',
          BeamWalletProblem.notSynced,
        ),
      ),
    );
    expect(host.lastTransport!.callsTo('tx_send'), isEmpty);
    review.dispose();
    expect(jsonEncode(b.spendable().keys.toList()), '[0,174]');
  });

  test('BeamSendReview never retries a payment whose outcome is unknown', () {
    expect(
      BeamSendReview.isOutcomeUnknown(
        const BeamWalletException(BeamWalletProblem.sendOutcomeUnknown, 'x'),
      ),
      isTrue,
    );
    expect(BeamSendReview.isOutcomeUnknown(TimeoutException('x')), isTrue);
    expect(
      BeamSendReview.isOutcomeUnknown(BansOwnerChanged('beam', 'a', 'b')),
      isFalse,
    );
  });

  test('beamCheckCanSpend says why in plain words', () async {
    final w = await ready();
    explorer.height = kTip + 100;
    await waitFor(() => !w.canSpend, what: 'falls behind');
    expect(
      () => beamCheckCanSpend(backendFor(w)),
      throwsA(
        isA<BeamWalletException>().having(
          (e) => e.message,
          'message',
          contains('Sending is'),
        ),
      ),
    );
  });
}
