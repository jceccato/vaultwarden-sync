# Project: vaultwarden-sync

One-way restore of a Google-Cloud Vaultwarden backup into a **standby Vaultwarden
container on Unraid**. Runs on a schedule: pull the newest backup from Google
Drive, verify it, snapshot the current appdata, restore, update the image, restart.

This directory (`C:\temp\vaultwardenSync` on the author's Windows box) is the
source that gets deployed to Unraid at `/mnt/user/appdata/vaultwarden-sync/src`.
It is **not currently a git repo**.

## Context / who this is for

- User self-hosts Vaultwarden on Google Cloud via
  [dadatuputi/bitwarden_gcloud](https://github.com/dadatuputi/bitwarden_gcloud),
  with nightly encrypted backups pushed to Google Drive.
- They keep a **warm standby** copy on Unraid, restored from those backups "just
  in case". This project automates keeping that standby in sync.
- Strictly one-way (Drive → Unraid). The rclone remote should be read-only.
- **Not HA** - the standby lags by up to one backup cycle; GCloud is primary.

## How the upstream GCloud backup works (drives the whole restore design)

Backups are made by `ghcr.io/dadatuputi/bwgc_backup` (script: `scripts/backup.sh`
in [dadatuputi/bwgc_backup](https://github.com/dadatuputi/bwgc_backup)), pushed to
Drive via `rclone sync`. Verified against the actual source, not just docs:

- **Filenames:** `bw_backup_<YYYY-MM-DD-HHMMSS>.tar.gz`, or
  `...tar.gz.aes256` when `BACKUP_ENCRYPTION_KEY` is set (**this user's case**).
  The zero-padded timestamp means the newest backup is the
  **lexicographically-greatest** filename (`... | sort | tail -1`).
- **Encryption:** `openssl enc -e -aes256 -salt -pbkdf2 -pass pass:<key>`.
  Decrypt with the matching `-d` flags.
- **Tar contents:** `db.sqlite3` at the archive **ROOT** (added via `-C /tmp`),
  plus under `data/`: `attachments/`, `sends/`, `config.json`, `rsa_key*`, and
  optionally `.env`. The restore logic mirrors upstream `restore_backup()`.
- The GCloud `.env` is **deliberately ignored** on restore - a single Unraid
  container gets its env from its template, not a `.env` file.

## Repo layout

| File | Purpose |
|------|---------|
| `scripts/vaultwarden-sync.sh` | Core logic. Subcommands: `sync` (default), `sync --force`, `restore <file>`, `rollback`, `status` |
| `entrypoint.sh` | Container entrypoint: no args → busybox `crond` loop; a subcommand → run once and exit |
| `Dockerfile` | alpine:3.20 + bash, rclone, openssl, sqlite, rsync, tar, docker-cli, tini |
| `docker-compose.yml` | **Mode A** - persistent self-scheduling helper (compose) |
| `unraid-user-script.sh` | **Mode B** - ephemeral `docker run ... sync` via User Scripts plugin |
| `unraid/my-vaultwarden-sync.xml` | **Mode C** - Unraid GUI template for the helper |
| `unraid/my-vaultwarden.xml` | Optional GUI template for the standby Vaultwarden |
| `.env.example` | Config template for Mode A |
| `config/rclone.conf.example` | Shape of the rclone remote (real one is git-ignored) |
| `README.md` | Full setup guide (Steps 0–4, three modes, verify/rollback) |

## sync flow (`scripts/vaultwarden-sync.sh` → `cmd_sync`)

1. `latest_remote` = newest `bw_backup_*` on `RCLONE_REMOTE:RCLONE_PATH`.
   If it equals `.last_restored` and no `--force` → exit, nothing to do.
2. Download it to `WORK_DIR`.
3. **`stage_and_validate`** (nothing live touched yet): decrypt (if `.aes256`) +
   extract to a temp dir, require `db.sqlite3`, run `PRAGMA integrity_check`.
   Any failure aborts here - the standby keeps running on old data.
4. `stop_container` (docker stop).
5. `rotate_rollback`: `rsync -a --delete APPDATA → ROLLBACK` (clear + copy).
   Skipped on first run when appdata has no `db.sqlite3`.
6. `apply_backup`: remove old `db.sqlite3` + `-wal`/`-shm`, copy new db, then
   replace attachments/sends/config.json/rsa_key* from `data/`.
7. `update_container` (see UPDATE_METHOD).
8. `start_container`, then write `.last_restored`, prune old downloads.

## Deployment modes (pick ONE; all share the same image + script)

- **A - compose:** `docker compose up -d --build`; container self-schedules via
  built-in cron (`SCHEDULE`).
- **B - User Scripts:** build image once, User Scripts entry runs an ephemeral
  `docker run ... vaultwarden-sync:local sync` on a cron schedule.
- **C - Unraid GUI (chosen by user):** build image, drop XML in
  `/boot/config/plugins/dockerMan/templates-user/`, Add Container from the
  template. Fully GUI-managed (Edit/Start/Stop/Logs).

## Critical gotchas / design decisions (don't regress these)

- **Encryption-key chicken-and-egg:** the user stores `BACKUP_ENCRYPTION_KEY`
  *inside the vault*. Restore needs it, so an offline copy is mandatory. The key
  is a masked/secret field - never commit it; `.env` + `rclone.conf` are
  git-ignored.
- **Image published at `ghcr.io/jceccato/vaultwarden-sync`:** the Docker image is
  built and pushed by the `publish.yml` workflow on push to `master` (`:latest`)
  and on `v*` tags (semver tags). The Unraid XML template uses the registry image
  by default. For local development, build with a `:local` tag to avoid Unraid
  overwriting your build:
  `docker build -t vaultwarden-sync:local .`
- **WAL removal on restore:** must delete `db.sqlite3-wal` / `-shm` before
  dropping in the new db, or a stale WAL corrupts the restored DB (vaultwarden
  uses WAL mode).
- **Validate before touching live data:** download+decrypt+integrity_check happen
  in a staging dir *before* the container is stopped.
- **Data-path alignment:** the helper's `APPDATA_DIR` (`/data/live`) must map to
  the exact same host path as Vaultwarden's `/data`
  (`/mnt/user/appdata/vaultwarden`).
- **`UPDATE_METHOD=watchtower`** runs `containrrr/watchtower --run-once
  --include-stopped --revive-stopped <name>` so it updates the container while
  it's stopped and preserves the Unraid template settings (a plain `docker pull`
  can't recreate it). Alternatives: `pull` (image only), `none`.
- Shell scripts must stay **LF** line endings (they run in a Linux container).
- Unraid templates must be **well-formed XML**; `BACKUP_ENCRYPTION_KEY` uses
  `Mask="true"`, `UPDATE_METHOD` uses a `Default="watchtower|pull|none"` dropdown.

## Config reference (env / template vars)

`CONTAINER_NAME` (vaultwarden), `APPDATA_DIR` (/data/live), `ROLLBACK_DIR`
(/data/rollback), `WORK_DIR` (/data/downloads), `RCLONE_CONF`
(/config/rclone.conf), `RCLONE_REMOTE` (gdrive), `RCLONE_PATH` (bw_backups =
`BACKUP_RCLONE_DEST`), `RCLONE_EXTRA_FLAGS`, `BACKUP_ENCRYPTION_KEY` (secret),
`UPDATE_METHOD` (watchtower|pull|none), `VAULTWARDEN_IMAGE`, `SCHEDULE`
(`0 3 * * *`), `RUN_ON_START` (false), `TZ`.

## Current setup status (as of last session)

Deploying via **Mode C**, guided by SSH commands. Runbook order:
0. Install standby Vaultwarden (Apps tab, `/data`=`/mnt/user/appdata/vaultwarden`,
   port 8484, `SIGNUPS_ALLOWED=false`) - user reported the old container was gone.
1. `scp -r` this dir to `/mnt/user/appdata/vaultwarden-sync/src`; make
   `downloads/` and `vaultwarden-rollback/` dirs.
2. `docker build -t vaultwarden-sync:local .../src`.
3. rclone remote: reuse the working `rclone.conf` from the GCloud VM (fast) or set
   up a fresh `drive.readonly` remote. **Next checkpoint** was verifying
   `rclone lsf REMOTE:BACKUP_RCLONE_DEST` lists the `bw_backup_*` files.
4. (pending) install template, Add Container with the encryption key, then
   `sync --force` and log into the standby to prove the vault decrypts.

## Verify / recover

- `... vaultwarden-sync.sh status` - read-only: newest remote vs last restored.
- `... vaultwarden-sync.sh sync --force` - restore newest even if already done.
- `... vaultwarden-sync.sh rollback` - restore appdata from the rollback snapshot.
- Proof of a good DR copy: log into the standby web UI with real credentials and
  confirm the vault decrypts (validates `rsa_key*` + db came across).
