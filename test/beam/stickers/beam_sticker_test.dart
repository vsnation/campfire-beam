/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:stackwallet/widgets/beam/stickers/beam_sticker.dart';

void main() {
  test('every sticker the app names is bundled', () {
    for (final s in BeamSticker.values) {
      expect(File(s.asset).existsSync(), isTrue, reason: s.asset);
    }
    for (final s in BeamAnimatedSticker.values) {
      expect(File(s.asset).existsSync(), isTrue, reason: s.asset);
    }
  });

  test('every animated sticker decodes from its .tgs', () async {
    for (final s in BeamAnimatedSticker.values) {
      final c = await BeamAnimatedStickerView.decodeTgs(
        File(s.asset).readAsBytesSync(),
      );
      expect(c, isNotNull, reason: s.name);
      expect(c!.duration, const Duration(seconds: 3), reason: s.name);
      expect(c.bounds.width, 512, reason: s.name);
    }
  });

  test('the theme points at files that exist and has no Sparky left', () {
    final zip = ZipDecoder().decodeBytes(
      File(
        'asset_sources/default_themes/campfire/light.zip',
      ).readAsBytesSync(),
    );
    final names = {for (final f in zip.files) f.name};
    final raw = zip.findFile('theme.json')!.content as List<int>;
    final theme = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final assets = theme['assets'] as Map<String, dynamic>;

    void check(String? path) {
      if (path == null) return;
      expect(names, contains('assets/$path'), reason: path);
    }

    for (final v in assets.values) {
      if (v is String) check(v);
    }
    for (final group in (assets['coins'] as Map<String, dynamic>).values) {
      for (final v in (group as Map<String, dynamic>).values) {
        check(v as String?);
      }
    }
    // The four places Sparky used to be.
    for (final key in ['persona_easy', 'persona_incognito', 'stack']) {
      expect(assets[key], startsWith('png/beam_girl/'), reason: key);
    }
    expect(
      (assets['coins']['images'] as Map)['beam'],
      startsWith('png/beam_girl/'),
    );
  });

  testWidgets('reduce motion shows the still sticker', (tester) async {
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BeamAnimatedStickerView(BeamAnimatedSticker.hiFive),
        ),
      ),
    );
    expect(find.byType(Lottie), findsNothing);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, BeamSticker.bravo.asset);
  });

  testWidgets('animated by default', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: BeamAnimatedStickerView(BeamAnimatedSticker.greatNews),
      ),
    );
    expect(find.byType(Lottie), findsOneWidget);
  });
}
