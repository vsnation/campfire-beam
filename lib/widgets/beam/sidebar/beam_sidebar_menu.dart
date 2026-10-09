/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's desktop side menu with every BEAM feature in it.
//
// Spec (USER_PSYCHOLOGY §6):
//   1. Job: get to any part of the wallet in one click.
//   2. Primary CTA: none of its own; the selected item is the one pill.
//   3. Clicks from app open: every BEAM feature 1, its sub-tasks 2.
//
// Layout: Campfire's own pieces (living logo, app name, DesktopMenuItem
// pills, Exit, minimize), with the Tor line replaced by the BEAM node chip
// (Tor stays as an icon beside it). Thirteen items plus Exit do not fit an
// 800 px window at Campfire's 52 px rows, so the BEAM build uses 40 px rows
// 1 px apart and a smaller logo: the whole menu never scrolls in the
// 1280 × 800 window (beam_sidebar_menu_test.dart measures it); a shorter
// window scrolls the items, never the logo or Exit.
//
// Exit-intent (§1.7): a menu that scrolls, so Settings is hidden below the
// fold (fits); icons that mean nothing once minimized (every item has a
// tooltip then); a status line that claims "connected" when it is not (the
// chip only says what the core reports).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../app_config.dart';
import '../../../pages_desktop_specific/desktop_menu.dart';
import '../../../pages_desktop_specific/desktop_menu_item.dart';
import '../../../providers/desktop/current_desktop_menu_item.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/beam_app_identity.dart';
import '../../../utilities/text_styles.dart';
import '../../desktop/living_stack_icon.dart';
import '../quit/beam_quit_guard.dart';
import 'beam_sidebar.dart';
import 'beam_sidebar_node_chip.dart';

/// The BEAM build's side menu. [DesktopMenu] owns its width and selection;
/// this lays the items out.
class BeamSidebarMenu extends ConsumerStatefulWidget {
  const BeamSidebarMenu({
    super.key,
    required this.width,
    required this.expanded,
    required this.duration,
    required this.onToggleMinimize,
    required this.onSelected,
  });

  final double width;

  /// Labels shown (false: icons only, with tooltips).
  final bool expanded;
  final Duration duration;
  final VoidCallback onToggleMinimize;
  final void Function(DesktopMenuItemId) onSelected;

  /// Item rows of the BEAM build (Campfire's are 52).
  static const double itemHeight = 40;

  @override
  ConsumerState<BeamSidebarMenu> createState() => _BeamSidebarMenuState();
}

class _BeamSidebarMenuState extends ConsumerState<BeamSidebarMenu> {
  final Map<String, DMIController> _controllers = {};

  DMIController _controller(String key) =>
      _controllers.putIfAbsent(key, DMIController.new);

  @override
  void didUpdateWidget(covariant BeamSidebarMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded != widget.expanded) {
      // DesktopMenuItem animates its label away on toggle.
      for (final c in _controllers.values) {
        c.toggle?.call();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _item(String key, DesktopMenuItemId id, String label, Widget icon) =>
      DesktopMenuItem<DesktopMenuItemId>(
        key: ValueKey(key),
        duration: widget.duration,
        icon: icon,
        label: label,
        value: id,
        onChanged: widget.onSelected,
        controller: _controller(key),
        isExpandedInitially: widget.expanded,
        dense: true,
        tooltip: label,
      );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final expanded = widget.expanded;
    final duration = widget.duration;
    // 16 px either side when expanded, 8 when minimized (Campfire's).
    final inner = expanded ? widget.width - 32 : widget.width - 16;

    const gap = SizedBox(height: 1);
    final items = <Widget>[
      _item(
        'myStack',
        DesktopMenuItemId.myStack,
        'My ${AppConfig.prefix}',
        const DesktopMyStackIcon(),
      ),
      for (final d in BeamSidebarDestination.shown) ...[
        gap,
        _item(
          d.menuKey.value,
          d.menuId,
          d.label,
          BeamSidebarMenuIcon(destination: d),
        ),
      ],
      Padding(
        padding: EdgeInsets.symmetric(
          vertical: 7,
          horizontal: expanded ? 12 : 8,
        ),
        child: Container(
          key: const Key('beamSidebarDivider'),
          height: 1,
          color: colors.textFieldDefaultBG,
        ),
      ),
      _item(
        'notifications',
        DesktopMenuItemId.notifications,
        'Notifications',
        const DesktopNotificationsIcon(),
      ),
      gap,
      _item(
        'addressBook',
        DesktopMenuItemId.addressBook,
        'Address Book',
        const DesktopAddressBookIcon(),
      ),
      gap,
      _item(
        'settings',
        DesktopMenuItemId.settings,
        'Settings',
        const DesktopSettingsIcon(),
      ),
      gap,
      _item(
        'support',
        DesktopMenuItemId.support,
        'Support',
        const DesktopSupportIcon(),
      ),
      gap,
      _item(
        'about',
        DesktopMenuItemId.about,
        'About',
        const DesktopAboutIcon(),
      ),
    ];

    return Material(
      key: const Key('beamSidebarMenu'),
      color: colors.popupBG,
      child: AnimatedContainer(
        width: widget.width,
        duration: duration,
        child: Column(
          children: [
            const SizedBox(height: 16),
            AnimatedContainer(
              duration: duration,
              width: expanded ? 48 : 32,
              height: expanded ? 48 : 32,
              child: LivingStackIcon(onPressed: widget.onToggleMinimize),
            ),
            const SizedBox(height: 6),
            AnimatedOpacity(
              duration: duration,
              opacity: expanded ? 1 : 0,
              child: SizedBox(
                height: 24,
                child: Text(
                  BeamAppIdentity.displayName,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.fade,
                  style: STextStyles.desktopH2(context)
                      .copyWith(fontSize: 18, height: 23.4 / 18),
                ),
              ),
            ),
            const SizedBox(height: 10),
            AnimatedContainer(
              duration: duration,
              width: inner,
              child: BeamSidebarStatusLine(
                showTor: AppConfig.hasFeature(AppFeature.tor),
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: AnimatedContainer(
                duration: duration,
                width: inner,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        key: const Key('beamSidebarItems'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: items,
                        ),
                      ),
                    ),
                    if (!Platform.isIOS) ...[
                      const SizedBox(height: 8),
                      DesktopMenuItem<int>(
                        key: const ValueKey('exit'),
                        duration: duration,
                        labelLength: 123,
                        icon: const DesktopExitIcon(),
                        label: 'Exit',
                        value: 7,
                        onChanged: (_) => unawaited(beamDesktopExit(context)),
                        controller: _controller('exit'),
                        isExpandedInitially: expanded,
                        dense: true,
                        tooltip: 'Exit',
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Row(
              children: [
                const Spacer(),
                IconButton(
                  key: const Key('beamSidebarMinimize'),
                  tooltip: expanded ? 'Show icons only' : 'Show labels',
                  splashRadius: 18,
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.standard,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 36,
                  ),
                  onPressed: widget.onToggleMinimize,
                  icon: SvgPicture.asset(
                    Assets.svg.minimize,
                    height: 12,
                    width: 12,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A BEAM item's icon in Campfire's menu colours (as DesktopExchangeIcon).
class BeamSidebarMenuIcon extends ConsumerWidget {
  const BeamSidebarMenuIcon({super.key, required this.destination});

  final BeamSidebarDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final selected =
        ref.watch(currentDesktopMenuItemProvider.state).state ==
        destination.menuId;
    // A square box, so a wide glyph (dApps' box) never pushes its label
    // out of line with the others.
    return SizedBox.square(
      dimension: 20,
      child: SvgPicture.asset(
        destination.icon,
        width: 20,
        height: 20,
        colorFilter: ColorFilter.mode(
          selected
              ? colors.accentColorDark
              : colors.accentColorDark.withValues(alpha: 0.8),
          BlendMode.srcIn,
        ),
      ),
    );
  }
}
