/*
 * This file is part of Campfire for BEAM, a fork of Stack Wallet.
 *
 * Copyright (c) 2026 vsnation
 * All Rights Reserved.
 * The code is distributed under GPLv3 license, see LICENSE file for details.
 *
 */

import 'dart:convert';

import 'package:meta/meta.dart';

import 'dapp_api_version.dart';
import 'dapp_errors.dart';

/// Relative paths inside a dApp package: zip entry names, the manifest's
/// `url` and `icon`, and request paths on the loopback server all pass
/// through [DappPath.parse].
///
/// A path is plain `/`-separated segments. Refused: empty or `.` / `..`
/// segments, a leading `/` (absolute), backslashes, drive letters, NUL and
/// every other control character, and anything outside a conservative
/// ASCII set. Windows device names and segments ending in a dot or space
/// are refused too, so a package extracts to the same files everywhere. The
/// 9 bundled mainnet packages use only `[A-Za-z0-9 ._-]`.
abstract final class DappPath {
  static const maxLength = 512;
  static const maxSegmentLength = 255;
  static const maxDepth = 32;

  static final _segment = RegExp(r'^[A-Za-z0-9 ._\-+@~(),!=\[\]]+$');
  static final _device = RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
    caseSensitive: false,
  );

  /// The segments of [path], or a [DappInstallException] with
  /// [DappInstallError.unsafePath].
  static List<String> parse(String path) {
    if (path.isEmpty || path.length > maxLength) {
      throw _unsafe('path length ${path.length}');
    }
    if (path.startsWith('/')) throw _unsafe('absolute path');
    final segments = path.split('/');
    if (segments.length > maxDepth) throw _unsafe('path too deep');
    for (final s in segments) {
      checkSegment(s);
    }
    return List.unmodifiable(segments);
  }

  /// Throws unless [s] is one safe path segment.
  static void checkSegment(String s) {
    if (s.isEmpty) throw _unsafe('empty path segment');
    if (s == '.' || s == '..') throw _unsafe('dot segment');
    if (s.length > maxSegmentLength) throw _unsafe('segment too long');
    if (!_segment.hasMatch(s)) {
      throw _unsafe('character not allowed in a file name');
    }
    if (s.startsWith(' ') || s.endsWith(' ') || s.endsWith('.')) {
      throw _unsafe('segment starts or ends with a space or dot');
    }
    if (_device.hasMatch(s)) throw _unsafe('reserved device name');
  }

  /// The key two paths collide on when extracted to a case-insensitive
  /// file system (macOS, Windows).
  static String foldKey(List<String> segments) =>
      segments.join('/').toLowerCase();

  static DappInstallException _unsafe(String why) =>
      DappInstallException(DappInstallError.unsafePath, why);
}

/// A parsed, validated `manifest.json`.
///
/// Rules follow beam-ui's `parseAppManifestImpl` (`apps_view.cpp:447-607`)
/// and field limits (`:60-64, 269-305`), with these additions:
/// * `guid` must be 32 hex digits (or a hyphenated UUID) and is only ever
///   used in its canonical lowercase form, never as written. beam-ui used
///   it unvalidated as a folder name (`rm -rf <localapps>/<guid>`), which a
///   guid of `../..` turns into deleting outside the apps folder.
/// * `url` must be a `localapp/` path; a dApp is served only from its own
///   package. A non-local `icon` is ignored rather than fetched.
/// * Text shown in the consent sheet (`name`, `publisher`) may not contain
///   control or bidirectional-override characters, which could make one
///   dApp's name read as another's.
@immutable
class DappManifest {
  const DappManifest({
    required this.guid,
    required this.name,
    required this.description,
    required this.startPath,
    this.iconPath,
    this.version,
    this.apiVersion,
    this.minApiVersion,
    this.category,
    this.publisher,
  });

  static const fileName = 'manifest.json';
  static const maxBytes = 64 * 1024;
  static const nameMaxLength = 30;
  static const descriptionMaxLength = 1024;
  static const apiVersionMaxLength = 10;
  static const iconMaxLength = 10240;
  static const publisherMaxLength = 256;
  static const localPrefix = 'localapp/';

  /// Canonical: 32 lowercase hex digits.
  final String guid;
  final String name;
  final String description;

  /// The start page, relative to the package root (`app/index.html`).
  final String startPath;

  /// The icon file, relative to the package root, when the manifest names
  /// a local one.
  final String? iconPath;

  /// `major[.minor[.release[.build]]]`, digits only.
  final String? version;

  /// As written (`major.minor`); null means `current`.
  final String? apiVersion;
  final String? minApiVersion;

  /// 0 Undefined, 1 Other, 2 Finance, 3 Games, 4 Technology, 5 Governance
  /// (`apps_view.h:122-130`).
  final int? category;

  /// The publisher key, as written.
  final String? publisher;

  /// The version this dApp is served, or null when this wallet cannot run
  /// it (`DappApiVersion.negotiate`).
  DappApiVersion? get negotiatedApiVersion =>
      DappApiVersion.negotiate(wanted: apiVersion, minimum: minApiVersion);

  static final _hexGuid = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _uuidGuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );
  static final _canonicalGuid = RegExp(r'^[0-9a-f]{32}$');

  /// The canonical form of a manifest guid, or null when it is not 32 hex
  /// digits or a hyphenated UUID.
  static String? canonicalGuid(String raw) {
    if (_hexGuid.hasMatch(raw)) return raw.toLowerCase();
    if (_uuidGuid.hasMatch(raw)) return raw.replaceAll('-', '').toLowerCase();
    return null;
  }

  /// True for a guid already in canonical form: the only form allowed in a
  /// path.
  static bool isCanonicalGuid(String guid) => _canonicalGuid.hasMatch(guid);

  static final _version = RegExp(r'^[0-9]{1,9}(\.[0-9]{1,9}){0,3}$');
  static final _apiVersion = RegExp(r'^[0-9]{1,4}(\.[0-9]{1,4})?$');

  /// Control characters (C0, DEL, C1) and Unicode bidi/format controls that
  /// can reorder or hide displayed text.
  static final _unsafeDisplay = RegExp(
    _charClass(const [
      (0x0000, 0x001f),
      (0x007f, 0x009f),
      (0x061c, 0x061c),
      (0x200b, 0x200f),
      (0x202a, 0x202e),
      (0x2060, 0x2069),
      (0xfeff, 0xfeff),
    ]),
  );

  /// As [_unsafeDisplay], but tab and line breaks are allowed.
  static final _unsafeDescription = RegExp(
    _charClass(const [
      (0x0000, 0x0008),
      (0x000b, 0x000c),
      (0x000e, 0x001f),
      (0x007f, 0x009f),
      (0x061c, 0x061c),
      (0x200b, 0x200f),
      (0x202a, 0x202e),
      (0x2060, 0x2069),
      (0xfeff, 0xfeff),
    ]),
  );

  /// A RegExp character class of code point ranges, written with escapes
  /// so no invisible character appears in this source file.
  static String _charClass(List<(int, int)> ranges) {
    String esc(int c) => '${r'\'}u${c.toRadixString(16).padLeft(4, '0')}';
    return '[${ranges.map((r) => '${esc(r.$1)}-${esc(r.$2)}').join()}]';
  }

  /// Parses manifest bytes. Throws [DappInstallException] with
  /// [DappInstallError.cantReadManifest] for unreadable JSON and
  /// [DappInstallError.invalidFile] for a rule violation.
  static DappManifest parse(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw DappInstallException(
        DappInstallError.cantReadManifest,
        'manifest.json is ${bytes.length} bytes (max $maxBytes)',
      );
    }
    final Object? json;
    try {
      var text = utf8.decode(bytes);
      if (text.startsWith(String.fromCharCode(0xfeff))) {
        text = text.substring(1);
      }
      json = jsonDecode(text);
    } on FormatException catch (e) {
      throw DappInstallException(
        DappInstallError.cantReadManifest,
        'manifest.json is not UTF-8 JSON: ${e.message}',
      );
    }
    if (json is! Map<String, Object?> || json.isEmpty) {
      throw _invalid('manifest.json is not a JSON object');
    }

    final rawGuid = _requiredString(json, 'guid');
    final guid = canonicalGuid(rawGuid);
    if (guid == null) {
      throw _invalid('guid must be 32 hex digits or a UUID');
    }

    final name = _requiredString(json, 'name');
    if (name.length > nameMaxLength) {
      throw _invalid('name longer than $nameMaxLength characters');
    }
    if (_unsafeDisplay.hasMatch(name) || name.trim().isEmpty) {
      throw _invalid('name contains control characters');
    }

    final description = _requiredString(json, 'description');
    if (description.length > descriptionMaxLength) {
      throw _invalid('description longer than $descriptionMaxLength');
    }
    if (_unsafeDescription.hasMatch(description)) {
      throw _invalid('description contains control characters');
    }

    final url = _requiredString(json, 'url');
    final startPath = _localPath(url, 'url');
    if (startPath == null) {
      throw _invalid('url must start with "$localPrefix"');
    }
    final lower = startPath.toLowerCase();
    if (!lower.endsWith('.html') && !lower.endsWith('.htm')) {
      throw _invalid('url must name an .html file');
    }

    String? iconPath;
    final icon = _optionalString(json, 'icon');
    if (icon != null) {
      if (icon.length > iconMaxLength) {
        throw _invalid('icon longer than $iconMaxLength characters');
      }
      // A remote or data: icon is not fetched or shown; only local files.
      if (icon.startsWith(localPrefix)) iconPath = _localPath(icon, 'icon');
    }

    final version = _optionalString(json, 'version');
    if (version != null && !_version.hasMatch(version)) {
      throw _invalid('version must be up to 4 numeric parts');
    }
    final apiVersion = _apiVersionField(json, 'api_version');
    final minApiVersion = _apiVersionField(json, 'min_api_version');

    int? category;
    final c = json['category'];
    if (c != null) {
      if (c is! int || c < 0 || c > 0xffffffff) {
        throw _invalid('category must be an unsigned integer');
      }
      category = c;
    }

    final publisher = _optionalString(json, 'publisher');
    if (publisher != null &&
        (publisher.length > publisherMaxLength ||
            _unsafeDisplay.hasMatch(publisher))) {
      throw _invalid('publisher too long or contains control characters');
    }

    return DappManifest(
      guid: guid,
      name: name,
      description: description,
      startPath: startPath,
      iconPath: iconPath,
      version: version,
      apiVersion: apiVersion,
      minApiVersion: minApiVersion,
      category: category,
      publisher: publisher,
    );
  }

  static String _requiredString(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v is! String || v.isEmpty) {
      throw _invalid('"$key" must be a non-empty string');
    }
    return v;
  }

  static String? _optionalString(Map<String, Object?> json, String key) {
    final v = json[key];
    if (v == null) return null;
    if (v is! String) throw _invalid('"$key" must be a string');
    return v;
  }

  static String? _apiVersionField(Map<String, Object?> json, String key) {
    final v = _optionalString(json, key);
    if (v == null) return null;
    if (v.length > apiVersionMaxLength || !_apiVersion.hasMatch(v)) {
      throw _invalid('"$key" must be major.minor');
    }
    return v;
  }

  /// The package-relative path of a `localapp/...` reference, or null when
  /// [ref] is not local. Throws when it is local but not a safe path.
  static String? _localPath(String ref, String key) {
    if (!ref.startsWith(localPrefix)) return null;
    final rest = ref.substring(localPrefix.length);
    try {
      return DappPath.parse(rest).join('/');
    } on DappInstallException catch (e) {
      throw _invalid('"$key" is not a safe path: ${e.message}');
    }
  }

  static DappInstallException _invalid(String why) =>
      DappInstallException(DappInstallError.invalidFile, why);

  /// The fields worth persisting next to an install.
  Map<String, Object?> toJson() => {
    'guid': guid,
    'name': name,
    'description': description,
    'start_path': startPath,
    'icon_path': ?iconPath,
    'version': ?version,
    'api_version': ?apiVersion,
    'min_api_version': ?minApiVersion,
    'category': ?category,
    'publisher': ?publisher,
  };
}
