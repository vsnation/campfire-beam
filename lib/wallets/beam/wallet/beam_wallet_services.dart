/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import '../../wallet/impl/beam_wallet.dart';
import '../api/beam_api.dart';
import '../contracts/airdrop/airdrop_constants.dart';
import '../contracts/airdrop/beam_airdrop_service.dart';
import '../contracts/airdrop/voucher_code_store.dart';
import '../contracts/bans/bans_inbox_monitor.dart';
import '../contracts/bans/bans_service.dart';
import '../contracts/burn/beam_burn_service.dart';
import '../contracts/burn/blackhole_constants.dart';
import '../contracts/common/asset_shader_source.dart';
import '../contracts/common/pinned_shader.dart';
import '../contracts/dex/beam_dex_service.dart';
import '../contracts/dex/dex_constants.dart';
import '../contracts/minter/beam_minter_service.dart';
import '../contracts/minter/minter_constants.dart';
import '../explorer/beam_explorer_client.dart';
import '../explorer/campfire_proxy_info.dart';
import '../price/beam_asset_pricer.dart';
import '../rpc/beam_connection_exception.dart';
import '../rpc/beam_transport.dart';

/// The contract services every BEAM screen uses, one set per wallet.
///
/// Screens get them here instead of building their own, for two reasons:
///
/// * They all share one [BeamApi] over one [transport], so `invoke_contract`
///   calls from the DEX, BANS, airdrop and minter screens queue in order
///   (`BeamApi` keeps one shader lane per transport). Separate APIs would
///   each have their own lane and could overlap in the core.
/// * The transport forwards to the wallet's *current* core connection,
///   which is replaced whenever the wallet moves between the public node and
///   the private one. A service holding the old connection would fail after
///   every handover.
class BeamWalletServices {
  BeamWalletServices._(this.wallet, {this._voucherStore})
    : transport = BeamWalletTransport(() => wallet.coreApi);

  static final Map<String, BeamWalletServices> _byWallet = {};

  /// The services of [wallet], created on first use.
  static BeamWalletServices of(
    BeamWallet wallet, {
    VoucherCodeStore? voucherStore,
  }) => _byWallet[wallet.walletId] ??= BeamWalletServices._(
    wallet,
    voucherStore: voucherStore,
  );

  /// Drops [walletId]'s services, e.g. when the wallet is deleted.
  static Future<void> forget(String walletId) async {
    await _byWallet.remove(walletId)?._dispose();
  }

  final BeamWallet wallet;
  final BeamWalletTransport transport;
  final VoucherCodeStore? _voucherStore;

  late final BeamApi api = BeamApi(transport);

  late final ShaderSource _shaders = AssetShaderSource();

  late final BeamExplorerClient explorer = BeamExplorerClient(
    proxyInfo: campfireProxyInfo,
  );

  late final BeamDexService dex = BeamDexService(api, ammAppShader(_shaders));

  late final BeamBansService bans = BeamBansService(api, explorer);

  late final BansInboxMonitor bansInbox = BansInboxMonitor(bans.inbox);

  /// Needs the app's secure voucher store; screens that create batches must
  /// have passed one to [of] first.
  late final BeamAirdropService airdrop = BeamAirdropService(
    api,
    airdropAppShader(_shaders),
    store: _voucherStore,
  );

  late final BeamMinterService minter = BeamMinterService(
    api,
    minterAppShader(_shaders),
  );

  late final BeamBurnService burn = BeamBurnService(
    api,
    blackHoleAppShader(_shaders),
  );

  BeamAssetPricer? _pricer;
  DateTime? _pricedAt;

  /// Asset prices from the DEX, re-read at most every [maxAge].
  Future<BeamAssetPricer> pricer({
    Duration maxAge = const Duration(minutes: 2),
  }) async {
    final at = _pricedAt;
    final cached = _pricer;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < maxAge) {
      return cached;
    }
    final fresh = BeamAssetPricer(await dex.listPools());
    _pricer = fresh;
    _pricedAt = DateTime.now();
    return fresh;
  }

  Future<void> _dispose() => bansInbox.dispose();
}

/// A [BeamTransport] that always talks through the wallet's current core
/// connection. It never opens or closes anything itself: the wallet owns
/// the connection's lifetime.
class BeamWalletTransport implements BeamTransport {
  /// [currentApi] returns the wallet's API right now (`BeamWallet.coreApi`),
  /// or null while the core is not connected.
  BeamWalletTransport(this._currentApi);

  final BeamApi? Function() _currentApi;

  BeamTransport? get _current => _currentApi()?.transport;

  @override
  Future<void> connect() async {}

  @override
  bool get isConnected => _current?.isConnected ?? false;

  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) {
    final t = _current;
    if (t == null) {
      return Future.error(
        const BeamConnectionException(
          'The BEAM wallet is not connected yet',
        ),
      );
    }
    return t.call(method, params, timeout);
  }

  /// Events of the connection current when the stream is listened to.
  @override
  Stream<BeamEvent> get events =>
      _current?.events ?? const Stream<BeamEvent>.empty();

  @override
  Future<void> close() async {}
}
