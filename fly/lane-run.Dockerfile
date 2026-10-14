# fly/lane-run.Dockerfile — the image of the Fly app `lane-run` (BH-6126).
# Built from the repo root: flyctl deploy . -c fly/lane-run.toml --build-only
# --push --image-label latest. It bakes bin/, catalog/ and fleet.conf; lane code
# on a machine is as fresh as the last deploy. No secret and no env file is in
# the image: the entrypoint writes them from Fly secrets at boot.
FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 util-linux tini gh openssl \
 && rm -rf /var/lib/apt/lists/*
COPY bin /opt/harness/bin
COPY catalog /opt/harness/catalog
COPY fleet.conf /opt/harness/fleet.conf
COPY fly/lane-run-entrypoint.sh /opt/lane-run/entrypoint.sh
ENV HARNESS=/opt/harness
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/lane-run/entrypoint.sh"]
