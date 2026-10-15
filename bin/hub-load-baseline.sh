#!/bin/bash
# gh-identity: app-token
# gh-rest: no-graphql
# bin/hub-load-baseline.sh [--print] — BH-6939 (rest of #6882, part of #6881):
# the 24 h hub load baseline. Hub only. bin/hub-load-sample.sh calls it once
# per run, after its own summary line. No LLM call, no paid call.
#
# T0 is the time of the earliest line in state/hub-load/????-??-??.tsv (the
# first sample after the sampler was deployed). Until NOW >= T0 + 24 h it only
# logs `waiting(<n>h left)`. After that, over the lines with
# T0 <= time < T0 + 24 h, it computes runnable, steal and forks_s p50, p90 and
# mean (linear interpolation, the rule of the sampler's p90 alert). NA and
# non-numeric values are skipped and counted, and a field with no value is
# NA, never 0.
#
# One run (no flag):
#   1. state/hub-load/baseline.state says `posted` or `gave-up`: stop. No read
#      of the tsv files, no network.
#   2. Write the report to state/hub-load/baseline.txt (tmp + mv).
#   3. Read the comments of issue <settings row hub_load.baseline_issue,
#      default 6881> on $HARNESS_REPO, as the App. A comment that holds
#      `<!-- hub-load-baseline:<T0> -->` means it was posted: state `posted
#      <ts> found`, no post.
#   4. Else post the report as one comment that ends with that marker. rc 0:
#      state `posted <ts> <issue>`.
#   5. A failed read or post: state `attempts <n>`. The 6th failure writes
#      `gave-up <ts> <reason>` and one bin/lane-alert.sh --log-only line.
# To post again: delete baseline.state. The marker read still stops a second
# comment for the same T0.
#
# --print: compute and print the report (or waiting/no-data). Writes nothing,
# calls nothing.
#
# Log line (logs/hub-load-baseline.log), exit 0 on every path:
#   <ts> baseline=<no-data|waiting(<n>h left)|not-configured|read-failed|
#   post-failed|posted|gave-up|skipped (running)> issue=<n>(row|default)
#
# Test seams: HUB_LOAD_NOW (epoch seconds, as the sampler);
#   HUB_LOAD_BASELINE_GH_LIB, a file that defines the four GitHub functions,
#   read only under HARNESS_TEST_SANDBOX=1. A sandbox run without it is
#   not-configured and makes no network call.
#
# OFF: flags/lane-off-hub-load-sample (the sampler's switch).
# Doc: docs/notes/2026-10-15-BH-6939-hub-load-baseline.md.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
PRINT=0
case "${1:-}" in
  --print) PRINT=1 ;;
  "") ;;
  *) echo "usage: hub-load-baseline.sh [--print]" >&2; exit 2 ;;
esac

if [[ "${HUB_LOAD_NOW:-}" =~ ^[0-9]+$ ]]; then NOW=$HUB_LOAD_NOW; else NOW=$(date -u +%s); fi
STAMP=$(date -u -d "@$NOW" +%FT%TZ)
DIR_HL="$H/state/hub-load"
STATE="$DIR_HL/baseline.state"
REPORT="$DIR_HL/baseline.txt"
LOG="$H/logs/hub-load-baseline.log"
MAX_ATTEMPTS=6
ISSUE=6881; ISSUE_SRC=default

out() {
  if [ "$PRINT" = 1 ]; then printf 'baseline=%s\n' "$1"; return 0; fi
  printf '%s baseline=%s issue=%s(%s)\n' "$STAMP" "$1" "$ISSUE" "$ISSUE_SRC" >> "$LOG"
}

# report <file> — rc 0 and the report in <file> when ready; else rc 1 and
# OUTCOME set to no-data or waiting(<n>h left). Sets T0.
report() {
  local first t0e t1
  first=$(cat "$DIR_HL"/????-??-??.tsv 2>/dev/null \
    | cut -f1 | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' | LC_ALL=C sort | head -1)
  [ -n "$first" ] && t0e=$(date -u -d "$first" +%s 2>/dev/null) \
    || { OUTCOME=no-data; return 1; }
  T0=$first
  if [ "$NOW" -lt $((t0e + 86400)) ]; then
    OUTCOME="waiting($(( (t0e + 86400 - NOW + 3599) / 3600 ))h left)"; return 1
  fi
  t1=$(date -u -d "@$((t0e + 86400))" +%FT%TZ)
  # ISO UTC times of one fixed width sort as text, so the window is a string
  # compare: T0 <= time < T1.
  cat "$DIR_HL"/????-??-??.tsv 2>/dev/null | awk -F '\t' -v a="$T0" -v b="$t1" '
    $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/ && $1 >= a && $1 < b {
      n++; split("", got)
      for (k = 2; k <= NF; k++) {
        e = index($k, "="); if (!e) continue
        key = substr($k, 1, e - 1); v = substr($k, e + 1)
        if (key == "runnable" || key == "steal" || key == "forks_s") got[key] = v
      }
      for (w = 1; w <= 3; w++) {
        key = (w == 1) ? "runnable" : (w == 2) ? "steal" : "forks_s"
        if ((key in got) && got[key] ~ /^[0-9]+(\.[0-9]+)?$/) print key, got[key]
        else print key, "NA"
      }
    }
    END { print "lines", n + 0 }' > "$1.vals"
  {
    printf 'window %s to %s\n' "$T0" "$t1"
    printf 'lines %s/144\n' "$(awk '$1 == "lines" { print $2 }' "$1.vals")"
    for key in runnable steal forks_s; do
      awk -v k="$key" '$1 == k { print $2 }' "$1.vals" | LC_ALL=C sort -g | awk -v k="$key" '
        function f(x,   s) { s = sprintf("%.2f", x); sub(/\.?0+$/, "", s); return s }
        function q(p,   i, lo, hi) { i = p * (m - 1); lo = int(i); hi = (lo + 1 < m) ? lo + 1 : lo
                                     return f(v[lo] + (i - lo) * (v[hi] - v[lo])) }
        $1 == "NA" { na++; next }
        { v[m++] = $1; sum += $1 }
        END {
          if (m == 0) printf "%s p50=NA p90=NA mean=NA n=0 na=%d\n", k, na
          else printf "%s p50=%s p90=%s mean=%s n=%d na=%d\n", k, q(0.5), q(0.9), f(sum / m), m, na + 0
        }'
    done
  } > "$1"
  rm -f "$1.vals"
  return 0
}

if [ "$PRINT" = 1 ]; then
  TMPF=$(mktemp "${TMPDIR:-/tmp}/hlb.XXXXXX") || exit 0
  if report "$TMPF"; then cat "$TMPF"; else out "$OUTCOME"; fi
  rm -f "$TMPF"
  exit 0
fi

# shellcheck disable=SC1091
. "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit hub-load-sample

mkdir -p "$H/logs" "$H/locks" "$DIR_HL" 2>/dev/null
# shellcheck source=bin/jobs-client.sh
LOADED=1; . "$SELF/jobs-client.sh" 2>/dev/null || LOADED=0
v=""
[ "$LOADED" = 1 ] && v=$(setting_get hub_load.baseline_issue 2>/dev/null | tr -d '[:space:]')
if [[ "$v" =~ ^[1-9][0-9]{0,6}$ ]]; then ISSUE=$v; ISSUE_SRC=row; fi

exec 7> "$H/locks/hub-load-baseline.lock" 2>/dev/null || { out "skipped (no lock file)"; exit 0; }
flock -n 7 || { out "skipped (running)"; exit 0; }

# ── 1. terminal state ────────────────────────────────────────────────────────
read -r S_WORD S_REST < "$STATE" 2>/dev/null || S_WORD=""
case "$S_WORD" in
  posted|gave-up) out "$S_WORD"; exit 0 ;;
  attempts) ATTEMPTS=${S_REST%% *}; [[ "$ATTEMPTS" =~ ^[0-9]+$ ]] || ATTEMPTS=0 ;;
  *) ATTEMPTS=0 ;;
esac

# ── 2. the local copy, before any send ───────────────────────────────────────
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hlb.XXXXXX") || { out "skipped (mktemp)"; exit 0; }
trap 'command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset; rm -rf "$TMP"' EXIT
report "$TMP/report" || { out "$OUTCOME"; exit 0; }
cp "$TMP/report" "$REPORT.tmp" && mv -f "$REPORT.tmp" "$REPORT"

# ── 3. GitHub, as the App ────────────────────────────────────────────────────
if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ]; then
  # shellcheck disable=SC1090
  [ -n "${HUB_LOAD_BASELINE_GH_LIB:-}" ] && [ -r "$HUB_LOAD_BASELINE_GH_LIB" ] && . "$HUB_LOAD_BASELINE_GH_LIB"
else
  # shellcheck source=bin/lib/deployment.sh
  . "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-rest.sh
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-rest-list.sh
  . "$SELF/lib/gh-rest-list.sh" 2>/dev/null || true
  # shellcheck source=bin/lib/gh-app-auth.sh
  . "$SELF/lib/gh-app-auth.sh" 2>/dev/null || true
fi
SLUG="${HARNESS_REPO:-}"
for f in gh_auth_for gh_rest_issue_comments gh_rest_comment; do
  command -v "$f" >/dev/null 2>&1 || SLUG=""
done
[ -n "$SLUG" ] || { out not-configured; exit 0; }
gh_auth_for "$SLUG" >/dev/null 2>&1 || true

MARK="<!-- hub-load-baseline:$T0 -->"
# fail <outcome> — count one failed attempt; the last one gives up and alerts.
fail() {
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    printf 'gave-up %s %s\n' "$STAMP" "$1" > "$STATE"
    "$SELF/lane-alert.sh" --log-only hub-load-sample \
      "The 24 h hub load baseline was not posted on #$ISSUE after $ATTEMPTS tries ($1). The numbers are in state/hub-load/baseline.txt on the hub. Post them by hand, or delete state/hub-load/baseline.state to try again." \
      >/dev/null 2>&1
    out gave-up
  else
    printf 'attempts %s\n' "$ATTEMPTS" > "$STATE"
    out "$1"
  fi
  exit 0
}

if ! gh_rest_issue_comments "$SLUG" "$ISSUE" > "$TMP/comments.json" 2>/dev/null \
   || ! jq -e 'type == "array"' "$TMP/comments.json" >/dev/null 2>&1; then
  fail read-failed
fi
if jq -e --arg m "$MARK" 'any(.[]; (.body // "") | contains($m))' "$TMP/comments.json" >/dev/null 2>&1; then
  printf 'posted %s found\n' "$STAMP" > "$STATE"
  out posted; exit 0
fi

# ── 4. the comment ───────────────────────────────────────────────────────────
row() { # row <key> <label> — one table row from the report
  awk -v k="$1" -v l="$2" '$1 == k { for (i = 2; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
    printf "| %s | %s | %s | %s | %s | %s |\n", l, v["p50"], v["p90"], v["mean"], v["n"], v["na"] }' "$TMP/report"
}
{
  echo "Hub load baseline: the first 24 h of samples after the sampler started (BH-6939)."
  echo
  echo "Window: $(awk '$1 == "window" { print $2 " to " $4 }' "$TMP/report") (UTC)."
  echo "Coverage: $(awk '$1 == "lines" { print $2 }' "$TMP/report") sample lines."
  echo
  echo "| Metric | p50 | p90 | Mean | n | NA |"
  echo "|---|---|---|---|---|---|"
  row runnable "Runnable processes"
  row steal "Steal (%)"
  row forks_s "Forks per second"
  echo
  echo "Source: state/hub-load/*.tsv on the hub, bin/hub-load-baseline.sh"
  echo "$MARK"
} > "$TMP/body.md"
gh_rest_comment "$SLUG" "$ISSUE" "$TMP/body.md" >/dev/null 2>&1 || fail post-failed
printf 'posted %s %s\n' "$STAMP" "$ISSUE" > "$STATE"
out posted
exit 0
