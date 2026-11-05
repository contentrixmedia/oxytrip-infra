/**
 * Docker healthcheck for the frontend container — mirrors scripts/healthcheck.sh
 * env validation for REQUIRED_* keys (presence booleans from /api/health).
 */
const REQUIRED = ['PAYLOAD_API_URL', 'NEXTAUTH_SECRET', 'SITE_URL'];
const REQUIRED_IN_PROD = [
  'REVALIDATION_SECRET',
  'BOT_WEBHOOK_SECRET',
  // the site's key to Centoway (oxytrip-site src/lib/env.ts). TripScript was cut off on 5 Nov 2026 and the
  // site's /api/health no longer reports its keys - listing them here marked a working site unhealthy.
  'CENTOWAY_API_KEY',
];

async function main() {
  const res = await fetch('http://127.0.0.1:3000/api/health');
  if (!res.ok) process.exit(1);
  const body = await res.json();
  if (body.status !== 'ok') process.exit(1);

  const env = body.env ?? {};
  for (const key of REQUIRED) {
    if (!env[key]) process.exit(1);
  }

  if ((process.env.NODE_ENV ?? 'development') === 'production') {
    for (const key of REQUIRED_IN_PROD) {
      if (!env[key]) process.exit(1);
    }
    if (!env.BOT_URL && !env.NEXT_PUBLIC_BOT_URL) process.exit(1);
  }

  process.exit(0);
}

main().catch(() => process.exit(1));
