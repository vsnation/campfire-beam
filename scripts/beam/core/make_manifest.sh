#!/usr/bin/env bash
# Write scripts/beam/core/manifest.json from the built binaries:
#   { "<platform>-<arch>": { "<binary>": { "sha256", "size", "version" } } }
#
# Keys: macos-arm64, linux-arm64, linux-x86_64 (out/ dir linux-aarch64 -> linux-arm64).
# version is what the binary itself prints for --version: run natively when the host
# can, otherwise inside the beamcore-builder image for that platform.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MANIFEST="${CORE_SCRIPTS_DIR}/manifest.json"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

host="$(uname -s)-$(uname -m)"
for dir in "$OUT_ROOT"/*/; do
    plat="$(basename "$dir")"
    key="${plat/aarch64/arm64}"
    for b in "${BEAM_TARGETS[@]}"; do
        f="${dir}${b}"
        [[ -f "$f" ]] || continue
        case "$plat:$host" in
            macos-arm64:Darwin-arm64) v="$("$f" --version)" ;;
            linux-aarch64:*) v="$(docker run --rm --platform linux/arm64 -v "$OUT_ROOT:/out:ro" beamcore-builder:ubuntu22.04-arm64 "/out/$plat/$b" --version)" ;;
            linux-x86_64:*)  v="$(docker run --rm --platform linux/amd64 -v "$OUT_ROOT:/out:ro" beamcore-builder:ubuntu22.04-amd64 "/out/$plat/$b" --version)" ;;
            *) die "cannot run $plat binaries here" ;;
        esac
        v="$(printf '%s' "$v" | tr -d '\r\n')"
        [[ "$v" == "$BEAM_EXPECTED_VERSION" ]] || die "$f reports version '$v'"
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$b" "$(sha256_of "$f")" "$(wc -c < "$f" | tr -d ' ')" "$v" >> "$tmp"
    done
done

python3 - "$tmp" "$MANIFEST" <<'EOF'
import json, sys
out = {}
for line in open(sys.argv[1]):
    key, b, sha, size, ver = line.rstrip("\n").split("\t")
    out.setdefault(key, {})[b] = {"sha256": sha, "size": int(size), "version": ver}
order = ["macos-arm64", "linux-arm64", "linux-x86_64"]
out = {k: out[k] for k in sorted(out, key=lambda k: order.index(k) if k in order else 99)}
open(sys.argv[2], "w").write(json.dumps(out, indent=2) + "\n")
EOF
log "wrote $MANIFEST"
cat "$MANIFEST"
