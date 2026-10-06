#!/usr/bin/env bash
# Sends a message to the owner's Telegram. Credentials are read from
# ~/.config/campfire-beam/telegram.env (mode 0600, never in this repo):
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
# With no credentials it prints the message and exits 0, so callers never fail on it.
set -euo pipefail
ENV_FILE="${HOME}/.config/campfire-beam/telegram.env"
msg="${*:-}"
[[ -z "$msg" ]] && { echo "usage: notify_telegram.sh <message>"; exit 2; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo "notify_telegram: no $ENV_FILE — message not sent:"
  echo "$msg"
  exit 0
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
: "${TELEGRAM_BOT_TOKEN:?missing in $ENV_FILE}" "${TELEGRAM_CHAT_ID:?missing in $ENV_FILE}"

# The token goes in the URL, so keep it out of `set -x` traces and process listings:
# curl reads the URL from stdin via --config.
resp=$(printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
  | curl -sS --max-time 20 --config - \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
      --data-urlencode "text=${msg}" \
      --data-urlencode "disable_web_page_preview=true")
if echo "$resp" | grep -q '"ok":true'; then
  echo "notify_telegram: sent"
else
  echo "notify_telegram: FAILED — $(echo "$resp" | sed -E 's/bot[0-9]+:[A-Za-z0-9_-]+/bot<redacted>/g' | head -c 300)"
  exit 1
fi
