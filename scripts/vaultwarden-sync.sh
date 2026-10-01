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
#      If Drive cannot be listed or read, or holds no backup, send a
#      notification and exit non-zero: the live vault would otherwise go stale
#      without a word. So, too, if the newest backup is older than
#      MAX_BACKUP_AGE_HOURS (the source has stalled), restored or not.
#   2. Download it, decrypt (openssl aes256) and extract to a staging dir,
#      then validate the SQLite DB BEFORE touching anything live. A backup that
#      will not decrypt, holds no db.sqlite3 or fails the integrity check is
#      notified and never applied.
#      Refuse it, and send a notification, unless its vault is newer than the
#      live one (see check_fresh). Without --force a stale backup never lands.
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
#   sync --force         restore the newest even if already restored, and even
#                        if it is not newer than the live vault
#   restore <file>       restore a specific local backup file (DR drill / manual)
#   restore <file> --force   ... even if it is not newer than the live vault
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

# Notifications (ntfy). A refused, missing, unreachable, stalled or broken
# backup is published here. Leave NTFY_URL empty to disable; each is still logged and still exits
# non-zero.
NTFY_URL="${NTFY_URL:-}"                          # e.g. https://ntfy.example.net
NTFY_TOPIC="${NTFY_TOPIC:-infra}"
NTFY_TOKEN="${NTFY_TOKEN:-}"                      # publisher token (SECRET)
NOTIFY_HOST="${NOTIFY_HOST:-vaultwarden-sync}"    # named first in the title

BACKUP_GLOB="${BACKUP_GLOB:-bw_backup_*}"
# A newest backup older than this means the source has stopped uploading. Its
# age is read from its name (..._YYYY-MM-DD-HHMMSS...), in BACKUP_TZ: the zone
# the backup source stamps names in (empty = this container's TZ).
MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-36}"
BACKUP_TZ="${BACKUP_TZ:-}"
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

# RCLONE_EXTRA_FLAGS is split on purpose: it may hold several flags.
# shellcheck disable=SC2086
rclone_cmd() { rclone --config "$RCLONE_CONF" $RCLONE_EXTRA_FLAGS "$@"; }

# The token reaches curl as a header file on a file descriptor, never in argv,
# which ps shows. No token, no header.
auth_header() {
  if [ -n "$NTFY_TOKEN" ]; then printf 'Authorization: Bearer %s\n' "$NTFY_TOKEN"; fi
}

# notify <low|medium|high> <title> <message> - publish to ntfy, never fail.
# The title is "<NOTIFY_HOST>: <title>". The message goes on stdin, so a leading
# @ in it is not read as a filename by curl.
notify() {
  local priority
  case "$1" in
    low) priority=2 ;; medium) priority=3 ;; high) priority=4 ;;
    *) warn "notify: invalid severity '$1'; nothing published: $2"; return 0 ;;
  esac
  if [ -z "$NTFY_URL" ]; then
    warn "NTFY_URL is not set; notification not sent: $2"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl not found; notification not sent: $2"
    return 0
  fi
  if printf '%s' "$3" | curl --silent --show-error --fail --output /dev/null \
        --max-time 10 --retry 5 --retry-delay 10 --retry-connrefused \
        --header @<(auth_header) \
        --header "Title: $NOTIFY_HOST: $2" \
        --header "Priority: $priority" \
        --data-binary @- \
        "${NTFY_URL%/}/$NTFY_TOPIC"; then
    log "Notification sent: $NOTIFY_HOST: $2"
  else
    warn "Notification to $NTFY_URL/$NTFY_TOPIC failed: $2"
  fi
  return 0
}

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

# Print the newest backup filename on the remote (or empty if none, or if the
# remote cannot be listed). For status; sync uses newest_backup, which tells
# those apart.
latest_remote() {
  rclone_cmd lsf "$REMOTE" --files-only --include "$BACKUP_GLOB" 2>/dev/null \
    | sort | tail -n 1
}

# rclone_error <stderr file> - the lines of rclone's stderr that say what went
# wrong, on one line, without their timestamps. rclone on a read-only
# single-file config also logs "Failed to save config" on every run, which is
# harmless and never the reason, so it is left out.
rclone_error() {
  local msg
  # --progress output can carry carriage returns and colour codes; strip them
  # so they never reach a notification.
  msg="$(tr -d '\r' < "$1" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | grep -E 'ERROR|Failed|error' | grep -v 'Failed to save config' \
    | tail -n 2 | sed -E 's#^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:]{8} ##' | tr '\n' ' ' | head -c 300)" || true
  printf '%s' "${msg% }"
}

# abort_unreachable <what failed> - Drive could not be listed or read. Notify,
# then stop without touching anything.
abort_unreachable() {
  notify medium "Vaultwarden Backup Unreachable" \
    "$1. The live vault was left as it was, and goes stale until this is fixed; this repeats every run. Test with: rclone lsf $REMOTE"
  die "$1. Live vault left untouched."
}

# abort_missing <what was found> - Drive answered, but there is no backup to
# apply. Notify, then stop without touching anything.
abort_missing() {
  notify medium "Vaultwarden Backup Missing" \
    "Google Drive answered, but $1. The live vault was left as it was, and goes stale until a backup arrives; this repeats every run. Check the backup source and RCLONE_PATH."
  die "No backup to restore: $1. Live vault left untouched."
}

# Print the newest backup filename on the remote, or end the run, notified.
# Unlike latest_remote it tells "Drive is down" from "Drive has nothing": the
# first is a token or network to fix, the second a backup source that stopped,
# and they are acted on differently. rclone exits 3 when the folder itself is
# absent, which is the second kind.
newest_backup() {
  [ -f "$RCLONE_CONF" ] || abort_unreachable "rclone config not found: $RCLONE_CONF"
  local errf listing rc=0 why
  errf="$(mktemp "${TMPDIR:-/tmp}/vwlsf.XXXXXX")"
  listing="$(rclone_cmd lsf "$REMOTE" --files-only --include "$BACKUP_GLOB" 2>"$errf")" || rc=$?
  why="$(rclone_error "$errf")"; rm -f "$errf"
  case "$rc" in
    0) ;;
    3) abort_missing "the folder $REMOTE does not exist (${why:-rclone exited 3})" ;;
    *) abort_unreachable "Could not list backups at $REMOTE (${why:-rclone exited $rc})" ;;
  esac
  [ -n "$listing" ] || abort_missing "$REMOTE holds no backup matching $BACKUP_GLOB"
  printf '%s\n' "$listing" | sort | tail -n 1
}

# backup_epoch <name> - the time in a backup's name (..._YYYY-MM-DD-HHMMSS...)
# as epoch seconds, read in BACKUP_TZ; nothing if the name carries no time.
backup_epoch() {
  local ts
  ts="$(printf '%s' "$1" \
    | sed -nE 's/.*([0-9]{4}-[0-9]{2}-[0-9]{2})-([0-9]{2})([0-9]{2})([0-9]{2}).*/\1 \2:\3:\4/p')"
  [ -n "$ts" ] || return 0
  if [ -n "$BACKUP_TZ" ]; then
    TZ="$BACKUP_TZ" date -d "$ts" +%s 2>/dev/null || true
  else
    date -d "$ts" +%s 2>/dev/null || true
  fi
}

# check_stalled <name> - notify, and fail, when the newest backup is older than
# MAX_BACKUP_AGE_HOURS: the source has stopped uploading, and every run would
# otherwise find "nothing new" and stay quiet. Applying it, if it is new, is
# still up to the caller.
check_stalled() {
  local name="$1" stamp now limit="$MAX_BACKUP_AGE_HOURS"
  if [[ ! "$limit" =~ ^[0-9]+$ ]] || [ "$limit" -eq 0 ]; then
    warn "MAX_BACKUP_AGE_HOURS='$limit' is not a whole number of hours; using 36."
    limit=36
  fi
  stamp="$(backup_epoch "$name")"
  if [ -z "$stamp" ]; then
    warn "Cannot read a date from '$name'; its age was not checked."
    return 0
  fi
  now="$(date +%s)"
  [ $((now - stamp)) -gt $((limit * 3600)) ] || return 0
  notify medium "Vaultwarden Backup Stalled" \
    "The newest backup at $REMOTE is $name, $(((now - stamp) / 3600)) hours old (the limit is $limit). The backup source has stopped uploading, so the live vault is no newer than that backup and goes stale until it resumes; this repeats every run. Check the backup job on the source."
  err "The newest backup, $name, is $(((now - stamp) / 3600)) hours old (limit $limit): the backup source has stalled."
  return 1
}

last_restored() {
  [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo ""
}

# Download a named backup from the remote into WORK_DIR; echoes local path.
download_backup() {
  local name="$1"
  mkdir -p "$WORK_DIR"
  log "Downloading '$name' from $REMOTE ..."
  local errf rc=0 why
  errf="$(mktemp "${TMPDIR:-/tmp}/vwcopy.XXXXXX")"
  rclone_cmd copy "$REMOTE/$name" "$WORK_DIR" --progress 2>&1 | tee "$errf" | sed 's/^/    /' >&2 || rc=$?
  why="$(rclone_error "$errf")"; rm -f "$errf"
  if [ "$rc" -ne 0 ] || [ ! -f "$WORK_DIR/$name" ]; then
    abort_unreachable "Could not download $name from $REMOTE (${why:-rclone exited $rc})"
  fi
  printf '%s' "$WORK_DIR/$name"
}

# ---------------------------------------------------------------------------
# Stage + validate a backup file (does NOT touch live data)
# ---------------------------------------------------------------------------
# first_lines <file> - the first two non-empty lines of an error file, on one
# line, for a message.
first_lines() {
  tr -d '\r' < "$1" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 2 | tr '\n' ' ' \
    | head -c 300 | sed 's/ $//' || true
}

# broken <staging dir> <backup file> <what is wrong> - a downloaded backup that
# cannot be applied. Notify, then stop without touching anything. Nothing is
# recorded as restored, so a sync repeats this every run until a good backup
# arrives.
broken() {
  local name
  name="$(basename "$2")"
  rm -rf "$1" "$1.err"
  notify medium "Vaultwarden Backup Broken" \
    "$name $3. Nothing was applied: the live vault was left as it was, and goes stale until a good backup arrives; this repeats every run until then."
  die "$name $3. Live vault left untouched."
}

# Echoes the staging dir on success.
stage_and_validate() {
  local file="$1"
  [ -f "$file" ] || die "Backup file not found: $file"

  local staging
  staging="$(mktemp -d "${TMPDIR:-/tmp}/vwstage.XXXXXX")"

  log "Extracting backup to staging: $staging"
  local errf="$staging.err"
  case "$file" in
    *.aes256)
      [ -n "$BACKUP_ENCRYPTION_KEY" ] \
        || broken "$staging" "$file" "is encrypted (.aes256), but BACKUP_ENCRYPTION_KEY is empty"
      if ! openssl enc -d -aes256 -salt -pbkdf2 -pass pass:"$BACKUP_ENCRYPTION_KEY" -in "$file" 2>"$errf" \
            | tar xzf - -C "$staging" 2>>"$errf"; then
        broken "$staging" "$file" "could not be decrypted and unpacked ($(first_lines "$errf")): a wrong BACKUP_ENCRYPTION_KEY, or a damaged file"
      fi
      ;;
    *.tar.gz|*.tgz)
      if ! tar xzf "$file" -C "$staging" 2>"$errf"; then
        broken "$staging" "$file" "could not be unpacked ($(first_lines "$errf")): a damaged file"
      fi
      ;;
    *)
      broken "$staging" "$file" "is not a .tar.gz, .tgz or .aes256 backup"
      ;;
  esac
  rm -f "$errf"

  # db.sqlite3 is at the archive root in both layouts apply_backup accepts.
  [ -f "$staging/db.sqlite3" ] || broken "$staging" "$file" "holds no db.sqlite3"

  log "Verifying SQLite integrity of restored database..."
  local res
  res="$(sqlite3 "$staging/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 | grep -v '^\*\*\* in database' | head -n1 | head -c 200 || true)"
  if [ "$res" != "ok" ]; then
    broken "$staging" "$file" "failed the SQLite integrity check ('$res'): a damaged database"
  fi
  log "Database integrity OK."

  printf '%s' "$staging"
}

# ---------------------------------------------------------------------------
# Freshness: never replace the live vault with one that is not newer
# ---------------------------------------------------------------------------

# Print a vault's newest revision: the latest timestamp Vaultwarden writes when
# the vault changes or a client syncs. Diesel stores them as sortable text
# ("YYYY-MM-DD HH:MM:SS.fffffffff"), so max() and string comparison order them.
# Opened read-only: reading the live vault must never change it.
vault_revision() {
  sqlite3 -readonly "$1" "
    SELECT max(t) FROM (
      SELECT max(updated_at)    AS t FROM users   UNION ALL
      SELECT max(updated_at)         FROM ciphers UNION ALL
      SELECT max(deleted_at)         FROM ciphers UNION ALL
      SELECT max(updated_at)         FROM folders UNION ALL
      SELECT max(updated_at)         FROM devices UNION ALL
      SELECT max(revision_date)      FROM sends
    );"
}

# refuse <backup name> <reason> - notify, then stop without touching anything.
refuse() {
  notify medium "Vaultwarden Backup Refused" \
    "$1 was not applied: $2. The live vault was left as it was. If the backup source is stuck, this repeats every run until it is fixed; to apply this backup anyway, run: vaultwarden-sync.sh restore $1 --force"
  die "Refusing $1: $2. Live vault left untouched."
}

# check_fresh <staging dir> <backup name> - refuse unless the staged vault is
# strictly newer than the live one. A frozen backup looks exactly like
# yesterday's, so "equal" is refused too.
check_fresh() {
  local staging="$1" name="$2" new cur
  if [ ! -f "$APPDATA_DIR/db.sqlite3" ]; then
    log "No live vault yet -- freshness check skipped."
    return 0
  fi
  local errf="${TMPDIR:-/tmp}/vwrev.$$"
  new="$(vault_revision "$staging/db.sqlite3" 2>"$errf")" \
    || refuse "$name" "could not read the backup's newest revision ($(head -c 300 "$errf"))"
  cur="$(vault_revision "$APPDATA_DIR/db.sqlite3" 2>"$errf")" \
    || refuse "$name" "could not read the live vault's newest revision ($(head -c 300 "$errf"))"
  rm -f "$errf"
  [ -n "$new" ] || refuse "$name" "the backup's vault has no revision timestamps"
  log "Newest revision  : backup $new, live ${cur:-<none>}"
  if [[ ! "$new" > "$cur" ]]; then
    refuse "$name" "its newest revision $new is not newer than the live vault's $cur"
  fi
  log "Backup is newer than the live vault."
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
  local file="$1" force="${2:-}"
  local staging
  staging="$(stage_and_validate "$file")"
  # shellcheck disable=SC2064
  trap "rm -rf '$staging'; rmdir '$LOCK_DIR' 2>/dev/null || true" EXIT

  if [ "$force" = "--force" ]; then
    warn "--force: freshness check skipped; applying $(basename "$file") whatever its age."
  else
    check_fresh "$staging" "$(basename "$file")"
  fi

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

  local newest prev stalled=0
  newest="$(newest_backup)"
  prev="$(last_restored)"

  log "Newest on remote : $newest"
  log "Last restored    : ${prev:-<none>}"

  check_stalled "$newest" || stalled=1

  if [ "$newest" = "$prev" ] && [ "$force" != "--force" ]; then
    [ "$stalled" -eq 0 ] || die "Already restored the newest backup, and it is stale. Live vault left untouched."
    log "Already restored the newest backup -- nothing to do. (Use --force to redo.)"
    return 0
  fi

  local local_file
  local_file="$(download_backup "$newest")"

  restore_from_file "$local_file" "$force"

  printf '%s' "$newest" > "$STATE_FILE"
  log "Recorded last-restored: $newest"

  # Tidy WORK_DIR: keep only the backup we just restored.
  find "$WORK_DIR" -maxdepth 1 -type f -name "$BACKUP_GLOB" ! -name "$newest" -delete 2>/dev/null || true

  # Applied, but it was already stale: the source is still stuck, so the run
  # still fails, as it does when there is nothing new to apply.
  [ "$stalled" -eq 0 ] || die "Applied $newest, but it is stale: the backup source has stalled."
}

cmd_restore() {
  local file="${1:-}" force="${2:-}"
  [ -n "$file" ] || die "Usage: $0 restore <backup-file> [--force]"
  require openssl; require tar; require sqlite3; require rsync; require docker
  # Allow a bare filename that lives in WORK_DIR.
  [ -f "$file" ] || file="$WORK_DIR/$file"
  restore_from_file "$file" "$force"
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
  if [ -z "$newest" ]; then
    echo "Status          : NO backup found, or Drive unreachable (a sync would notify)"
  elif [ "$newest" != "$prev" ]; then
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
    restore)  acquire_lock; cmd_restore "${1:-}" "${2:-}" ;;
    rollback) acquire_lock; cmd_rollback ;;
    status)   cmd_status ;;
    *)        die "Unknown command '$cmd'. Use: sync [--force] | restore <file> [--force] | rollback | status" ;;
  esac
}

main "$@"
