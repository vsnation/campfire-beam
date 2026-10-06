/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

import '../host/beam_binaries_manifest.dart';
import '../rpc/beam_transport.dart';
import 'dapp_errors.dart';
import 'dapp_rpc.dart';
import 'dapp_text.dart';

/// Size limits on what a dApp may send.
@immutable
class DappRequestLimits {
  const DappRequestLimits({
    this.maxRequestLength = 8 * 1024 * 1024,
    this.maxShaderBytes = 2 * 1024 * 1024,
    this.maxInvokeDataBytes = 2 * 1024 * 1024,
    this.maxArgsLength = 1024 * 1024,
    this.maxCommentLength = 1024,
    this.maxAddressLength = 4096,
    this.maxInFlight = 64,
    this.maxSignMessageLength = 4096,
    this.maxKeyMaterialLength = 1024,
  });

  /// One request as text. The app shaders of the 9 bundled dApps are at
  /// most 62 KB (about 250 KB as a JSON byte array); wallet-api's TCP line
  /// limit is set to 16 MiB.
  final int maxRequestLength;
  final int maxShaderBytes;
  final int maxInvokeDataBytes;
  final int maxArgsLength;

  /// `comment` and `confirm_comment`: text shown in the approval sheet.
  final int maxCommentLength;
  final int maxAddressLength;

  /// Requests one dApp may have waiting on the core at once.
  final int maxInFlight;

  /// `sign_message` `message`: text shown in the approval sheet.
  final int maxSignMessageLength;

  /// `sign_message` `key_material`, in hex digits.
  final int maxKeyMaterialLength;
}

/// Narrows what an allowed method may carry before it reaches wallet-api.
///
/// * `invoke_contract`: `contract_file` is dropped (it makes the wallet
///   process read any local path, research/02 risks), as is every other
///   unknown key; `create_tx: true` is refused with the core's own error
///   (`v6_1_api_parse.cpp:284-287`) and `create_tx` is always sent as
///   false, so a dApp can never start a contract transaction without
///   `process_invoke_data` and its approval. `contract` bytes whose
///   SHA-256 is on Campfire's privileged list ([privilegedShaderSha256s],
///   the BANS app shader) are refused: Campfire's wallet-api runs those at
///   privilege 1 for whoever sends them, which would let a dApp read the
///   payments waiting for the user's names.
/// * `sign_message`: only `message` and `key_material`, the key material as
///   strict even-length hex. The core's `from_hex` stops at the first
///   non-hex character (`utility/hex.cpp:56-90`); refusing anything else
///   means the key checked here is the key the core derives.
/// * `tx_send` and `process_invoke_data`: only the keys the approval sheet
///   accounts for are accepted, with checked types; anything else is
///   refused rather than silently forwarded, because what executes must be
///   what was shown. `coins` (manual coin selection) is refused.
/// * `ev_subunsub`: `ev_utxos_changed` and `ev_assets_changed` are refused,
///   as the core refuses them for apps (`v6_1_api_parse.cpp:22-50`).
/// * Every other method: `contract_file` is dropped, the rest is forwarded
///   for the core to validate.
class DappRequestSanitizer {
  const DappRequestSanitizer([
    this.limits = const DappRequestLimits(),
    this.privilegedShaderSha256s = kBeamPrivilegedShaderSha256s,
  ]);

  final DappRequestLimits limits;

  /// App shaders Campfire's wallet-api runs at privilege 1; never accepted
  /// from a dApp.
  final List<String> privilegedShaderSha256s;

  static const _invokeKeys = {
    'contract',
    'args',
    'create_tx',
    'priority',
    'unique',
  };
  static const _processKeys = {'data', 'confirm_comment'};
  static const _signKeys = {'message', 'key_material'};
  static const _sendKeys = {
    'address',
    'value',
    'asset_id',
    'fee',
    'comment',
    'confirm_comment',
    'from',
    'txId',
    'offline',
  };
  static const events = {
    'ev_sync_progress',
    'ev_system_state',
    'ev_assets_changed',
    'ev_addrs_changed',
    'ev_utxos_changed',
    'ev_txs_changed',
    'ev_connection_changed',
  };
  static const _eventsBlockedForApps = {
    'ev_utxos_changed',
    'ev_assets_changed',
  };

  static final _txId = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _hex = RegExp(r'^(?:[0-9a-fA-F]{2})+$');

  /// The params to forward for [request], or a [BeamRpcException].
  Map<String, Object?> sanitize(DappRpcRequest request) {
    final params = request.params;
    switch (request.method) {
      case 'invoke_contract':
        return _invokeContract(params);
      case 'process_invoke_data':
        return _processInvokeData(params);
      case 'tx_send':
        return _txSend(params);
      case 'ev_subunsub':
        return _evSubUnsub(params);
      case 'sign_message':
        return _signMessage(params);
      default:
        return Map.unmodifiable({
          for (final e in params.entries)
            if (e.key != 'contract_file') e.key: e.value,
        });
    }
  }

  Map<String, Object?> _invokeContract(Map<String, Object?> params) {
    final out = <String, Object?>{};
    for (final e in params.entries) {
      if (!_invokeKeys.contains(e.key)) continue; // contract_file et al.
      out[e.key] = e.value;
    }
    final createTx = out['create_tx'];
    if (createTx != null && createTx is! bool) {
      throw _params('create_tx must be a boolean');
    }
    if (createTx == true) {
      throw DappRpcErrors.error(
        DappRpcErrors.notAllowed,
        'Applications must set create_tx to false and use '
        'process_contract_data',
      );
    }
    out['create_tx'] = false;
    if (out.containsKey('contract')) {
      final shader = _bytes(
        out['contract'],
        'contract',
        limits.maxShaderBytes,
      );
      final hash = crypto.sha256.convert(shader).toString();
      if (privilegedShaderSha256s.contains(hash)) {
        throw DappRpcErrors.error(
          DappRpcErrors.notAllowed,
          'Campfire refused this request: the app shader is one Campfire '
          'reserves for its own name service. Nothing was run.',
        );
      }
      out['contract'] = shader;
    }
    final args = out['args'];
    if (args != null &&
        (args is! String || args.length > limits.maxArgsLength)) {
      throw _params('args must be a string of at most ${limits.maxArgsLength}');
    }
    for (final k in const ['priority', 'unique']) {
      final v = out[k];
      if (v != null && (v is! int || v < 0 || v > 0xffffffff)) {
        throw _params('$k must be an unsigned 32-bit integer');
      }
    }
    return Map.unmodifiable(out);
  }

  Map<String, Object?> _processInvokeData(Map<String, Object?> params) {
    _onlyKeys(params, _processKeys);
    if (!params.containsKey('data')) throw _params('data is required');
    final data = _bytes(params['data'], 'data', limits.maxInvokeDataBytes);
    if (data.isEmpty) throw _params('data is empty');
    final comment = _optText(params, 'confirm_comment');
    return Map.unmodifiable({'data': data, 'confirm_comment': ?comment});
  }

  Map<String, Object?> _txSend(Map<String, Object?> params) {
    if (params.containsKey('coins')) {
      throw _params('coins is not accepted from dApps');
    }
    _onlyKeys(params, _sendKeys);
    final address = params['address'];
    if (address is! String ||
        address.isEmpty ||
        address.length > limits.maxAddressLength) {
      throw _params('address must be a non-empty string');
    }
    final value = params['value'];
    if (value is! int || value <= 0) {
      throw _params('value must be a positive integer');
    }
    final assetId = params['asset_id'];
    if (assetId != null &&
        (assetId is! int || assetId < 0 || assetId > 0xffffffff)) {
      throw _params('asset_id must be an unsigned 32-bit integer');
    }
    final fee = params['fee'];
    if (fee != null && (fee is! int || fee <= 0)) {
      throw _params('fee must be a positive integer');
    }
    final from = params['from'];
    if (from != null &&
        (from is! String ||
            from.isEmpty ||
            from.length > limits.maxAddressLength)) {
      throw _params('from must be a non-empty string');
    }
    final txId = params['txId'];
    if (txId != null && (txId is! String || !_txId.hasMatch(txId))) {
      throw _params('txId must be 32 hex digits');
    }
    final offline = params['offline'];
    if (offline != null && offline is! bool) {
      throw _params('offline must be a boolean');
    }
    final comment = _optText(params, 'comment');
    final confirm = _optText(params, 'confirm_comment');
    return Map.unmodifiable({
      'address': address,
      'value': value,
      'asset_id': ?assetId,
      'fee': ?fee,
      'comment': ?comment,
      'confirm_comment': ?confirm,
      'from': ?from,
      'txId': ?txId,
      'offline': ?offline,
    });
  }

  Map<String, Object?> _signMessage(Map<String, Object?> params) {
    _onlyKeys(params, _signKeys);
    final message = params['message'];
    if (message is! String ||
        message.isEmpty ||
        message.length > limits.maxSignMessageLength) {
      throw _params(
        'message must be a non-empty string of at most '
        '${limits.maxSignMessageLength}',
      );
    }
    if (dappTextHasHidden(message)) {
      // The sheet must show exactly what is signed; hidden characters
      // cannot be shown.
      throw _params('message must not contain control or bidi characters');
    }
    final key = params['key_material'];
    if (key is! String ||
        key.length > limits.maxKeyMaterialLength ||
        !_hex.hasMatch(key)) {
      throw _params('key_material must be an even number of hex digits');
    }
    return Map.unmodifiable({'message': message, 'key_material': key});
  }

  Map<String, Object?> _evSubUnsub(Map<String, Object?> params) {
    if (params.isEmpty) {
      throw _params('Must subunsub at least one supported event');
    }
    for (final e in params.entries) {
      if (!events.contains(e.key)) {
        throw _params("The event '${e.key}' is unknown.");
      }
      if (_eventsBlockedForApps.contains(e.key)) {
        throw DappRpcErrors.error(DappRpcErrors.notAllowed);
      }
      if (e.value is! bool) throw _params('${e.key} must be a boolean');
    }
    return Map.unmodifiable(params);
  }

  void _onlyKeys(Map<String, Object?> params, Set<String> allowed) {
    for (final k in params.keys) {
      if (!allowed.contains(k)) throw _params('$k is not accepted from dApps');
    }
  }

  String? _optText(Map<String, Object?> params, String key) {
    final v = params[key];
    if (v == null) return null;
    if (v is! String || v.length > limits.maxCommentLength) {
      throw _params(
        '$key must be a string of at most ${limits.maxCommentLength}',
      );
    }
    return v;
  }

  static List<int> _bytes(Object? v, String key, int max) {
    if (v is! List<Object?> || v.length > max) {
      throw _params('$key must be a byte array of at most $max');
    }
    for (final b in v) {
      if (b is! int || b < 0 || b > 255) {
        throw _params('$key must be a byte array');
      }
    }
    return List<int>.unmodifiable(v.cast<int>());
  }

  static BeamRpcException _params(String why) =>
      DappRpcErrors.error(DappRpcErrors.invalidParams, why);
}
