---
name: Bug report
about: Report a problem with vaultwarden-sync
title: "[Bug] "
labels: bug
assignees: ''
---

## Describe the bug

A clear and concise description of what went wrong.

## Steps to reproduce

1. ...
2. ...
3. ...

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened. Include error messages, log output, or unexpected state.

### Relevant logs

```text
Paste logs from `docker logs vaultwarden-sync` or the relevant section here.
```

## Environment

- **Deployment mode:** (A: compose / B: User Scripts / C: Unraid GUI)
- **Unraid version:** (e.g., 6.12.10)
- **Vaultwarden image:** (e.g., `vaultwarden/server:1.33.0` or `latest`)
- **Backup encryption:** (encrypted `.aes256`, or unencrypted `.tar.gz`)
- **rclone version:** (output of `docker run --rm vaultwarden-sync rclone version`)

## Additional context

- [ ] I have searched the [existing issues](https://github.com/jceccato/vaultwarden-sync/issues) and this is not a duplicate.
- [ ] I have checked the [Troubleshooting table](README.md#troubleshooting) in the README.
