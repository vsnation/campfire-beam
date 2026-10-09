#!/usr/bin/env bash
# Writes test/beam/bridge/fixtures/relayer_fee_vectors.json by running BeamMW's
# own relayer fee code on fixed inputs: utils/eth_gas.js and utils/eth_fee.js
# from beam-bridge-ethrelay, downloaded unmodified at the pinned commits below
# (`mainnet` = the forward relayers, 120 000 gas; `reverse_mainnet` = the WBEAM
# relayer, 96 000 gas). Only web3 (a few BN helpers and eth_feeHistory),
# dotenv, and the CoinGecko server (a local one) are stand-ins.
#
# relayer_parity_test.dart then checks that Campfire computes the same
# minimum, to the unit, for every vector. Re-run when the relayer changes.
#
#   scripts/beam/bridge/relayer_fee/make_vectors.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../../.." && pwd)"
MAINNET=d626ceb89dcc5360af9905f8b3eca99096278bf7
REVERSE=19b0daa64bdfab168a075374fc2ce36c6dc9ec15
base=https://raw.githubusercontent.com/BeamMW/beam-bridge-ethrelay
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/fwd" "$work/rev" "$work/node_modules"
for f in eth_gas.js eth_fee.js; do
  curl -fsS "$base/$MAINNET/utils/$f" -o "$work/fwd/$f"
  curl -fsS "$base/$REVERSE/utils/$f" -o "$work/rev/$f"
done
for d in fwd rev; do
  echo 'export class CurrencyRateError extends Error {}' > "$work/$d/exceptions.js"
done
cp -R "$here/stubs/web3" "$here/stubs/dotenv" "$work/node_modules/"
cp "$here/run.mjs" "$work/run.mjs"
echo '{"type":"module"}' > "$work/package.json"
(cd "$work" && node run.mjs) > "$root/test/beam/bridge/fixtures/relayer_fee_vectors.json"
echo "wrote test/beam/bridge/fixtures/relayer_fee_vectors.json"
