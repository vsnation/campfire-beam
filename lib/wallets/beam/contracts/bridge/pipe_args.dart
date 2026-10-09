/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../bridge/bridge_routes.dart';

/// `args` strings for the bridge's two pipe app shaders
/// (BeamMW/beam-bridge-pipe@fd5b2a67 `shaders/pipe_app.cpp`, and the
/// reverse one, which answers the same actions). Pure functions; every
/// input is validated here so nothing the shader would misread is sent.
///
/// The shaders parse only `action` and never a `role` (the official apps
/// send one; it is ignored), so none is sent. They read a missing number
/// as 0 and parse with `strtoull(.., 0)`, where a leading zero means
/// octal: only canonical decimals are written, and every parameter an
/// action reads is written explicitly.
///
/// Only the five pipes of [kBridgeRoutes] are accepted as `cid`: the
/// asset-owner contract beside each pipe answers `get_pk` with a key that
/// nobody can ever claim with, and four stale pipes in the forward
/// registry still answer every action.
abstract final class PipeArgs {
  static final _maxAmount = (BigInt.one << 63) - BigInt.one;
  static final _receiver = RegExp(r'^[0-9a-f]{40}$');

  /// `get_pk`: the key the pipe pays this wallet's e2b crossings to,
  /// `{"pk": "<66 hex>"}` (forward) or `{"pubkey": "<66 hex>"}` (reverse).
  static String getPk({required String cid}) => _join('get_pk', cid, const {});

  /// `local_msg_count`: `{"count": n}`, the b2e messages recorded so far.
  static String localMsgCount({required String cid}) =>
      _join('local_msg_count', cid, const {});

  /// `local_msg`: b2e message [msgId], `{"amount", "relayerFee",
  /// "receiver": "<40 hex>", "height"}`. BEAM-side ids start at 1.
  static String localMsg({required String cid, required int msgId}) {
    if (msgId < 1) {
      throw ArgumentError.value(msgId, 'msgId', 'b2e ids start at 1');
    }
    return _join('local_msg', cid, {'msgId': '$msgId'});
  }

  /// `remote_msg`: e2b message [msgId] while pushed and unclaimed,
  /// `{"amount", "relayerFee", "receiver": "<66 hex>"}`. The ids are the
  /// Ethereum pipe's, which start at 0.
  static String remoteMsg({required String cid, required int msgId}) =>
      _join('remote_msg', cid, {'msgId': _msgId(msgId)});

  /// `view_incoming`: the unclaimed e2b messages for this wallet's key,
  /// from id [startFrom] on, `{"incoming": [{"MsgId": n, "amount": a}]}`.
  static String viewIncoming({required String cid, int? startFrom}) => _join(
    'view_incoming',
    cid,
    {if (startFrom != null) 'startFrom': _msgId(startFrom)},
  );

  /// `send` (b2e): locks or burns [amount] + [relayerFee] groth and
  /// records a message paying [amount] to [receiver] on Ethereum.
  ///
  /// [receiver] is 40 lowercase hex with no `0x`, as the official app
  /// sends it: the shader reads a raw 20-byte blob (`DocGetBlobEx`), and
  /// anything else could leave part of the address unset.
  static String send({
    required String cid,
    required BigInt amount,
    required String receiver,
    required BigInt relayerFee,
  }) {
    if (!_receiver.hasMatch(receiver)) {
      throw ArgumentError.value(
        receiver,
        'receiver',
        '40 lowercase hex characters, no 0x',
      );
    }
    _amount(amount, 'amount');
    _amount(relayerFee, 'relayerFee');
    // The contract adds them in 64 bits without a check: a sum past 2^64
    // wraps, locking almost nothing for a huge payout the relayer refuses.
    if (amount + relayerFee > _maxAmount) {
      throw ArgumentError.value(
        amount + relayerFee,
        'amount + relayerFee',
        'above 2^63-1',
      );
    }
    return _join('send', cid, {
      'amount': '$amount',
      'receiver': receiver,
      'relayerFee': '$relayerFee',
    });
  }

  /// `receive` (e2b claim) of pushed message [msgId], signed with the key
  /// [getPk] returns.
  static String receive({required String cid, required int msgId}) =>
      _join('receive', cid, {'msgId': _msgId(msgId)});

  // ---------------------------------------------------------------- helpers

  static String _join(String action, String cid, Map<String, String> p) {
    if (!kBridgeRoutes.any((r) => r.beamPipeCid == cid)) {
      throw ArgumentError.value(cid, 'cid', 'not one of the bridge pipes');
    }
    return [
      'action=$action',
      'cid=$cid',
      for (final e in p.entries) '${e.key}=${e.value}',
    ].join(',');
  }

  static String _msgId(int id) {
    if (id < 0) throw ArgumentError.value(id, 'msgId', 'must not be negative');
    return '$id';
  }

  static void _amount(BigInt v, String name) {
    if (v <= BigInt.zero) {
      throw ArgumentError.value(v, name, 'must be positive');
    }
    if (v > _maxAmount) {
      throw ArgumentError.value(v, name, 'above 2^63-1');
    }
  }
}
