// Proof that the macOS host can render Campfire widgets to PNG without Xcode, a
// device or a display: flutter_tester renders off-screen and matchesGoldenFile
// writes / compares the image.
//
// It pumps real app widgets (PrimaryButton, SecondaryButton,
// RoundedWhiteContainer, STextStyles) themed with Campfire's own default
// theme (asset_sources/default_themes/campfire/light.zip) and the bundled
// Inter fonts.
//
// Write or refresh the golden:
//   flutter test --update-goldens test/beam/screenshot_smoke_test.dart
// Compare against it:
//   flutter test test/beam/screenshot_smoke_test.dart
//
// Goldens are platform-specific (font rasterisation differs between macOS and
// Linux). Generate and compare on the same OS; see the project notes.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:stackwallet/models/isar/stack_theme.dart';
import 'package:stackwallet/themes/stack_colors.dart';
import 'package:stackwallet/utilities/text_styles.dart';
import 'package:stackwallet/widgets/desktop/primary_button.dart';
import 'package:stackwallet/widgets/desktop/secondary_button.dart';
import 'package:stackwallet/widgets/rounded_white_container.dart';

StackTheme _campfireLightTheme() {
  final zip = File('asset_sources/default_themes/campfire/light.zip')
      .readAsBytesSync();
  final themeJson = ZipDecoder()
      .decodeBytes(zip)
      .files
      .singleWhere((f) => f.name == 'theme.json');
  final json = jsonDecode(utf8.decode(themeJson.content as List<int>)) as Map;
  return StackTheme.fromJson(json: Map<String, dynamic>.from(json));
}

// The parts of the app's ThemeData (lib/main.dart, MaterialApp.theme) that the
// widgets below read. PrimaryButton/SecondaryButton copyWith() the app's
// textButtonTheme, so without it they render with no background at all.
ThemeData _appThemeData(StackColors colors) => ThemeData(
  extensions: [colors],
  highlightColor: colors.highlight,
  brightness: colors.brightness,
  fontFamily: GoogleFonts.inter().fontFamily,
  splashColor: Colors.transparent,
  textButtonTheme: TextButtonThemeData(
    style: ButtonStyle(
      overlayColor: WidgetStateProperty.all(colors.splash),
      minimumSize: WidgetStateProperty.all<Size>(const Size(46, 46)),
      foregroundColor: WidgetStateProperty.all(colors.buttonTextSecondary),
      backgroundColor: WidgetStateProperty.all<Color>(
        colors.buttonBackSecondary,
      ),
      shape: WidgetStateProperty.all<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(1000)),
      ),
    ),
  ),
);

void main() {
  testWidgets('Campfire theme renders to a golden PNG', (tester) async {
    GoogleFonts.config.allowRuntimeFetching = false;
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Load Inter from the bundled google_fonts/ assets BEFORE the first layout.
    // Otherwise the first frame lays out in flutter_tester's square test font,
    // the buttons overflow, and the golden shows boxes instead of text.
    await tester.runAsync(() async {
      for (final w in [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
      ]) {
        GoogleFonts.inter(fontWeight: w);
      }
      await GoogleFonts.pendingFonts();
    });

    final colors = StackColors.fromStackColorTheme(_campfireLightTheme());
    const boundaryKey = ValueKey('screenshot-smoke');

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _appThemeData(colors),
        home: RepaintBoundary(
          key: boundaryKey,
          child: Builder(
            builder: (context) => Scaffold(
              backgroundColor: colors.background,
              body: Padding(
                padding: const EdgeInsets.all(32),
                child: RoundedWhiteContainer(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Campfire toolchain smoke test',
                        style: STextStyles.pageTitleH1(context),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Rendered by flutter_tester with the Campfire '
                        'light theme.',
                        style: STextStyles.desktopTextExtraExtraSmall(context),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: SecondaryButton(
                              label: 'Restore wallet',
                              onPressed: () {},
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: PrimaryButton(
                              label: 'Create wallet',
                              onPressed: () {},
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Create wallet'), findsOneWidget);
    await expectLater(
      find.byKey(boundaryKey),
      matchesGoldenFile('goldens/campfire_theme_smoke.png'),
    );
  });
}
