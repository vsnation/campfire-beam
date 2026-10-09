/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// ignore_for_file: lines_longer_than_80_chars

// The bytes the Uniswap swap sends, pinned against Foundry's `cast
// abi-encode` / `cast calldata` (the expected hex below was produced by
// cast 2026-10-09), and Permit2's domain separator against the value its
// DOMAIN_SEPARATOR() returns on mainnet.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/permit2.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_constants.dart';
import 'package:stackwallet/wallets/ethereum/uniswap/uniswap_models.dart';

const _wbeam = '0xe5acbb03d73267c03349c76ead672ee4d941f499';
const _zero = '0x0000000000000000000000000000000000000000';

void main() {
  test('v4 ExactInputSingleParams, as one dynamic tuple', () {
    final got = abiEncode(
      '((address,address,uint24,int24,address),bool,uint128,uint128,bytes)',
      [
        [
          [_zero, _wbeam, 10000, 200, _zero],
          true,
          BigInt.parse('10000000000000000'),
          1,
          Uint8List(0),
        ],
      ],
    );
    expect(
      bytesToHex(got),
      '0x00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e5acbb03d73267c03349c76ead672ee4d941f499000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000c800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000002386f26fc10000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000',
    );
  });

  test('bytes + bytes[]', () {
    final got = abiEncode('bytes,bytes[]', [
      hexToBytes('0x060c0f'),
      [hexToBytes('0x1234'), Uint8List(0)],
    ]);
    expect(
      bytesToHex(got),
      '0x000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000003060c0f0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000212340000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',
    );
  });

  test('v2 swap input with CONTRACT_BALANCE and a path', () {
    final got = abiEncode('address,uint256,uint256,address[],bool', [
      URConstants.addressThis,
      URConstants.contractBalance,
      5,
      [_wbeam, UniswapAddresses.weth],
      false,
    ]);
    expect(
      bytesToHex(got),
      '0x00000000000000000000000000000000000000000000000000000000000000028000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000500000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000e5acbb03d73267c03349c76ead672ee4d941f499000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2',
    );
  });

  test('negative int24 round-trips', () {
    final got = abiEncode('int24,int24', [-887220, 200]);
    expect(
      bytesToHex(got),
      '0xfffffffffffffffffffffffffffffffffffffffffffffffffffffffffff2764c00000000000000000000000000000000000000000000000000000000000000c8',
    );
    expect(abiDecode('int24,int24', got), [
      BigInt.from(-887220),
      BigInt.from(200),
    ]);
  });

  test('Multicall3 aggregate3 calldata', () {
    final got = encodeCall('aggregate3((address,bool,bytes)[])', [
      [
        [_wbeam, true, hexToBytes('0x313ce567')],
        [_zero, false, Uint8List(0)],
      ],
    ]);
    expect(
      bytesToHex(got),
      '0x82ad56cb00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000e5acbb03d73267c03349c76ead672ee4d941f499000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000004313ce567000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000000',
    );
  });

  test('PERMIT2_PERMIT input: the permit inline, then the signature', () {
    final permit = PermitSingle(
      token: _wbeam,
      amount: BigInt.from(100000000000),
      expiration: 1791555705,
      nonce: 0,
      spender: UniswapAddresses.universalRouter,
      sigDeadline: BigInt.from(1791555705),
    );
    final signed = SignedPermit(
      permit,
      Uint8List.fromList(List.filled(65, 0xab)),
    );
    expect(
      bytesToHex(signed.routerInput),
      '0x000000000000000000000000e5acbb03d73267c03349c76ead672ee4d941f499000000000000000000000000000000000000000000000000000000174876e800000000000000000000000000000000000000000000000000000000006ac8f879000000000000000000000000000000000000000000000000000000000000000000000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af000000000000000000000000000000000000000000000000000000006ac8f87900000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000041ababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababababab00000000000000000000000000000000000000000000000000000000000000',
    );
  });

  test("Permit2's domain separator is the one on mainnet", () {
    expect(
      bytesToHex(permit2DomainSeparator()),
      '0x866a5aba21966af95d6c7ab78eb2b2fc913915c28be3b9aa07cc04ff903e3f28',
    );
  });

  test('a v4 pool id is keccak(abi.encode(PoolKey))', () {
    final pool = UniV4Pool.key(
      currency0: _zero,
      currency1: _wbeam,
      fee: 10000,
      tickSpacing: 200,
      hooks: _zero,
    );
    expect(
      pool.id,
      '0xce7ff1b044aaee5bf9e632a3b537e10fbca0222004ee50348d492c1e5b54419c',
    );
  });

  test('decodes what it encodes, nested and dynamic', () {
    const types = '(address,bool,bytes)[],uint256,(int24,(address,bytes))';
    final values = [
      [
        [_wbeam, true, hexToBytes('0xdeadbeef')],
        [_zero, false, Uint8List(0)],
      ],
      BigInt.from(42),
      [
        BigInt.from(-5),
        [UniswapAddresses.weth, hexToBytes('0x01')],
      ],
    ];
    final decoded = abiDecode(types, abiEncode(types, values));
    expect(decoded[1], BigInt.from(42));
    final arr = decoded[0] as List;
    expect((arr[0] as List)[0], _wbeam);
    expect((arr[0] as List)[2], hexToBytes('0xdeadbeef'));
    expect((arr[1] as List)[1], false);
    final t = decoded[2] as List;
    expect(t[0], BigInt.from(-5));
    expect((t[1] as List)[0], UniswapAddresses.weth);
  });

  test('v3 path packs fees in three bytes', () {
    expect(
      bytesToHex(v3Path([_wbeam, UniswapAddresses.weth], [3000])),
      '0x${_wbeam.substring(2)}000bb8${UniswapAddresses.weth.substring(2)}',
    );
  });

  test('uint out of range is refused', () {
    expect(() => abiEncode('uint8', [256]), throwsArgumentError);
    expect(
      () => abiEncode('uint160', [BigInt.one << 160]),
      throwsArgumentError,
    );
  });
}
