#!/usr/bin/env bash
# Fetches the 9 mainnet .dapp packages that beam-ui bundles into a cache
# OUTSIDE this repository, and refuses any whose SHA-256 differs from the pin
# in lib/wallets/beam/dapps/dapp_catalogue.dart.
#
#   test/beam/dapps/tool/fetch_bundled_dapps.sh                  # from GitHub
#   test/beam/dapps/tool/fetch_bundled_dapps.sh --from <beam-ui checkout>
#
# Destination: $CFB_DAPP_PACKAGES, default ~/.cache/campfire-beam/dapps.
# test/beam/dapps/bundled_dapps_test.dart reads them from there.
#
# The packages are not committed: they bundle third-party fonts (SF Pro,
# Proxima Nova) whose licences do not clearly allow redistribution.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CATALOGUE="$REPO/lib/wallets/beam/dapps/dapp_catalogue.dart"
DEST="${CFB_DAPP_PACKAGES:-$HOME/.cache/campfire-beam/dapps}"
FROM=""
if [ "${1:-}" = "--from" ]; then FROM="${2:?--from needs a beam-ui checkout}"; fi

if command -v sha256sum >/dev/null; then
  sha() { sha256sum "$1" | cut -d' ' -f1; }
else
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fi

mkdir -p "$DEST"

# "<file> <sha256> <url>" per package, read from the Dart catalogue.
LIST="$(python3 -I - "$CATALOGUE" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
commit = re.search(r"sourceCommit = '([0-9a-f]{40})'", text).group(1)
for name, digest in re.findall(
        r"fileName: '([a-z0-9-]+\.dapp)'.*?sha256: '([0-9a-f]{64})'",
        text, re.S):
    url = (f"https://raw.githubusercontent.com/BeamMW/beam-ui/{commit}/"
           f"ui/apps/mainnet/{name}")
    print(name, digest, url)
PY
)"
[ "$(printf '%s\n' "$LIST" | grep -c .)" = 9 ] || { echo "catalogue parse failed"; exit 1; }

while read -r name want url; do
  out="$DEST/$name"
  if [ -f "$out" ] && [ "$(sha "$out")" = "$want" ]; then
    echo "ok    $name (cached)"; continue
  fi
  part="$out.part"
  if [ -n "$FROM" ]; then
    cp "$FROM/ui/apps/mainnet/$name" "$part"
  else
    curl -fsSL --proto '=https' --max-filesize 52428800 "$url" -o "$part"
  fi
  got="$(sha "$part")"
  if [ "$got" != "$want" ]; then
    rm -f "$part"
    echo "FAIL  $name: sha256 $got, pinned $want"; exit 1
  fi
  mv "$part" "$out"
  echo "ok    $name"
done <<< "$LIST"
echo "9 packages verified in $DEST"
