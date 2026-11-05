#!/usr/bin/env bash
# Curl both app health endpoints through edge Caddy. Exit non-zero on failure or
# missing required frontend env (presence booleans only - never reads secrets).
set -euo pipefail

BASE="${1:-https://localhost}"
NODE_ENV="${NODE_ENV:-production}"
CURL=(curl -fsS -k)

echo "[healthcheck] frontend via ${BASE}/api/health"
FE_JSON="$("${CURL[@]}" "${BASE}/api/health")"

node -e "
const body = JSON.parse(process.argv[1]);
const nodeEnv = process.argv[2];
if (body.status !== 'ok') {
  console.error('[healthcheck] frontend status is not ok');
  process.exit(1);
}
const env = body.env ?? {};
const required = ['PAYLOAD_API_URL', 'NEXTAUTH_SECRET', 'SITE_URL'];
const requiredInProd = [
  'REVALIDATION_SECRET',
  'BOT_WEBHOOK_SECRET',
  // the site's key to Centoway (oxytrip-site src/lib/env.ts). TripScript was cut off on 5 Nov 2026 and the
  // site's /api/health no longer reports its keys - listing them here marked a working site unhealthy.
  'CENTOWAY_API_KEY',
];
for (const key of required) {
  if (!env[key]) {
    console.error('[healthcheck] missing required env presence:', key);
    process.exit(1);
  }
}
if (nodeEnv === 'production') {
  for (const key of requiredInProd) {
    if (!env[key]) {
      console.error('[healthcheck] missing production env presence:', key);
      process.exit(1);
    }
  }
  if (!env.BOT_URL && !env.NEXT_PUBLIC_BOT_URL) {
    console.error('[healthcheck] missing BOT_URL|NEXT_PUBLIC_BOT_URL');
    process.exit(1);
  }
}
console.log('[healthcheck] frontend env presence ok');
" "$FE_JSON" "$NODE_ENV"

echo "[healthcheck] panel via ${BASE}/bot/health"
PANEL_JSON="$("${CURL[@]}" "${BASE}/bot/health")"
node -e "
const body = JSON.parse(process.argv[1]);
if (body.status !== 'ok') {
  console.error('[healthcheck] panel /bot/health status is not ok');
  process.exit(1);
}
console.log('[healthcheck] panel ok');
" "$PANEL_JSON"

echo "[healthcheck] all checks passed"
