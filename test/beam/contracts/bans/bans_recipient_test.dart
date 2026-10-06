/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_exceptions.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_models.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_name.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_recipient.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_service.dart';
import 'package:stackwallet/wallets/beam/contracts/bans/bans_timeline.dart';
import 'package:stackwallet/wallets/beam/models/beam_address.dart';

const _key =
    '72e368c016bec94e0aa0274aae5b6e9ef4bbb64d0ce1436acb134488570d51ef01';
const _tip = 4068300;

BansResolution _res(
  String name, {
  int? expire,
  bool inSync = true,
}) => BansResolution(
  name: BansName(name),
  domain: expire == null
      ? null
      : BansDomain(name: name, ownerKey: _key, expireHeight: expire),
  tipHeight: _tip,
  tipTime: DateTime.utc(2026, 10, 6),
  walletInSync: inSync,
);

void main() {
  group('classify', () {
    final vectors =
        jsonDecode(
              File(
                'test/beam/fixtures/beam_core_address_vectors.json',
              ).readAsStringSync(),
            )
            as Map;

    test('every BEAM address type stays an address', () {
      for (final v in vectors['valid'] as List) {
        final address = (v as Map)['address'] as String;
        final input = BeamRecipientInput.classify(address);
        expect(input, isA<BeamRecipientAddress>(), reason: '${v['type']}');
      }
    });

    test('a name, with or without @ and .beam, in any case', () {
      for (final text in ['alice', '@alice', 'Alice.beam', ' ALICE ']) {
        final input = BeamRecipientInput.classify(text);
        expect(input, isA<BeamRecipientName>(), reason: text);
        expect((input as BeamRecipientName).name.value, 'alice');
      }
    });

    test('a 64-hex string that is a valid address is never a name', () {
      final hex = (vectors['valid'] as List)
          .cast<Map<String, Object?>>()
          .map((v) => v['address'] as String)
          .firstWhere((a) => RegExp(r'^[0-9a-f]+$').hasMatch(a));
      expect(BeamRecipientInput.classify(hex), isA<BeamRecipientAddress>());
    });

    test('neither address nor name says why', () {
      final bad = BeamRecipientInput.classify('al');
      expect(bad, isA<BeamRecipientInvalid>());
      expect(
        (bad as BeamRecipientInvalid).nameProblem,
        BansNameProblem.tooShort,
      );
      expect(BeamRecipientInput.classify('   '), isA<BeamRecipientEmpty>());
    });
  });

  group('resolver', () {
    Future<List<BansRecipientState?>> run(
      BansRecipientResolver r,
      void Function() act,
    ) async {
      final seen = <BansRecipientState?>[];
      final sub = r.states.listen(seen.add);
      act();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await sub.cancel();
      return seen;
    }

    test('an active name is payable and shows its owner', () async {
      final r = BansRecipientResolver(
        (n) async => _res(n.value, expire: _tip + 1000),
        debounce: const Duration(milliseconds: 10),
      );
      final seen = await run(r, () => r.input('alice'));
      expect(seen.first, isA<BansRecipientResolving>());
      final last = seen.last! as BansRecipientPayable;
      expect(last.ownerFingerprint, '72e3…ef01');
      expect(last.onHold, isFalse);
      expect(last.maybeStale, isFalse);
      await r.dispose();
    });

    test('a name in its hold is payable with a warning', () async {
      final r = BansRecipientResolver(
        (n) async => _res(n.value, expire: _tip - 10),
        debounce: const Duration(milliseconds: 10),
      );
      final last = (await run(r, () => r.input('alice'))).last!;
      expect((last as BansRecipientPayable).onHold, isTrue);
      await r.dispose();
    });

    test('an unregistered or lapsed name is not payable', () async {
      final r = BansRecipientResolver(
        (n) async => _res(n.value),
        debounce: const Duration(milliseconds: 10),
      );
      final last = (await run(r, () => r.input('nobody-here'))).last!;
      expect(last, isA<BansRecipientNotPayable>());
      expect(
        (last as BansRecipientNotPayable).status,
        BansNameStatus.available,
      );
      await r.dispose();
    });

    test('an answer read while out of sync is marked stale', () async {
      final r = BansRecipientResolver(
        (n) async => _res(n.value, expire: _tip + 1000, inSync: false),
        debounce: const Duration(milliseconds: 10),
      );
      final last = (await run(r, () => r.input('alice'))).last!;
      expect((last as BansRecipientPayable).maybeStale, isTrue);
      await r.dispose();
    });

    test('a slow answer for old text never replaces the newest', () async {
      final slow = Completer<BansResolution>();
      final r = BansRecipientResolver((n) {
        if (n.value == 'alice') return slow.future;
        return Future.value(_res(n.value, expire: _tip + 1000));
      }, debounce: const Duration(milliseconds: 5));
      final seen = <BansRecipientState?>[];
      final sub = r.states.listen(seen.add);
      r.input('alice');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.input('bob');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      slow.complete(_res('alice', expire: _tip + 1000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final finals = seen.whereType<BansRecipientPayable>().toList();
      expect(finals.map((s) => s.name.value), ['bob']);
      await sub.cancel();
      await r.dispose();
    });

    test('an address or nothing clears the card', () async {
      final r = BansRecipientResolver(
        (n) async => _res(n.value, expire: _tip + 1000),
        debounce: const Duration(milliseconds: 5),
      );
      final seen = await run(r, () => r.input(''));
      expect(seen, [null]);
      await r.dispose();
    });

    test('a failed lookup is reported, not swallowed', () async {
      final r = BansRecipientResolver(
        (n) async => throw StateError('node unreachable'),
        debounce: const Duration(milliseconds: 5),
      );
      final last = (await run(r, () => r.input('alice'))).last!;
      expect(last, isA<BansRecipientFailed>());
      await r.dispose();
    });
  });

  test('BeamAddressType is the models enum', () {
    expect(BeamAddressType.regular.name, 'regular');
  });
}
