#!/usr/bin/env bash
# Back up the support bot's SQLite database (customer chats) - review 6 Nov 2026.
#
# The bot keeps every conversation in /app/bot/data/support.db inside the panel
# container (DB_PATH in env/panel.env; TURSO_* is not set), on the named volume
# panel_bot_data. Docker volumes are not in the droplet's snapshot-free rebuild
# path and nothing copied them anywhere, so losing the server lost the chats.
#
#   sudo ./scripts/backup-bot-db.sh                 take a backup now (what cron runs)
#   sudo ./scripts/backup-bot-db.sh install-cron    nightly at 23:40 UTC (03:40 Dubai)
#   sudo ./scripts/backup-bot-db.sh restore FILE    put a backup back (stops and starts the panel)
#
# How: SQLite's online backup API, run inside the running panel container with the
# better-sqlite3 module the bot already ships (the image has no sqlite3 CLI). It is
# the same mechanism as `sqlite3 .backup`: a consistent copy while the bot keeps
# writing - copying the file with cp could catch it mid-write. The copy is checked
# with PRAGMA integrity_check before it is kept.
#
# Local copies: /opt/oxytrip/backups/bot/bot-YYYYMMDD-HHMMSS.db.gz, mode 600, the
# newest BOT_BACKUP_KEEP (default 14) are kept.
#
# Off-site (optional, same idea as the hub's deploy/backup/offsite.sh: encrypted
# before it leaves the server). Make an rclone *crypt* remote once:
#   sudo docker run --rm -it -v /opt/oxytrip/env:/config/rclone rclone/rclone:1.68.2 config
#   sudo chmod 600 /opt/oxytrip/env/rclone.conf
# then put its name and folder in /opt/oxytrip/env/backup.env:
#   OFFSITE_REMOTE=oxytrip-safe:bot
# The script refuses a remote that is not of type crypt: these are customer chats.
# Keep the crypt passphrase outside the server (password manager), or the off-site
# copies cannot be opened after losing it.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${BOT_BACKUP_DIR:-${ROOT}/backups/bot}"
KEEP="${BOT_BACKUP_KEEP:-14}"
DB="${BOT_DB_PATH:-/app/bot/data/support.db}"
RCLONE_IMAGE="rclone/rclone:1.68.2"
RCLONE_CONF="${ROOT}/env/rclone.conf"
OFFSITE_KEEP_DAYS="${OFFSITE_KEEP_DAYS:-30}"

if [[ -f "${ROOT}/env/backup.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/env/backup.env"
  set +a
fi

log() { echo "$(date -u +%FT%TZ) $*"; }

# Found by compose labels, so this works without env/stack.env (prod.yml needs it).
panel_container() {
  docker ps -q \
    --filter label=com.docker.compose.project=oxytrip \
    --filter label=com.docker.compose.service=panel | head -1
}

backup() {
  mkdir -p "$OUT"
  chmod 700 "$OUT" "$(dirname "$OUT")"
  exec 9>"${OUT}/.lock"
  flock -n 9 || { log "another backup is running"; exit 1; }

  local cid stamp tmp part
  cid="$(panel_container)"
  [[ -n "$cid" ]] || { log "backup FAILED: no running panel container"; exit 1; }
  stamp="$(date -u +%Y%m%d-%H%M%S)"
  tmp="/tmp/bot-backup-${stamp}.db"
  part="${OUT}/bot-${stamp}.db.part"

  # cwd /app/bot so require() finds the bot's own node_modules/better-sqlite3.
  docker exec -w /app/bot "$cid" node -e '
    const Database = require("better-sqlite3");
    const [src, dest] = process.argv.slice(1);
    const db = new Database(src, { fileMustExist: true, timeout: 15000 });
    db.backup(dest).then(() => {
      db.close();
      // The copy inherits WAL mode; switch it to a single self-contained file, or
      // part of it could sit in a -wal file that docker cp below would not take.
      const w = new Database(dest);
      w.pragma("journal_mode = DELETE");
      w.close();
      const copy = new Database(dest, { readonly: true });
      const ok = copy.pragma("integrity_check", { simple: true });
      const tables = copy.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = ?").get("table").n;
      copy.close();
      if (ok !== "ok") { console.error("integrity_check: " + ok); process.exit(1); }
      console.log("integrity ok, " + tables + " tables");
    }).catch((e) => { console.error(e.message); process.exit(1); });
  ' "$DB" "$tmp" || { docker exec "$cid" rm -f "$tmp" "${tmp}-wal" "${tmp}-shm" || true; log "backup FAILED"; exit 1; }

  docker cp -q "${cid}:${tmp}" "$part"
  docker exec "$cid" rm -f "$tmp" "${tmp}-wal" "${tmp}-shm"
  gzip -9 "$part"
  chmod 600 "${part}.gz"
  mv "${part}.gz" "${OUT}/bot-${stamp}.db.gz"

  # Keep the newest $KEEP. Names sort by time, so no reliance on mtimes.
  find "$OUT" -maxdepth 1 -name 'bot-*.db.gz' -printf '%f\n' | sort -r | tail -n +"$((KEEP + 1))" \
    | while read -r old; do rm -f "${OUT}/${old}"; done
  find "$OUT" -maxdepth 1 -name '*.part*' -mmin +120 -delete

  log "backup ok: bot-${stamp}.db.gz ($(du -h "${OUT}/bot-${stamp}.db.gz" | cut -f1)), $(find "$OUT" -maxdepth 1 -name 'bot-*.db.gz' | wc -l) kept"
  offsite
}

rclone_run() {
  # rclone.conf is mounted writable: rclone saves refreshed OAuth tokens back into it.
  docker run --rm \
    -v "${RCLONE_CONF}:/config/rclone/rclone.conf" \
    -v "${OUT}:/data:ro" \
    "$RCLONE_IMAGE" "$@"
}

offsite() {
  [[ -n "${OFFSITE_REMOTE:-}" ]] || return 0
  [[ -f "$RCLONE_CONF" ]] || { log "offsite FAILED: OFFSITE_REMOTE set but no ${RCLONE_CONF}"; exit 1; }
  local name="${OFFSITE_REMOTE%%:*}"
  rclone_run listremotes --long | grep -Eq "^${name}:[[:space:]]+crypt\$" \
    || { log "offsite FAILED: remote '${name}' is not an rclone crypt remote - refusing to upload chats unencrypted"; exit 1; }
  rclone_run copy /data "$OFFSITE_REMOTE" --include 'bot-*.db.gz' --max-depth 1 --retries 3
  rclone_run delete "$OFFSITE_REMOTE" --include 'bot-*.db.gz' --min-age "${OFFSITE_KEEP_DAYS}d"
  log "offsite ok: $(rclone_run lsf "$OFFSITE_REMOTE" --include 'bot-*.db.gz' | wc -l) copies on ${name}"
}

install_cron() {
  [[ "$(id -u)" == 0 ]] || { echo "run with sudo" >&2; exit 1; }
  cat > /etc/cron.d/oxytrip-bot-backup <<EOF
# Nightly backup of the support bot database - see ${ROOT}/scripts/backup-bot-db.sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
40 23 * * * root ${ROOT}/scripts/backup-bot-db.sh >> /var/log/oxytrip-bot-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/oxytrip-bot-backup
  touch /var/log/oxytrip-bot-backup.log && chmod 600 /var/log/oxytrip-bot-backup.log
  echo "Installed /etc/cron.d/oxytrip-bot-backup (23:40 UTC). Log: /var/log/oxytrip-bot-backup.log"
}

# Stops the panel, replaces the database file on the volume, starts the panel.
restore() {
  local file="${1:?usage: backup-bot-db.sh restore backups/bot/bot-YYYYMMDD-HHMMSS.db.gz}"
  [[ -f "$file" ]] || { echo "No such file: $file" >&2; exit 1; }
  [[ -f "${ROOT}/env/stack.env" ]] || { echo "No env/stack.env - restore env files first." >&2; exit 1; }
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/env/stack.env"
  set +a
  local dc=(docker compose -f "${ROOT}/compose/docker-compose.base.yml" -f "${ROOT}/compose/prod.yml")
  local stage; stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  gunzip -c "$file" > "${stage}/support.db"
  chmod 644 "${stage}/support.db"

  # Creates the volume on a fresh server without starting anything else.
  "${dc[@]}" create panel >/dev/null
  "${dc[@]}" stop panel
  local vol; vol="$(docker volume ls -q --filter label=com.docker.compose.project=oxytrip | grep -x 'oxytrip_panel_bot_data')"
  # The panel image is already on the server; it runs as root, like the bot does.
  # Stale -wal/-shm files belong to the old database and must not be replayed onto this one.
  docker run --rm --network none --entrypoint sh \
    -v "${vol}:/data" -v "${stage}:/in:ro" \
    "ghcr.io/contentrixmedia/oxytrip-cms:${PANEL_TAG:?set PANEL_TAG}" -c '
      set -e
      if [ -f /data/support.db ]; then cp -p /data/support.db "/data/support.db.before-restore-$(date -u +%Y%m%d-%H%M%S)"; fi
      rm -f /data/support.db-wal /data/support.db-shm /data/support.db-journal
      cp /in/support.db /data/support.db
      cd /app/bot && node -e "const D=require(\"better-sqlite3\"); const d=new D(\"/data/support.db\",{readonly:true}); const r=d.pragma(\"integrity_check\",{simple:true}); if(r!==\"ok\"){console.error(r);process.exit(1)} console.log(\"restored database: integrity ok\")"
    '
  "${dc[@]}" start panel
  echo "Panel started. The previous database (if any) is kept on the volume as support.db.before-restore-*."
}

case "${1:-backup}" in
  backup)       backup ;;
  install-cron) install_cron ;;
  restore)      restore "${2:-}" ;;
  *) echo "usage: backup-bot-db.sh [backup|install-cron|restore FILE]" >&2; exit 1 ;;
esac
