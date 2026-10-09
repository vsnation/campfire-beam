/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web3dart/web3dart.dart' as web3;

import '../../app_config.dart';
import '../../networking/socks5_tunnel.dart';
import '../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../services/tor_service.dart';
import '../../utilities/eth_rpc_url.dart';
import '../../utilities/prefs.dart';

/// Tor is on, but not connected yet: the request was not sent at all
/// (it never falls back to a direct connection).
class EthTorNotConnectedException implements IOException {
  const EthTorNotConnectedException();

  @override
  String toString() =>
      'Tor is on but not connected, so nothing was sent to Ethereum';
}

/// A Tor (.onion) address while Tor is off: not sent, so the name never
/// reaches this device's DNS.
class EthOnionNeedsTorException implements IOException {
  const EthOnionNeedsTorException();

  @override
  String toString() => 'A .onion address needs Tor; nothing was sent';
}

/// Decides, for one request, how it leaves this device: null for a direct
/// connection, or Tor's SOCKS5 proxy. Throws to send nothing.
typedef EthRoute = SocksProxy? Function(Uri url);

/// Whether [host] is this machine (127.0.0.0/8, ::1, localhost).
bool isLoopbackHost(String host) {
  final h = host.toLowerCase();
  if (h == 'localhost' || h.endsWith('.localhost')) return true;
  final ip = InternetAddress.tryParse(
    h.startsWith('[') && h.endsWith(']') ? h.substring(1, h.length - 1) : h,
  );
  return ip != null && ip.isLoopback;
}

/// Campfire's rule, read at every request (the user's Tor switch, owner
/// 2026-10-09: "When the user turns Tor on, it must proxy ALL requests"):
/// * Tor off, or a build without Tor: direct.
/// * Tor on and connected: through Tor's SOCKS5 proxy, which also resolves
///   the host name.
/// * Tor on, not connected: [EthTorNotConnectedException]; nothing is sent.
/// * A .onion address with Tor off: [EthOnionNeedsTorException].
///
/// The user's own server on this machine is reached directly either way: no
/// packet leaves the device, and Tor refuses loopback addresses. (The BEAM
/// core does the same for a node on 127.0.0.1, `BeamNodeRoute`.)
SocksProxy? campfireEthRoute(Uri url) => ethRouteFor(
  url,
  torOn: AppConfig.hasFeature(AppFeature.tor) && Prefs.instance.useTor,
  torStatus: () => TorService.sharedInstance.status,
  proxy: () => TorService.sharedInstance.getProxyInfo(),
);

/// [campfireEthRoute] without Campfire's singletons, for tests.
SocksProxy? ethRouteFor(
  Uri url, {
  required bool torOn,
  required TorConnectionStatus Function() torStatus,
  required SocksProxy Function() proxy,
}) {
  if (isLoopbackHost(url.host)) return null;
  if (!torOn) {
    if (EthRpcUrl.isOnion(url.host)) throw const EthOnionNeedsTorException();
    return null;
  }
  if (torStatus() != TorConnectionStatus.connected) {
    throw const EthTorNotConnectedException();
  }
  try {
    return proxy();
  } catch (_) {
    throw const EthTorNotConnectedException();
  }
}

/// The HTTP client every Ethereum JSON-RPC call goes through (web3dart has
/// no proxy option of its own). Each request asks [route] how to go out,
/// so turning Tor on or off applies to the next request, and direct and Tor
/// connections are pooled apart: a connection opened directly is never
/// reused once Tor is on.
class EthRpcHttpClient extends http.BaseClient {
  EthRpcHttpClient({
    EthRoute? route,
    this.connectionTimeout = const Duration(seconds: 30),
  }) : _route = route ?? campfireEthRoute;

  final EthRoute _route;

  /// For opening a connection (through Tor: the whole tunnel and TLS).
  final Duration connectionTimeout;

  http.Client? _direct;
  ({SocksProxy proxy, http.Client client})? _viaTor;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw http.ClientException('This client was closed', request.url);
    }
    final proxy = _route(request.url);
    return _clientFor(proxy).send(request);
  }

  http.Client _clientFor(SocksProxy? proxy) {
    if (proxy == null) {
      return _direct ??= IOClient(
        HttpClient()..connectionTimeout = connectionTimeout,
      );
    }
    final current = _viaTor;
    if (current != null &&
        current.proxy.host == proxy.host &&
        current.proxy.port == proxy.port) {
      return current.client;
    }
    // Tor restarted on another port: connections to the old one are dead.
    current?.client.close();
    final httpClient = HttpClient()..connectionTimeout = connectionTimeout;
    routeHttpClientThroughSocks5(httpClient, proxy);
    final client = IOClient(httpClient);
    _viaTor = (proxy: proxy, client: client);
    return client;
  }

  @override
  void close() {
    _closed = true;
    _direct?.close();
    _viaTor?.client.close();
  }
}

/// The HTTP client for any Ethereum JSON-RPC: Tor's SOCKS proxy when Tor
/// is on, direct when it is off. With Tor on but not connected, each
/// request throws [EthTorNotConnectedException] and nothing is sent; the
/// rule is read per request, so it follows the Tor switch for the client's
/// whole life. Close it when done.
http.Client createEthHttpClient() => EthRpcHttpClient();

/// A web3dart client for the RPC at [url] whose every call follows
/// [campfireEthRoute] (or [route]). [httpClient] lets a wallet share one
/// connection pool between calls.
web3.Web3Client ethWeb3Client(
  String url, {
  EthRpcHttpClient? httpClient,
  EthRoute? route,
}) => web3.Web3Client(url, httpClient ?? EthRpcHttpClient(route: route));
