#!/usr/bin/env bash
# Refuses a commit that would publish a secret. Scans what is staged (default) or,
# with --all, every tracked file plus the BEAM docs.
#
# Two layers:
#  1. Pattern rules for things that look like secrets (bot tokens, private keys, wallet DBs).
#  2. An exact-match denylist kept OUTSIDE the repo (~/.config/campfire-beam/secret_denylist.txt,
#     one literal per line) holding the real test passwords and seeds. The repo never contains
#     the secrets it is checking for.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DENYLIST="${HOME}/.config/campfire-beam/secret_denylist.txt"
mode="${1:---staged}"

if [[ "$mode" == "--all" ]]; then
  files=$(git ls-files; git ls-files --others --exclude-standard)
else
  files=$(git diff --cached --name-only --diff-filter=ACMR)
fi
[[ -z "$files" ]] && { echo "secret_scan: nothing to scan"; exit 0; }

fail=0
report() { echo "secret_scan: $1"; fail=1; }

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.db|*.db-wal|*.db-shm|*wallet.db*) report "wallet database staged: $f"; continue ;;
    *.env|*telegram.env) report "env file staged: $f"; continue ;;
    *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ttf|*.otf|*.wasm|*.so|*.dylib|*.a|*.zip|*.gz) continue ;;
  esac
  # Telegram bot token: <8-10 digits>:<35 url-safe chars>
  if grep -nE '[0-9]{8,10}:[A-Za-z0-9_-]{35}' "$f" >/dev/null 2>&1; then
    report "telegram-token-like string in $f"
  fi
  if grep -nE -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$f" >/dev/null 2>&1; then
    report "PEM private key in $f"
  fi
  # A literal password handed to a BEAM binary or RPC (placeholders like <pass> are fine)
  if grep -nE -- '--pass(word)?="?[^"<$ {][^" ]{5,}' "$f" | grep -vE 'PASSWORD|YOUR_|<|\$\{?[A-Za-z_]' >/dev/null 2>&1; then
    report "literal --pass= value in $f"
  fi
done <<< "$files"

if [[ -f "$DENYLIST" ]]; then
  while IFS= read -r secret; do
    [[ -z "$secret" || "$secret" == \#* ]] && continue
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      if grep -qF -- "$secret" "$f" 2>/dev/null; then
        report "denylisted secret found in $f (value not shown)"
      fi
    done <<< "$files"
  done < "$DENYLIST"
else
  echo "secret_scan: note — no denylist at $DENYLIST, pattern rules only"
fi

if [[ $fail -ne 0 ]]; then
  echo "secret_scan: FAILED — nothing may be committed until these are removed"
  exit 1
fi
echo "secret_scan: clean ($(echo "$files" | wc -l | tr -d ' ') files)"
