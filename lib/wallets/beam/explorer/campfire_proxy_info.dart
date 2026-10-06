/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import '../../../app_config.dart';
import '../../../services/tor_service.dart';
import '../../../utilities/prefs.dart';
import 'beam_explorer_client.dart';

/// Campfire's Tor rule for outgoing HTTP, the same one the price service and
/// node checks use: with Tor switched on, requests go through Tor's SOCKS
/// proxy. If Tor is on but not connected, [TorService.getProxyInfo] throws
/// and [BeamExplorerClient] sends nothing rather than leak onto clearnet.
///
/// Pass this as `BeamExplorerClient(proxyInfo: campfireProxyInfo)`.
BeamProxyInfo? campfireProxyInfo() {
  if (!AppConfig.hasFeature(AppFeature.tor)) return null;
  if (!Prefs.instance.useTor) return null;
  return TorService.sharedInstance.getProxyInfo();
}
