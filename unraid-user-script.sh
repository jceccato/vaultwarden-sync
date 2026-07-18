#!/bin/bash
#
# Mode B -- Unraid "User Scripts" entry.
#
# Paste this into a new script in the User Scripts plugin and give it a cron
# schedule (e.g. custom: 0 3 * * *). It runs the sync ONCE in a throwaway
# container, then exits. No persistent helper container required.
#
# Build the image first (one time), on the Unraid terminal:
#   cd /boot/config/plugins/user.scripts/scripts/vaultwarden-sync   # or wherever you put it
#   docker build -t vaultwarden-sync /mnt/user/appdata/vaultwarden-sync/src
#
# Then edit the paths/values below to match your setup.

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
# --------------------------------------------------------------------------

mkdir -p "$ROLLBACK_DIR" "$DOWNLOAD_DIR"

docker run --rm \
  -e TZ="$TZ" \
  -e CONTAINER_NAME="$CONTAINER_NAME" \
  -e RCLONE_REMOTE="$RCLONE_REMOTE" \
  -e RCLONE_PATH="$RCLONE_PATH" \
  -e BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
  -e UPDATE_METHOD="$UPDATE_METHOD" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$APPDATA_DIR":/data/live \
  -v "$ROLLBACK_DIR":/data/rollback \
  -v "$DOWNLOAD_DIR":/data/downloads \
  -v "$RCLONE_CONF":/config/rclone.conf:ro \
  vaultwarden-sync:latest sync
