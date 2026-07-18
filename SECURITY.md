# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in vaultwarden-sync, **please do not
open a public issue.** Instead, report it privately so we can address it before
it becomes publicly known.

**Preferred method:** Open a [private security advisory][advisory] on GitHub.

If you are unable to use GitHub Security Advisories, you may open a regular
GitHub Issue and mention the maintainer (`[jceccato]`). Mark
the issue clearly as a security concern.

**Do not** post security vulnerabilities in public Discussions, social media, or
any other public forum before a fix is released.

## Supported Versions

Only the **latest release** (or the `master` branch head) receives security
patches. This project does not maintain backport branches for older versions.

If a security fix is published, upgrade to the latest version immediately.

## Disclosure Timeline

When you report a vulnerability, you can expect:

- **Acknowledgment:** Within 5 business days.
- **Fix:** A patch within 30 days for critical issues, 90 days for lower-severity
  issues. Complex fixes may take longer and will be communicated.
- **Coordinated disclosure:** We will agree on a disclosure date. The advisory
  will be published alongside the fix release.

## Scope

### In scope

- The vaultwarden-sync shell scripts (`scripts/vaultwarden-sync.sh`, `entrypoint.sh`)
- The Docker image (Dockerfile, base image, bundled tools)
- The container's handling of secrets (encryption keys, rclone tokens, Docker socket)
- Restore logic that could corrupt or expose Vaultwarden data
- The `docker-compose.yml` and Unraid XML template configurations

### Out of scope

- TLS/SSL configuration on the user's reverse proxy
- Physical access to the Unraid server
- Social engineering attacks
- Vulnerabilities in upstream dependencies (rclone, openssl, sqlite3, Docker
  itself) - please report those to their respective projects
- Misconfiguration by the user (weak encryption key, world-readable config files,
  exposed Docker socket)

## Security Model

This project is a helper tool that runs as a Docker container on Unraid. Key
security considerations:

- **Docker socket access:** The container mounts `/var/run/docker.sock` so it can
  stop, start, and update the Vaultwarden container. Escaping this container
  gives an attacker full Docker host access. Treat this container as **privileged**
  and never expose it to untrusted networks.

- **Encryption key:** The backup decryption key (`BACKUP_ENCRYPTION_KEY`) is
  passed as an environment variable and used with `openssl enc`. Never commit
  `.env` files containing this key. The `.gitignore` already excludes `.env` and
  `rclone.conf`, but double-check before pushing.

- **Read-only rclone remote:** The tool only reads from Google Drive. The rclone
  remote should be configured with `scope = drive.readonly`. This is a defense-in-depth
  measure - even if the tool were compromised, it could not modify your backups.

- **Staging before live data:** Backups are downloaded, decrypted, extracted,
  and validated in a temporary staging directory before the live Vaultwarden
  container is touched. A bad or malicious backup file can corrupt the staging
  area but will never reach your live data.

- **No network exposure:** This container exposes no ports and accepts no inbound
  connections. It only makes outbound requests to Google Drive (via rclone) and
  interacts with the local Docker daemon via the mounted socket.

[advisory]: https://github.com/jceccato/vaultwarden-sync/security/advisories/new
