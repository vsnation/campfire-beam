/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/widgets.dart';

import '../../../utilities/util.dart';

/// Overrides Campfire's platform check ([Util.isDesktop]) for the BEAM
/// asset screens below it. The app never sets it; golden tests use it to
/// render the phone layout on a desktop test host. (Campfire's shared
/// widgets inside, such as buttons, still follow the real platform.)
class BeamAssetLayout extends InheritedWidget {
  const BeamAssetLayout({
    super.key,
    required this.desktop,
    required super.child,
  });

  final bool desktop;

  static bool isDesktop(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BeamAssetLayout>()?.desktop ??
      Util.isDesktop;

  @override
  bool updateShouldNotify(BeamAssetLayout oldWidget) =>
      oldWidget.desktop != desktop;
}
