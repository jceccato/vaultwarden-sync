#!/bin/sh
#
# Container entrypoint.
#
#   docker run ... vaultwarden-sync                 -> set up cron, run forever
#   docker run ... vaultwarden-sync sync            -> run once and exit
#   docker run ... vaultwarden-sync sync --force    -> force a re-restore and exit
#   docker run ... vaultwarden-sync status          -> print status and exit
#   docker run ... vaultwarden-sync rollback        -> roll back and exit
#
set -e

SCRIPT=/usr/local/bin/vaultwarden-sync.sh

case "${1:-}" in
  sync|restore|rollback|status)
    exec "$SCRIPT" "$@"
    ;;
  ""|cron|crond)
    : "${SCHEDULE:=0 3 * * *}"   # default: 03:00 nightly
    : "${TZ:=UTC}"

    # busybox crond reads /etc/crontabs/root (5 fields + command, no user column).
    # Redirect job output to PID 1's stdout so it shows up in `docker logs`.
    echo "$SCHEDULE $SCRIPT sync >> /proc/1/fd/1 2>&1" > /etc/crontabs/root
    chmod 0600 /etc/crontabs/root

    if [ "${RUN_ON_START:-false}" = "true" ]; then
      echo "[entrypoint] RUN_ON_START=true -> running an initial sync"
      "$SCRIPT" sync || echo "[entrypoint] initial sync exited non-zero (see log above)"
    fi

    echo "[entrypoint] starting crond (TZ=$TZ, schedule: '$SCHEDULE')"
    exec crond -f -l 8
    ;;
  *)
    # Anything else: run it verbatim (debugging, e.g. `... sh`)
    exec "$@"
    ;;
esac
