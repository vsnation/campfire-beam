#!/usr/bin/env bash
# The web wallet's release files, ready to attach to a GitHub release (#35):
# anyone hosting a copy, or checking one, can compare it with these.
#
#   scripts/beam/pwa_release_assets.sh <signed build dir> <out dir>
#
# Writes to <out dir>:
#   beam-campfire-web-<version>.zip   every file of the signed build, the same
#                                     bytes the hosting repository serves, with
#                                     its loader and the hosting configs
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

# The loader is not in the manifest, but its name is: lib/version.js (a signed
# file) names it by the start of its SHA-256. Without it a copy cannot install.
LOADER="$(sed -n 's/^export const LOADER = "\(sw-[0-9a-f]*\.js\)";$/\1/p' "$BUILD/lib/version.js")"
[[ -n "$LOADER" && -f "$BUILD/$LOADER" ]] || { echo "loader named in lib/version.js is missing: ${LOADER:-none}" >&2; exit 1; }
want="${LOADER#sw-}"; want="${want%.js}"
got="$(shasum -a 256 "$BUILD/$LOADER" | cut -c1-${#want})"
[[ "$got" == "$want" ]] || { echo "$LOADER: its bytes do not match its name" >&2; exit 1; }

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
ZIP="$OUT/beam-campfire-web-$VERSION.zip"
rm -f "$ZIP"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
python3 -I - "$BUILD" "$STAGE/list" "$LOADER" <<'PY'
import json, os, sys
root, out, loader = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(os.path.join(root, 'manifest.json')))
extra = {'release.json', 'release.sig', 'manifest.json', loader}
# Hosting help, when the build has it: headers for Netlify/Cloudflare-style
# hosts, server configs, and how to host a copy.
extra |= {p for p in ('_headers', 'README.md', 'deploy/nginx.conf', 'deploy/Caddyfile') if os.path.isfile(os.path.join(root, p))}
paths = sorted({f['path'] for f in m['files']} | extra)
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
