# Contributing to vaultwarden-sync

Thank you for considering contributing! This guide will help you get set up and
explain the contribution process.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
By participating, you are expected to uphold this code.

## What to work on

- Check the [open issues](https://github.com/jceccato/vaultwarden-sync/issues)
  for bugs and feature requests.
- Look for issues tagged `good first issue` if you're new.
- The README has a [Roadmap](#) section (if present) listing planned features.

## Development setup

### Prerequisites

- Docker (the project builds and runs entirely inside a container)
- A Unraid server, or a Linux VM, for integration testing
- [shellcheck](https://www.shellcheck.net/) (optional, for linting shell scripts)

### Clone and build

```bash
git clone https://github.com/jceccato/vaultwarden-sync.git
cd vaultwarden-sync

# Build the Docker image
docker build -t vaultwarden-sync .
```

This builds an Alpine-based image containing bash, rclone, openssl, sqlite3,
rsync, tar, and docker-cli.

### Linting

The project uses [shellcheck](https://www.shellcheck.net/) for shell script
quality. Install it, then run:

```bash
# Lint all shell scripts
shellcheck scripts/vaultwarden-sync.sh entrypoint.sh
```

Existing `shellcheck` directives (e.g., `# shellcheck disable=SC2064`) are
intentional - read the comment before removing them.

### Testing

The freshness check (a backup must be newer than the live vault) has an
automated test, run inside the image so every tool is the real one:

```bash
docker build -t vaultwarden-sync:test .
docker run --rm -v "$PWD:/src:ro" --entrypoint bash vaultwarden-sync:test /src/tests/freshness-test.sh
```

Everything else is tested by hand:

1. **Build the image:** `docker build -t vaultwarden-sync .`
2. **Run the status command** (read-only, safe anywhere):
   ```bash
   docker run --rm \
     -v /path/to/rclone.conf:/config/rclone.conf:ro \
     vaultwarden-sync status
   ```
3. **Full integration test on Unraid:** Follow the [Step 0 through Verification]
   in the README. The gold-standard test is logging into the standby Vaultwarden
   web UI with real credentials after a `sync --force`.

Before submitting a PR, at minimum verify:
- The Docker image builds without errors
- `shellcheck` passes with no new warnings
- The script runs without syntax errors: `bash -n scripts/vaultwarden-sync.sh`

## Code style

- **Shell scripts are bash**, not POSIX sh. Use `#!/usr/bin/env bash`.
- **`set -euo pipefail`** is required at the top of every script.
- **Functions use `snake_case`** (e.g., `stop_container`, `latest_remote`).
- **Variables use `UPPER_CASE`** for config/env and `lower_case` for locals.
- **Always quote variable expansions** unless you have an explicit reason not to.
- **Comments explain *why*, not *what*** - the code should be readable on its own.
- **Log levels:** `log()` for normal info, `warn()` for recoverable issues,
  `err()` / `die()` for fatal errors. Messages go to stderr so they show up in
  `docker logs`.
- **Line endings must be LF** (Unix). The scripts run inside a Linux container.
  On Windows, configure your editor or run `dos2unix` before committing.

## Pull request process

1. **Fork** the repository and create a branch from `master`.
2. **Make your changes** in a focused branch. One feature or fix per PR.
3. **Lint** your shell scripts with `shellcheck`.
4. **Test** manually (see [Testing](#testing) above).
5. **Open a pull request** against the `master` branch. Fill in the PR template.
6. **Reference** any related issues in the PR description.

### PR checklist

- [ ] Shell scripts pass `bash -n` (syntax check)
- [ ] Shell scripts pass `shellcheck` (no new warnings)
- [ ] Docker image builds: `docker build -t vaultwarden-sync .`
- [ ] Changes are documented in `README.md` if they affect user-facing behavior
- [ ] No secrets or local paths in the diff (`.env`, `rclone.conf`, etc.)
- [ ] Line endings are LF, not CRLF

## Commit messages

Use conventional commits if you're comfortable with them:

```
feat: add support for Backblaze B2 as a remote
fix: handle missing rclone binary gracefully
docs: clarify encryption key warning in README
chore: update Alpine base image to 3.21
```

At minimum, write a short, descriptive summary in the imperative mood
("Add X" not "Added X" or "Adds X").

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE) covering this project.

## Questions?

Open an issue or start a [Discussion](https://github.com/jceccato/vaultwarden-sync/discussions)
if you're unsure about anything.
