#!/bin/bash
# Backs up the world and server config to S3. Runs after Minecraft has stopped (see idle-check.sh).
#   s3://$BACKUP_BUCKET/backups/latest.tar.gz        always the newest (never expires)
#   s3://$BACKUP_BUCKET/backups/dated/<time>.tar.gz  history (expires after 90 days)
set -euo pipefail
source /opt/mc/host.env

stamp=$(date -u +%Y-%m-%dT%H%MZ)
tmp=$(mktemp /tmp/mc-backup.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT

# Mods, libraries and the server jar are re-downloaded on boot; only keep what's ours.
tar -C /opt/mc/data -czf "$tmp" \
  --exclude=./mods --exclude=./libraries --exclude=./versions --exclude=./.fabric \
  --exclude=./logs --exclude=./crash-reports --exclude=./.cache --exclude='./*.jar' .

aws s3 cp --only-show-errors "$tmp" "s3://$BACKUP_BUCKET/backups/dated/$stamp.tar.gz"
aws s3 cp --only-show-errors "$tmp" "s3://$BACKUP_BUCKET/backups/latest.tar.gz"
logger -t mc-backup "backed up world ($(du -h "$tmp" | cut -f1)) as $stamp"
