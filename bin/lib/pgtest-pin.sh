#!/bin/bash
# bin/lib/pgtest-pin.sh — the throwaway Postgres the pool image bakes (BH-5962).
# Sourced, never executed; sourcing it only sets the pins.
#
# fly/Dockerfile's bake-pgtest block holds the same three literals (the build
# context is fly/ and cannot read this file), and
# tests/pool-test-postgres.bh-5962-test.sh (P8) fails when they differ.
# bin/lib/pg-test.sh's PGT_BIN_DIR default is "$PGTEST_PIN_DIR/bin" (P8 too).
# Major 16 is the major the project-6-os suite runs on: its CI, and the
# embedded Postgres 16 the TK-3 build started. A second major is a second pin.
#
# They are assigned, not defaulted, so no environment variable can move the pin.
PGTEST_PIN_PKG_VERSION=16.14.0-beta.17
PGTEST_PIN_SHA256=dfe7ecd8365ab907786e5f3d69179399f9675ac800153219efb2590257c2d551
PGTEST_PIN_PG_VERSION=16.14
PGTEST_PIN_DIR=/opt/pgtest
# pgvector (BH-9435): the release fly/Dockerfile's pgvector-build stage compiles
# against the PG 16 headers and bake-pgvector copies into $PGTEST_PIN_DIR. The
# Dockerfile holds the same literals; tests/pool-pgvector-image.bh-9435-test.sh
# (V1, V2, V4) fails when they differ or the sha256 is not 64 hex.
PGVECTOR_PIN_VERSION=0.8.1
PGVECTOR_PIN_SHA256=a9094dfb85ccdde3cbb295f1086d4c71a20db1d26bf1d6c39f07a7d164033eb4
