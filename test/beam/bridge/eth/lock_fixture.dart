/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// A reference lock from mainnet: tx 0x8596…0684, block 25 868 098,
// 2026-08-30, msgId 222, 105 WBEAM with a 0.02 WBEAM fee, into the BEAM
// pipe. fixtures/receipt_0x8596_msg222.json is its
// `eth_getTransactionReceipt`, fetched read-only through Tor from
// ethereum-rpc.publicnode.com on 2026-10-09 and identical (bar the
// optional `blockTimestamp`) to eth2.stackwallet.com's answer.

import 'dart:convert';
import 'dart:io';

import 'package:stackwallet/wallets/ethereum/uniswap/abi.dart';

const refHash =
    '0x8596783918bb46a873b872405b102826f8619c659a54599ec5fdb8591c430684';

/// The receiver of msgId 222 (33 bytes, parity 01).
final refKey = hexToBytes(
  '83324744834f22c9f113abed7abd2e9f69f339decec2e24aae2789dbd2fb307b01',
);
const refOwner = '0xf1e43ede41881fdfb7868ab506236dbd6ec63329';
final refValue = BigInt.from(10500000000); // 105 WBEAM
final refFee = BigInt.from(2000000); // 0.02 WBEAM

/// A fresh copy of the receipt (tests change it).
Map<String, dynamic> refReceipt() => jsonDecode(
  File('test/beam/bridge/eth/fixtures/receipt_0x8596_msg222.json')
      .readAsStringSync(),
) as Map<String, dynamic>;
