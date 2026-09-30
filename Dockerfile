# Helper image: everything needed to pull a backup from Google Drive and
# restore it into a local Vaultwarden container on Unraid.
#
#   build:  docker build -t vaultwarden-sync .
FROM alpine:3.20

RUN apk add --no-cache \
      bash \
      coreutils \
      findutils \
      tar \
      gzip \
      openssl \
      sqlite \
      rsync \
      rclone \
      docker-cli \
      tzdata \
      ca-certificates \
      curl \
      tini

COPY scripts/vaultwarden-sync.sh /usr/local/bin/vaultwarden-sync.sh
COPY entrypoint.sh               /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/vaultwarden-sync.sh /usr/local/bin/entrypoint.sh

# tini reaps zombies and forwards signals; entrypoint decides cron vs one-shot.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
