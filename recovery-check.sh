#!/bin/sh
# Quick health check for a home server: mounts, Docker containers, a couple of
# service endpoints, and freshness of the last configuration backup.
# Exit code is the failure count, so this drops straight into cron/monitoring.
set -u

# Space-separated list of mountpoints that must be present.
MOUNTS=${MOUNTS:-"/ /mnt/media /mnt/backup-drive"}

# Space-separated list of Docker container names expected running and healthy.
CONTAINERS=${CONTAINERS:-"cloudflared uptime-kuma diun glances homepage portainer jellyfin"}

# Backup dir + filename prefix + minimum plausible size (bytes) for the
# "is there a recent, non-empty config backup" check.
BACKUP_DIR=${BACKUP_DIR:-/mnt/media/backups}
BACKUP_PREFIX=${BACKUP_PREFIX:-backup}
BACKUP_MIN_BYTES=${BACKUP_MIN_BYTES:-524288000}

fail=0
ok() { printf 'OK   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

for mnt in $MOUNTS; do
  mountpoint -q "$mnt" && ok "mounted: $mnt" || bad "not mounted: $mnt"
done

for name in $CONTAINERS; do
  state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null || true)
  health=$(docker inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)
  if [ "$state" = running ] && [ "$health" != unhealthy ]; then
    ok "container: $name${health:+ ($health)}"
  else
    bad "container: $name state=${state:-missing} health=${health:-n/a}"
  fi
done

curl -fsS --max-time 10 http://127.0.0.1:3001/ >/dev/null && ok 'Uptime Kuma endpoint' || bad 'Uptime Kuma endpoint'
curl -fsS --max-time 10 http://127.0.0.1:8096/health >/dev/null && ok 'Jellyfin health endpoint' || bad 'Jellyfin health endpoint'

latest=$(find "$BACKUP_DIR" -maxdepth 1 -name "${BACKUP_PREFIX}-*.tar.gz" -type f -printf '%T@ %s %p\n' 2>/dev/null | sort -rn | head -1)
if [ -n "$latest" ] && [ "$(printf '%s' "$latest" | cut -d' ' -f2)" -ge "$BACKUP_MIN_BYTES" ]; then
  ok "configuration backup: $(printf '%s' "$latest" | cut -d' ' -f3-)"
else
  bad "no plausible configuration backup in $BACKUP_DIR"
fi

printf '\n%d failure(s)\n' "$fail"
exit "$fail"
