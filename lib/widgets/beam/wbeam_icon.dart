/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';

import '../../themes/coin_icon_provider.dart';
import '../../wallets/ethereum/wbeam.dart';

export '../../wallets/ethereum/wbeam.dart';

/// WBEAM drawn as BEAM: BEAM's own icon from the theme, nothing downloaded.
class WbeamIcon extends ConsumerWidget {
  const WbeamIcon({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SvgPicture.file(
    File(ref.watch(coinIconProvider(wbeamCoin))),
    key: const ValueKey('wbeam-icon'),
    width: size,
    height: size,
  );
}
