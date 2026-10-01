#!/usr/bin/env bash
#
# freshness-test.sh - the freshness check, and Drive failing, tested from outside.
#
# Feeds vaultwarden-sync.sh backups older, equal and newer than the vault it
# would replace, and a Drive that cannot be reached, holds no backup or fails a
# download, and observes what a person would: is the live vault changed, was
# the Vaultwarden container stopped, did a notification go out.
#
# Only the edges of the machine are stubbed: docker (the container), rclone
# (Google Drive) and curl (the notification hub). Everything else is real:
# tar, sqlite3, rsync and the script itself.
#
# Run it inside the image, which carries every tool the script needs:
#
#   docker build -t vaultwarden-sync:test .
#   docker run --rm -v "$PWD:/src:ro" --entrypoint bash vaultwarden-sync:test \
#     /src/tests/freshness-test.sh
#
# Not -e: a failing check must be counted and reported, not end the run.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/scripts/vaultwarden-sync.sh"
REAL_DATE="$(command -v date)"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
not() { ! "$@"; }

# --- fixtures ---------------------------------------------------------------

# A vault whose every timestamp is <ts>: the tables Vaultwarden stamps when the
# vault changes or a client syncs. <label> tells two vaults apart afterwards.
make_vault() {
  local db="$1" ts="$2" label="$3"
  rm -f "$db"
  sqlite3 "$db" <<SQL
CREATE TABLE users   (uuid TEXT, updated_at TEXT);
CREATE TABLE ciphers (uuid TEXT, name TEXT, updated_at TEXT, deleted_at TEXT);
CREATE TABLE folders (uuid TEXT, updated_at TEXT);
CREATE TABLE devices (uuid TEXT, updated_at TEXT);
CREATE TABLE sends   (uuid TEXT, revision_date TEXT);
INSERT INTO users   VALUES ('u1', '$ts.000000000');
INSERT INTO ciphers VALUES ('c1', '$label', '$ts.000000000', NULL);
INSERT INTO folders VALUES ('f1', '2024-08-05 21:18:19.350986269');
INSERT INTO devices VALUES ('d1', '$ts.000000000');
SQL
}

# A backup archive in bw2's layout (db.sqlite3 and rsa_key* at the root).
make_backup() {
  local out="$1" ts="$2" label="$3" dir
  dir="$(mktemp -d)"
  make_vault "$dir/db.sqlite3" "$ts" "$label"
  echo "key-$label" > "$dir/rsa_key.pem"
  tar czf "$out" -C "$dir" .
  rm -rf "$dir"
}

label_of() { sqlite3 -readonly "$1" 'SELECT name FROM ciphers LIMIT 1;' 2>/dev/null; }

# A fresh world per test: live appdata, rollback, downloads, a fake Drive and
# stubs that record what they were asked to do.
setup() {
  T="$(mktemp -d /tmp/vwtest.XXXXXX)"
  mkdir -p "$T/live" "$T/rollback" "$T/downloads" "$T/drive" "$T/bin"
  : > "$T/docker.log"; : > "$T/notify.log"

  cat > "$T/bin/docker" <<EOF
#!/bin/sh
echo "\$*" >> "$T/docker.log"
case "\$1" in inspect) echo running ;; esac
exit 0
EOF
  # rclone: lsf lists the fake Drive, copy copies from it; the remote prefix
  # (gdrive:bw_backups/) is stripped. Every call first prints the harmless
  # "Failed to save config" line the real one prints with a single-file config mount. Drive breaks
  # like the real rclone breaks: drive_down (exit 1, the remote not found),
  # drive_nodir (exit 3, the folder not found), copy_fails (exit 1 on copy).
  cat > "$T/bin/rclone" <<EOF
#!/bin/sh
while [ "\$1" = --config ]; do shift 2; done
cmd="\$1"; shift
echo "2026/09/30 23:29:36 ERROR : Failed to save config after 10 tries: device or resource busy" >&2
if [ -f "$T/drive_down" ]; then
  echo "2026/09/30 23:29:31 Failed to create file system for \"nope:\": didn't find section in config file" >&2
  exit 1
fi
case "\$cmd" in
  lsf)
    if [ -f "$T/drive_nodir" ]; then
      echo "2026/09/30 23:29:38 ERROR : : error listing: directory not found" >&2
      echo "2026/09/30 23:29:38 Failed to ls" >&2
      exit 3
    fi
    ls "$T/drive" ;;
  copy)
    if [ -f "$T/copy_fails" ]; then
      echo "2026/09/30 23:29:40 ERROR : Attempt 3/3 failed with 1 errors and: couldn't find file" >&2
      exit 1
    fi
    cp "$T/drive/\${1#*:*/}" "\$2/" ;;
esac
EOF
  # curl: record the headers (reading any --header @file), URL and body of
  # every publish; answer 200.
  cat > "$T/bin/curl" <<EOF
#!/bin/bash
args=()
while [ \$# -gt 0 ]; do
  if [ "\$1" = --header ] && [ "\${2#@}" != "\$2" ]; then args+=(--header "\$(cat "\${2#@}")"); shift 2
  else args+=("\$1"); shift; fi
done
{ echo "ARGS \${args[*]}"; echo "BODY \$(cat)"; } >> "$T/notify.log"
exit 0
EOF
  # date: the clock. "date +%s" (now) answers FAKE_NOW; everything else, such
  # as reading a backup's name as a date, is the real date.
  cat > "$T/bin/date" <<EOF
#!/bin/sh
if [ "\$*" = "+%s" ]; then echo "\$FAKE_NOW"; exit 0; fi
exec $REAL_DATE "\$@"
EOF
  chmod +x "$T/bin/"*

  export PATH="$T/bin:$PATH"
  export CONFIG_FILE="$T/none.conf"
  export APPDATA_DIR="$T/live" ROLLBACK_DIR="$T/rollback" WORK_DIR="$T/downloads"
  export LOCK_DIR="$T/lock" TMPDIR="$T"
  export RCLONE_CONF="$T/rclone.conf"; : > "$RCLONE_CONF"
  export UPDATE_METHOD=none BACKUP_ENCRYPTION_KEY=""
  export NTFY_URL="https://hub.example" NTFY_TOPIC="infra" NTFY_TOKEN="tk_test" NOTIFY_HOST="testhost"
  # hostnas runs in Brisbane, the zone bw2 stamps its backup names in. Now is
  # the daily run on 2026-10-01 unless a test moves it.
  export TZ=Australia/Brisbane
  FAKE_NOW="$(at '2026-10-01 11:30:00')"; export FAKE_NOW
}

# at <local time> - that time in Brisbane as epoch seconds.
at() { TZ=Australia/Brisbane "$REAL_DATE" -d "$1" +%s; }
teardown() { rm -rf "$T"; }

run() { "$SCRIPT" "$@" > "$T/out.log" 2>&1; }

stopped()   { grep -q '^stop' "$T/docker.log"; }
not_stopped() { ! stopped; }
not_notified() { ! notified; }
notified()  { grep -q 'ARGS' "$T/notify.log"; }

# --- tests ------------------------------------------------------------------

echo "restore: a backup older than the live vault is refused"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/downloads/bw_backup_2026-09-13-100000.tar.gz" "2026-09-13 14:25:00" old
run restore "$T/downloads/bw_backup_2026-09-13-100000.tar.gz"; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    notified
check "  to the hub's topic"            grep -q 'https://hub.example/infra' "$T/notify.log"
check "  titled <host>: ... Refused"    grep -q 'Title: testhost: Vaultwarden Backup Refused' "$T/notify.log"
check "  at medium severity (3)"        grep -q 'Priority: 3' "$T/notify.log"
check "  with the publisher token"      grep -q 'Authorization: Bearer tk_test' "$T/notify.log"
check "  naming both revisions"         grep -q '2026-09-13 14:25:00.*2026-09-29 10:22:34' "$T/notify.log"
teardown

echo "restore: a newer backup is applied as before"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
make_backup "$T/downloads/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
run restore "$T/downloads/bw_backup_2026-09-30-100000.tar.gz"; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "live vault is the backup's"      [ "$(label_of "$T/live/db.sqlite3")" = new ]
check "RSA key applied"                 grep -q key-new "$T/live/rsa_key.pem"
check "old vault kept in rollback"      [ "$(label_of "$T/rollback/db.sqlite3")" = live ]
check "Vaultwarden stopped"             stopped
check "Vaultwarden started again"       grep -q '^start' "$T/docker.log"
check "no notification"                 not_notified
teardown

echo "sync: the scheduled run refuses an older newest-on-Drive, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
echo bw_backup_2026-09-29-100000.tar.gz > "$T/downloads/.last_restored"
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-13 14:25:00" frozen
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    grep -q 'Title: testhost: Vaultwarden Backup Refused' "$T/notify.log"
check "  naming the backup"             grep -q 'BODY bw_backup_2026-09-30-100000' "$T/notify.log"
check "not recorded as restored"        grep -q 2026-09-29 "$T/downloads/.last_restored"
teardown

echo "sync: a backup equal to the live vault (a frozen source) is refused"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 10:22:34" same
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "a notification was published"    notified
teardown

echo "sync: a newer newest-on-Drive is applied and recorded"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
run sync; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "live vault is the backup's"      [ "$(label_of "$T/live/db.sqlite3")" = new ]
check "recorded as restored"            grep -q 2026-09-30-100000 "$T/downloads/.last_restored"
check "no notification"                 not_notified
teardown

echo "restore --force: an older backup is applied on purpose"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
make_backup "$T/downloads/bw_backup_2026-09-13-100000.tar.gz" "2026-09-13 14:25:00" old
run restore "$T/downloads/bw_backup_2026-09-13-100000.tar.gz" --force; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "live vault is the backup's"      [ "$(label_of "$T/live/db.sqlite3")" = old ]
check "no notification"                 not_notified
teardown

echo "restore: a live vault that cannot be read refuses, and says so"
setup
echo "not a database" > "$T/live/db.sqlite3"
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/downloads/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
run restore "$T/downloads/bw_backup_2026-09-30-100000.tar.gz"; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    grep -q "could not read the live vault" "$T/notify.log"
teardown

echo "first run: no live vault yet, the backup is applied"
setup
make_backup "$T/downloads/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
run restore "$T/downloads/bw_backup_2026-09-30-100000.tar.gz"; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "live vault is the backup's"      [ "$(label_of "$T/live/db.sqlite3")" = new ]
teardown

echo "sync: Drive cannot be reached, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
touch "$T/drive_down"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    notified
check "  titled <host>: ... Unreachable" grep -q 'Title: testhost: Vaultwarden Backup Unreachable' "$T/notify.log"
check "  at medium severity (3)"        grep -q 'Priority: 3' "$T/notify.log"
check "  with the publisher token"      grep -q 'Authorization: Bearer tk_test' "$T/notify.log"
check "  naming the remote"             grep -q 'BODY .*gdrive:bw_backups' "$T/notify.log"
check "  quoting rclone's error"        grep -q "didn't find section in config file" "$T/notify.log"
check "  not the save-config noise"     not grep -q 'Failed to save config' "$T/notify.log"
teardown

echo "sync: Drive answers but holds no backup, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    notified
check "  titled <host>: ... Missing"    grep -q 'Title: testhost: Vaultwarden Backup Missing' "$T/notify.log"
check "  at medium severity (3)"        grep -q 'Priority: 3' "$T/notify.log"
check "  saying no backup is there"     grep -q 'BODY .*gdrive:bw_backups holds no backup' "$T/notify.log"
teardown

echo "sync: Drive answers but the folder is not there, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
touch "$T/drive_nodir"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "Vaultwarden never stopped"       not_stopped
check "  titled <host>: ... Missing"    grep -q 'Title: testhost: Vaultwarden Backup Missing' "$T/notify.log"
check "  saying the folder is absent"   grep -q 'BODY .*gdrive:bw_backups does not exist' "$T/notify.log"
teardown

echo "sync: a backup that cannot be downloaded, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
touch "$T/copy_fails"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "  titled <host>: ... Unreachable" grep -q 'Title: testhost: Vaultwarden Backup Unreachable' "$T/notify.log"
check "  naming the backup"             grep -q 'BODY .*download bw_backup_2026-09-30-100000' "$T/notify.log"
check "  quoting rclone's error"        grep -q "couldn't find file" "$T/notify.log"
check "not recorded as restored"        [ ! -f "$T/downloads/.last_restored" ]
teardown

echo "sync: nothing new on Drive is still quiet"
setup
make_vault "$T/live/db.sqlite3" "2026-09-29 10:22:34" live
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-29 23:07:19" new
echo bw_backup_2026-09-30-100000.tar.gz > "$T/downloads/.last_restored"
run sync; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "Vaultwarden never stopped"       not_stopped
check "no notification"                 not_notified
teardown

echo "sync: a stalled source (newest backup 3 days old, already restored) says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-28 10:22:34" live
before="$(sha256sum < "$T/live/db.sqlite3")"
make_backup "$T/drive/bw_backup_2026-09-28-100000.tar.gz" "2026-09-28 10:22:34" stuck
echo bw_backup_2026-09-28-100000.tar.gz > "$T/downloads/.last_restored"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault unchanged"            [ "$(sha256sum < "$T/live/db.sqlite3")" = "$before" ]
check "Vaultwarden never stopped"       not_stopped
check "a notification was published"    notified
check "  titled <host>: ... Stalled"    grep -q 'Title: testhost: Vaultwarden Backup Stalled' "$T/notify.log"
check "  at medium severity (3)"        grep -q 'Priority: 3' "$T/notify.log"
check "  with the publisher token"      grep -q 'Authorization: Bearer tk_test' "$T/notify.log"
check "  naming the backup and its age" grep -q 'BODY .*bw_backup_2026-09-28-100000.* 73 hours old' "$T/notify.log"
teardown

echo "sync: a stalled source whose newest backup is not yet restored: applied, and says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-26 10:22:34" live
echo bw_backup_2026-09-27-100000.tar.gz > "$T/downloads/.last_restored"
make_backup "$T/drive/bw_backup_2026-09-28-100000.tar.gz" "2026-09-28 10:22:34" late
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "live vault is the backup's"      [ "$(label_of "$T/live/db.sqlite3")" = late ]
check "recorded as restored"            grep -q 2026-09-28-100000 "$T/downloads/.last_restored"
check "  titled <host>: ... Stalled"    grep -q 'Title: testhost: Vaultwarden Backup Stalled' "$T/notify.log"
check "  and nothing else"              [ "$(grep -c '^ARGS' "$T/notify.log")" -eq 1 ]
teardown

echo "sync: a newest backup just inside the limit (35 hours) is quiet"
setup
make_vault "$T/live/db.sqlite3" "2026-09-30 10:22:34" live
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-30 10:22:34" new
echo bw_backup_2026-09-30-100000.tar.gz > "$T/downloads/.last_restored"
FAKE_NOW="$(at '2026-10-01 21:00:00')"
run sync; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "no notification"                 not_notified
teardown

echo "sync: a newest backup just past the limit (37 hours) says so"
setup
make_vault "$T/live/db.sqlite3" "2026-09-30 10:22:34" live
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-30 10:22:34" new
echo bw_backup_2026-09-30-100000.tar.gz > "$T/downloads/.last_restored"
FAKE_NOW="$(at '2026-10-01 23:00:00')"
run sync; rc=$?
check "exits non-zero"                  [ "$rc" -ne 0 ]
check "  titled <host>: ... Stalled"    grep -q 'Title: testhost: Vaultwarden Backup Stalled' "$T/notify.log"
teardown

echo "sync: MAX_BACKUP_AGE_HOURS moves the limit"
setup
make_vault "$T/live/db.sqlite3" "2026-09-30 10:22:34" live
make_backup "$T/drive/bw_backup_2026-09-30-100000.tar.gz" "2026-09-30 10:22:34" new
echo bw_backup_2026-09-30-100000.tar.gz > "$T/downloads/.last_restored"
MAX_BACKUP_AGE_HOURS=24 run sync; rc=$?
check "exits non-zero at 25 hours"      [ "$rc" -ne 0 ]
check "  titled <host>: ... Stalled"    grep -q 'Title: testhost: Vaultwarden Backup Stalled' "$T/notify.log"
teardown

echo "sync: a name with no date in it is not called stalled"
setup
make_vault "$T/live/db.sqlite3" "2026-09-30 10:22:34" live
make_backup "$T/drive/bw_backup_latest.tar.gz" "2026-09-30 10:22:34" new
echo bw_backup_latest.tar.gz > "$T/downloads/.last_restored"
run sync; rc=$?
check "exits zero"                      [ "$rc" -eq 0 ]
check "no notification"                 not_notified
check "  but says the age went unchecked" grep -q 'age was not checked' "$T/out.log"
teardown

echo
echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
