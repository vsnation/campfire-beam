/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'package:flutter/material.dart';

import '../../../themes/stack_colors.dart';
import '../../../utilities/text_styles.dart';
import '../../../wallets/beam/api/beam_api.dart';
import '../../../wallets/beam/assets/beam_asset_catalog.dart';
import '../../../wallets/beam/models/beam_asset_info.dart';
import '../../rounded_white_container.dart';
import '../assets/beam_asset_logo.dart';
import 'beam_layout.dart';
import 'beam_units.dart';

/// Names and tickers for asset ids, through [BeamAssetCatalog]: verified
/// assets by the catalogue, anything else from its on-chain metadata (when
/// [loadMetadata] can fetch it) and always with its id, since anyone can
/// mint an asset and call it anything.
class BeamAssetNames extends ChangeNotifier {
  BeamAssetNames({this.loadMetadata});

  /// Reads each unverified asset's metadata from the wallet core.
  factory BeamAssetNames.fromApi(BeamApi api) => BeamAssetNames(
    loadMetadata: (id) async => (await api.getAssetInfo(id)).metadata,
  );

  final Future<BeamAssetMetadata?> Function(int assetId)? loadMetadata;

  final _metadata = <int, BeamAssetMetadata?>{};
  final _tried = <int>{};

  BeamAssetDisplay display(int assetId) =>
      BeamAssetCatalog.display(assetId, _metadata[assetId]);

  /// The ticker, e.g. `FOMO`, or `#188` for an unnamed asset.
  String symbol(int assetId) => display(assetId).symbol;

  /// `1,234.5 FOMO`.
  String amount(int assetId, BigInt units) =>
      BeamUnits.withSymbol(units, symbol(assetId));

  /// Uses metadata the caller already has (e.g. the Minter's).
  void remember(int assetId, String? rawMetadata) {
    if (rawMetadata == null || _metadata[assetId] != null) return;
    _metadata[assetId] = BeamAssetMetadata.parse(rawMetadata);
    _tried.add(assetId);
    notifyListeners();
  }

  /// Fetches metadata for unverified assets not tried yet. A failure only
  /// means the asset keeps its id as its name.
  Future<void> preload(Iterable<int> assetIds) async {
    final load = loadMetadata;
    if (load == null) return;
    var changed = false;
    for (final id in assetIds) {
      if (id == 0 ||
          BeamAssetCatalog.verified.containsKey(id) ||
          !_tried.add(id)) {
        continue;
      }
      try {
        _metadata[id] = await load(id);
        changed = true;
      } catch (_) {
        // Unknown to the core or not reachable: shown by its id.
      }
    }
    if (changed) notifyListeners();
  }
}

/// The asset's icon: [BeamAssetLogo], the same on every BEAM screen.
class BeamAssetAvatar extends StatelessWidget {
  const BeamAssetAvatar({super.key, required this.display, this.size = 32});

  final BeamAssetDisplay display;
  final double size;

  @override
  Widget build(BuildContext context) => BeamAssetLogo(display, size: size);
}

/// Avatar, name and ticker, with the warnings an unverified asset needs.
class BeamAssetTitle extends StatelessWidget {
  const BeamAssetTitle({
    super.key,
    required this.display,
    this.trailing,
    this.subtitle,
    this.markUnverified = true,
  });

  final BeamAssetDisplay display;
  final String? subtitle;
  final Widget? trailing;

  /// False only for an asset that does not exist yet (a token being
  /// created), which has no id to show.
  final bool markUnverified;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final desktop = BeamLayoutScope.isDesktop(context);
    final copies = display.impersonates;
    final copied = copies == null ? null : BeamAssetCatalog.verified[copies];
    final notes = [
      if (subtitle != null) subtitle!,
      if (!display.verified && markUnverified)
        'Not verified · ${display.idLabel}',
    ];
    return Row(
      children: [
        BeamAssetAvatar(display: display, size: desktop ? 36 : 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                display.name == display.symbol
                    ? display.name
                    : '${display.name} (${display.symbol})',
                style: desktop
                    ? STextStyles.desktopTextExtraSmall(context)
                          .copyWith(color: colors.textDark)
                    : STextStyles.titleBold12(context),
                overflow: TextOverflow.ellipsis,
              ),
              for (final n in notes)
                Text(
                  n,
                  style: STextStyles.label(context),
                  overflow: TextOverflow.ellipsis,
                ),
              if (copied != null)
                Text(
                  'Not the verified ${copied.symbol} (#${copied.id})',
                  style: STextStyles.label(context)
                      .copyWith(color: colors.textError),
                ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// One asset this wallet holds, for an asset picker.
class BeamHeldAsset {
  const BeamHeldAsset(this.assetId, this.available);

  final int assetId;
  final BigInt available;
}

/// What the wallet can spend right now, per asset id (`wallet_status`
/// totals; BEAM is always present).
Future<Map<int, BigInt>> beamAvailableBalances(BeamApi api) async {
  final s = await api.walletStatus();
  final out = <int, BigInt>{for (final t in s.totals) t.assetId: t.available};
  out.putIfAbsent(0, () => s.available ?? BigInt.zero);
  return out;
}

/// Lets the user pick one of [assets]: a bottom sheet on a phone, a dialog
/// on desktop. Null when dismissed.
Future<int?> showBeamAssetPicker({
  required BuildContext context,
  required List<BeamHeldAsset> assets,
  required BeamAssetNames names,
  required String title,
}) {
  final desktop = BeamLayoutScope.isDesktop(context);
  Widget list(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Text(
          title,
          style: desktop
              ? STextStyles.desktopH3(context)
              : STextStyles.pageTitleH2(context),
        ),
      ),
      Flexible(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            for (final a in assets)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: RoundedWhiteContainer(
                  key: ValueKey('beam-asset-option-${a.assetId}'),
                  onPressed: () => Navigator.of(context).pop(a.assetId),
                  child: BeamAssetTitle(
                    display: names.display(a.assetId),
                    subtitle:
                        'You have ${names.amount(a.assetId, a.available)}',
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
  if (desktop) {
    return showDialog<int>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
          child: list(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).extension<StackColors>()!.popupBG,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: list(context),
      ),
    ),
  );
}
