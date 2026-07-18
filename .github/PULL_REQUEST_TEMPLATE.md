## Description

<!-- Briefly describe what this PR does and why. Reference any related issues. -->

Closes # <!-- issue number -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Code quality / refactor (no behavior change)
- [ ] CI / tooling

## Checklist

- [ ] Shell scripts pass `bash -n` (syntax check):
      ```bash
      bash -n scripts/vaultwarden-sync.sh entrypoint.sh
      ```
- [ ] Shell scripts pass `shellcheck` (no new warnings):
      ```bash
      shellcheck scripts/vaultwarden-sync.sh entrypoint.sh
      ```
- [ ] Docker image builds successfully:
      ```bash
      docker build -t vaultwarden-sync .
      ```
- [ ] Manual testing completed (describe below)
- [ ] README updated if user-facing behavior changed
- [ ] No secrets, local paths, or personal configuration in the diff
- [ ] Line endings are LF (not CRLF)

## Testing performed

<!-- Describe what you tested and how. For example:
- Built the image and ran `status` against a live rclone remote
- Ran a `sync --force` on a test Unraid server and verified login
-->

## Screenshots / Logs (if applicable)

<!-- Paste relevant output here. -->
