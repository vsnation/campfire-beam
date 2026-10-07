#!/usr/bin/env bash
# Static checks on an Android core build (wallet-api or beam-wallet). No device or
# emulator needed.
#
#   scripts/beam/core/android/verify_android.sh <abi> <path> [wallet-api|beam-wallet]
#
# The binary kind defaults to the file's name. Every binary must be:
#   - an ELF PIE executable for the ABI's machine, interpreter /system/bin/linker64,
#     with an Android ABI note for API $ANDROID_API (built by the pinned NDK);
#   - linked only against Android system libraries (libc, libm, libdl, liblog), with
#     no RPATH/RUNPATH and no libc++_shared.so (the STL is static);
#   - aligned for 16 KB pages (every PT_LOAD Align >= 0x4000) and without an
#     executable stack;
#   - built with the HF6 rules: the fork height 3928666 (0x3bf25a) is in the code
#     (`Rules`, core/block_crypt.cpp). The rules hash itself is computed at run time,
#     so only a run on a device shows `3928666-96df3f33ee02ad9e`;
#   - carrying the Campfire branch label and the release version string;
#   - free of the build machine's home directory and account name.
# wallet-api must also carry the patched code of 0002: the --privileged_shader_sha256
# option and the process_invoke_data guard message. beam-wallet must be the CLI that
# exports the owner key and restores wallets (its command names are present).
# The loopback bind (0001) changes a constant, not a string; its presence is shown
# by the source fingerprint (out/<platform>/.source) and the patch check in the build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

[[ $# -eq 2 || $# -eq 3 ]] || die "usage: $0 <arm64-v8a|x86_64> <path> [wallet-api|beam-wallet]"
abi="$(abi_normalize "$1")"; bin="$2"; kind="${3:-$(basename "$bin")}"
[[ -f "$bin" ]] || die "no such file: $bin"
case "$kind" in
    wallet-api|beam-wallet) ;;
    *) die "unknown binary kind '$kind' (use wallet-api or beam-wallet)" ;;
esac
RE="${NDK_TC}/bin/llvm-readelf"
fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }

printf '== %s (%s, %s)\n' "$bin" "$abi" "$kind"
file "$bin" | sed "s#^.*: #file: #"
printf 'size: %s bytes  sha256: %s\n' "$(wc -c < "$bin" | tr -d ' ')" "$(sha256_of "$bin")"

hdr="$("$RE" -h "$bin")"
type="$(awk -F': *' '/^ *Type:/{print $2}' <<<"$hdr")"
mach="$(awk -F': *' '/^ *Machine:/{print $2}' <<<"$hdr")"
[[ "$type" == DYN* ]] && pass "ELF type $type (position independent)" || fail "ELF type $type, want DYN (PIE)"
[[ "$mach" == "$(abi_elf_machine "$abi")" ]] && pass "machine $mach" || fail "machine $mach, want $(abi_elf_machine "$abi")"

dyn="$("$RE" -d "$bin")"
needed="$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn" | sort | tr '\n' ' ')"
printf 'NEEDED: %s\n' "$needed"
bad_needed=""
for n in $needed; do
    case "$n" in libc.so|libm.so|libdl.so|liblog.so) ;; *) bad_needed+="$n " ;; esac
done
[[ -z "$bad_needed" ]] && pass "only Android system libraries are needed" || fail "unexpected NEEDED: $bad_needed"
grep -qE '\((RPATH|RUNPATH)\)' <<<"$dyn" && fail "has RPATH/RUNPATH" || pass "no RPATH/RUNPATH"
grep -qE '\(FLAGS_1\).*PIE' <<<"$dyn" && pass "FLAGS_1 has PIE" || fail "FLAGS_1 lacks PIE"

prog="$("$RE" -lW "$bin")"
interp="$(sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p' <<<"$prog")"
[[ "$interp" == "/system/bin/linker64" ]] && pass "interpreter $interp" || fail "interpreter '$interp'"
aligns="$(awk '$1=="LOAD"{print $NF}' <<<"$prog" | sort -u | tr '\n' ' ')"
small=0
for a in $aligns; do (( a >= 0x4000 )) || small=1; done
[[ -n "$aligns" && "$small" == 0 ]] && pass "PT_LOAD alignment: $aligns(16 KB pages ok)" || fail "PT_LOAD alignment: $aligns(need >= 0x4000)"
stack="$(awk '$1=="GNU_STACK"{print $(NF-1)}' <<<"$prog")"
[[ "$stack" == "RW" ]] && pass "GNU_STACK $stack (not executable)" || fail "GNU_STACK flags '$stack'"

# .note.android.ident (NT_ANDROID_TYPE_IDENT): u32 API level, char[64] NDK version,
# char[64] NDK build number. macOS `file` does not decode it, so read the bytes.
hex="$("$RE" -n "$bin" 2>/dev/null | sed -n '/NT_ANDROID_TYPE_IDENT/,/^$/p' | sed -n 's/.*description data: *//p' | tr -d ' \n')"
read -r api ndk_ver ndk_build < <(python3 -I -c '
import sys
b = bytes.fromhex(sys.argv[1]) if sys.argv[1] else b""
if len(b) < 132: print("? ? ?"); sys.exit()
s = lambda x: x.split(b"\0")[0].decode() or "?"
print(int.from_bytes(b[0:4], "little"), s(b[4:68]), s(b[68:132]))' "$hex")
[[ "$api" == "$ANDROID_API" ]] && pass "Android ABI note: API $api" || fail "Android ABI note API '$api', want $ANDROID_API"
[[ "$ndk_build" == "${NDK_VERSION##*.}" ]] && pass "built by NDK $ndk_ver ($ndk_build)" \
    || fail "NDK note '$ndk_ver ($ndk_build)', want build ${NDK_VERSION##*.}"

# HF6: Rules sets pForks[6].m_Height = 3928666 = 0x3bf25a. x86_64 loads it as one
# immediate; arm64 builds it with mov #0xf25a + movk #0x3b, lsl #16 on one register.
dis="$("${NDK_TC}/bin/llvm-objdump" -d --no-show-raw-insn "$bin")"
case "$abi" in
    x86_64) hf6="$(grep -cE '\$0x3bf25a([^0-9a-f]|$)' <<<"$dis" || true)" ;;
    arm64-v8a) hf6="$(awk '
        match($0, /mov[ \t]+w[0-9]+, #0xf25a([ \t]|$)/) {
            r = $0; sub(/.*mov[ \t]+/, "", r); sub(/,.*/, "", r); want = r; n = 4; next }
        n > 0 { n--; if ($0 ~ ("movk[ \t]+" want ", #0x3b, lsl #16")) c++ }
        END { print c + 0 }' <<<"$dis")" ;;
esac
unset dis
[[ "${hf6:-0}" -ge 1 ]] && pass "HF6 fork height 3928666 (0x3bf25a) in the code (${hf6}x)" \
    || fail "HF6 fork height 3928666 (0x3bf25a) not found in the code"

strs="$(mktemp)"; trap 'rm -f "$strs"' EXIT
"${NDK_TC}/bin/llvm-strings" -a "$bin" > "$strs"
want_str() {   # want_str <label> <fixed string>
    if grep -qF -- "$2" "$strs"; then pass "$1: \"$2\""; else fail "$1: \"$2\" not found"; fi
}
case "$kind" in
    wallet-api)
        want_str "0002 option" "privileged_shader_sha256"
        want_str "0002 invoke-data guard" "invoke data requests a shader privilege that was not granted"
        ;;
    beam-wallet)
        want_str "CLI command" "export_owner_key"
        want_str "CLI command" "restore"
        ;;
esac
want_str "branch label" "${BEAM_TAG}-campfire"
want_str "version" "$BEAM_EXPECTED_VERSION"
if grep -qF -- "$HOME" "$strs" || grep -qF -- "$(id -un)" "$strs"; then
    fail "contains the build machine's home directory or account name ($(grep -cF -- "$(id -un)" "$strs") strings)"
else
    pass "no home directory or account name embedded"
fi
grep -qE '^/(Users|home)/' "$strs" && fail "absolute /Users or /home path embedded: $(grep -mE '^/(Users|home)/' "$strs" | head -1)" \
    || pass "no /Users or /home paths embedded"

if [[ "$fails" -eq 0 ]]; then printf 'ALL CHECKS PASSED (%s, %s)\n' "$abi" "$kind"; else printf '%s CHECK(S) FAILED (%s, %s)\n' "$fails" "$abi" "$kind"; exit 1; fi
