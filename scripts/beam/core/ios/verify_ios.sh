#!/usr/bin/env bash
# Checks for libbeam_wallet_api.a, the in-process BEAM core for iOS.
#
#   verify_ios.sh <slice> <libbeam_wallet_api.a>            static checks
#   verify_ios.sh --live <simulator udid|booted> [<lib>]    + run it in the Simulator
#
# Static checks (no device needed): architecture, platform and minimum OS of every
# object, the exported C interface (and nothing called main), no build-machine
# path or account name, and the Campfire patches' strings.
#
# --live links beam_core_selftest (selftest/) against the simulator slice, then
# runs it in the Simulator with `xcrun simctl spawn`: version and rules, a
# throwaway wallet (random words from BEAM's own dictionary, written to 0600
# files, never printed), wrong/right password, wallet-api on a loopback port with
# an ACL key against a public mainnet node until it is in sync, stop() from
# another thread, and the database opening again afterwards. LIVE_NODE and
# LIVE_SECONDS override the node (eu-nodes.mainnet.beam.mw:8100) and the time
# limit (180 s).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

fail=0
pass_() { printf 'PASS  %s\n' "$*"; }
fail_() { printf 'FAIL  %s\n' "$*"; fail=1; }

static_checks() {
    local slice="$1" lib="$2"
    [[ -f "$lib" ]] || die "no such file: $lib"
    echo "== ${slice}: ${lib/#$HOME/~}"
    printf '%s  %s bytes\n' "$(sha256_of "$lib")" "$(wc -c < "$lib" | tr -d ' ')"

    local archs; archs="$(lipo -archs "$lib" 2>/dev/null || true)"
    [[ "$archs" == "arm64" ]] && pass_ "architecture: arm64 only" || fail_ "architectures: '${archs}'"

    # Every member's LC_BUILD_VERSION: one platform, minos no higher than the floor.
    local want; want="$(slice_macho_platform "$slice")"
    local lc; lc="$(otool -l "$lib" 2>/dev/null | awk '/cmd LC_BUILD_VERSION/{f=1;next} f&&/platform/{p=$2} f&&/minos/{print p" "$2; f=0}')"
    local n_obj; n_obj="$(printf '%s\n' "$lc" | grep -c . || true)"
    local platforms; platforms="$(printf '%s\n' "$lc" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    local minmax; minmax="$(printf '%s\n' "$lc" | awk '{print $2}' | sort -t. -k1,1n -k2,2n | tail -1)"
    if [[ "$platforms" == "$want " ]]; then
        pass_ "platform ${want} ($( [[ $want == 2 ]] && echo iOS || echo iOS-simulator )) in all ${n_obj} objects with LC_BUILD_VERSION"
    else
        fail_ "platforms found: ${platforms}(want ${want})"
    fi
    if [[ "$(printf '%s\n%s\n' "$minmax" "$IOS_MIN" | sort -t. -k1,1n -k2,2n | tail -1)" == "$IOS_MIN" ]]; then
        pass_ "highest minos ${minmax} <= ${IOS_MIN}"
    else
        fail_ "an object needs iOS ${minmax} (> ${IOS_MIN})"
    fi

    # The C interface, defined and global; no main().
    local defined; defined="$(nm -gU "$lib" 2>/dev/null | awk '$2=="T"{print $3}' | sort -u)"
    local f
    for f in beam_wallet_api_run beam_wallet_api_stop beam_wallet_api_is_running beam_wallet_api_version \
             beam_wallet_api_rules_signature beam_wallet_api_init_wallet beam_wallet_api_check_wallet; do
        grep -qx "_${f}" <<<"$defined" && pass_ "exports ${f}" || fail_ "does not export ${f}"
    done
    grep -qx '_main' <<<"$defined" && fail_ "defines main()" || pass_ "no main() (wallet-api's is renamed)"

    # No build-machine paths. $HOME holds the account name.
    local strs; strs="$(strings -a "$lib")"
    local acct; acct="$(basename "$HOME")"
    local hits
    hits="$(grep -cF -- "$HOME" <<<"$strs" || true)"; [[ "$hits" == 0 ]] && pass_ "no home directory embedded" || fail_ "${hits} strings contain the home directory"
    hits="$(grep -cF -- "$acct" <<<"$strs" || true)"; [[ "$hits" == 0 ]] && pass_ "no account name embedded" || fail_ "${hits} strings contain the account name"
    hits="$(grep -cE '/Users/|/home/' <<<"$strs" || true)"; [[ "$hits" == 0 ]] && pass_ "no /Users or /home paths embedded" || fail_ "${hits} /Users or /home strings"

    local s
    for s in "privileged_shader_sha256" "invoke data requests a shader privilege that was not granted" \
             "beam-7.5.14493-campfire" "7.5.14493"; do
        grep -qF -- "$s" <<<"$strs" && pass_ "string: \"${s}\"" || fail_ "missing string \"${s}\""
    done
    grep -q 'OPENSSLDIR: "/opt/campfire-beam/openssl/ssl"' <<<"$strs" && pass_ "OpenSSL directories are neutral" || fail_ "OPENSSLDIR is not the neutral prefix"
}

live_checks() {
    local udid="$1" lib="$2"
    local sim_lib="$lib"
    [[ -f "$sim_lib" ]] || die "no simulator library at $sim_lib (build ios-arm64-simulator first)"
    need_cmd python3
    local work; work="$(mktemp -d "${TMPDIR:-/tmp}/beam-ios-selftest.XXXXXX")"
    chmod 700 "$work"
    local exe="${work}/beam_core_selftest"
    log "linking the self-test against ${sim_lib/#$HOME/~}"
    xcrun --sdk iphonesimulator clang -target "$(slice_triple ios-arm64-simulator)" -O1 \
        -I "${IOS_SCRIPTS_DIR}/src" "${IOS_SCRIPTS_DIR}/selftest/beam_core_selftest.c" \
        "$sim_lib" -lc++ -o "$exe" 2> "${work}/link.log" \
        || { tail -30 "${work}/link.log"; die "self-test link failed"; }
    pass_ "self-test links against the library (no undefined symbols)"

    if [[ "$udid" == "booted" ]]; then
        udid="$(xcrun simctl list devices booted | sed -nE 's/.*\(([0-9A-F-]{36})\) \(Booted\).*/\1/p' | head -1)"
        [[ -n "$udid" ]] || die "no booted simulator; pass a UDID"
    fi
    if ! xcrun simctl list devices | grep -q "${udid}) (Booted)"; then
        log "booting simulator ${udid}"
        xcrun simctl boot "$udid"
        xcrun simctl bootstatus "$udid" -b > /dev/null
    fi
    echo "== simulator: $(xcrun simctl list devices | grep "$udid" | sed 's/^ *//')"
    xcrun simctl spawn "$udid" "$exe" version || fail=1

    # A throwaway wallet: 12 random words from BEAM's dictionary (BEAM checks
    # dictionary membership, not the BIP39 checksum) and a random password, in
    # 0600 files the self-test deletes once read. Never printed.
    local dict="${IOS_SRC}/mnemonic/dictionary.cpp"
    [[ -f "$dict" ]] || die "no BEAM dictionary at $dict (run build_wallet_api.sh --prepare-only)"
    (umask 077
     python3 -I -c '
import re, secrets, sys
text = open(sys.argv[1]).read()
en = text[text.index("const Dictionary en"):text.index("const Dictionary es")]
words = re.findall(r"\"([a-z]+)\"", en)
assert len(words) == 2048, len(words)
open(sys.argv[2] + "/phrase.txt", "w").write(";".join(secrets.choice(words) for _ in range(12)))
open(sys.argv[2] + "/pass.txt", "w").write(secrets.token_hex(24))
' "$dict" "$work")
    xcrun simctl spawn "$udid" "$exe" live "$work" "${LIVE_NODE:-eu-nodes.mainnet.beam.mw:8100}" "${LIVE_SECONDS:-180}" || fail=1
    local leftovers; leftovers="$(cd "$work" && ls phrase.txt pass.txt selftest.cfg selftest.acl 2>/dev/null || true)"
    [[ -z "$leftovers" ]] && pass_ "no secret file left behind" || fail_ "left behind: ${leftovers}"
    if [[ -d "${work}/logs" ]]; then
        echo "BEAM file log (warnings and errors): $(cat "${work}"/logs/*.log 2>/dev/null | wc -l | tr -d ' ') lines"
    fi
    rm -rf "$work"
}

if [[ "${1:-}" == "--live" ]]; then
    [[ $# -ge 2 ]] || die "usage: $0 --live <simulator udid|booted> [<simulator libbeam_wallet_api.a>]"
    lib="${3:-${OUT_ROOT}/ios-arm64-simulator/${IOS_LIB_NAME}}"
    static_checks ios-arm64-simulator "$lib"
    live_checks "$2" "$lib"
else
    [[ $# -eq 2 ]] || die "usage: $0 <slice> <libbeam_wallet_api.a> | --live <udid|booted> [<lib>]"
    static_checks "$(slice_normalize "$1")" "$2"
fi
[[ "$fail" == 0 ]] || die "verification failed"
log "verification passed"
