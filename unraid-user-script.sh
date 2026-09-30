#!/bin/bash
#
# Mode B -- Unraid "User Scripts" entry.
#
# Paste this into a new script in the User Scripts plugin and give it a cron
# schedule (e.g. custom: 0 3 * * *). It runs the sync ONCE in a throwaway
# container, then exits. No persistent helper container required.
#
# The image is published to GitHub Container Registry. On first run Docker will
# pull it automatically. Edit the paths/values below to match your setup.

set -euo pipefail

# ---- edit these ----------------------------------------------------------
APPDATA_DIR="/mnt/user/appdata/vaultwarden"
ROLLBACK_DIR="/mnt/user/appdata/vaultwarden-rollback"
DOWNLOAD_DIR="/mnt/user/appdata/vaultwarden-sync/downloads"
RCLONE_CONF="/mnt/user/appdata/vaultwarden-sync/rclone.conf"

CONTAINER_NAME="vaultwarden"
RCLONE_REMOTE="gdrive"
RCLONE_PATH="bw_backups"
BACKUP_ENCRYPTION_KEY="CHANGE_ME"        # openssl passphrase (keep an offline copy!)
UPDATE_METHOD="watchtower"               # watchtower | pull | none
TZ="Australia/Brisbane"
NTFY_URL=""                              # ntfy server for a refused backup; blank = log only
NTFY_TOKEN=""                            # ntfy publisher token
NOTIFY_HOST="$(hostname -s)"             # named first in the notification title
# --------------------------------------------------------------------------

mkdir -p "$ROLLBACK_DIR" "$DOWNLOAD_DIR"

docker run --rm \
  -e TZ="$TZ" \
  -e CONTAINER_NAME="$CONTAINER_NAME" \
  -e RCLONE_REMOTE="$RCLONE_REMOTE" \
  -e RCLONE_PATH="$RCLONE_PATH" \
  -e BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
  -e UPDATE_METHOD="$UPDATE_METHOD" \
  -e NTFY_URL="$NTFY_URL" \
  -e NTFY_TOKEN="$NTFY_TOKEN" \
  -e NOTIFY_HOST="$NOTIFY_HOST" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$APPDATA_DIR":/data/live \
  -v "$ROLLBACK_DIR":/data/rollback \
  -v "$DOWNLOAD_DIR":/data/downloads \
  -v "$RCLONE_CONF":/config/rclone.conf:ro \
  ghcr.io/jceccato/vaultwarden-sync:latest sync
