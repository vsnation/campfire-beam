/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:io';

import 'package:path/path.dart' as p;

/// The directory Android extracted this app's native libraries to
/// (`ApplicationInfo.nativeLibraryDir`), or null when this is not Android or
/// the libraries were not extracted.
///
/// The BEAM core ships as `jniLibs/<abi>/libbeam_core.so`, the core as one
/// library loaded into the app (`scripts/android/stage_beam_core.sh`), and
/// `android/app/campfire_beam.gradle` turns on legacy packaging so the
/// package manager extracts it there. The directory belongs to the system and
/// is read-only to the app, so the library cannot be swapped between its hash
/// check and its load (`beam_core_location.dart`).
///
/// Read from `/proc/self/maps`: the Flutter engine (`libflutter.so`) is
/// loaded from that same directory before any Dart code runs. That keeps the
/// lookup synchronous (`BeamBinaries.locate` is) and needs no platform
/// channel in the generated `MainActivity`. A library mapped straight from
/// the APK (`base.apk`, libraries not extracted) gives null, and the app then
/// reports the core as not installed instead of failing later.
String? androidNativeLibraryDir() =>
    Platform.isAndroid ? _cached ??= _fromProcMaps() : null;

String? _cached;

String? _fromProcMaps() {
  try {
    return nativeLibraryDirFromMaps(File('/proc/self/maps').readAsLinesSync());
  } on FileSystemException {
    return null;
  }
}

/// The directory `libflutter.so` was loaded from, given the lines of
/// `/proc/<pid>/maps`, when it is an installed app's extracted library
/// directory: `/data/app/...`, or `/mnt/expand/<uuid>/app/...` on adopted
/// storage. Null when the engine is mapped from inside an APK or from
/// anywhere else.
String? nativeLibraryDirFromMaps(Iterable<String> mapsLines) {
  for (final line in mapsLines) {
    final i = line.indexOf('/');
    if (i < 0) continue;
    final path = line.substring(i).trim();
    if (!path.endsWith('/libflutter.so')) continue;
    if (path.contains('.apk')) return null;
    final dir = p.dirname(path);
    if (dir.startsWith('/data/app/') || dir.startsWith('/mnt/expand/')) {
      return dir;
    }
    return null;
  }
  return null;
}
