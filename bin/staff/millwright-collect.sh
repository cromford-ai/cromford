#!/bin/bash
# bin/staff/millwright-collect.sh — Millwright's collector (BH-10124, C3 of
# #9423). bin/staff.sh runs it at step 6 of `staff.sh tick millwright` and
# claims what it prints. Deterministic: no model call, no gh call, no write.
#
# It reads the four fault kinds of the metric failed_bakes_and_broken_boxes
# through bin/lib/millwright-read.sh and prints one JSONL line per finding in
# the staff collector format:
#   {"item":…, "title":…, "source":{"kind":"millwright","url":…,"labels":[]},
#    "observedAt":…, "class":…}
#
#   bake-failed    item {check, project, sha:<sha12>}: a pool image bake that
#                  failed and has no ok bake since. Printed only when no retry
#                  is queued (state/fly/<p>.image-dirty absent): a bake whose
#                  retry waits is not yet a failure to file. The sha is the
#                  bake id, so the same sha failing again is the same finding.
#   resolv-broken  item {check, box}: /etc/resolv.conf has no usable nameserver.
#   tmp-full       item {check, box}: /tmp use% at or above MW_TMP_FULL_PCT.
#   stale-bin      item {check, box, sha:<harness_commit sha12>}: the box's
#                  harness checkout lags main past harness_version.max_lag_min.
#
# The item holds no count and no time; the numbers ride in the title. Output is
# sorted, so the same state prints the same bytes.
#
# rc 0: a read (lines or none). A half that is unreadable is one warn line in
# logs/staff.log, and the other half still prints. rc 1: the read lib or jq is
# missing; nothing printed.
#
# Knobs: catalog/lanes.d/_lib.staff-millwright.json (lib_env_apply
# staff-millwright). Test seams (HARNESS_TEST_SANDBOX=1 only): MW_FIXTURE (a
# file sourced after the libs), MW_NOW and the read lib's seams.
# Note: docs/notes/2026-11-25-BH-10124-millwright.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
BIN="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
{
  . "$BIN/lib/lane-gate.sh" 2>/dev/null || true
  . "$BIN/jobs-client.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/millwright-read.sh
. "$BIN/lib/millwright-read.sh" 2>/dev/null || exit 1
command -v jq >/dev/null 2>&1 && command -v mw_bakes >/dev/null 2>&1 || exit 1
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MW_FIXTURE:-}" ]; then
  # shellcheck disable=SC1090
  . "$MW_FIXTURE"
fi
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply staff-millwright
export HARNESS="$H"

NOW_S=$(_mw_now)
OBS=$(date -u -d "@$NOW_S" +%Y-%m-%dT%H:%M:%SZ)
URL="${CONSOLE_URL:-}"; URL="${URL%/}/machines"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mw-collect.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

mw_bakes "$H" > "$TMP/bakes.tsv" || { _mw_warn "state/fleet-propagate.json is unreadable; no bake-failed finding this read"; : > "$TMP/bakes.tsv"; }
mw_boxes "$H" "$TMP/w" > "$TMP/boxes.tsv" || _mw_warn "box read incomplete ($(cat "$TMP/w/counts" 2>/dev/null)); the box findings it could read still print"

{
  while IFS=$'\t' read -r p sha _at reason q; do
    [ "$q" = 0 ] || continue
    jq -cn --arg p "$p" --arg s "${sha:0:12}" --arg s8 "${sha:0:8}" --arg r "$reason" \
      '{k: ("bake-failed\t" + $p), item: {check: "bake-failed", project: $p, sha: $s},
        title: ("Pool image bake for \($p) failed at \($s8) (\($r)) and no ok bake since; fix: bin/fly-image-build.sh \($p)"),
        class: "bake-failed"}'
  done < "$TMP/bakes.tsv"
  while IFS=$'\t' read -r box kind detail; do
    case "$kind" in
      resolv-broken)
        jq -cn --arg b "$box" '{k: ("resolv-broken\t" + $b), item: {check: "resolv-broken", box: $b},
          title: ("Box \($b): /etc/resolv.conf has no usable nameserver; fix: bin/dns-guard.sh on \($b)"), class: "resolv-broken"}' ;;
      tmp-full)
        jq -cn --arg b "$box" --arg d "$detail" '{k: ("tmp-full\t" + $b), item: {check: "tmp-full", box: $b},
          title: ("Box \($b): /tmp is \($d) full; clear what the box housekeeping owns"), class: "tmp-full"}' ;;
      stale-bin)
        sha=$(sed -n 's/.* sha=\([^ ]*\).*/\1/p' <<<"$detail")
        lag=$(sed -n 's/^lag=\([0-9]*\) .*/\1/p' <<<"$detail")
        max=$(sed -n 's/.* max=\([0-9]*\) .*/\1/p' <<<"$detail")
        jq -cn --arg b "$box" --arg s "${sha:--}" --arg l "$lag" --arg m "$max" '{k: ("stale-bin\t" + $b), item: {check: "stale-bin", box: $b, sha: $s},
          title: ("Box \($b): the harness checkout (\($s)) lags main by \($l) min, over harness_version.max_lag_min \($m); fix: bin/harness-sync.sh on \($b)"),
          class: "stale-bin"}' ;;
    esac
  done < "$TMP/boxes.tsv"
} | jq -sc --arg obs "$OBS" --arg url "$URL" 'sort_by(.k)[]
      | {item, title, source: {kind: "millwright", url: $url, labels: []}, observedAt: $obs, class}'
exit 0
