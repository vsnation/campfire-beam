/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../wallets/beam/models/beam_address.dart';
import '../../../wallets/beam/rpc/beam_connection_exception.dart';
import 'beam_private_receive.dart';
import 'beam_receive_backend.dart';
import 'beam_receive_text.dart';

/// State and actions of the BEAM receive screen and address list.
///
/// The address shown on Receive is the newest unexpired *regular* address
/// the wallet owns, the same rule `BeamWallet` uses for Campfire's cached
/// receiving address. One is made only when the wallet has none (or only
/// one about to expire): opening Receive never makes a new address by
/// itself, which LightWallet did on every open.
class BeamReceiveModel extends ChangeNotifier {
  BeamReceiveModel(
    this.backend, {
    this.tick = const Duration(seconds: 2),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BeamReceiveBackend backend;

  /// How often the private-node state is re-read and a failed load retried.
  final Duration tick;

  final DateTime Function() _now;

  /// An address expiring sooner than this is not handed out again.
  static const minimumLifetime = Duration(hours: 24);

  /// Regular addresses being made, per wallet, so two screens open at once
  /// (desktop tab and dialog) never make two.
  static final Map<String, Future<String>> _making = {};

  Timer? _timer;
  bool _disposed = false;
  bool _ensureAddress = true;
  bool _reloading = false;
  bool _namesAsked = false;
  Timer? _slowTimer;
  bool _slow = false;

  String? _address;
  bool _fromCore = false;
  String? _problem;
  bool _connected = false;
  List<BeamAddress>? _own;
  Object? _listError;
  BeamPrivateReceive _private = const BeamPrivateReceive.blocked(
    BeamPrivateReceiveBlock.connecting,
  );
  List<String> _names = const [];
  bool _makingRegular = false;
  BeamAddressType? _makingPrivate;

  // ------------------------------------------------------------- reads

  /// The regular address shown on Receive; null until one is known.
  String? get address => _address;

  /// [address] was confirmed by the core this session (not only cached).
  bool get addressFromCore => _fromCore;

  /// Why no address can be shown, in the user's words.
  String? get problem => _problem;

  bool get loading => _address == null && _problem == null;

  /// Still loading after three seconds: say what is happening.
  bool get slow => loading && _slow;

  /// The last call reached the core.
  bool get connected => _connected;

  /// The wallet's own addresses; null until read from the core.
  List<BeamAddress>? get ownAddresses => _own;

  /// Why [ownAddresses] could not be read, when it could not.
  Object? get listError => _listError;

  /// Unexpired addresses, newest first.
  List<BeamAddress> get active => _sorted(
    (_own ?? const []).where((a) => a.own && !a.expired),
  );

  /// Expired addresses, newest first.
  List<BeamAddress> get expired => _sorted(
    (_own ?? const []).where((a) => a.own && a.expired),
  );

  BeamPrivateReceive get privateReceive => _private;

  /// BANS names this wallet owns ("alice.beam"); empty when it owns none
  /// or when names cannot be read with this core.
  List<String> get names => _names;

  bool get makingRegular => _makingRegular;

  /// The private type being made right now, if any.
  BeamAddressType? get makingPrivate => _makingPrivate;

  // ----------------------------------------------------------- lifecycle

  /// Shows the cached address at once, then reads the core. With
  /// [ensureAddress] (Receive) a regular address is made if the wallet has
  /// none; without it (the address list) nothing is ever made.
  Future<void> start({bool ensureAddress = true}) async {
    _ensureAddress = ensureAddress;
    _slowTimer = Timer(const Duration(seconds: 3), () {
      _slow = true;
      _notify();
    });
    if (ensureAddress) {
      final cached = backend.cachedAddress();
      if (cached.isNotEmpty) _address = cached;
    }
    _timer = Timer.periodic(tick, (_) => unawaited(_onTick()));
    await _refreshGate();
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _slowTimer?.cancel();
    super.dispose();
  }

  /// Reads the wallet's addresses again (and on Receive, makes sure there
  /// is one to show).
  Future<void> reload() async {
    if (_reloading || _disposed) return;
    _reloading = true;
    try {
      var own = await backend.api().addrList(own: true);
      _connected = true;
      _listError = null;
      if (_ensureAddress) {
        var current = pickCurrent(own, _now());
        if (current == null) {
          // The wallet makes its own first address when it opens; let it
          // finish before deciding none exists.
          await _waitLive();
          own = await backend.api().addrList(own: true);
          current = pickCurrent(own, _now());
        }
        if (current == null) {
          final token = await _makeRegular();
          own = await backend.api().addrList(own: true);
          current = _byToken(own, token) ?? pickCurrent(own, _now());
          _address = current?.address ?? token;
        } else {
          _address = current.address;
        }
        _fromCore = true;
        _problem = null;
      }
      _own = own;
      if (!_namesAsked) {
        _namesAsked = true;
        unawaited(_loadNames());
      }
    } on BeamConnectionException catch (e) {
      _connected = false;
      _listError = e;
      if (_address == null) _problem = backend.coreProblem();
    } catch (e) {
      backend.log('BEAM receive: could not read addresses ($e)');
      _listError = e;
      if (_address == null) _problem = BeamReceiveText.error(e);
    } finally {
      _reloading = false;
      _notify();
    }
  }

  Future<void> _onTick() async {
    if (_disposed) return;
    await _refreshGate();
    if (!_connected || (_ensureAddress && !_fromCore)) {
      await reload();
    }
  }

  Future<void> _refreshGate() async {
    bool wanted;
    try {
      wanted = await backend.privateNodeWanted();
    } catch (_) {
      wanted = false;
    }
    if (_disposed) return;
    final next = backend.privateReceive(wanted);
    if (next != _private) {
      _private = next;
      _notify();
    }
  }

  Future<void> _waitLive() async {
    try {
      await backend.whenLive().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      // The core answers; making an address is safe without the first sync.
    }
  }

  Future<void> _loadNames() async {
    try {
      final names = await backend.myNames();
      _names = List.unmodifiable(names);
    } catch (e) {
      // Names need the BANS shader and a core that may run it; without
      // them the screen simply shows no name.
      backend.log('BEAM receive: no BANS names ($e)');
      _names = const [];
    }
    _notify();
  }

  // ------------------------------------------------------------- actions

  /// Makes a new regular address and shows it. The old one keeps working.
  Future<void> newRegularAddress() async {
    if (_makingRegular) return;
    _makingRegular = true;
    _notify();
    try {
      final token = await _makeRegular(forceNew: true);
      _address = token;
      _fromCore = true;
      _problem = null;
      final own = await backend.api().addrList(own: true);
      _own = own;
      _address = _byToken(own, token)?.address ?? token;
    } finally {
      _makingRegular = false;
      _notify();
    }
  }

  /// An address of a private [type] (offline, max privacy or public),
  /// ready to give out. Max privacy and offline addresses are made new each
  /// time (each is good for one payment); a public address is reused.
  ///
  /// Throws when the core refuses, e.g. -32005 when the wallet is no
  /// longer on its own node.
  Future<String> privateAddress(BeamAddressType type) async {
    if (!_isPrivateType(type)) {
      throw ArgumentError.value(type, 'type', 'not a private address type');
    }
    if (!_private.available) {
      throw StateError('private receive is not available: $_private');
    }
    if (type == BeamAddressType.publicOffline) {
      final existing = active.where(
        (a) => a.type == BeamAddressType.publicOffline,
      );
      if (existing.isNotEmpty) return existing.first.address;
    }
    _makingPrivate = type;
    _notify();
    try {
      final token = await backend.api().createAddress(
        type: type,
        expiration: type == BeamAddressType.publicOffline
            ? BeamAddressExpiration.never
            : BeamAddressExpiration.auto,
        // One payment per offline address: ten (the core's own default)
        // makes an address too long for a QR code.
        offlinePayments: type == BeamAddressType.offline ? 1 : null,
      );
      try {
        _own = await backend.api().addrList(own: true);
      } catch (_) {
        // The address exists; the list catches up on the next read.
      }
      return token;
    } finally {
      _makingPrivate = null;
      _notify();
    }
  }

  /// Sets the label (the core's comment) of [address].
  Future<void> rename(BeamAddress address, String label) async {
    await backend.api().editAddress(address.address, comment: label.trim());
    _own = await backend.api().addrList(own: true);
    _notify();
  }

  /// Deletes [address] from the wallet.
  Future<void> delete(BeamAddress address) async {
    await backend.api().deleteAddress(address.address);
    // Campfire's cache follows in the background; the list does not wait.
    unawaited(
      backend.forgetAddress(address.address).catchError((Object e) {
        backend.log('BEAM receive: cache not updated after delete ($e)');
      }),
    );
    _own = await backend.api().addrList(own: true);
    if (_address == address.address) {
      _address = null;
      _fromCore = false;
    }
    _notify();
    if (_ensureAddress && _address == null) await reload();
  }

  /// Makes the first address from an empty address list.
  Future<void> makeFirstAddress() async {
    if (_makingRegular) return;
    _makingRegular = true;
    _notify();
    try {
      await _makeRegular();
      _own = await backend.api().addrList(own: true);
    } finally {
      _makingRegular = false;
      _notify();
    }
  }

  // ------------------------------------------------------------- helpers

  /// The address Receive shows from [own]: the newest unexpired regular
  /// address that does not expire within [minimumLifetime].
  static BeamAddress? pickCurrent(List<BeamAddress> own, DateTime now) {
    BeamAddress? best;
    for (final a in own) {
      if (!a.own || a.expired || a.type != BeamAddressType.regular) continue;
      final ends = a.expiresAt;
      if (ends != null && ends.isBefore(now.add(minimumLifetime))) continue;
      if (best == null || a.createTime > best.createTime) best = a;
    }
    return best;
  }

  /// The address Receive shows, for the list's badge.
  BeamAddress? get receiveAddress {
    final own = _own;
    if (own == null) return null;
    final shown = _address;
    return (shown == null ? null : _byToken(own, shown)) ??
        pickCurrent(own, _now());
  }

  /// Not reachable: the last read failed because the core is not
  /// connected (as opposed to refusing).
  bool get offline => !_connected && _listError is BeamConnectionException;

  Future<String> _makeRegular({bool forceNew = false}) {
    final id = backend.walletId;
    final running = _making[id];
    if (running != null && !forceNew) return running;
    final made = backend.api().createAddress(
      expiration: BeamAddressExpiration.never,
    );
    _making[id] = made;
    return made.whenComplete(() {
      if (identical(_making[id], made)) _making.remove(id);
    });
  }

  static BeamAddress? _byToken(List<BeamAddress> own, String token) {
    for (final a in own) {
      if (a.address == token) return a;
    }
    return null;
  }

  static bool _isPrivateType(BeamAddressType t) =>
      t == BeamAddressType.offline ||
      t == BeamAddressType.maxPrivacy ||
      t == BeamAddressType.publicOffline;

  static List<BeamAddress> _sorted(Iterable<BeamAddress> list) =>
      list.toList()..sort((a, b) => b.createTime.compareTo(a.createTime));

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
