/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The connection line under Campfire's logo, for BEAM: one chip that says
// honestly which node the wallet uses and whether it keeps up, and opens
// Node & sync. Campfire's Tor indicator sits beside it.
//
// Exit-intent (USER_PSYCHOLOGY §1.7): a green "Connected" while nothing is
// connected would be a lie the user finds out at the worst moment (a send
// that will not go). So the chip only says "Public node" / "Private node"
// when the core is up and following the chain; "Catching up" while it is
// behind; "Not syncing" when it stopped; "Not connected" otherwise.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../pages_desktop_specific/desktop_menu.dart';
import '../../../pages_desktop_specific/settings/settings_menu.dart';
import '../../../providers/desktop/current_desktop_menu_item.dart';
import '../../../providers/global/prefs_provider.dart';
import '../../../services/event_bus/events/global/tor_connection_status_changed_event.dart';
import '../../../services/event_bus/global_event_bus.dart';
import '../../../services/tor_service.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/assets.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/node/beam_private_node_coordinator.dart';
import '../../../wallets/beam/sync/beam_sync_state.dart';
import '../wallet_home/beam_home_text.dart';
import '../wallet_home/beam_wallet_home.dart';
import '../wiring/beam_wallet_listenables.dart';
import 'beam_sidebar.dart';

/// What the node chip says.
enum BeamSidebarNodeState {
  publicNode('Public node'),
  privateNode('Private node'),
  catchingUp('Catching up'),
  connecting('Connecting'),
  notSyncing('Not syncing'),

  /// The core is up but reaches no node, or failed to start.
  notConnected('Not connected'),

  /// No BEAM wallet in use, or its core is not running.
  closed('Not connected');

  const BeamSidebarNodeState(this.label);

  final String label;

  /// Following the chain: sending is possible.
  bool get healthy => this == publicNode || this == privateNode;
}

/// The rule, without Flutter.
BeamSidebarNodeState beamSidebarNodeState({
  required bool hasWallet,
  required bool isOpen,
  required BeamSyncAssessment? assessment,
  BeamPrivateNodeStatus? privateNode,
  bool coreProblem = false,
}) {
  if (!hasWallet || assessment == null) return BeamSidebarNodeState.closed;
  if (coreProblem) return BeamSidebarNodeState.notConnected;
  if (!isOpen) return BeamSidebarNodeState.closed;
  return switch (assessment) {
    BeamSynced() =>
      BeamHomeText.onPrivateNode(privateNode)
          ? BeamSidebarNodeState.privateNode
          : BeamSidebarNodeState.publicNode,
    BeamSyncCatchingUp() => BeamSidebarNodeState.catchingUp,
    BeamSyncConnecting() => BeamSidebarNodeState.connecting,
    BeamSyncStalled() => BeamSidebarNodeState.notSyncing,
    BeamSyncNotConnected() => BeamSidebarNodeState.notConnected,
  };
}

Color beamSidebarNodeColor(StackColors c, BeamSidebarNodeState s) =>
    switch (s) {
      BeamSidebarNodeState.publicNode ||
      BeamSidebarNodeState.privateNode => c.accentColorGreen,
      BeamSidebarNodeState.catchingUp ||
      BeamSidebarNodeState.connecting => c.accentColorYellow,
      BeamSidebarNodeState.notSyncing ||
      BeamSidebarNodeState.notConnected => c.accentColorRed,
      BeamSidebarNodeState.closed => c.textSubtitle3,
    };

/// The node state of the wallet the sidebar pages use.
final pBeamSidebarNodeState = Provider.autoDispose<BeamSidebarNodeState>((ref) {
  final wallet = ref.watch(pBeamSidebarWallet).wallet;
  if (wallet == null) return BeamSidebarNodeState.closed;
  final home = ref.watch(pBeamHome(wallet.walletId));
  return beamSidebarNodeState(
    hasWallet: true,
    isOpen: home.source.isOpen,
    assessment: home.assessment,
    privateNode: home.privateNodeStatus,
    coreProblem: home.coreProblem != null,
  );
});

/// Opens Node & sync for the wallet in use; with none, Campfire's node
/// settings (where BEAM's public nodes are listed).
void openBeamSidebarNodeAndSync(BuildContext context, WidgetRef ref) {
  final wallet = ref.read(pBeamSidebarWallet).wallet;
  if (wallet != null) {
    unawaited(showBeamNodePanel(context, wallet.walletId));
    return;
  }
  ref.read(currentDesktopMenuItemProvider.state).state =
      DesktopMenuItemId.settings;
  ref.read(prevDesktopMenuItemProvider.state).state =
      DesktopMenuItemId.settings;
  // Settings → Nodes (settings_menu.dart's sixth entry).
  ref.read(selectedSettingsMenuItemStateProvider.state).state = 5;
}

/// The chip, plus Campfire's Tor indicator beside it when there is room.
/// Icon only when the menu is minimized (it follows its own width, so it
/// never overflows while the menu animates).
class BeamSidebarStatusLine extends StatelessWidget {
  const BeamSidebarStatusLine({super.key, this.showTor = true});

  final bool showTor;

  static const double height = 36;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 140;
      return SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(child: BeamSidebarNodeChip(iconOnly: !wide)),
            if (wide && showTor) ...[
              const SizedBox(width: 4),
              const BeamSidebarTorButton(),
            ],
          ],
        ),
      );
    },
  );
}

/// "Public node", with the node icon in the state's colour: tap for Node &
/// sync.
class BeamSidebarNodeChip extends ConsumerWidget {
  const BeamSidebarNodeChip({super.key, this.iconOnly = false});

  final bool iconOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final state = ref.watch(pBeamSidebarNodeState);
    final tint = beamSidebarNodeColor(colors, state);
    final icon = SvgPicture.asset(
      Assets.svg.node,
      width: 16,
      height: 16,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
    );
    final button = TextButton(
      key: const Key('beamSidebarNodeChip'),
      style: beamSidebarPillStyle(context, colors),
      onPressed: () => openBeamSidebarNodeAndSync(context, ref),
      child: iconOnly
          ? Center(child: icon)
          : Padding(
              // Room for the longest state ("Not connected") beside Tor.
              padding: const EdgeInsets.fromLTRB(10, 0, 8, 0),
              child: Row(
                children: [
                  icon,
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      state.label,
                      key: const Key('beamSidebarNodeChipLabel'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: STextStyles.smallMed12(context)
                          .copyWith(color: colors.textDark),
                    ),
                  ),
                ],
              ),
            ),
    );
    return Semantics(
      button: true,
      label: '${state.label}. Opens node and sync.',
      excludeSemantics: true,
      child: Tooltip(
        message: iconOnly ? '${state.label} · Node & sync' : 'Node & sync',
        waitDuration: const Duration(milliseconds: 400),
        child: SizedBox.expand(child: button),
      ),
    );
  }
}

/// A rounded outline pill in the menu's colours, the same height whatever
/// the platform's density.
ButtonStyle? beamSidebarPillStyle(BuildContext context, StackColors colors) =>
    colors
        .getDesktopMenuButtonStyle(context)
        ?.copyWith(
          padding: WidgetStateProperty.all(EdgeInsets.zero),
          minimumSize: WidgetStateProperty.all(const Size(34, 36)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: WidgetStateProperty.all(
            StadiumBorder(side: BorderSide(color: colors.textFieldDefaultBG)),
          ),
        );

/// Campfire's Tor status, as an icon (the full line is Campfire's own
/// `DesktopTorStatusButton`). Opens Settings → Tor settings, as it does.
class BeamSidebarTorButton extends ConsumerStatefulWidget {
  const BeamSidebarTorButton({super.key});

  @override
  ConsumerState<BeamSidebarTorButton> createState() =>
      _BeamSidebarTorButtonState();
}

class _BeamSidebarTorButtonState extends ConsumerState<BeamSidebarTorButton> {
  late TorConnectionStatus _status;
  StreamSubscription<TorConnectionStatusChangedEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _status = ref.read(pTorService).status;
    _sub = GlobalEventBus.instance.on<TorConnectionStatusChangedEvent>().listen(
      (e) {
        if (mounted) setState(() => _status = e.newStatus);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    // With Tor switched off in Settings, "Disconnected" would read like a
    // fault: say it is off.
    final useTor = ref.watch(
      prefsChangeNotifierProvider.select((p) => p.useTor),
    );
    final (tint, word) = !useTor
        ? (colors.textSubtitle3, 'Tor is off')
        : switch (_status) {
            TorConnectionStatus.disconnected => (
              colors.textSubtitle3,
              'Tor: Disconnected',
            ),
            TorConnectionStatus.connecting => (
              colors.accentColorYellow,
              'Tor: Connecting',
            ),
            TorConnectionStatus.connected => (
              colors.accentColorGreen,
              'Tor: Connected',
            ),
          };
    return Tooltip(
      key: const Key('beamSidebarTorTooltip'),
      message: word,
      waitDuration: const Duration(milliseconds: 400),
      child: Semantics(
        button: true,
        label: '$word. Opens Tor settings.',
        excludeSemantics: true,
        child: SizedBox(
          width: 34,
          height: BeamSidebarStatusLine.height,
          child: TextButton(
            key: const Key('beamSidebarTorButton'),
            style: beamSidebarPillStyle(context, colors),
            onPressed: () {
              ref.read(currentDesktopMenuItemProvider.state).state =
                  DesktopMenuItemId.settings;
              ref.read(prevDesktopMenuItemProvider.state).state =
                  DesktopMenuItemId.settings;
              // Settings → Tor settings, as DesktopMenu's Tor line does.
              ref.read(selectedSettingsMenuItemStateProvider.state).state = 4;
            },
            child: SvgPicture.asset(
              Assets.svg.tor,
              width: 16,
              height: 16,
              colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
            ),
          ),
        ),
      ),
    );
  }
}

/// For Campfire's desktop Settings → Nodes: the way to BEAM's node and sync
/// panel from Settings (the chip under the logo is the other way).
class BeamNodeSyncSettingsButton extends ConsumerWidget {
  const BeamNodeSyncSettingsButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final state = ref.watch(pBeamSidebarNodeState);
    final wallet = ref.watch(pBeamSidebarWallet).wallet;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.textFieldDefaultBG),
      ),
      child: InkWell(
        key: const Key('beamSettingsNodeAndSync'),
        borderRadius: BorderRadius.circular(20),
        onTap: wallet == null
            ? null
            : () => unawaited(showBeamNodePanel(context, wallet.walletId)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              SvgPicture.asset(
                Assets.svg.node,
                width: 20,
                height: 20,
                colorFilter: ColorFilter.mode(
                  beamSidebarNodeColor(colors, state),
                  BlendMode.srcIn,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BEAM node & sync',
                      style: STextStyles.desktopTextSmall(context),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      wallet == null
                          ? 'Open a BEAM wallet to see which node it uses.'
                          : '${wallet.info.name}: ${state.label}. Which node '
                                'you use, and how up to date.',
                      style: STextStyles.desktopTextExtraExtraSmall(context),
                    ),
                  ],
                ),
              ),
              if (wallet != null)
                SvgPicture.asset(
                  Assets.svg.chevronRight,
                  width: 8,
                  height: 14,
                  colorFilter: ColorFilter.mode(
                    colors.textSubtitle1,
                    BlendMode.srcIn,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
