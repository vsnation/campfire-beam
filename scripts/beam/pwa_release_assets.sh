#!/usr/bin/env bash
# The web wallet's release files, ready to attach to a GitHub release (#35):
# anyone hosting a copy, or checking one, can compare it with these.
#
#   scripts/beam/pwa_release_assets.sh <signed build dir> <out dir>
#
# Writes to <out dir>:
#   beam-campfire-web-<version>.zip   every file of the signed build, the same
#                                     bytes the hosting repository serves
#   release.json, release.sig         the signed release and its signature
#   manifest.json                     every file's path, size and SHA-256
#   SHA256SUMS.txt                    of the four files above
#
# The zip is reproducible: sorted entries, fixed timestamps, no extra
# attributes, so two people zipping the same build get the same bytes.
set -euo pipefail

BUILD="${1:?usage: pwa_release_assets.sh <signed build dir> <out dir>}"
OUT="${2:?usage: pwa_release_assets.sh <signed build dir> <out dir>}"

for f in release.json release.sig manifest.json; do
  [[ -f "$BUILD/$f" ]] || { echo "not a signed build: $BUILD/$f is missing" >&2; exit 1; }
done
VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$BUILD/release.json")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "unexpected version: $VERSION" >&2; exit 1; }

# Every file the manifest lists must be in the build with the listed hash:
# the zip is the release, not whatever else is lying in the folder.
python3 -I - "$BUILD" <<'PY'
import hashlib, json, os, sys
root = sys.argv[1]
m = json.load(open(os.path.join(root, 'manifest.json')))
for f in m['files']:
    p = os.path.join(root, f['path'])
    h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
    if h != f['sha256']:
        sys.exit(f"{f['path']}: sha256 differs from the manifest")
print(f"{len(m['files'])} files match the manifest")
PY

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ZIP="$OUT/beam-campfire-web-$VERSION.zip"
rm -f "$ZIP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
python3 -I - "$BUILD" "$STAGE/list" <<'PY'
import json, os, sys
root, out = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(root, 'manifest.json')))
paths = sorted({f['path'] for f in m['files']} | {'release.json', 'release.sig', 'manifest.json'})
open(out, 'w').write('\n'.join(paths) + '\n')
PY
cp -R "$BUILD/." "$STAGE/tree"
# Fixed timestamps (2020-01-01) on everything that goes in.
while IFS= read -r p; do touch -t 202001010000 "$STAGE/tree/$p"; done < "$STAGE/list"
( cd "$STAGE/tree" && TZ=UTC zip -X -q -9 "$ZIP" -@ < "$STAGE/list" )
cp "$BUILD/release.json" "$BUILD/release.sig" "$BUILD/manifest.json" "$OUT/"
( cd "$OUT" && shasum -a 256 "beam-campfire-web-$VERSION.zip" release.json release.sig manifest.json > SHA256SUMS.txt )
echo "web wallet $VERSION -> $OUT"
cat "$OUT/SHA256SUMS.txt"
