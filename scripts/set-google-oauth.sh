#!/usr/bin/env bash
# Set the Google sign-in credentials for the frontend and restart it.
#
#   ./scripts/set-google-oauth.sh
#
# Prompts for the Client ID and Client Secret so neither ends up in shell
# history. Writes them to env/frontend.env (owner-readable only), escaping any
# "$" as "$$" - Compose expands a bare "$" and would silently truncate the value,
# which is how the bot dashboard password broke.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/env/frontend.env"

[[ -f "$ENV_FILE" ]] || { echo "No $ENV_FILE on this machine - run this on the server." >&2; exit 1; }

read -r -p "Google Client ID: " CLIENT_ID
read -r -s -p "Google Client Secret (not shown): " CLIENT_SECRET
echo

[[ -n "$CLIENT_ID" && -n "$CLIENT_SECRET" ]] || { echo "Both values are required." >&2; exit 1; }
case "$CLIENT_ID" in
  *.apps.googleusercontent.com) ;;
  *) echo "That Client ID does not end in .apps.googleusercontent.com - check you copied the ID, not the secret." >&2; exit 1 ;;
esac

escape() { printf '%s' "$1" | sed 's/\$/$$/g'; }

# The backup is a full copy of the live secrets: owner-only, like the file itself
# (cp -p would keep whatever mode env/frontend.env had). .gitignore covers env/*.env*
# so it cannot be committed (review 6 Nov 2026).
BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
(umask 077 && cp "$ENV_FILE" "$BACKUP")
chmod 600 "$BACKUP"

set_var() {
  local key="$1" value; value="$(escape "$2")"
  if grep -q "^${key}=" "$ENV_FILE"; then
    # Use a control character as the sed delimiter: secrets may contain / and &.
    sed -i "s"$'\x01'"^${key}=.*"$'\x01'"${key}=${value}"$'\x01' "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

set_var GOOGLE_CLIENT_ID "$CLIENT_ID"
set_var GOOGLE_CLIENT_SECRET "$CLIENT_SECRET"
chmod 600 "$ENV_FILE"

echo "Updated (lengths only, values not shown):"
awk -F= '/^GOOGLE_CLIENT_(ID|SECRET)=/ {printf "  %s: %d characters\n", $1, length($2)}' "$ENV_FILE"

echo "Restarting the website..."
cd "$ROOT"
set -a; . env/stack.env; set +a
docker compose -f compose/docker-compose.base.yml -f compose/prod.yml up -d --no-deps frontend >/dev/null

for _ in $(seq 1 30); do
  status="$(docker inspect --format '{{.State.Health.Status}}' oxytrip-frontend-1 2>/dev/null || echo unknown)"
  [[ "$status" == healthy ]] && break
  sleep 5
done
echo "website: ${status}"

# Presence only - never prints the values.
echo "Server sees:"
docker exec oxytrip-frontend-1 sh -c 'printf "  GOOGLE_CLIENT_ID: %s chars\n  GOOGLE_CLIENT_SECRET: %s chars\n" "${#GOOGLE_CLIENT_ID}" "${#GOOGLE_CLIENT_SECRET}"'
echo
echo "Now try signing in with Google at https://oxytrip.com/auth/login"
