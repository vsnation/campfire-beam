/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// Campfire's REAL desktop home (DesktopHomeView → DesktopMenu) in the BEAM
// build: every BEAM item in the menu, in order; it fits the 1280 × 800
// window; a shorter window scrolls; minimized it keeps working with
// tooltips; the node chip is honest and opens Node & sync; other builds
// keep Campfire's own menu. Goldens go to docs/beam/screenshots/B-SIDEBAR/.
//
//   CFB_HOST_WORKDIR=/private/tmp/cfb-sidebar scripts/beam/host_test.sh \
//       --no-analyze --update-goldens --copy-goldens test/beam/sidebar_ui

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stackwallet/pages_desktop_specific/beam/node/desktop_beam_node_sync_dialog.dart';
import 'package:stackwallet/pages_desktop_specific/beam/sidebar/beam_sidebar_scaffold.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu.dart';
import 'package:stackwallet/pages_desktop_specific/desktop_menu_item.dart';
import 'package:stackwallet/pages_desktop_specific/my_stack_view/my_stack_view.dart';
import 'package:stackwallet/pages_desktop_specific/settings/settings_menu.dart';
import 'package:stackwallet/providers/desktop/current_desktop_menu_item.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar_menu.dart';
import 'package:stackwallet/widgets/beam/sidebar/beam_sidebar_node_chip.dart';
import 'package:stackwallet/widgets/desktop/desktop_tor_status_button.dart';

import 'sidebar_harness.dart';

const _beamOrder = [
  'My Campfire',
  'Swap',
  'Bridge',
  'Assets',
  'Names',
  'dApps',
  'Airdrops',
  'Tokens',
  'Notifications',
  'Address Book',
  'Settings',
  'Support',
  'About',
  'Exit',
];

double _bottomOf(WidgetTester tester, Finder f) => tester.getRect(f).bottom;

ScrollPosition _itemsScroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('beamSidebarItems')),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

void main() {
  final db = WiringDb();
  setUpAll(db.open);
  tearDownAll(db.close);

  testWidgets('fits the 1280 × 800 window without scrolling', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(tester, wallets: [wallet]);
    expect(_itemsScroll(tester).maxScrollExtent, 0);
    final menu = tester.getRect(find.byKey(const Key('beamSidebarMenu')));
    expect(menu.height, 800);
    for (final label in _beamOrder) {
      final item = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is DesktopMenuItem),
      );
      final r = tester.getRect(item);
      expect(r.top, greaterThanOrEqualTo(0), reason: label);
      expect(r.bottom, lessThanOrEqualTo(800), reason: label);
    }
    expect(
      _bottomOf(tester, find.byKey(const Key('beamSidebarMinimize'))),
      lessThanOrEqualTo(800),
    );
    await finishSidebar(tester);
  });

  testWidgets('a shorter window scrolls the items, never the logo or Exit', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    final container = await pumpSidebar(
      tester,
      wallets: [wallet],
      size: const Size(1280, 600),
    );
    final scroll = _itemsScroll(tester);
    expect(scroll.maxScrollExtent, greaterThan(0));
    expect(
      _bottomOf(tester, find.byKey(const ValueKey('exit'))),
      lessThanOrEqualTo(600),
    );
    // About, at the end of the list, is reached by scrolling.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('about')),
      60,
      scrollable: find.descendant(
        of: find.byKey(const Key('beamSidebarItems')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('about')));
    await settle(tester, rounds: 1);
    expect(
      container.read(currentDesktopMenuItemProvider.state).state,
      DesktopMenuItemId.about,
    );
    await finishSidebar(tester);
  });

  testWidgets('minimized: icons only, each with a tooltip, still navigating', (
    tester,
  ) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    final container = await pumpSidebar(tester, wallets: [wallet]);
    await tapMenu(tester, BeamSidebarDestination.swap.menuKey);
    await tester.tap(find.byKey(const Key('beamSidebarMinimize')));
    await settle(tester, rounds: 2);

    expect(tester.getSize(find.byKey(const Key('beamSidebarMenu'))).width, 72);
    // Labels are gone, every item shows its label as a tooltip.
    for (final e
        in find.byWidgetPredicate((w) => w is DesktopMenuItem).evaluate()) {
      final item = e.widget as DesktopMenuItem;
      final visibility = tester.widget<TooltipVisibility>(
        find.descendant(
          of: find.byWidget(item),
          matching: find.byType(TooltipVisibility),
        ),
      );
      expect(visibility.visible, isTrue, reason: item.label);
      final tip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byWidget(item),
          matching: find.byType(Tooltip),
        ),
      );
      expect(tip.message, item.label);
      expect(
        tester.getSize(
          find.descendant(
            of: find.byWidget(item),
            matching: find.byType(TextButton),
          ),
        ),
        const Size(56, BeamSidebarMenu.itemHeight),
      );
    }
    // The chip is an icon with its state as the tooltip.
    expect(find.byKey(const Key('beamSidebarNodeChipLabel')), findsNothing);
    expect(find.byKey(const Key('beamSidebarTorButton')), findsNothing);
    expect(_itemsScroll(tester).maxScrollExtent, 0);

    // A hover shows the tooltip (one more "Names" on screen: the label
    // stays in the tree at zero width).
    final namesBefore = find.text('Names').evaluate().length;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(
      tester.getCenter(find.byKey(BeamSidebarDestination.names.menuKey)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Names').evaluate().length, namesBefore + 1);

    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/menu_minimized.png'),
    );
    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 2));

    // Still navigates.
    await tapMenu(tester, BeamSidebarDestination.assets.menuKey);
    expect(
      container.read(currentDesktopMenuItemProvider.state).state,
      DesktopMenuItemId.beamAssets,
    );
    expect(find.byKey(const Key('beamSidebarTitle')), findsOneWidget);

    // And expands again.
    await tester.tap(find.byKey(const Key('beamSidebarMinimize')));
    await settle(tester, rounds: 2);
    expect(tester.getSize(find.byKey(const Key('beamSidebarMenu'))).width, 225);
    for (final e
        in find.byWidgetPredicate((w) => w is DesktopMenuItem).evaluate()) {
      expect(
        tester
            .widget<TooltipVisibility>(
              find.descendant(
                of: find.byWidget(e.widget),
                matching: find.byType(TooltipVisibility),
              ),
            )
            .visible,
        isFalse,
      );
    }
    await finishSidebar(tester);
  });

  testWidgets('the node chip is honest and opens Node & sync', (tester) async {
    final behind = await openBeamWallet(
      tester,
      db,
      core: SidebarCore(),
      explorerHeight: kTip + 42,
      name: 'Behind BEAM',
    );
    await pumpSidebar(tester, wallets: [behind]);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('beamSidebarNodeChipLabel')))
          .data,
      'Catching up',
    );
    // One wallet: nothing to tell apart.
    expect(
      tester
          .widget<Tooltip>(
            find.ancestor(
              of: find.byKey(const Key('beamSidebarNodeChip')),
              matching: find.byType(Tooltip),
            ),
          )
          .message,
      'Node & sync',
    );
    await tester.tap(find.byKey(const Key('beamSidebarNodeChip')));
    await settle(tester, rounds: 2);
    expect(find.byType(DesktopBeamNodeSyncDialog), findsOneWidget);
    await closeRouteOf(tester, find.byType(DesktopBeamNodeSyncDialog));
    await finishSidebar(tester);
  });

  // On the wallet list nothing said whose node the chip describes.
  testWidgets('several wallets: the chip names the wallet it describes', (
    tester,
  ) async {
    final a = await openBeamWallet(tester, db, core: SidebarCore(), name: 'A');
    final b = await openBeamWallet(tester, db, core: SidebarCore(), name: 'B');
    final container = await pumpSidebar(tester, wallets: [a, b]);
    container.read(pBeamSidebarWalletChoice.notifier).choose(b.walletId);
    await tester.pump();
    final described = container.read(pBeamSidebarWallet).wallet;
    expect(described?.info.name, 'B');
    final tip = tester.widget<Tooltip>(
      find.ancestor(
        of: find.byKey(const Key('beamSidebarNodeChip')),
        matching: find.byType(Tooltip),
      ),
    );
    expect(tip.message, 'B · Node & sync');
    await finishSidebar(tester);
  });

  testWidgets('no BEAM wallet: the chip says "Not connected" and opens '
      'Settings → Nodes', (tester) async {
    final container = await pumpSidebar(tester, wallets: const []);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('beamSidebarNodeChipLabel')))
          .data,
      'Not connected',
    );
    // The longest state fits beside the Tor icon, without an ellipsis.
    expect(
      tester
          .renderObject<RenderParagraph>(
            find.byKey(const Key('beamSidebarNodeChipLabel')),
          )
          .didExceedMaxLines,
      isFalse,
    );
    await tester.tap(find.byKey(const Key('beamSidebarNodeChip')));
    expect(
      container.read(currentDesktopMenuItemProvider.state).state,
      DesktopMenuItemId.settings,
    );
    expect(container.read(selectedSettingsMenuItemStateProvider), 5);
    // Campfire's settings pages read secure storage, which a widget test
    // has no unlocked instance of: back to My Campfire before the frame.
    container.read(currentDesktopMenuItemProvider.state).state =
        DesktopMenuItemId.myStack;
    await finishSidebar(tester);
  });

  testWidgets('other builds keep Campfire\'s own menu', (tester) async {
    BeamSidebar.debugEnabled = false;
    await pumpSidebar(tester, wallets: const []);
    expect(find.byType(DesktopMenu), findsOneWidget);
    expect(find.byType(BeamSidebarMenu), findsNothing);
    final labels = menuLabels(tester);
    for (final d in BeamSidebarDestination.values) {
      expect(find.byKey(d.menuKey), findsNothing);
    }
    expect(labels, [
      'My Campfire',
      'Notifications',
      'Address Book',
      'Settings',
      'Support',
      'About',
      'Exit',
    ]);
    expect(find.byType(DesktopTorStatusButton), findsOneWidget);
    expect(find.byKey(const Key('beamSidebarNodeChip')), findsNothing);
    // Campfire's own taller rows.
    final first = find.descendant(
      of: find.byKey(const ValueKey('myStack')),
      matching: find.byType(TextButton),
    );
    expect(
      tester.getSize(first).height,
      greaterThan(BeamSidebarMenu.itemHeight),
    );
    expect(find.byType(BeamSidebarScaffold), findsNothing);
    await finishSidebar(tester);
  });

  testWidgets('Settings → Nodes can open Node & sync too', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(
      tester,
      wallets: [wallet],
      home: const Material(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 600, child: BeamNodeSyncSettingsButton()),
          ),
        ),
      ),
    );
    expect(
      find.text(
        'Everyday BEAM: Public node. Which node you use, and how up to date.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('beamSettingsNodeAndSync')));
    await settle(tester, rounds: 2);
    expect(find.byType(DesktopBeamNodeSyncDialog), findsOneWidget);
    await closeRouteOf(tester, find.byType(DesktopBeamNodeSyncDialog));
    await finishSidebar(tester);

    await pumpSidebar(
      tester,
      wallets: const [],
      home: const Material(child: BeamNodeSyncSettingsButton()),
    );
    expect(
      find.text('Open a BEAM wallet to see which node it uses.'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('beamSettingsNodeAndSync')));
    await settle(tester, rounds: 1);
    expect(find.byType(DesktopBeamNodeSyncDialog), findsNothing);
    await finishSidebar(tester);
  });

  // Last in the file: it shows the wallet in My Campfire (see
  // pumpSidebar), and no test after it adds one.
  testWidgets('BEAM build: every item in order, a divider after Tokens, '
      'Exit at the bottom; My Campfire selected', (tester) async {
    final wallet = await openBeamWallet(tester, db, core: SidebarCore());
    await pumpSidebar(tester, wallets: [wallet], myCampfire: [wallet.info]);

    expect(find.byType(DesktopMenu), findsOneWidget);
    expect(find.byType(BeamSidebarMenu), findsOneWidget);
    expect(find.byType(MyStackView), findsOneWidget);
    expect(menuLabels(tester), _beamOrder);

    // The divider sits between Tokens and Notifications.
    final divider = tester.getRect(find.byKey(const Key('beamSidebarDivider')));
    expect(
      divider.top,
      greaterThan(
        _bottomOf(tester, find.byKey(BeamSidebarDestination.tokens.menuKey)),
      ),
    );
    expect(
      divider.bottom,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('notifications'))).dy,
      ),
    );
    // Exit is pinned under the list, not part of it.
    expect(
      find.descendant(
        of: find.byKey(const Key('beamSidebarItems')),
        matching: find.byKey(const ValueKey('exit')),
      ),
      findsNothing,
    );

    // Every item has Campfire's icon size and the BEAM row height.
    for (final e
        in find.byWidgetPredicate((w) => w is DesktopMenuItem).evaluate()) {
      final size = tester.getSize(
        find.descendant(
          of: find.byWidget(e.widget),
          matching: find.byType(TextButton),
        ),
      );
      expect(size.height, BeamSidebarMenu.itemHeight);
    }
    for (final d in BeamSidebarDestination.values) {
      final icon = find.descendant(
        of: find.byKey(d.menuKey),
        matching: find.byType(BeamSidebarMenuIcon),
      );
      expect(tester.getSize(icon), const Size(20, 20));
    }

    // The node chip replaces Campfire's Tor line; Tor stays as an icon.
    expect(find.byType(DesktopTorStatusButton), findsNothing);
    expect(find.byKey(const Key('beamSidebarNodeChip')), findsOneWidget);
    expect(find.byKey(const Key('beamSidebarTorButton')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('beamSidebarNodeChipLabel')))
          .data,
      'Public node',
    );

    await expectLater(
      find.byKey(goldenKey),
      matchesGoldenFile('goldens/menu_my_campfire.png'),
    );
    await finishSidebar(tester);
  });
}
