# Vaultwarden one-way restore for Unraid

Keep a **warm standby** copy of your Google-Cloud Vaultwarden on Unraid, kept in
sync from the nightly Google Drive backups produced by
[dadatuputi/bitwarden_gcloud](https://github.com/dadatuputi/bitwarden_gcloud)
(backup container: [dadatuputi/bwgc_backup](https://github.com/dadatuputi/bwgc_backup)).

On a schedule it will:

1. Find the newest `bw_backup_*` on Google Drive (via `rclone`). If it's the same
   one restored last time → it stops, nothing changes.
2. Download it, **decrypt + extract + verify the SQLite DB** in a staging area
   *before* touching anything live.
3. **Stop** the local Vaultwarden container.
4. **Clear the rollback folder and copy the current appdata into it** (so you can
   undo).
5. **Apply** the verified backup over appdata.
6. **Update** the Vaultwarden image to the latest.
7. **Start** the container, and record what was restored.

It is strictly one-way (Drive → Unraid). It never writes to Drive
(the rclone remote is set up read-only).

> ⚠️ **This is a copy, not HA.** Both copies are independent Vaultwardens. Use the
> GCloud one as primary; the Unraid one is a break-glass standby that lags by up
> to one backup cycle.

---

## How the GCloud backup works (why this design)

The `bwgc_backup` container tars the Vaultwarden data and uploads it with
`rclone sync` to a folder on your Drive. Each file is named:

```
bw_backup_<YYYY-MM-DD-HHMMSS>.tar.gz            # if BACKUP_ENCRYPTION_KEY is unset
bw_backup_<YYYY-MM-DD-HHMMSS>.tar.gz.aes256     # if BACKUP_ENCRYPTION_KEY is set  ← your case
```

Encryption is `openssl enc -aes256 -salt -pbkdf2 -pass pass:<key>`. Inside the
tar: `db.sqlite3` (at the archive root), plus `data/attachments/`,
`data/sends/`, `data/config.json`, `data/rsa_key*`, and optionally `.env`.

This tool decrypts/extracts with the same `openssl`/`tar` settings and restores
exactly those files. The GCloud `.env` is **ignored** - on Unraid your container
settings come from its template, not a `.env`.

> 🔑 **Encryption-key warning.** You said the backup key lives *inside* Vaultwarden.
> That's a chicken-and-egg trap: if the vault is down you can't read the key to
> restore it. **Keep an offline copy** of `BACKUP_ENCRYPTION_KEY` somewhere
> independent (password-protected note, paper, another manager). This tool needs
> it to decrypt.

---

## What's in this repo

| File | Purpose |
|------|---------|
| `scripts/vaultwarden-sync.sh` | The actual sync / restore / rollback / status logic |
| `entrypoint.sh` | Container entrypoint: cron loop *or* one-shot |
| `Dockerfile` | Helper image (rclone + openssl + sqlite + rsync + docker-cli) |
| `docker-compose.yml` | **Mode A** - persistent, self-scheduling helper (compose) |
| `unraid-user-script.sh` | **Mode B** - ephemeral run driven by the User Scripts plugin |
| `unraid/my-vaultwarden-sync.xml` | **Mode C** - Unraid GUI template for the helper |
| `unraid/my-vaultwarden.xml` | Optional GUI template for the standby Vaultwarden itself |
| `.env.example` | Config template (copy to `.env`) |
| `config/rclone.conf.example` | What the rclone remote should look like |
| Prebuilt image | `ghcr.io/jceccato/vaultwarden-sync` - Docker image built by [GitHub Actions](https://github.com/jceccato/vaultwarden-sync/actions/workflows/publish.yml) |

You pick **one** of Mode A / B / C - all three share the same image and script.
**Mode C is the one to use if you want to manage the helper from the Unraid GUI.**

> Docker images are published automatically on every push to `master` (tagged
> `latest`) and on every `v*` tag (semver-tagged). You can pull the prebuilt
> image instead of building locally. See [Step 2](#step-2--get-the-image).

---

## Prerequisites

- The GCloud stack is backing up to Drive (`BACKUP=rclone`) and you know its
  `BACKUP_RCLONE_DEST` (the Drive folder name) and `BACKUP_ENCRYPTION_KEY`.
- Docker (built into Unraid). Everything else (rclone, openssl, sqlite, rsync)
  ships inside the helper image - nothing to install on the host.
- A **standby Vaultwarden container** on Unraid with data at
  `/mnt/user/appdata/vaultwarden`. If you don't have one, do **Step 0**.

---

## Step 0 - Install the standby Vaultwarden *(do this if you don't have one)*

**Option A - Community Applications (easiest):**

1. **Apps** tab → search **`vaultwarden`** → pick the one with repository
   `vaultwarden/server` → **Install**.
2. Set these before applying:
   - **Host Path (/data)** → `/mnt/user/appdata/vaultwarden`  ← remember this exact path
   - **WebUI Port** → e.g. `8484` (any free host port)
   - **`SIGNUPS_ALLOWED`** → `false` (accounts come from the restore)
   - Note the **container name** (default `vaultwarden`)
3. **Apply**, wait for it to start, open `http://<TOWER-IP>:8484` and confirm you
   get the Vaultwarden login page. Don't create an account - the first sync will
   replace `/data` with your production vault.

**Option B - XML template (paths pre-filled for the sync helper):**

1. Download the template from GitHub:

   ```bash
   mkdir -p /boot/config/plugins/dockerMan/templates-user
   curl -fsSL -o /boot/config/plugins/dockerMan/templates-user/my-vaultwarden.xml \
     https://raw.githubusercontent.com/jceccato/vaultwarden-sync/master/unraid/my-vaultwarden.xml
   ```

2. **Docker tab → Add Container →** open the **Template** dropdown, pick
   **`vaultwarden`** (under *User templates*). The data path is already
   `/mnt/user/appdata/vaultwarden` and `SIGNUPS_ALLOWED` is `false`. Set your
   WebUI port then **Apply**.

> The data path you choose here **must** equal `APPDATA_DIR` in the sync helper.
> Keep it at `/mnt/user/appdata/vaultwarden` and everything lines up.

---

## Step 1 - Create the working directories

The sync helper needs these folders on Unraid (create them once):

```bash
mkdir -p /mnt/user/appdata/vaultwarden-sync/downloads
mkdir -p /mnt/user/appdata/vaultwarden-rollback
```

> **Do you need the source code on Unraid?** Not for deployment. The Docker image
> is pulled from `ghcr.io` -- no local build required. You only need the source
> if you plan to build the image yourself or edit the scripts:
> ```bash
> git clone https://github.com/jceccato/vaultwarden-sync.git /mnt/user/appdata/vaultwarden-sync/src
> ```
> Each mode below tells you exactly which files to download (XML templates, user
> script, or compose file) -- you don't need the full repo unless you're developing.

## Step 2 - Get the image

The image is published to GitHub Container Registry. Pull it directly:

```bash
docker pull ghcr.io/jceccato/vaultwarden-sync:latest
```

**Or build it yourself** (for development or if you prefer):

```bash
docker build -t vaultwarden-sync /mnt/user/appdata/vaultwarden-sync/src
```

> Modes B and C below reference the prebuilt `ghcr.io/...` image. If you built
> locally, replace it with `vaultwarden-sync:latest` (or `vaultwarden-sync:local`
> for Mode C).

## Step 3 - Create the rclone remote (read-only)

You need an `rclone.conf` on Unraid with a remote pointing at the **same Drive**
your backups go to. Easiest is to authorise on your desktop and copy the result
over, because the OAuth step needs a browser.

On a desktop with rclone installed:

```bash
rclone config
# n) New remote
# name> gdrive                 (must match RCLONE_REMOTE)
# Storage> drive
# scope> 2  (drive.readonly)   ← least privilege; this tool only reads
# leave client_id/secret blank for default, finish the browser auth
```

Then copy the generated config to Unraid as
`/mnt/user/appdata/vaultwarden-sync/rclone.conf`.

Verify it can see your backups:

```bash
docker run --rm -v /mnt/user/appdata/vaultwarden-sync/rclone.conf:/c.conf:ro \
  rclone/rclone --config /c.conf lsf gdrive:bw_backups
# → should list bw_backup_2026-06-30-031500.tar.gz.aes256, etc.
```

(Replace `bw_backups` with your `BACKUP_RCLONE_DEST`.)

---

## Step 4a - Mode A: persistent self-scheduling helper *(recommended)*

```bash
# Clone the repo (for docker-compose.yml + .env.example)
git clone https://github.com/jceccato/vaultwarden-sync.git /mnt/user/appdata/vaultwarden-sync/src
cd /mnt/user/appdata/vaultwarden-sync/src
cp .env.example .env
nano .env            # set paths, container name, RCLONE_PATH, BACKUP_ENCRYPTION_KEY...
docker compose up -d
```

> The `docker-compose.yml` still has `build: .` for development. If you want to
> use the prebuilt image instead, comment out `build: .` and set `image:
> ghcr.io/jceccato/vaultwarden-sync:latest` in the compose file, or just keep
> `build: .` -- both work.

The helper now wakes on `SCHEDULE` (default `0 3 * * *`) and syncs. Watch it:

```bash
docker logs -f vaultwarden-sync
```

Run an immediate sync any time:

```bash
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh sync
```

## Step 4b - Mode B: Unraid User Scripts *(alternative)*

If you'd rather schedule with the **User Scripts** plugin and not keep a helper
container running:

1. Pull the image (Step 2), or Docker will auto-pull it on first run.
2. **Download the user script** from GitHub:

   ```bash
   curl -fsSL -o /tmp/vaultwarden-sync-user-script.sh \
     https://raw.githubusercontent.com/jceccato/vaultwarden-sync/master/unraid-user-script.sh
   ```

3. Plugins → User Scripts → **Add New Script**, paste the contents of that file,
   edit the paths/values at the top.
3. Set its schedule (Custom cron, e.g. `0 3 * * *`).

Each run spins up a throwaway container, does one sync, and exits.

## Step 4c - Mode C: Unraid GUI (XML template) *(manage it from the webUI)*

Native Unraid management (Edit / Start / Stop / Logs from the Docker tab), no
compose plugin needed. The image pulls from GitHub Container Registry automatically.

1. **Install the template** -- download it from GitHub:

   ```bash
   mkdir -p /boot/config/plugins/dockerMan/templates-user
   curl -fsSL -o /boot/config/plugins/dockerMan/templates-user/my-vaultwarden-sync.xml \
     https://raw.githubusercontent.com/jceccato/vaultwarden-sync/master/unraid/my-vaultwarden-sync.xml
   ```
2. **Docker tab → Add Container →** open the **Template** dropdown at the top and
   pick **`vaultwarden-sync`** (under *User templates*). The fields populate from
   the XML.
3. Fill in `BACKUP_ENCRYPTION_KEY`, check the paths/`CONTAINER_NAME`/`RCLONE_PATH`,
   then **Apply**. Unraid pulls the image from `ghcr.io` automatically.

> For a **locally-built image**, change the Repository in the template to
> `vaultwarden-sync:local`, build it with `docker build -t vaultwarden-sync:local ...`,
> and Apply. Unraid will report a harmless pull failure and use your local image.

To update the image later (after a new version is published): stop the container
in the Docker tab, then Edit → Apply. Unraid pulls the latest image from
`ghcr.io` on Apply.

---

## Verifying it works (do this once, on purpose)

```bash
# What would happen? (read-only)
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh status

# Force a full restore from the newest backup, even if already restored:
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh sync --force
```

`--force` also skips the freshness check, so this re-applies a backup the
standby already holds.

The freshness check has its own tests, run inside the image:

```bash
docker build -t vaultwarden-sync:test .
docker run --rm -v "$PWD:/src:ro" --entrypoint bash vaultwarden-sync:test /src/tests/freshness-test.sh
```

Then open the local Vaultwarden web UI and log in with your real credentials to
confirm the vault decrypts. **If login works on the standby, your DR copy is
real.** (If it doesn't, the encryption key or rsa_keys didn't come across -
check the log.)

---

## Recovering / undoing

**Roll back** the standby to the snapshot taken just before the last restore:

```bash
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh rollback
```

**Restore a specific** backup file you've downloaded into the downloads folder:

```bash
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh restore bw_backup_2026-06-30-031500.tar.gz.aes256
```

A backup that is not newer than the live vault is refused (see Safety notes).
To apply one anyway, on purpose, add `--force`:

```bash
docker exec vaultwarden-sync /usr/local/bin/vaultwarden-sync.sh restore bw_backup_2026-06-30-031500.tar.gz.aes256 --force
```

---

## Configuration reference

Set via `.env` (Mode A) or the top of the User Script (Mode B).

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONTAINER_NAME` | `vaultwarden` | Name of your local Vaultwarden container |
| `APPDATA_DIR` | `/data/live` (in container) | Host: your Vaultwarden `/data` |
| `ROLLBACK_DIR` | `/data/rollback` | Host: rollback snapshot (outside appdata) |
| `DOWNLOAD_DIR` | `/data/downloads` | Host: downloads + `.last_restored` state |
| `RCLONE_CONF` | `/config/rclone.conf` | rclone config with your Drive remote |
| `RCLONE_REMOTE` | `gdrive` | Remote name inside `rclone.conf` |
| `RCLONE_PATH` | `bw_backups` | Drive folder = `BACKUP_RCLONE_DEST` |
| `RCLONE_EXTRA_FLAGS` | *(empty)* | e.g. `--drive-shared-with-me` |
| `BACKUP_ENCRYPTION_KEY` | *(empty)* | openssl passphrase = GCloud `BACKUP_ENCRYPTION_KEY` |
| `UPDATE_METHOD` | `watchtower` | `watchtower` \| `pull` \| `none` |
| `VAULTWARDEN_IMAGE` | `vaultwarden/server:latest` | Image for `pull` method |
| `SCHEDULE` | `0 3 * * *` | Cron for Mode A (run after the GCloud backup) |
| `RUN_ON_START` | `false` | Mode A: also sync on container start |
| `TZ` | `UTC` | Timezone for the schedule/logs |
| `NTFY_URL` | *(empty)* | ntfy server to notify when a backup is refused, missing or unreachable; empty = log only |
| `NTFY_TOPIC` | `infra` | ntfy topic |
| `NTFY_TOKEN` | *(empty)* | ntfy publisher token (secret) |
| `NOTIFY_HOST` | `vaultwarden-sync` | Named first in the notification title |

### About `UPDATE_METHOD`

- **`watchtower`** *(recommended)* - runs `containrrr/watchtower --run-once` against
  just your container: pulls the latest image and, if newer, recreates the
  container **preserving its Unraid template settings**, then starts it. A plain
  `docker pull` can't recreate it, so the container would otherwise keep running
  the old image.
- **`pull`** - only pulls the image (you recreate later in the Unraid UI).
- **`none`** - leave updates to your existing watchtower / CA Auto Update.

---

## Safety notes

- **Live data is only touched after** the backup downloads, decrypts, extracts,
  and passes a `PRAGMA integrity_check`. A bad/partial download aborts before the
  container is stopped - your standby stays up on its previous data.
- **A backup must be newer than the vault it replaces.** Before stopping
  anything, the newest timestamp in the backup's vault (users, ciphers, folders,
  devices, sends) is compared with the live vault's. If the backup is not
  strictly newer, it is refused: nothing is stopped or changed, a notification
  is sent to `NTFY_URL` if set, and the run exits non-zero. It is not recorded
  as restored, so every run repeats the refusal until the source is fixed. This
  catches a backup job that keeps uploading the same frozen database. `--force`
  skips the check. Device timestamps move whenever a client syncs, so a day
  with no vault edits still gives a newer backup as long as some client was
  used; a day with none is refused, and says so.
  Logging in to the standby itself moves *its* device timestamps, so the next
  backup can be refused until some client uses the primary again.
- **A missing backup is loud too.** If Drive cannot be listed or a download
  fails, the run publishes *Vaultwarden Backup Unreachable*; if Drive answers
  but the folder is absent or holds no `bw_backup_*`, *Vaultwarden Backup
  Missing*. Either way nothing is stopped or changed and the run exits
  non-zero, every run, until it is fixed. Without this the standby would go
  stale in silence.
- The DB's `-wal`/`-shm` sidecars are removed during restore so a stale WAL can't
  corrupt the freshly restored database.
- `ROLLBACK_DIR` and `DOWNLOAD_DIR` **must be outside** `APPDATA_DIR`.
- The helper mounts `/var/run/docker.sock` (to stop/start/update Vaultwarden) and
  reads your encryption key - treat this container as sensitive.
- This tool only **reads** from Drive. Even so, prefer a `drive.readonly` rclone
  scope so it physically cannot modify your GCloud backups.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `Backup is encrypted (.aes256) but BACKUP_ENCRYPTION_KEY is empty` | Set the key in `.env` / script |
| `Failed to decrypt/extract` | Wrong `BACKUP_ENCRYPTION_KEY` |
| `Could not list backups at gdrive:...` / `Could not download ...` | Wrong `RCLONE_REMOTE`, an expired or revoked Drive token, or no network - test with `rclone lsf` |
| `No backup to restore: ...` | Wrong `RCLONE_PATH`, or the backup source has stopped uploading |
| `SQLite integrity_check failed` | The downloaded backup is corrupt; it refuses to apply it |
| `Refusing bw_backup_...: its newest revision ... is not newer than the live vault's ...` | The backup source is not producing fresh backups, or no client used the vault since the last one. Check the source; `restore <file> --force` applies it anyway |
| Standby won't decrypt the vault after restore | `rsa_key*` missing from backup, or you logged in against the wrong server |
| Update step warns but continues | watchtower couldn't reach a registry; container still starts on current image |

## License

MIT - see [LICENSE](LICENSE) for the full text.
