/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge's Ethereum bytes, against values computed outside Dart:
//
// * calldata: the input of the real lock 0x8596…0684 (read from mainnet)
//   and Foundry's `cast calldata`;
// * the paid-flag storage keys: `cast index uint64 <id> <slot>`;
// * the receipt reader: that lock's real receipt (lock_fixture.dart), and
//   the same receipt changed one way at a time.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/bridge/bridge_routes.dart';
import 'package:stackwallet/wallets/bridge/bridge_sides.dart';
import 'package:stackwallet/wallets/ethereum/bridge/eth_pipe_calls.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';

import 'lock_fixture.dart';

Map<String, dynamic> fixture() => refReceipt();

List<Map<String, dynamic>> logsOf(Map<String, dynamic> r) =>
    (r['logs'] as List).cast<Map<String, dynamic>>();

EthPipeLock read(
  Map<String, dynamic> receipt, {
  BridgeRoute? route,
  String owner = refOwner,
  BigInt? value,
  BigInt? fee,
  Uint8List? key,
}) => decodeLockReceipt(
  route ?? bridgeRouteById('beam'),
  receipt,
  owner: owner,
  value: value ?? refValue,
  fee: fee ?? refFee,
  receiverKey: key ?? refKey,
);

Matcher refused() => throwsA(
  isA<BridgeException>().having(
    (e) => e.code,
    'code',
    BridgeErrorCode.unexpectedTransaction,
  ),
);

void main() {
  group('calldata', () {
    test('sendFunds is the real lock of msgId 222, byte for byte', () {
      // eth_getTransactionByHash(0x8596…0684).input, and `cast calldata
      // "sendFunds(uint256,uint256,bytes)" 10500000000 2000000 0x8332…01`.
      const input =
          '0x4d5dd2bc'
          '0000000000000000000000000000000000000000000000000000000271d94900'
          '00000000000000000000000000000000000000000000000000000000001e8480'
          '0000000000000000000000000000000000000000000000000000000000000060'
          '0000000000000000000000000000000000000000000000000000000000000021'
          '83324744834f22c9f113abed7abd2e9f69f339decec2e24aae2789dbd2fb307b'
          '0100000000000000000000000000000000000000000000000000000000000000';
      final data = sendFundsCall(refValue, refFee, refKey);
      expect(bytesToHex(data), input);
      expect(bytesToHex(data.sublist(0, 4)), kSendFundsSelector);
      expect(bytesToHex(selector(kBridgeSendFundsSignature)), '0x4d5dd2bc');
    });

    test('approve is an exact amount to the pipe', () {
      // cast calldata "approve(address,uint256)" <USDT pipe> 100000000
      expect(
        bytesToHex(
          erc20ApproveCall(
            bridgeRouteById('usdt').ethPipe,
            BigInt.from(100000000),
          ),
        ),
        '0x095ea7b3'
        '0000000000000000000000007c3fe09e86b0d8661d261a49bfa385536b7077f9'
        '0000000000000000000000000000000000000000000000000000000005f5e100',
      );
    });

    test('the selectors the freeze checks and the fork tests use', () {
      // cast sig
      expect(bytesToHex(selector('isBlackListed(address)')), '0xe47d6060');
      expect(bytesToHex(selector('basisPointsRate()')), '0xdd644f72');
      expect(bytesToHex(selector('paused()')), '0x5c975abb');
      expect(
        bytesToHex(
          selector('processRemoteMessage(uint64,uint256,uint256,address)'),
        ),
        '0x6efe7df5',
      );
      expect(
        bytesToHex(
          keccak(
            Uint8List.fromList(
              utf8.encode('NewLocalMessage(uint64,uint256,uint256,bytes)'),
            ),
          ),
        ),
        kBridgeNewLocalMessageTopic,
      );
    });
  });

  group('paid flag', () {
    test('storage keys are what `cast index uint64 <id> <slot>` gives', () {
      // Computed once with Foundry cast 1.x on 2026-10-09.
      const cast = {
        (
          107,
          1,
        ): '0xd70e245266dfd722d237312ada32b3921705992efb298b14480ba0acaaa0765a',
        (
          108,
          1,
        ): '0xd80c728dcb954e7539257f5b9090fa0c83e482d978be864c61ec2b155c05c252',
        (
          108,
          2,
        ): '0x5c02fad6158ba4ff0547bf3f852d51853ec7aacd92af6352c7a69490ade9671a',
        (
          109,
          2,
        ): '0xda4fbfd2174b26f2972ec2761ecc2e7a7d1eb0d5cc01aa04b334b35ee3251cc2',
        (
          639,
          2,
        ): '0xabf0a2a556cb3ca04d8ba0f52f0693e838ddbb50ab2a3ad1267171e912eee456',
        (
          640,
          2,
        ): '0x4b731f6157a6421eb979b42466aa68fb410b9338c286875652dec93423cb2e04',
        (
          1,
          1,
        ): '0xcc69885fda6bcc1a4ace058b4a62bf5e179ea78fd58a1ccd71c22cc9b688792f',
        (
          0,
          2,
        ): '0xac33ff75c19e70fe83507db0d683fd3465c996598dc972688b7ace676c89077b',
        (
          222,
          2,
        ): '0x66388a99db3d9747e46ce2fca9ca0912a710973e25f7899306b55ded62dc2dee',
      };
      for (final MapEntry(key: (id, slot), :value) in cast.entries) {
        expect(processedKey(id, slot), value, reason: 'id $id slot $slot');
      }
      expect(() => processedKey(-1, 2), throwsArgumentError);
    });

    test('each route reads the slot its pipe keeps the map in', () {
      for (final r in kBridgeRoutes) {
        expect(r.processedSlot, r.isNativeEth ? 1 : 2, reason: r.id);
      }
    });
  });

  group('receiver key', () {
    test('a real key, the generator and x = 1 are claimable', () {
      expect(isBeamReceiverKey(refKey), isTrue);
      final g = hexToBytes(
        '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798',
      );
      expect(isBeamReceiverKey(Uint8List.fromList([...g, 0])), isTrue);
      final one = Uint8List(33)..[31] = 1;
      expect(isBeamReceiverKey(one), isTrue);
    });

    test('a wrong parity byte, length, or x off the curve is not', () {
      // The four WBEAM receivers that can never be claimed end in 23, b5,
      // 22, f9 (research §A.4).
      for (final parity in [0x02, 0x23, 0xb5, 0x22, 0xf9]) {
        final k = Uint8List.fromList(refKey)..[32] = parity;
        expect(isBeamReceiverKey(k), isFalse, reason: 'parity $parity');
      }
      expect(isBeamReceiverKey(refKey.sublist(0, 32)), isFalse);
      expect(isBeamReceiverKey(Uint8List(34)), isFalse);
      // x = 0 and x = 5: x³ + 7 is not a square mod p.
      expect(isBeamReceiverKey(Uint8List(33)), isFalse);
      expect(isBeamReceiverKey(Uint8List(33)..[31] = 5), isFalse);
      // x ≥ p.
      expect(
        isBeamReceiverKey(Uint8List.fromList([...List.filled(32, 0xff), 0])),
        isFalse,
      );
    });
  });

  group('the lock receipt', () {
    test('reads msgId 222 from the real receipt', () {
      final lock = read(fixture());
      expect(lock.success, isTrue);
      expect(lock.msgId, 222);
      expect(lock.blockNumber, 25868098);
      expect(lock.hash, refHash);
    });

    test('the message decodes to what the spec says', () {
      final log = logsOf(fixture())[1];
      final m = decodePipeMessage(hexToBytes(log['data'] as String));
      expect(m.msgId, 222);
      expect(m.amount, refValue);
      expect(m.relayerFee, refFee);
      expect(m.receiver, refKey);
    });

    test("refuses another wallet's key", () {
      final other = Uint8List.fromList(refKey)..[0] ^= 1;
      expect(() => read(fixture(), key: other), refused());
    });

    test('refuses other amounts', () {
      expect(() => read(fixture(), value: refValue + BigInt.one), refused());
      expect(() => read(fixture(), fee: refFee - BigInt.one), refused());
      // The same total split differently is still another crossing.
      expect(
        () => read(
          fixture(),
          value: refValue + BigInt.one,
          fee: refFee - BigInt.one,
        ),
        refused(),
      );
    });

    test('refuses a message from another contract', () {
      final r = fixture();
      logsOf(r)[1]['address'] = bridgeRouteById('usdt').ethPipe;
      expect(() => read(r), refused());
    });

    test('refuses a lock read as another route', () {
      expect(() => read(fixture(), route: bridgeRouteById('usdt')), refused());
    });

    test('refuses a transaction to another contract or from another '
        'address', () {
      final r = fixture()..['to'] = bridgeRouteById('dai').ethPipe;
      expect(() => read(r), refused());
      expect(
        () => read(fixture(), owner: bridgeRouteById('eth').ethPipe),
        refused(),
      );
    });

    test('refuses a lock whose token did not move', () {
      final r = fixture();
      logsOf(r).removeAt(0);
      expect(() => read(r), refused());
    });

    test('refuses a token transfer short of amount + fee', () {
      final r = fixture();
      final t = logsOf(r)[0];
      t['data'] = bytesToHex(
        abiEncode('uint256', [refValue + refFee - BigInt.one]),
      );
      expect(() => read(r), refused());
    });

    test('refuses a token transfer that went elsewhere (not burnt)', () {
      final r = fixture();
      (logsOf(r)[0]['topics'] as List)[2] =
          '0x${'0' * 24}${bridgeRouteById('beam').ethPipe.substring(2)}';
      expect(() => read(r), refused());
    });

    test('refuses two token transfers (a fee taken on the way)', () {
      final r = fixture();
      logsOf(r).insert(0, Map.of(logsOf(r)[0]));
      expect(() => read(r), refused());
    });

    test('refuses two messages, or none', () {
      final two = fixture();
      logsOf(two).add(Map.of(logsOf(two)[1]));
      expect(() => read(two), refused());
      final none = fixture();
      logsOf(none).removeAt(1);
      expect(() => read(none), refused());
    });

    test('refuses a message with trailing bytes', () {
      final r = fixture();
      final log = logsOf(r)[1];
      log['data'] = '${log['data']}${'00' * 32}';
      expect(() => read(r), refused());
    });

    test('a reverted lock locked nothing', () {
      final r = fixture()..['status'] = '0x0';
      r['logs'] = <Object>[];
      final lock = read(r);
      expect(lock.success, isFalse);
      expect(lock.msgId, isNull);
      expect(lock.blockNumber, 25868098);
    });

    test('a receipt without a status is refused', () {
      final r = fixture()..remove('status');
      expect(() => read(r), refused());
    });
  });
}
