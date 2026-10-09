/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The bridge's Ethereum side for one Ethereum wallet ([EthPipeSide]):
//
// * before a quote: is the route frozen (a paused token, Tether's
//   blacklist or transfer fee), what gas the relayer prices at, and the
//   USD prices it prices with;
// * moving coins to BEAM ("e2b"): an exact approval of the pipe (never an
//   unlimited one), then `sendFunds`, each priced and checked before it is
//   signed, and the lock read back from its receipt;
// * coming from BEAM ("b2e"): whether the relayer has paid a message yet,
//   one storage read.
//
// Everything goes through the wallet's own RPC ([EthRpc]: the node in its
// network settings, Tor when Tor is on) and prices through the same Tor
// rule ([BridgePriceFeed]). Keys never leave the wallet: [UniSwapSigner]
// signs and broadcasts inside it. Nothing here is sent unless the
// controller calls [send], after the user's PIN.

import 'dart:async';
import 'dart:typed_data';

import '../../bridge/bridge_fees.dart';
import '../../bridge/bridge_routes.dart';
import '../../bridge/bridge_sides.dart';
import '../uniswap/abi.dart';
import '../uniswap/eth_rpc.dart';
import '../uniswap/uniswap_service.dart';
import 'bridge_price_feed.dart';
import 'eth_pipe_calls.dart';

/// Gas for `sendFunds` when it cannot be measured yet: while the approval
/// it needs is not mined, `eth_estimateGas` reverts. Measured on mainnet
/// (2026-10-09): ETH ~31 000; WBTC ~47 000, DAI ~50 000, WBEAM 49–54 000,
/// USDT 55–60 000. About twice that, so a cold storage slot or a USDT
/// fee check cannot run it out of gas; only the gas used is paid.
final BigInt kSendFundsGasEth = BigInt.from(80000);
final BigInt kSendFundsGasToken = BigInt.from(120000);

/// Gas for an `approve` that cannot be measured (USDT's, before its reset
/// to zero is mined), as the swap budgets it.
final BigInt kApproveGas = BigInt.from(70000);

class EthPipeService implements EthPipeSide {
  EthPipeService({
    required this.rpc,
    required this.signer,
    required this.priceFeed,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final EthRpc rpc;

  /// The wallet: its address, and `sendContractCall` behind [send].
  final UniSwapSigner signer;
  final BridgePriceFeed priceFeed;
  final DateTime Function() _clock;

  /// A freeze check is reused for this long…
  static const freezeFresh = Duration(minutes: 10);

  /// …and, when the RPC does not answer, for up to this long. After that
  /// nothing is quoted (fail closed).
  static const freezeStale = Duration(hours: 1);

  final Map<String, ({List<BridgeFreeze> freezes, DateTime at})> _freezes = {};

  /// Requests already handed to the wallet (see [send]).
  final Expando<bool> _sent = Expando('bridge tx sent');

  @override
  String get owner => signer.address.toLowerCase();

  // -------------------------------------------------------------- freezes

  @override
  Future<List<BridgeFreeze>> freezes(BridgeRoute route) async {
    final checks = _freezeChecks(route);
    // ETH and DAI: nothing can stop them. Native ETH has no issuer; DAI
    // has no pause and no blacklist, and the pipes themselves have no
    // admin at all.
    if (checks.isEmpty) return const [];

    final now = _clock();
    final cached = _freezes[route.id];
    if (cached != null && now.difference(cached.at) < freezeFresh) {
      return cached.freezes;
    }
    BridgeException failure;
    try {
      final results = await rpc.multicall([for (final c in checks) c.call]);
      final found = <BridgeFreeze>[];
      for (var i = 0; i < checks.length; i++) {
        final r = results[i];
        if (!r.success || r.data.length != 32) {
          throw BridgeException(
            BridgeErrorCode.frozen,
            'Could not tell whether ${checks[i].token} is frozen, so it '
            'is not bridged for now.',
          );
        }
        final word = bytesToBigInt(r.data);
        if (checks[i].isFlag && word > BigInt.one) {
          throw BridgeException(
            BridgeErrorCode.frozen,
            '${checks[i].token} gave an answer it never gives, so it is '
            'not bridged for now.',
          );
        }
        if (word != BigInt.zero) found.add(BridgeFreeze(checks[i].reason));
      }
      final frozen = List<BridgeFreeze>.unmodifiable(found);
      _freezes[route.id] = (freezes: frozen, at: now);
      return frozen;
    } on BridgeException catch (e) {
      failure = e;
    } on Exception catch (e) {
      failure = BridgeException(
        BridgeErrorCode.network,
        'Could not reach Ethereum to check ${route.ethSymbol} ($e).',
      );
    }
    // An RPC that flaps does not stop the bridge for an hour; after that
    // an old "not frozen" is not trusted.
    if (cached != null && now.difference(cached.at) < freezeStale) {
      return cached.freezes;
    }
    throw failure;
  }

  static List<_FreezeCheck> _freezeChecks(BridgeRoute route) {
    final token = route.ethToken;
    if (token == null) return const [];
    final paused = selector('paused()');
    return switch (route.id) {
      // WBEAM: one key holds its pause (and its minting).
      'beam' => [
        _FreezeCheck(
          EthCall(token, paused),
          'WBEAM',
          'WBEAM is paused by its issuer',
        ),
      ],
      'wbtc' => [
        _FreezeCheck(
          EthCall(token, paused),
          'WBTC',
          'WBTC is paused by its issuer',
        ),
      ],
      // Tether can pause USDT, blacklist the pipe (every USDT in it then
      // stays there for good), or switch on a transfer fee (the pipe would
      // get less than the message says).
      'usdt' => [
        _FreezeCheck(EthCall(token, paused), 'USDT', 'Tether has paused USDT'),
        _FreezeCheck(
          EthCall(token, encodeCall('isBlackListed(address)', [route.ethPipe])),
          'USDT',
          "Tether has frozen the bridge's USDT",
        ),
        _FreezeCheck(
          EthCall(token, selector('basisPointsRate()')),
          'USDT',
          'USDT now charges a transfer fee',
          isFlag: false,
        ),
      ],
      _ => const [],
    };
  }

  // ----------------------------------------------------------- the quote

  @override
  Future<BridgeRelayerGas> relayerGas() async {
    try {
      final r = await rpc.call('eth_feeHistory', [
        '0xa',
        'latest',
        [50],
      ]);
      return BridgeRelayerGas.fromFeeHistory(
        (r! as Map).cast<String, dynamic>(),
        at: _clock(),
      );
    } catch (e) {
      // A node that does not answer, or answers without fee history: no
      // gas price, so no quote.
      throw BridgeException(
        BridgeErrorCode.noPrice,
        'Could not read the Ethereum gas price ($e).',
      );
    }
  }

  @override
  Future<BridgePrices> prices(List<String> coingeckoIds) =>
      priceFeed.usd(coingeckoIds);

  // ------------------------------------------------------------- balances

  @override
  Future<BigInt> balance(BridgeRoute route) {
    final token = route.ethToken;
    if (token == null) return ethBalance();
    return _read('your ${route.ethSymbol} balance', () async {
      final r = await rpc.ethCall(
        token,
        encodeCall('balanceOf(address)', [owner]),
      );
      return abiDecode('uint256', r)[0] as BigInt;
    });
  }

  @override
  Future<BigInt> ethBalance() => _read('your ETH balance', () async {
    final r = await rpc.call('eth_getBalance', [owner, 'latest']);
    return _hex(r! as String);
  });

  /// [route]'s token the pipe may take from the wallet now.
  Future<BigInt> allowance(BridgeRoute route) {
    final token = route.ethToken;
    if (token == null) throw ArgumentError('ETH needs no approval');
    return _read('your ${route.ethSymbol} approval', () async {
      final r = await rpc.ethCall(
        token,
        encodeCall('allowance(address,address)', [owner, route.ethPipe]),
      );
      return abiDecode('uint256', r)[0] as BigInt;
    });
  }

  // ------------------------------------------------------------- the lock

  @override
  Future<EthPipeLockPlan> planLock(
    BridgeRoute route, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  }) async {
    checkLockAmounts(route, value: value, fee: fee, receiverKey: receiverKey);
    final total = value + fee;
    final fees = await _read('Ethereum fees', () => walletFees(rpc));
    final steps = <UniTxRequest>[];

    final token = route.ethToken;
    if (token != null) {
      final current = await allowance(route);
      if (current < total) {
        // Exactly what this lock takes, never "any amount": a pipe left
        // with an open approval could take more later.
        if (current > BigInt.zero && !await _changesAllowance(route, total)) {
          // USDT refuses to change an allowance that is not zero.
          steps.add(
            (await _approvalTx(route, BigInt.zero, fees)).withNote(
              'Reset the ${route.ethSymbol} permission of the '
              'BEAM bridge to 0',
            ),
          );
        }
        steps.add(
          (await _approvalTx(route, total, fees)).withNote(
            'Approve ${_units(total, route)} ${route.ethSymbol} for the '
            'BEAM bridge',
          ),
        );
      }
    }

    final data = sendFundsCall(value, fee, receiverKey);
    final msgValue = route.isNativeEth ? total : BigInt.zero;
    final fallback = route.isNativeEth ? kSendFundsGasEth : kSendFundsGasToken;
    var gas = fallback;
    if (steps.isEmpty) {
      try {
        gas = gasWithHeadroom(
          await rpc.estimateGas(
            from: owner,
            to: route.ethPipe,
            data: data,
            value: msgValue,
          ),
        );
      } on EthRpcError {
        // It reverts (not enough of the coin yet, or a freeze): the
        // controller checks balances and freezes; the plan keeps a safe
        // limit rather than failing to show a price.
      } on Exception catch (e) {
        throw BridgeException(
          BridgeErrorCode.network,
          'Could not reach Ethereum to price the lock ($e).',
        );
      }
    }
    steps.add(
      UniTxRequest(
        kind: UniTxKind.bridgeLock,
        to: route.ethPipe,
        data: data,
        value: msgValue,
        gasLimit: gas,
        fees: fees,
        note:
            'Bridge: move ${_units(value, route)} ${route.ethSymbol} '
            'to BEAM',
      ),
    );
    return EthPipeLockPlan(
      route: route,
      value: value,
      fee: fee,
      receiverKey: Uint8List.fromList(receiverKey),
      steps: List.unmodifiable(steps),
      fees: fees,
    );
  }

  /// Refuses (badAmount) what the pipes or the relayer would get wrong:
  /// nothing to move, a negative fee, an amount the relayer would cut to
  /// BEAM's 8 decimals (the cut stays in the pipe), a sum that wraps the
  /// pipe's unchecked `value + fee` (nothing deposited, nothing paid), or
  /// one BEAM cannot hold. Refuses (badPipe) a receiver nobody can claim
  /// with. A zero fee is allowed: the relayer delivers it (it never
  /// checks an e2b fee), though Campfire always pays one.
  static void checkLockAmounts(
    BridgeRoute route, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  }) {
    Never bad(String why) =>
        throw BridgeException(BridgeErrorCode.badAmount, why);
    if (value <= BigInt.zero) bad('Nothing to move.');
    if (fee < BigInt.zero) bad('The bridge fee cannot be negative.');
    final grid = route.ethGrid;
    if (value % grid != BigInt.zero || fee % grid != BigInt.zero) {
      bad(
        '${route.ethSymbol} moves to BEAM in steps of '
        '${_units(grid, route)}; the rest would stay in the bridge.',
      );
    }
    if (value + fee >= kUint256Limit) bad('This amount is too large.');
    if (route.ethToGroth(value) + route.ethToGroth(fee) >= kBeamAmountLimit) {
      bad('This amount is too large for BEAM.');
    }
    if (!isBeamReceiverKey(receiverKey)) {
      // It comes from the BEAM pipe's `get_pk`: a shader error or the
      // wrong contract, and coins sent to it could never be claimed.
      throw const BridgeException(
        BridgeErrorCode.badPipe,
        'The BEAM wallet gave a receive key nobody could claim with.',
      );
    }
  }

  /// Whether [route]'s token lets the wallet change its non-zero
  /// allowance to [amount] directly (USDT reverts: zero first).
  Future<bool> _changesAllowance(BridgeRoute route, BigInt amount) async {
    try {
      await rpc.ethCall(
        route.ethToken!,
        erc20ApproveCall(route.ethPipe, amount),
        from: owner,
      );
      return true;
    } on EthRpcError catch (e) {
      if (e.code == 3 || e.message.toLowerCase().contains('revert')) {
        return false;
      }
      throw BridgeException(
        BridgeErrorCode.network,
        'Could not reach Ethereum to check the approval ($e).',
      );
    } on Exception catch (e) {
      throw BridgeException(
        BridgeErrorCode.network,
        'Could not reach Ethereum to check the approval ($e).',
      );
    }
  }

  Future<UniTxRequest> _approvalTx(
    BridgeRoute route,
    BigInt amount,
    UniFees fees,
  ) async {
    final token = route.ethToken!;
    final data = erc20ApproveCall(route.ethPipe, amount);
    var gas = kApproveGas;
    try {
      gas = gasWithHeadroom(
        await rpc.estimateGas(from: owner, to: token, data: data),
      );
    } on EthRpcError {
      // Reverts until an earlier step is mined (USDT's reset).
    } on Exception catch (e) {
      throw BridgeException(
        BridgeErrorCode.network,
        'Could not reach Ethereum to price the approval ($e).',
      );
    }
    return UniTxRequest(
      kind: amount == BigInt.zero ? UniTxKind.approveReset : UniTxKind.approve,
      to: token,
      data: data,
      value: BigInt.zero,
      gasLimit: gas,
      fees: fees,
    );
  }

  /// Hands [tx] to the wallet to sign and broadcast, and returns its hash
  /// as soon as it is broadcast. Only a bridge transaction goes: an exact
  /// approval of a pipe, or `sendFunds` to a pipe with a claimable
  /// receiver and the ETH it needs; anything else is refused
  /// (unexpectedTransaction) unsigned. A request goes at most once, even
  /// when the wallet throws (it may have reached the network anyway):
  /// a second [send] of it is refused (alreadySent); plan again instead.
  @override
  Future<String> send(UniTxRequest tx) async {
    checkBridgeTx(tx);
    if (_sent[tx] == true) {
      throw const BridgeException(
        BridgeErrorCode.alreadySent,
        'This transaction was already handed to the wallet once.',
      );
    }
    _sent[tx] = true;
    return signer.send(tx);
  }

  /// Throws unless [tx] is an `approve(pipe, amount)` of a route's token
  /// or a `sendFunds` to a route's pipe, as [planLock] builds them.
  static void checkBridgeTx(UniTxRequest tx) {
    Never refuse() => throw const BridgeException(
      BridgeErrorCode.unexpectedTransaction,
      'This is not a bridge transaction; it was not sent.',
    );
    final to = tx.to.toLowerCase();
    final data = tx.data;
    if (data.length < 4) refuse();
    final sel = bytesToHex(data.sublist(0, 4));
    final args = Uint8List.fromList(data.sublist(4));
    for (final r in kBridgeRoutes) {
      if (to == r.ethToken && sel == kApproveSelector) {
        if (tx.value != BigInt.zero || args.length != 64) refuse();
        final v = abiDecode('address,uint256', args);
        if (v[0] != r.ethPipe ||
            bytesToHex(erc20ApproveCall(r.ethPipe, v[1] as BigInt)) !=
                bytesToHex(data)) {
          refuse();
        }
        return;
      }
      if (to == r.ethPipe && sel == kSendFundsSelector) {
        final List<Object> v;
        try {
          v = abiDecode('uint256,uint256,bytes', args);
        } catch (_) {
          refuse();
        }
        final value = v[0] as BigInt;
        final fee = v[1] as BigInt;
        if (!isBeamReceiverKey(v[2] as Uint8List) ||
            value + fee >= kUint256Limit ||
            tx.value != (r.isNativeEth ? value + fee : BigInt.zero) ||
            bytesToHex(sendFundsCall(value, fee, v[2] as Uint8List)) !=
                bytesToHex(data)) {
          refuse();
        }
        return;
      }
    }
    refuse();
  }

  // --------------------------------------------------------- after sending

  @override
  Future<bool?> succeeded(String hash) async {
    final r = await _receipt(hash);
    return r == null ? null : r['status'] == '0x1';
  }

  @override
  Future<EthPipeLock?> lockResult(
    BridgeRoute route,
    String hash, {
    required BigInt value,
    required BigInt fee,
    required Uint8List receiverKey,
  }) async {
    final r = await _receipt(hash);
    if (r == null) return null;
    final lock = decodeLockReceipt(
      route,
      r,
      owner: owner,
      value: value,
      fee: fee,
      receiverKey: receiverKey,
    );
    if (lock.hash.toLowerCase() != hash.toLowerCase()) {
      throw const BridgeException(
        BridgeErrorCode.unexpectedTransaction,
        'The node answered with another transaction.',
      );
    }
    return lock;
  }

  @override
  Future<bool> isPaid(BridgeRoute route, int beamMsgId) async {
    final word = await _read('the bridge payout', () async {
      final r = await rpc.call('eth_getStorageAt', [
        route.ethPipe,
        processedKey(beamMsgId, route.processedSlot),
        'latest',
      ]);
      return _hex(r! as String);
    });
    if (word > BigInt.one) {
      throw BridgeException(
        BridgeErrorCode.badPipe,
        'The ${route.ethSymbol} pipe gave an answer it never gives.',
      );
    }
    return word == BigInt.one;
  }

  // --------------------------------------------------------------- private

  /// The mined receipt of [hash], or null while it is pending.
  Future<Map<String, dynamic>?> _receipt(String hash) =>
      _read('the transaction', () async {
        final r = await rpc.call('eth_getTransactionReceipt', [hash]);
        if (r is! Map || r['blockNumber'] == null) return null;
        return r.cast<String, dynamic>();
      });

  /// [f], with any failure to reach the RPC as a [BridgeException]
  /// (network) saying what could not be read.
  static Future<T> _read<T>(String what, Future<T> Function() f) async {
    try {
      return await f();
    } on BridgeException {
      rethrow;
    } on Exception catch (e) {
      throw BridgeException(
        BridgeErrorCode.network,
        'Could not read $what from Ethereum ($e).',
      );
    }
  }

  static BigInt _hex(String h) =>
      h == '0x' ? BigInt.zero : BigInt.parse(h.substring(2), radix: 16);

  /// [v] Ethereum units of [route]'s asset as a plain number ("100.02").
  static String _units(BigInt v, BridgeRoute route) {
    final d = route.ethDecimals;
    final s = v.toString().padLeft(d + 1, '0');
    final whole = s.substring(0, s.length - d);
    final frac = s.substring(s.length - d).replaceFirst(RegExp(r'0+$'), '');
    return frac.isEmpty ? whole : '$whole.$frac';
  }
}

class _FreezeCheck {
  const _FreezeCheck(this.call, this.token, this.reason, {this.isFlag = true});

  final EthCall call;
  final String token;

  /// Said to the user when the answer is not zero.
  final String reason;

  /// A bool (0 or 1); else any number, where only zero is fine.
  final bool isFlag;
}
