#!/usr/bin/env bash
# Create the local release signing key for Campfire for BEAM on Android, once.
#
#   ~/.config/campfire-beam/android/            0700
#     campfire-beam-release.p12                 0600  PKCS12 keystore, RSA 4096
#     key.properties                            0600  storeFile, passwords, alias
#
# android/app/campfire_beam.gradle reads key.properties from there, so nothing
# secret is ever written into the repository. The password is random and is
# only stored in key.properties. An existing keystore is never replaced: an
# app signed with a lost or replaced key cannot be updated in place.
#
# Prints the certificate's SHA-256 fingerprint (safe to publish; it is how a
# tester checks an APK came from this key).
set -euo pipefail
: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
KEYTOOL="$JAVA_HOME/bin/keytool"
DIR="${CAMPFIRE_ANDROID_KEY_DIR:-$HOME/.config/campfire-beam/android}"
STORE="$DIR/campfire-beam-release.p12"
PROPS="$DIR/key.properties"
ALIAS="campfirebeam"

umask 077
mkdir -p "$DIR"
chmod 0700 "$DIR"

if [ -e "$STORE" ] || [ -e "$PROPS" ]; then
  echo "make_release_keystore: $STORE or key.properties already exists; not replacing it." >&2
else
  PASS="$(openssl rand -hex 32)"
  # The password reaches keytool through its environment, never argv.
  CAMPFIRE_KS_PASS="$PASS" "$KEYTOOL" -genkeypair -noprompt \
    -keystore "$STORE" -storetype PKCS12 \
    -storepass:env CAMPFIRE_KS_PASS -keypass:env CAMPFIRE_KS_PASS \
    -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
    -dname "CN=Campfire for BEAM, O=vsnation" </dev/null
  [ -s "$STORE" ] || { echo "make_release_keystore: keytool did not create $STORE" >&2; exit 1; }
  {
    echo "storeFile=$STORE"
    echo "storePassword=$PASS"
    echo "keyPassword=$PASS"
    echo "keyAlias=$ALIAS"
  } > "$PROPS"
  chmod 0600 "$STORE" "$PROPS"
  unset PASS
fi

PASS="$(sed -n 's/^storePassword=//p' "$PROPS")"
CAMPFIRE_KS_PASS="$PASS" "$KEYTOOL" -list -v -keystore "$STORE" -storetype PKCS12 \
  -storepass:env CAMPFIRE_KS_PASS -alias "$ALIAS" | grep -E "SHA256:|Valid from|Owner:"
