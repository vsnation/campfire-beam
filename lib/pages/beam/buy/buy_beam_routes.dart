/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// How a Buy BEAM screen opens: a page on a phone, a dialog on desktop
// (as `showDexPage` does), as a route of its own so one screen can take
// another's place: once a deposit address exists, the form gives way to
// it, and Back goes to the wallet, not to a form already used.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../widgets/beam/dex/dex_widgets.dart';
import '../../../widgets/desktop/desktop_dialog.dart';

/// A route for [builder]: a page on a phone, a dialog on desktop.
Route<T> buyBeamRoute<T>(
  BuildContext context,
  DexLayout layout,
  WidgetBuilder builder,
) {
  if (!layout.desktop) return MaterialPageRoute<T>(builder: builder);
  return DialogRoute<T>(
    context: context,
    // A click beside it must not drop a half-filled form; Escape closes
    // it, as desktop dialogs do.
    barrierDismissible: false,
    builder: (context) => CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(Navigator.of(context).maybePop()),
      },
      child: Focus(
        autofocus: true,
        child: DesktopDialog(
          maxWidth: 580,
          maxHeight: 760,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: builder(context),
          ),
        ),
      ),
    ),
  );
}

/// Opens [builder] on top of [context]'s screen (a dialog over the whole
/// window on desktop, as `showDialog` puts it).
Future<T?> showBuyBeamPage<T>(
  BuildContext context,
  DexLayout layout,
  WidgetBuilder builder,
) => Navigator.of(
  context,
  rootNavigator: layout.desktop,
).push<T>(buyBeamRoute<T>(context, layout, builder));
