#!/usr/bin/env bash

set -x -e

# Configure files for Campfire with BEAM as its only coin.

# Campfire's logo and branding, named "BEAM Campfire" (owner, 2026-10-07): a
# second "Campfire.app" would replace Firo's Campfire in /Applications. The
# technical identifiers below (app id on every platform, iOS included; basic
# name; _appDataDirName) are new too, so this build never opens, updates or
# shares data with a real Campfire install on the same machine. _prefix below
# stays "Campfire": code branches on AppConfig.appName == "Campfire".
export NEW_NAME="BEAM Campfire"
export NEW_APP_ID="com.vsnation.campfirebeam"
export NEW_APP_ID_CAMEL="com.vsnation.campfirebeam"
export NEW_APP_ID_SNAKE="com.vsnation.campfirebeam"
export NEW_BASIC_NAME="campfirebeam"

# stackwallet, not Campfire's paymint: the upstream tests import
# package:stackwallet/... and lib/ only uses relative imports.
NEW_PUBSPEC_NAME="stackwallet"
PUBSPEC_FILE="${APP_PROJECT_ROOT_DIR}/pubspec.yaml"

# String replacements.
if [[ "$(uname)" == 'Darwin' ]]; then
  # macos specific sed
  sed -i '' "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i '' "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
else
  sed -i "s/name: PLACEHOLDER/name: ${NEW_PUBSPEC_NAME}/g" "${PUBSPEC_FILE}"
  sed -i "s/description: PLACEHOLDER/description: ${NEW_NAME}/g" "${PUBSPEC_FILE}"
fi

dart "${APP_PROJECT_ROOT_DIR}/tool/process_pubspec_deps.dart" \
      "${PUBSPEC_FILE}" \
      TOR \
      BEAM

dart "${APP_PROJECT_ROOT_DIR}/tool/gen_interfaces.dart" \
      "${APP_PROJECT_ROOT_DIR}/tool/wl_templates" \
      "${APP_PROJECT_ROOT_DIR}/lib/wl_gen/generated" \
      TOR \
      BEAM

# The desktop BEAM core runs as child processes; bundle its pinned binaries.
bash "${APP_PROJECT_ROOT_DIR}/scripts/beam/core/stage_binaries.sh" "${1:-}"

# Android runs the same core as child processes, shipped as jniLibs so they
# are extracted to nativeLibraryDir and executable (the project notes).
if [ "${1:-}" = "android" ]; then
  bash "${APP_PROJECT_ROOT_DIR}/scripts/android/campfire_android.sh"
fi


pushd "${APP_PROJECT_ROOT_DIR}"
BUILT_COMMIT_HASH=$(git log -1 --pretty=format:"%H")
popd

APP_CONFIG_DART_FILE="${APP_PROJECT_ROOT_DIR}/lib/app_config.g.dart"
rm -f "$APP_CONFIG_DART_FILE"
cat << EOF > "$APP_CONFIG_DART_FILE"
// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_config.dart';

const _prefix = "Campfire";
const _separator = "";
const _suffix = "";
const _emptyWalletsMessage =
    "Join us around the Campfire and create a wallet!";
const _appDataDirName = "campfirebeam";
const _shortDescriptionText = "Your privacy. Your wallet. Your BEAM.";
const _commitHash = "$BUILT_COMMIT_HASH";

const _mwebdExeHash = "";

// No AppFeature.swap until an exchange partner is verified to list BEAM.
const Set<AppFeature> _features = {
  AppFeature.tor,
};

const ({String light, String dark})? _appIconAsset = (
  light: "assets/in_app_logo_icons/campfire-icon_light.svg",
  dark: "assets/in_app_logo_icons/campfire-icon_dark.svg",
);

final List<CryptoCurrency> _supportedCoins = List.unmodifiable([
  Beam(CryptoCurrencyNetwork.main),
]);

const List<EthContract> _defaultEthTokens = [];

// Read by AppConfig.swapDefaults even while AppFeature.swap is off.
final ({String from, String fromFuzzyNet, String to, String toFuzzyNet})
_swapDefaults = (
  from: "BTC",
  fromFuzzyNet: "btc",
  to: "BEAM",
  toFuzzyNet: "beam",
);

EOF
