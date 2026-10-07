/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/dapps/dapp_bridge_js.dart';

/// `#rrggbb` / `#rrggbbaa` (CSS order) as a [Color]; [fallback] for anything
/// else.
Color dappCssColour(Object? css, Color fallback) {
  if (css is! String) return fallback;
  final m = RegExp(r'^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$').firstMatch(css);
  if (m == null) return fallback;
  final rgb = int.parse(m.group(1)!, radix: 16);
  final a = m.group(2) == null ? 0xff : int.parse(m.group(2)!, radix: 16);
  return Color((a << 24) | rgb);
}

/// The page colour dApps are drawn for (`background_main`): what the
/// webview shows before the page paints, where the platform lets Campfire
/// set it (Android, iOS; macOS WKWebView ignores it).
Color dappBackgroundColour([Map<String, Object> style = dappDefaultStyle]) =>
    dappCssColour(style['background_main'], const Color(0xff042548));

/// The area a dApp is shown in, painted the way the BEAM desktop wallet
/// paints the window behind its transparent dApp view, exactly as
/// [dappHostStylesheet] paints the page: `background_main`, with the tail
/// of the `background_main_top` gradient at the top (from
/// `appsGradientOffset` px above the area to `appsGradientTop` px into it).
///
/// So nothing light ever shows around or behind a dApp: not while it
/// loads, not before the webview's first paint, not in a phone's safe-area
/// margins.
class DappSurface extends StatelessWidget {
  const DappSurface({super.key, this.style = dappDefaultStyle, this.child});

  final Map<String, Object> style;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final main = dappBackgroundColour(style);
    final top = dappCssColour(style['background_main_top'], main);
    final offset = style['appsGradientOffset'];
    final end = style['appsGradientTop'];
    final from = offset is int ? offset.toDouble() : 0.0;
    final to = end is int ? end.toDouble() : 0.0;
    // The colour the gradient has reached at the area's top edge.
    final atTop = to > from && from < 0
        ? Color.lerp(top, main, -from / (to - from))!
        : top;
    return ColoredBox(
      color: main,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (to > 0)
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: to,
                width: double.infinity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [atTop, main],
                    ),
                  ),
                ),
              ),
            ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

/// What the dApp area shows until the page has loaded: a progress bar and
/// "Opening <name>…" on the dApp's own background, in its text colour.
class DappOpening extends StatelessWidget {
  const DappOpening({
    super.key,
    required this.name,
    this.style = dappDefaultStyle,
  });

  final String name;
  final Map<String, Object> style;

  @override
  Widget build(BuildContext context) {
    final text = dappCssColour(style['content_main'], Colors.white);
    return DappSurface(
      style: style,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                color: text.withValues(alpha: 0.8),
                backgroundColor: text.withValues(alpha: 0.15),
              ),
              const SizedBox(height: 8),
              Text(
                "Opening $name…",
                style: STextStyles.smallMed12(context)
                    .copyWith(color: text.withValues(alpha: 0.8)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
