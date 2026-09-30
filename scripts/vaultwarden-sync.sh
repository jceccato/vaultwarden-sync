#!/usr/bin/env bash
#
# vaultwarden-sync.sh
#
# One-way restore of a Vaultwarden backup (produced by dadatuputi/bwgc_backup on
# Google Cloud) into a local Vaultwarden container on Unraid.
#
# Flow (the "sync" command):
#   1. Find the newest bw_backup_* on the Google Drive remote (via rclone).
#      If it is the same one we restored last time -> exit, nothing to do.
#   2. Download it, decrypt (openssl aes256) and extract to a staging dir,
#      then validate the SQLite DB BEFORE touching anything live.
#   3. Stop the local Vaultwarden container.
#   4. Mirror the current appdata into the "rollback" dir (clear + copy).
#   5. Apply the validated backup over appdata.
#   6. Ensure the Vaultwarden image is up to date.
#   7. Start the Vaultwarden container.
#   8. Record the restored filename so we don't re-restore it next run.
#
# Nothing live is modified until a good, validated backup is staged, so a bad or
# partial download can never take your local copy down.
#
# Subcommands:
#   sync                 (default) download newest + restore if it is new
#   sync --force         restore the newest even if already restored
#   restore <file>       restore a specific local backup file (DR drill / manual)
#   rollback             restore appdata from the rollback dir (undo last restore)
#   status               show last-restored, newest-remote and container state
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment / config file)
# ---------------------------------------------------------------------------
# An optional config file can set any of these; env still wins for anything set.
CONFIG_FILE="${CONFIG_FILE:-/config/vaultwarden-sync.conf}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

CONTAINER_NAME="${CONTAINER_NAME:-vaultwarden}"   # name of the local vaultwarden container
APPDATA_DIR="${APPDATA_DIR:-/data/live}"          # vaultwarden /data dir (mounted in)
ROLLBACK_DIR="${ROLLBACK_DIR:-/data/rollback}"    # safety mirror of appdata
WORK_DIR="${WORK_DIR:-/data/downloads}"           # where backups are downloaded
STATE_FILE="${STATE_FILE:-$WORK_DIR/.last_restored}"

RCLONE_CONF="${RCLONE_CONF:-/config/rclone.conf}" # rclone config with the gdrive remote
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"          # remote name inside rclone.conf
RCLONE_PATH="${RCLONE_PATH:-bw_backups}"          # folder on Drive (== BACKUP_RCLONE_DEST)
RCLONE_EXTRA_FLAGS="${RCLONE_EXTRA_FLAGS:-}"      # e.g. --drive-shared-with-me

# openssl passphrase used by the backup (BACKUP_ENCRYPTION_KEY on GCloud).
# Leave empty only if your backups are NOT encrypted.
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"

# How to keep vaultwarden up to date: watchtower | pull | none
UPDATE_METHOD="${UPDATE_METHOD:-watchtower}"
WATCHTOWER_IMAGE="${WATCHTOWER_IMAGE:-containrrr/watchtower}"
VAULTWARDEN_IMAGE="${VAULTWARDEN_IMAGE:-vaultwarden/server:latest}"

BACKUP_GLOB="${BACKUP_GLOB:-bw_backup_*}"
LOCK_DIR="${LOCK_DIR:-/tmp/vaultwarden-sync.lock}"

REMOTE="${RCLONE_REMOTE}:${RCLONE_PATH}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()   { printf '%s [INFO]  %s\n'  "$(date '+%F %T')" "$*" >&2; }
warn()  { printf '%s [WARN]  %s\n'  "$(date '+%F %T')" "$*" >&2; }
err()   { printf '%s [ERROR] %s\n'  "$(date '+%F %T')" "$*" >&2; }
die()   { err "$*"; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

rclone_cmd() { rclone --config "$RCLONE_CONF" $RCLONE_EXTRA_FLAGS "$@"; }

# Acquire a simple lock so two runs can't overlap (mkdir is atomic).
acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another run is in progress (lock: $LOCK_DIR). Remove it if stale."
  fi
  # shellcheck disable=SC2064
  trap "rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT
}

container_state() {
  docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "absent"
}

stop_container() {
  case "$(container_state)" in
    running) log "Stopping container '$CONTAINER_NAME'..."; docker stop "$CONTAINER_NAME" >/dev/null ;;
    absent)  warn "Container '$CONTAINER_NAME' does not exist; nothing to stop." ;;
    *)       log "Container '$CONTAINER_NAME' is not running." ;;
  esac
}

start_container() {
  if [ "$(container_state)" = "absent" ]; then
    warn "Container '$CONTAINER_NAME' does not exist; cannot start it."
    return 0
  fi
  log "Starting container '$CONTAINER_NAME'..."
  docker start "$CONTAINER_NAME" >/dev/null
}

# Ensure vaultwarden runs the latest image, preserving its Unraid/template settings.
update_container() {
  case "$UPDATE_METHOD" in
    none)
      log "UPDATE_METHOD=none -> skipping image update."
      ;;
    pull)
      log "Pulling latest image: $VAULTWARDEN_IMAGE"
      docker pull "$VAULTWARDEN_IMAGE" >/dev/null || warn "docker pull failed."
      warn "UPDATE_METHOD=pull only fetches the image; the container is NOT recreated,"
      warn "so it keeps running the old image until you recreate it in the Unraid UI."
      ;;
    watchtower)
      log "Updating '$CONTAINER_NAME' via watchtower (one-shot)..."
      # Runs watchtower as a sibling container against the host docker socket.
      # --include-stopped / --revive-stopped so it works while we have it stopped.
      docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        "$WATCHTOWER_IMAGE" \
        --run-once --cleanup --include-stopped --revive-stopped \
        "$CONTAINER_NAME" || warn "watchtower update reported a problem (continuing)."
      ;;
    *)
      warn "Unknown UPDATE_METHOD='$UPDATE_METHOD'; skipping update."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Backup discovery / download
# ---------------------------------------------------------------------------

# Print the newest backup filename on the remote (or empty if none).
latest_remote() {
  rclone_cmd lsf "$REMOTE" --files-only --include "$BACKUP_GLOB" 2>/dev/null \
    | sort | tail -n 1
}

last_restored() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo ""
}

# Download a named backup from the remote into WORK_DIR; echoes local path.
download_backup() {
  local name="$1"
  mkdir -p "$WORK_DIR"
  log "Downloading '$name' from $REMOTE ..."
  rclone_cmd copy "$REMOTE/$name" "$WORK_DIR" --progress 2>&1 | sed 's/^/    /' >&2 || true
  [ -f "$WORK_DIR/$name" ] || die "Download failed: $WORK_DIR/$name not present."
  printf '%s' "$WORK_DIR/$name"
}

# ---------------------------------------------------------------------------
# Stage + validate a backup file (does NOT touch live data)
# ---------------------------------------------------------------------------
# Echoes the staging dir on success.
stage_and_validate() {
  local file="$1"
  [ -f "$file" ] || die "Backup file not found: $file"

  local staging
  staging="$(mktemp -d "${TMPDIR:-/tmp}/vwstage.XXXXXX")"

  log "Extracting backup to staging: $staging"
  case "$file" in
    *.aes256)
      [ -n "$BACKUP_ENCRYPTION_KEY" ] || { rm -rf "$staging"; die "Backup is encrypted (.aes256) but BACKUP_ENCRYPTION_KEY is empty."; }
      if ! openssl enc -d -aes256 -salt -pbkdf2 -pass pass:"$BACKUP_ENCRYPTION_KEY" -in "$file" \
            | tar xzf - -C "$staging"; then
        rm -rf "$staging"
        die "Failed to decrypt/extract '$file' (wrong key or corrupt file?)."
      fi
      ;;
    *.tar.gz|*.tgz)
      if ! tar xzf "$file" -C "$staging"; then
        rm -rf "$staging"
        die "Failed to extract '$file'."
      fi
      ;;
    *)
      rm -rf "$staging"
      die "Unrecognised backup extension: $file"
      ;;
  esac

  # db.sqlite3 is at the archive root in both layouts apply_backup accepts.
  [ -f "$staging/db.sqlite3" ] || { rm -rf "$staging"; die "Backup does not contain db.sqlite3 -- refusing to restore."; }

  log "Verifying SQLite integrity of restored database..."
  local res
  res="$(sqlite3 "$staging/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 | head -n1 || true)"
  if [ "$res" != "ok" ]; then
    rm -rf "$staging"
    die "SQLite integrity_check failed ('$res') -- refusing to restore a corrupt DB."
  fi
  log "Database integrity OK."

  printf '%s' "$staging"
}

# ---------------------------------------------------------------------------
# Rollback mirror + apply
# ---------------------------------------------------------------------------
rotate_rollback() {
  mkdir -p "$ROLLBACK_DIR"
  if [ ! -f "$APPDATA_DIR/db.sqlite3" ]; then
    warn "Appdata has no db.sqlite3 yet (first run?) -- skipping rollback snapshot."
    return 0
  fi
  log "Refreshing rollback snapshot: $ROLLBACK_DIR"
  # rsync --delete = clear the rollback dir, then copy the current appdata into it.
  rsync -a --delete "$APPDATA_DIR/" "$ROLLBACK_DIR/"
}

# Apply staged files onto appdata. Mirrors the upstream restore_backup() logic.
apply_backup() {
  local staging="$1"
  mkdir -p "$APPDATA_DIR"

  log "Applying database..."
  # Remove old DB + WAL/SHM sidecars so a stale WAL can't corrupt the new DB.
  rm -f "$APPDATA_DIR/db.sqlite3" "$APPDATA_DIR/db.sqlite3-wal" "$APPDATA_DIR/db.sqlite3-shm"
  cp "$staging/db.sqlite3" "$APPDATA_DIR/db.sqlite3"
  chmod 644 "$APPDATA_DIR/db.sqlite3" || true

  # The rest sits under data/ in a bwgc_backup archive, but at the archive root
  # in one made by bitwarden_gcloud's utilities/backup.sh. Accept either.
  local src="$staging"
  [ -d "$staging/data" ] && src="$staging/data"

  if [ -d "$src/attachments" ]; then
    log "Applying attachments..."
    rm -rf "$APPDATA_DIR/attachments"
    cp -a "$src/attachments" "$APPDATA_DIR/"
  fi

  if [ -d "$src/sends" ]; then
    log "Applying sends..."
    rm -rf "$APPDATA_DIR/sends"
    cp -a "$src/sends" "$APPDATA_DIR/"
  fi

  if [ -f "$src/config.json" ]; then
    log "Applying config.json..."
    cp -f "$src/config.json" "$APPDATA_DIR/config.json"
  fi

  # RSA keys (rsa_key.der / rsa_key.pem / rsa_key.pub.der etc.)
  if find "$src" -maxdepth 1 -name 'rsa_key*' -type f 2>/dev/null | grep -q .; then
    log "Applying RSA keys..."
    find "$src" -maxdepth 1 -name 'rsa_key*' -type f -exec cp -f {} "$APPDATA_DIR/" \;
  fi

  # The backup may include .env from the GCloud compose stack. It does NOT apply
  # to a single Unraid container (env there comes from the container template),
  # so we deliberately ignore it.
  if [ -f "$staging/.env" ]; then
    warn "Backup contains a GCloud .env -- ignored (not relevant to the Unraid container)."
  fi
}

# Full restore pipeline from a local file: stop -> rollback -> apply -> update -> start.
restore_from_file() {
  local file="$1"
  local staging
  staging="$(stage_and_validate "$file")"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'; rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT

  stop_container
  rotate_rollback
  apply_backup "$staging"
  update_container
  start_container

  rm -rf "$staging"
  log "Restore complete from: $(basename "$file")"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_sync() {
  local force="${1:-}"
  require rclone; require openssl; require tar; require sqlite3; require rsync; require docker

  [ -f "$RCLONE_CONF" ] || die "rclone config not found: $RCLONE_CONF"

  local newest prev
  newest="$(latest_remote || true)"
  [ -n "$newest" ] || { log "No backups found at $REMOTE -- nothing to do."; return 0; }
  prev="$(last_restored)"

  log "Newest on remote : $newest"
  log "Last restored    : ${prev:-<none>}"

  if [ "$newest" = "$prev" ] && [ "$force" != "--force" ]; then
    log "Already restored the newest backup -- nothing to do. (Use --force to redo.)"
    return 0
  fi

  local local_file
  local_file="$(download_backup "$newest")"

  restore_from_file "$local_file"

  printf '%s' "$newest" > "$STATE_FILE"
  log "Recorded last-restored: $newest"

  # Tidy WORK_DIR: keep only the backup we just restored.
  find "$WORK_DIR" -maxdepth 1 -type f -name "$BACKUP_GLOB" ! -name "$newest" -delete 2>/dev/null || true
}

cmd_restore() {
  local file="${1:-}"
  [ -n "$file" ] || die "Usage: $0 restore <backup-file>"
  require openssl; require tar; require sqlite3; require rsync; require docker
  # Allow a bare filename that lives in WORK_DIR.
  [ -f "$file" ] || file="$WORK_DIR/$file"
  restore_from_file "$file"
}

cmd_rollback() {
  require rsync; require docker
  [ -f "$ROLLBACK_DIR/db.sqlite3" ] || die "No rollback snapshot found in $ROLLBACK_DIR."
  warn "Rolling back appdata from the snapshot in $ROLLBACK_DIR"
  stop_container
  rsync -a --delete "$ROLLBACK_DIR/" "$APPDATA_DIR/"
  start_container
  log "Rollback complete. (State file unchanged: next sync may re-restore the newest backup.)"
}

cmd_status() {
  require rclone
  local newest prev
  newest="$(latest_remote || true)"
  prev="$(last_restored)"
  echo "Container       : $CONTAINER_NAME ($(container_state))"
  echo "Remote          : $REMOTE"
  echo "Newest on remote: ${newest:-<none>}"
  echo "Last restored   : ${prev:-<none>}"
  if [ -n "$newest" ] && [ "$newest" != "$prev" ]; then
    echo "Status          : NEW backup available"
  else
    echo "Status          : up to date"
  fi
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
main() {
  local cmd="${1:-sync}"; shift || true
  case "$cmd" in
    sync)     acquire_lock; cmd_sync "${1:-}" ;;
    restore)  acquire_lock; cmd_restore "${1:-}" ;;
    rollback) acquire_lock; cmd_rollback ;;
    status)   cmd_status ;;
    *)        die "Unknown command '$cmd'. Use: sync | restore <file> | rollback | status" ;;
  esac
}

main "$@"
