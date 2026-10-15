# fly/lane-run.Dockerfile — the image of the Fly app `lane-run` (BH-6126).
# Built from the repo root: flyctl deploy . -c fly/lane-run.toml --build-only
# --push --image-label latest --build-arg HARNESS_COMMIT=$(git rev-parse HEAD).
# It bakes bin/, catalog/ and fleet.conf; a machine then pulls main of the
# harness repo before its claims (bin/lib/lane-run-code.sh). HARNESS_COMMIT is
# the `harness.commit` label bin/lane-fleet.sh logs, and /opt/harness/
# HARNESS_COMMIT when it is 7-40 hex (else no file, so the first sync runs).
# No secret and no env file is in the image: the entrypoint writes them from
# Fly secrets at boot.
FROM ubuntu:24.04
ARG HARNESS_COMMIT=unknown
LABEL harness.commit=$HARNESS_COMMIT
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 util-linux tini gh openssl \
 && rm -rf /var/lib/apt/lists/*
COPY bin /opt/harness/bin
COPY catalog /opt/harness/catalog
COPY fleet.conf /opt/harness/fleet.conf
COPY fly/lane-run-entrypoint.sh /opt/lane-run/entrypoint.sh
RUN if printf '%s' "$HARNESS_COMMIT" | grep -qE '^[0-9a-f]{7,40}$'; then \
      printf '%s\n' "$HARNESS_COMMIT" > /opt/harness/HARNESS_COMMIT; fi
ENV HARNESS=/opt/harness
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lane-run/entrypoint.sh"]
