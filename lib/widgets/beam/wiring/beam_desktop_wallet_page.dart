/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

// The desktop wallet page of a BEAM wallet (DesktopWalletView's body):
// header, sync banner and the two columns, scrolling as ONE page.
//
// Seen in the DMG test: with the scanning banner showing, only the narrow
// Send/Receive column scrolled, a third of the window high, and Receive's
// "Copy address" sat at its cut-off bottom edge. Now:
// * when everything fits, the page looks exactly as before (the columns
//   reach the bottom of the window, the assets list scrolls inside its
//   column);
// * when the Send/Receive column is taller than the space under the header,
//   the whole page scrolls (wheel or trackpad anywhere on it), never just
//   that column.

import 'dart:math' as math;

import 'package:flutter/material.dart';

class BeamDesktopWalletPage extends StatefulWidget {
  const BeamDesktopWalletPage({
    super.key,
    required this.top,
    required this.columnWidth,
    required this.left,
    required this.right,
    this.padding = 24,
    this.gap = 16,
    this.minColumnsHeight = 360,
  });

  /// Above the columns: the header row, the sync banner, the column titles.
  final Widget top;

  /// Width of the Send / Receive / Transactions column.
  final double columnWidth;

  /// The Send / Receive / Transactions column, at its content's height (it
  /// must not scroll on its own). [visibleHeight] is how much of it shows
  /// under the header before the page scrolls.
  final Widget Function(double visibleHeight) left;

  /// The assets column: as high as the space under the header (never less
  /// than [minColumnsHeight]); it scrolls its own list.
  final Widget right;

  /// Around the page, as Campfire's desktop wallet has it.
  final double padding;

  /// Between the two columns.
  final double gap;

  /// The columns never get less than this, however short the window: the
  /// page scrolls instead.
  final double minColumnsHeight;

  @override
  State<BeamDesktopWalletPage> createState() => _BeamDesktopWalletPageState();
}

class _BeamDesktopWalletPageState extends State<BeamDesktopWalletPage> {
  // The column is rebuilt only when the space under the header changes,
  // not on every frame of a scroll (the sliver below re-runs its builder
  // whenever the page moves).
  double? _leftHeight;
  Widget? _left;

  Widget _leftFor(double height) {
    if (_left == null || _leftHeight != height) {
      _leftHeight = height;
      _left = widget.left(height);
    }
    return _left!;
  }

  @override
  void didUpdateWidget(BeamDesktopWalletPage old) {
    super.didUpdateWidget(old);
    _left = null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.padding;
    return CustomScrollView(
      key: const Key('beamDesktopWalletPage'),
      primary: false,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(p, p, p, 0),
          sliver: SliverToBoxAdapter(child: widget.top),
        ),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            // Under the header to the bottom of the window, at scroll 0.
            // Neither number moves while the page scrolls.
            final under =
                constraints.viewportMainAxisExtent -
                constraints.precedingScrollExtent -
                p;
            final height = math.max(widget.minColumnsHeight, under);
            return SliverPadding(
              padding: EdgeInsets.fromLTRB(p, 0, p, p),
              sliver: SliverToBoxAdapter(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: widget.columnWidth,
                      child: _leftFor(height),
                    ),
                    SizedBox(width: widget.gap),
                    Expanded(
                      child: SizedBox(height: height, child: widget.right),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
