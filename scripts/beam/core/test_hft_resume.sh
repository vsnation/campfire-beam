#!/usr/bin/env bash
# Regression test for core patch 0006 (patches/0006-hft-no-rebuild-after-restart.patch):
# an HFT contract tx (DEX trade) that was in flight when the wallet stopped must never be
# executed twice.
#
# Builds tests/hft_resume_test.cpp twice against the static libraries of an EXISTING core
# build (nothing in that build is changed or rebuilt):
#   stock   - wallet/core/contract_transaction.cpp exactly as at the pinned commit
#   patched - the same file with 0006 applied
# and runs both. Passes only if the stock build FAILS the checks (the bug is reproduced)
# and the patched build passes them all. No node, no network, no funds.
#
# Usage: scripts/beam/core/test_hft_resume.sh
#   BEAM_SRC   BEAM checkout at the pinned commit (default ~/Desktop/Beam/beam-core-build/beam)
#   BUILD_DIR  its CMake build dir, Unix Makefiles (default .../build/macos-arm64)
#   WORK_DIR   scratch dir (default: a new temporary dir, removed afterwards)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_ROOT="${CORE_ROOT:-$HOME/Desktop/Beam/beam-core-build}"
BEAM_SRC="${BEAM_SRC:-$CORE_ROOT/beam}"
BUILD_DIR="${BUILD_DIR:-$CORE_ROOT/build/macos-arm64}"
PATCH="$HERE/patches/0006-hft-no-rebuild-after-restart.patch"
TEST_SRC="$HERE/tests/hft_resume_test.cpp"
FILE=wallet/core/contract_transaction.cpp

die() { echo "test_hft_resume: $*" >&2; exit 2; }

[ -d "$BEAM_SRC/.git" ] || [ -f "$BEAM_SRC/.git" ] || die "no BEAM checkout at $BEAM_SRC"
FLAGS_MAKE="$BUILD_DIR/wallet/core/CMakeFiles/wallet_core.dir/flags.make"
LINK_TXT="$BUILD_DIR/wallet/api/CMakeFiles/wallet-api.dir/link.txt"
[ -f "$FLAGS_MAKE" ] || die "no $FLAGS_MAKE (build the core first)"
[ -f "$LINK_TXT" ] || die "no $LINK_TXT"
[ -f "$BUILD_DIR/wallet/core/libwallet_core.a" ] || die "no libwallet_core.a in $BUILD_DIR"

if [ -n "${WORK_DIR:-}" ]; then
    W="$WORK_DIR"; mkdir -p "$W"
else
    W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fi

flag() { sed -n "s/^$1 = //p" "$FLAGS_MAKE"; }
CXX="$(sed -n 's/^# compile CXX with //p' "$FLAGS_MAKE")"
DEFINES="$(flag CXX_DEFINES)"
INCLUDES="$(flag CXX_INCLUDES)"
CXXFLAGS="$(flag CXX_FLAGS)"
[ -n "$CXX" ] && [ -n "$INCLUDES" ] || die "could not read compile flags from $FLAGS_MAKE"

# The stock file from the pinned commit (the checkout itself may have patches applied).
mkdir -p "$W/stock/wallet/core" "$W/patched/wallet/core"
git -C "$BEAM_SRC" show "HEAD:$FILE" > "$W/stock/$FILE"
cp "$W/stock/$FILE" "$W/patched/$FILE"
(cd "$W/patched" && patch -p1 --forward -s < "$PATCH") || die "0006 does not apply to the pinned $FILE"

compile() { # <src> <obj>
    # shellcheck disable=SC2086  # flag strings are word lists by design
    eval "$CXX $DEFINES -I$BEAM_SRC/wallet/core $INCLUDES $CXXFLAGS -c \"$1\" -o \"$2\""
}
echo "compiling (stock, patched, test)..."
compile "$W/stock/$FILE" "$W/ct_stock.o"
compile "$W/patched/$FILE" "$W/ct_patched.o"
compile "$TEST_SRC" "$W/test.o"

# Link like wallet-api does (its archive list, relative to its build dir), with our object
# for contract_transaction in front so the archive's copy is never pulled in.
LIBS="$(sed -e 's/.* -o wallet-api //' "$LINK_TXT")"
link() { # <ct.o> <exe>
    (cd "$BUILD_DIR/wallet/api" && eval "$CXX $CXXFLAGS \"$W/test.o\" \"$1\" -o \"$2\" $LIBS")
}
link "$W/ct_stock.o" "$W/hft_stock"
link "$W/ct_patched.o" "$W/hft_patched"

echo
echo "== stock contract_transaction.cpp (expected to FAIL) =="
set +e
"$W/hft_stock"; stock=$?
echo
echo "== with 0006 (must pass) =="
"$W/hft_patched"; patched=$?
set -e

echo
if [ "$stock" -ne 0 ] && [ "$patched" -eq 0 ]; then
    echo "test_hft_resume: OK (stock reproduces the double execution, 0006 prevents it)"
    exit 0
fi
[ "$stock" -eq 0 ] && echo "test_hft_resume: the stock build passed: the test no longer reproduces the bug" >&2
[ "$patched" -ne 0 ] && echo "test_hft_resume: the patched build FAILED" >&2
exit 1
