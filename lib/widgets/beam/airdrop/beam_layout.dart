/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../background.dart';
import '../../custom_buttons/app_bar_icon_button.dart';
import '../../desktop/desktop_app_bar.dart';
import '../../desktop/desktop_scaffold.dart';

/// Overrides Campfire's platform check ([Util.isDesktop]) for the BEAM
/// screens below it. The app never needs it; golden tests use it to render
/// the phone layout on a desktop test host.
class BeamLayoutScope extends InheritedWidget {
  const BeamLayoutScope({
    super.key,
    required this.desktop,
    required super.child,
  });

  final bool desktop;

  /// Whether the BEAM screens at [context] use the desktop layout.
  static bool isDesktop(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BeamLayoutScope>()?.desktop ??
      Util.isDesktop;

  @override
  bool updateShouldNotify(BeamLayoutScope oldWidget) =>
      oldWidget.desktop != desktop;
}

/// The frame of every BEAM contract screen, built the way Campfire's own
/// pages are (`SparkCoinsView`, `ConfirmTransactionView`):
///
/// * phone: [Background] + [Scaffold] with Campfire's app bar and back
///   arrow, the content scrolling, and [bottom] pinned under it so the
///   primary button is on screen without scrolling (USER_PSYCHOLOGY §1.3);
/// * desktop: [DesktopScaffold] + [DesktopAppBar], content centred at
///   [desktopMaxWidth], and [bottom] right under the content when it fits
///   (never a window-height gap between a field and its button), pinned
///   under it only when the content has to scroll.
///
/// Where the content scrolls under [bottom], its last few pixels fade out,
/// so a card cut off at the edge reads as "more below" rather than as a
/// card glued to the notice or button under it.
class BeamPageScaffold extends StatelessWidget {
  const BeamPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.bottom,
    this.onBack,
    this.desktopMaxWidth = 640,
  });

  final String title;
  final Widget body;

  /// The primary action area: one [PrimaryButton], optionally with a
  /// secondary one above it.
  final Widget? bottom;

  /// Defaults to popping the route.
  final VoidCallback? onBack;
  final double desktopMaxWidth;

  /// How far the fade above [bottom] reaches.
  static const double _fade = 16;

  /// [scroll], fading out over its last [_fade] pixels when there is a
  /// [bottom] under it. Scrolled to the end, only the scroll view's own
  /// bottom padding is in the fade, so nothing stays faded.
  Widget _fadeAboveBottom(Widget scroll) => bottom == null
      ? scroll
      : ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final solid = rect.height <= _fade
                ? 0.0
                : 1 - _fade / rect.height;
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: const [Colors.black, Colors.black, Colors.transparent],
              stops: [0, solid, 1],
            ).createShader(rect);
          },
          child: scroll,
        );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final back = onBack ?? () => Navigator.of(context).maybePop();
    if (BeamLayoutScope.isDesktop(context)) {
      return DesktopScaffold(
        appBar: DesktopAppBar(
          background: colors.popupBG,
          isCompactHeight: true,
          useSpacers: false,
          leading: Expanded(
            child: Row(
              children: [
                const SizedBox(width: 32),
                AppBarIconButton(
                  size: 32,
                  color: colors.textFieldDefaultBG,
                  shadows: const [],
                  semanticsLabel: 'Back',
                  icon: SvgPicture.asset(
                    Assets.svg.arrowLeft,
                    width: 18,
                    height: 18,
                    colorFilter: ColorFilter.mode(
                      colors.topNavIconPrimary,
                      BlendMode.srcIn,
                    ),
                  ),
                  onPressed: back,
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    title,
                    style: STextStyles.desktopH3(context),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: desktopMaxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: _fadeAboveBottom(
                    SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      child: body,
                    ),
                  ),
                ),
                if (bottom != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    child: bottom,
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          automaticallyImplyLeading: false,
          titleSpacing: 0,
          // Campfire's AppBarBackButton, phone branch: it reads the platform
          // itself, which a BeamLayoutScope cannot override.
          leading: Padding(
            padding: const EdgeInsets.all(10),
            child: AppBarIconButton(
              size: 32,
              color: colors.background,
              shadows: const [],
              semanticsLabel: 'Back',
              icon: SvgPicture.asset(
                Assets.svg.arrowLeft,
                width: 24,
                height: 24,
                colorFilter: ColorFilter.mode(
                  colors.topNavIconPrimary,
                  BlendMode.srcIn,
                ),
              ),
              onPressed: back,
            ),
          ),
          title: Text(
            title,
            style: STextStyles.navBarTitle(context),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _fadeAboveBottom(
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: body,
                  ),
                ),
              ),
              if (bottom != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: bottom,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Vertical gap between blocks, a little wider on desktop.
class BeamGap extends StatelessWidget {
  // A spacer: nothing to key, and `BeamGap(16)` reads better than a named
  // argument at the many call sites.
  // ignore: use_key_in_widget_constructors
  const BeamGap([this.mobile = 12]);

  final double mobile;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: BeamLayoutScope.isDesktop(context) ? mobile * 4 / 3 : mobile,
  );
}
