#!/usr/bin/env bash
# Verify libbeam_core (wallet-api + the integrated node in one shared library).
#
#   verify_lib.sh <libbeam_core.dylib>            static checks, then the live self-test
#   verify_lib.sh --static <libbeam_core.dylib|.so>   static checks only (any platform's file)
#
# Static: architecture, minimum OS, install name / SONAME, ONLY the beam_* C
# interface exported, only system libraries needed, no home path or account name
# embedded, the pinned version and the Campfire patch strings present.
#
# Live (macOS, needs the network; about 15 minutes): harness/beam_core_selftest.c
# linked against the dylib runs ONE process with wallet-api and the node inside it,
# against BEAM mainnet, with a throwaway wallet in a 0700 temp dir that is deleted
# at the end. With Homebrew's `tor` installed, a private Tor (random SocksPort,
# DataDirectory in the temp dir) carries the second half: node host names are
# resolved THROUGH Tor (SOCKS5 RESOLVE), and harness/net_canary.c, inserted with
# DYLD_INSERT_LIBRARIES, records every name lookup, connect() and UDP send of the
# process, so "nothing but 127.0.0.1" is checked for every call. Three throwaway
# wallets then run as concurrent instances (beam_wallet_api_start) next to the
# node, directly and through Tor, with a stop/restart of one of them and 20
# start/stop cycles under load; at the end leaks(1) checks the process.
#
# Env: LIVE_NODE (wallet-api's node, default eu-node01.mainnet.beam.mw:8100),
#      LIVE_PEERS (the node's peers, default eu-nodes + us-nodes .mainnet.beam.mw:8100),
#      NODE_SECONDS (how long a node may take to show progress, default 180),
#      NO_TOR=1 (skip the Tor phases).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

fail=0
pass_() { printf 'PASS  %s\n' "$*"; }
fail_() { printf 'FAIL  %s\n' "$*"; fail=1; }
check() { local d="$1"; shift; if "$@"; then pass_ "$d"; else fail_ "$d"; fi; }

static_only=0
if [[ "${1:-}" == "--static" ]]; then static_only=1; shift; fi
[[ $# -eq 1 ]] || die "usage: $0 [--static] <libbeam_core.dylib|.so>"
LIB="$1"
[[ -f "$LIB" ]] || die "no library at $LIB"

EXPORTS_FILE="${LIB_SCRIPTS_DIR}/src/exports.txt"
want_exports="$(sed '/^$/d' "$EXPORTS_FILE" | sort)"
account="$(id -un)"

# ---- static ---------------------------------------------------------------------------
kind="$(file -b "$LIB")"
echo "== static checks: ${LIB/#$HOME/~}"
echo "   $kind"
echo "   size $(wc -c < "$LIB" | tr -d ' ') bytes, sha256 $(sha256_of "$LIB")"

strings_of() {
    if command -v strings >/dev/null 2>&1; then strings -a "$1" 2>/dev/null || true
    else # Git Bash on Windows may lack binutils
        "$(command -v python3 || command -v python)" -c '
import re, sys
for m in re.finditer(rb"[\x20-\x7e]{4,}", open(sys.argv[1], "rb").read()):
    print(m.group().decode())
' "$1"
    fi
}
common_strings() {
    local s; s="$(strings_of "$LIB")"
    if grep -qF "$HOME" <<< "$s"; then fail_ "no home directory embedded"; else pass_ "no home directory embedded"; fi
    if grep -qi -- "$account" <<< "$s"; then fail_ "no account name embedded"; else pass_ "no account name embedded"; fi
    if grep -qE '/Users/|/home/[a-z]' <<< "$s"; then fail_ "no /Users or /home paths embedded: $(grep -m3 -E '/Users/|/home/[a-z]' <<< "$s" | tr '\n' ' ')"; else pass_ "no /Users or /home paths embedded"; fi
    local needle
    for needle in "beam-7.5.14493-campfire" "7.5.14493" "privileged_shader_sha256" \
                  "invoke data requests a shader privilege that was not granted" \
                  "proxy_addr" "with --proxy, --node_addr must be an IPv4 address" \
                  "Node connections go through the SOCKS5 proxy at"; do
        if grep -qF -- "$needle" <<< "$s"; then pass_ "string: \"$needle\""; else fail_ "string: \"$needle\""; fi
    done
    local ossl; ossl="$(grep -E '^(OPENSSLDIR|ENGINESDIR|MODULESDIR): ' <<< "$s" | sort -u | tr '\n' ' ')"
    if [[ -z "$ossl" ]]; then
        pass_ "no OpenSSL directory strings"
    elif grep -qE '/Users/|/home/' <<< "$ossl"; then
        fail_ "OpenSSL directories carry a home path: $ossl"
    else
        pass_ "OpenSSL directories carry no home path: $ossl"
    fi
}

case "$kind" in
    *Mach-O*)
        archs="$(lipo -archs "$LIB" 2>/dev/null)"
        check "architecture: arm64 only ($archs)" test "$archs" == "arm64"
        minos="$(otool -l "$LIB" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
        plat="$(otool -l "$LIB" | awk '/LC_BUILD_VERSION/{f=1} f&&/platform/{print $2; exit}')"
        check "platform macOS (1), minos ${minos} <= 12.0" bash -c "[[ '$plat' == 1 ]] && awk 'BEGIN{exit !($minos <= 12.0)}'"
        idn="$(otool -D "$LIB" | tail -1)"
        check "install name ${idn}" test "$idn" == "@rpath/libbeam_core.dylib"
        got_exports="$(nm -gU "$LIB" | awk '{print $3}' | sed 's/^_//' | sort)"
        if [[ "$got_exports" == "$want_exports" ]]; then
            pass_ "exports exactly the $(wc -l <<< "$want_exports" | tr -d ' ') beam_* functions of src/exports.txt"
        else
            fail_ "exports differ from src/exports.txt:"; diff <(echo "$want_exports") <(echo "$got_exports") | sed 's/^/      /'
        fi
        nm -gU "$LIB" | awk '{print "      " $3}'
        deps="$(otool -L "$LIB" | tail -n +2 | awk '{print $1}' | grep -v '^@rpath/libbeam_core.dylib$')"
        bad="$(grep -vE '^/(usr/lib|System/Library)/' <<< "$deps" || true)"
        check "links only system libraries ($(tr '\n' ' ' <<< "$deps"))" test -z "$bad"
        check "no main() exported or defined" bash -c "! nm '$LIB' | grep -qE ' T _main$'"
        check "code signature valid" codesign --verify "$LIB"
        common_strings
        ;;
    *ELF*)
        readelf="$(command -v llvm-readelf || command -v readelf || true)"
        nmtool="$(command -v llvm-nm || command -v nm)"
        if [[ -z "$readelf" ]]; then
            for c in "${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"/ndk/*/toolchains/llvm/prebuilt/*/bin; do
                [[ -x "$c/llvm-readelf" ]] && { readelf="$c/llvm-readelf"; nmtool="$c/llvm-nm"; break; }
            done
        fi
        [[ -n "$readelf" ]] || die "no readelf / llvm-readelf found"
        echo "   machine: $("$readelf" -h "$LIB" | awk -F: '/Machine/{gsub(/^ +/,"",$2); print $2}')"
        soname="$("$readelf" -d "$LIB" | awk '/SONAME/{print $NF}' | tr -d '[]')"
        check "SONAME ${soname}" test "$soname" == "libbeam_core.so"
        needed="$("$readelf" -d "$LIB" | awk '/NEEDED/{print $NF}' | tr -d '[]' | tr '\n' ' ')"
        bad="$(tr ' ' '\n' <<< "$needed" | grep -vE '^(libc\.so|libm\.so|libdl\.so|liblog\.so|libpthread\.so\.0|libc\.so\.6|libm\.so\.6|libdl\.so\.2|librt\.so\.1|ld-linux.*)$' | grep -v '^$' || true)"
        check "NEEDED only system libraries: ${needed}" test -z "$bad"
        got_exports="$("$nmtool" -D --defined-only "$LIB" | awk '$2 ~ /^[TWDBR]$/ {print $3}' | sort)"
        if [[ "$got_exports" == "$want_exports" ]]; then
            pass_ "exports exactly the $(wc -l <<< "$want_exports" | tr -d ' ') beam_* functions of src/exports.txt"
        else
            fail_ "exports differ from src/exports.txt:"; diff <(echo "$want_exports") <(echo "$got_exports") | head -20 | sed 's/^/      /'
        fi
        # 16 KB page alignment of the LOAD segments (Android 15+ devices).
        aligns="$("$readelf" -lW "$LIB" | awk '$1=="LOAD"{print $NF}' | sort -u | tr '\n' ' ')"
        echo "   LOAD alignment: ${aligns}"
        common_strings
        ;;
    *PE32*|*MS\ Windows*)
        common_strings
        ;;
    *) fail_ "unknown file type: $kind" ;;
esac

if [[ "$static_only" == "1" ]]; then
    [[ "$fail" == 0 ]] || die "static verification failed"
    log "static verification passed"
    exit 0
fi

# ---- live -----------------------------------------------------------------------------
[[ "$kind" == *Mach-O* && "$(uname -s)" == "Darwin" ]] || die "the live self-test runs on macOS against the dylib"
need_cmd clang; need_cmd python3; need_cmd lsof; need_cmd pgrep
echo "== live self-test"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/beam-core-verify.XXXXXX")"
chmod 700 "$WORK"
TOR_PID=""
cleanup() {
    [[ -n "$TOR_PID" ]] && kill "$TOR_PID" 2>/dev/null
    [[ -n "${SELFTEST_PID:-}" ]] && kill -9 "$SELFTEST_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
BIN="${WORK}/bin"; RUN="${WORK}/run"
mkdir -p "$BIN" "$RUN" && chmod 700 "$RUN"
libdir="$(cd "$(dirname "$LIB")" && pwd)"
clang -O1 -Wall -Wno-unused-function -I "${LIB_SCRIPTS_DIR}/src" "${LIB_SCRIPTS_DIR}/harness/beam_core_selftest.c" \
    -L "$libdir" -lbeam_core -Wl,-rpath,"$libdir" -o "${BIN}/beam_core_selftest" 2> "${BIN}/link.log" \
    || { cat "${BIN}/link.log"; die "self-test build failed"; }
pass_ "self-test links against the library (no undefined symbols)"
clang -O1 -dynamiclib "${LIB_SCRIPTS_DIR}/harness/net_canary.c" -o "${BIN}/net_canary.dylib" 2>> "${BIN}/link.log" \
    || { cat "${BIN}/link.log"; die "canary build failed"; }

# Three throwaway wallets: 12 words each with a valid BIP39 checksum from BEAM's own English
# dictionary, and a random password, in 0600 files the self-test deletes once read.
dict="${LIB_SRC}/mnemonic/dictionary.cpp"
[[ -f "$dict" ]] || dict="${BEAM_SRC}/mnemonic/dictionary.cpp"
[[ -f "$dict" ]] || die "no BEAM dictionary (run build_lib_macos.sh --prepare-only)"
(umask 077
 python3 -I -c '
import hashlib, re, secrets, sys
text = open(sys.argv[1]).read()
en = text[text.index("const Dictionary en"):text.index("const Dictionary es")]
words = re.findall(r"\"([a-z]+)\"", en)
assert len(words) == 2048, len(words)
def phrase():
    ent = secrets.token_bytes(16)
    bits = int.from_bytes(ent, "big") << 4 | hashlib.sha256(ent).digest()[0] >> 4
    return ";".join(words[(bits >> (11 * (11 - i))) & 0x7FF] for i in range(12))
for name in ("phrase.txt", "phrase2.txt", "phrase3.txt"):
    open(sys.argv[2] + "/" + name, "w").write(phrase())
open(sys.argv[2] + "/pass.txt", "w").write(secrets.token_hex(24))
' "$dict" "$RUN")

# Tor, if installed: a private instance on a random port, data in the temp dir.
SOCKS_PORT=0; TOR_NODE="-"; TOR_PEERS="-"
socks_resolve() { # <port> <host>: IPv4 through Tor's SOCKS5 RESOLVE (0xF0); nothing local
    python3 -I -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=60)
s.sendall(b"\x05\x01\x00"); assert s.recv(2) == b"\x05\x00"
h = sys.argv[2].encode()
s.sendall(b"\x05\xf0\x00\x03" + bytes([len(h)]) + h + b"\x00\x00")
r = s.recv(10)
print(socket.inet_ntoa(r[4:8]) if len(r) >= 10 and r[1] == 0 else "")
' "$1" "$2"
}
to_ips() { # <port> <host:port,...>
    local out="" item host p ip
    IFS=',' read -ra items <<< "$2"
    for item in "${items[@]}"; do
        host="${item%:*}"; p="${item##*:}"
        ip="$(socks_resolve "$1" "$host")"
        [[ -n "$ip" ]] && out="${out:+${out},}${ip}:${p}"
    done
    echo "$out"
}
if [[ "${NO_TOR:-0}" != "1" ]] && command -v tor >/dev/null 2>&1; then
    SOCKS_PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    mkdir -p "${WORK}/tor" && chmod 700 "${WORK}/tor"
    cat > "${WORK}/tor/torrc" <<EOF
SocksPort 127.0.0.1:${SOCKS_PORT}
DataDirectory ${WORK}/tor/data
Log notice file ${WORK}/tor/tor.log
AvoidDiskWrites 1
EOF
    tor -f "${WORK}/tor/torrc" > /dev/null 2>&1 &
    TOR_PID=$!
    echo "   $(tor --version | head -1), SocksPort 127.0.0.1:${SOCKS_PORT}, pid ${TOR_PID}"
    for _ in $(seq 1 120); do
        grep -q "Bootstrapped 100%" "${WORK}/tor/tor.log" 2>/dev/null && break
        sleep 1
    done
    if grep -q "Bootstrapped 100%" "${WORK}/tor/tor.log" 2>/dev/null; then
        pass_ "Tor bootstrapped"
        TOR_NODE="$(to_ips "$SOCKS_PORT" "${LIVE_NODE:-eu-node01.mainnet.beam.mw:8100}")"
        TOR_PEERS="$(to_ips "$SOCKS_PORT" "${LIVE_PEERS:-eu-nodes.mainnet.beam.mw:8100,us-nodes.mainnet.beam.mw:8100}")"
        check "node names resolved through Tor (SOCKS5 RESOLVE): wallet node ${TOR_NODE}, peers ${TOR_PEERS}" test -n "$TOR_NODE" -a -n "$TOR_PEERS"
        [[ -n "$TOR_NODE" ]] || TOR_NODE="-"
        [[ -n "$TOR_PEERS" ]] || TOR_PEERS="-"
    else
        fail_ "Tor did not bootstrap in 120 s"; tail -5 "${WORK}/tor/tor.log"
        SOCKS_PORT=0
    fi
else
    echo "SKIP  Tor phases (tor not installed or NO_TOR=1)"
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[[ -n "$LAN_IP" ]] || LAN_IP="-"

# The self-test, with the canary inserted. A watchdog bounds it; the time from its
# last line to the process's exit shows whether shutdown hangs.
OUTF="${WORK}/selftest.out"
t_start=$(date +%s)
DYLD_INSERT_LIBRARIES="${BIN}/net_canary.dylib" "${BIN}/beam_core_selftest" "$RUN" \
    "${LIVE_NODE:-eu-node01.mainnet.beam.mw:8100}" \
    "${LIVE_PEERS:-eu-nodes.mainnet.beam.mw:8100,us-nodes.mainnet.beam.mw:8100}" \
    "$SOCKS_PORT" "$TOR_NODE" "$TOR_PEERS" "$LAN_IP" "${NODE_SECONDS:-180}" > "$OUTF" 2>&1 &
SELFTEST_PID=$!
limit=$(( ${NODE_SECONDS:-180} * 3 + 1500 ))
t_last=""
printed=0
while kill -0 "$SELFTEST_PID" 2>/dev/null; do
    sleep 1
    # Stream new lines; the LAN address never appears in the output.
    total=$(wc -l < "$OUTF" | tr -d ' ')
    if (( total > printed )); then
        sed -n "$((printed + 1)),${total}p" "$OUTF" | { if [[ "$LAN_IP" != "-" ]]; then sed "s/${LAN_IP//./\\.}/<lan>/g"; else cat; fi; }
        printed=$total
    fi
    if [[ -z "$t_last" ]] && grep -q '^selftest: ' "$OUTF"; then t_last=$(date +%s); fi
    if (( $(date +%s) - t_start > limit )); then
        fail_ "self-test still running after ${limit} s; killed"
        kill -9 "$SELFTEST_PID" 2>/dev/null
        break
    fi
done
wait "$SELFTEST_PID"; rc=$?
SELFTEST_PID=""
total=$(wc -l < "$OUTF" | tr -d ' ')
(( total > printed )) && sed -n "$((printed + 1)),${total}p" "$OUTF" | { if [[ "$LAN_IP" != "-" ]]; then sed "s/${LAN_IP//./\\.}/<lan>/g"; else cat; fi; }
t_end=$(date +%s)
[[ -z "$t_last" ]] && grep -q '^selftest: ' "$OUTF" && t_last=$t_end
if (( rc > 128 )); then fail_ "self-test died from signal $((rc - 128))"; fi
check "self-test exit status ${rc} (0: all its checks passed)" test "$rc" -eq 0
if [[ -n "$t_last" ]]; then
    check "the process exited $((t_end - t_last)) s after its last line (no hang at exit, limit 30 s)" test $((t_end - t_last)) -le 30
fi
echo "   self-test ran $((t_end - t_start)) s"

[[ -n "$TOR_PID" ]] && { kill "$TOR_PID" 2>/dev/null; wait "$TOR_PID" 2>/dev/null; TOR_PID=""; }
du -sh "$RUN" 2>/dev/null | awk '{print "   temp dir peak content at the end: " $1}'
rm -rf "$WORK"
check "temp dir (wallet, node db, logs, Tor data) deleted" test ! -e "$WORK"
trap - EXIT

[[ "$fail" == 0 ]] || die "verification failed"
log "verification passed"
