/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../services/ethereum/ethereum_api.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';

/// Under the Ethereum node list: the RPC chosen there is not the only
/// server an Ethereum wallet talks to. History, fees and token details come
/// from Stack Wallet's index whichever RPC is picked.
class EthIndexNote extends StatelessWidget {
  const EthIndexNote({super.key});

  static String get text {
    final host = Uri.tryParse(EthereumAPI.stackBaseServer)?.host;
    return "Payment history, fee estimates and token details come from Stack "
        "Wallet's Ethereum index (${host ?? EthereumAPI.stackBaseServer}), "
        "through Tor when Tor is on.";
  }

  @override
  Widget build(BuildContext context) => Text(
    text,
    key: const Key('ethIndexNote'),
    style: Util.isDesktop
        ? STextStyles.desktopTextExtraExtraSmall(context)
        : STextStyles.itemSubtitle12(context),
  );
}
