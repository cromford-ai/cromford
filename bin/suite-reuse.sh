#!/bin/bash
# bin/suite-reuse.sh — run a suite once per input fingerprint (BH-5354.0 / BH-5366).
#
# The one helper every suite runner calls: before it runs a selection, `plan`
# asks the harness-jobs suite ledger which of those suites already went green
# at the same input fingerprint, and hands back the ones still to run; after,
# `record` writes what happened so the next run can reuse it. Callers:
# bin/test-impact-gate.sh (the builder and prequeue gates) and bin/ci-plan.sh
# (the merge-queue batch). Doc: docs/notes/2026-10-08-BH-5354-suite-reuse.md.
#
#   bin/suite-reuse.sh plan --class ci|builder --repo R --ctx C --suites IN \
#       --run OUT --reused OUT.tsv --fingerprints OUT.tsv [--rev HEAD]
#     Always writes all three outputs. --run gets the suites to execute, in
#     IN's order; --reused gets `<suite>\t<run_id>\t<duration_s>\t<class>` per
#     suite skipped; --fingerprints gets bin/lib/suite-fingerprint.sh's rows,
#     for `record`. Prints `suite-reuse: image <id>` once the fingerprints are
#     written (the runner image id in the key, bin/lib/suite-fingerprint.sh),
#     then `suite-reuse: reused <suite> from <run_id> (<d>s)` per hit and
#     `suite-reuse: ran X reused R of N (saved ~Ss)`.
#     FAIL-SAFE: on ANY failure (SUITE_REUSE not on, no credential, no URL,
#     a --class the credential does not carry, dirty tree, fingerprint failure,
#     curl error or timeout, a non-200, unparseable JSON, the server's knob off,
#     or a filter that would leave nothing to run) --run is IN verbatim,
#     --reused is empty, ONE `suite-reuse: off (<why>)` line prints, rc 0.
#
#   bin/suite-reuse.sh record --repo R --ctx C --run-key K --fingerprints FP \
#       (--results TSV | --from-gate-log LOG) [--reused TSV] [--url U]
#     TSV rows are `<suite>\t<ok|fail|skipped>\t<duration_s>`. From a gate log
#     (bin/test-trace-safety.sh --gate) a `--- <suite> rc=<n> <s>s` line is ok
#     only with rc 0 and no HIT/TIMEOUT line for its basename; no `TRACE:`
#     summary line means the scan did not finish and NOTHING is written.
#     Rows with fp `-`, rows not in FP and suites in --reused are not written.
#     PUTs /api/suite-results in chunks of 500 (run_id = K), then the run row.
#     A green that just went red prints `suite-reuse: MISS ...` (a ::warning::
#     under GITHUB_ACTIONS). A write failure is ONE stderr line, rc 0: a ledger
#     problem never turns a run red. Recording does not read SUITE_REUSE.
#
# Transport: SUITE_LEDGER_URL + SUITE_LEDGER_TOKEN (header x-suite-ledger-token)
# is class ci; else JOBS_URL + HARNESS_SECRET through bin/lib/jobs/req.sh is
# class builder. Test seam: SUITE_REUSE_CURL is run as
# `$SUITE_REUSE_CURL <method> <path> <body-file> <class>` instead, and prints
# the body then a final line holding the HTTP code. No token is ever printed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/suite-fingerprint.sh
. "$HERE/lib/suite-fingerprint.sh" || exit 1

SR_CHUNK=500
SR_W=""
cleanup() { [ -n "$SR_W" ] && rm -rf "$SR_W"; }
trap cleanup EXIT
SR_W=$(mktemp -d "${TMPDIR:-/tmp}/suite-reuse.XXXXXX") || { echo "suite-reuse: mktemp failed" >&2; exit 2; }

usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0" >&2; exit 2; }

# sr_transport — SR_CLASS/SR_URL from the environment, or SR_WHY when neither
# credential set is complete.
sr_transport() {
  SR_CLASS="" SR_URL="" SR_WHY=""
  local url="${SR_URL_OVERRIDE:-${SUITE_LEDGER_URL:-}}"
  if [ -n "$url" ] && [ -n "${SUITE_LEDGER_TOKEN:-}" ]; then SR_CLASS=ci; SR_URL="$url"
  elif [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ]; then SR_CLASS=builder; SR_URL="$JOBS_URL"
  elif [ -z "${SUITE_LEDGER_TOKEN:-}" ] && [ -z "${HARNESS_SECRET:-}" ]; then SR_WHY="no credential"
  else SR_WHY="no ledger url"
  fi
}

# sr_call <method> <path> <body-file> — rc 0 with SR_HTTP/SR_BODY set when the
# ledger answered (any status), rc 1 when it did not answer at all.
sr_call() {
  local method="$1" path="$2" bodyf="$3" out rc
  SR_HTTP="" SR_BODY=""
  if [ -n "${SUITE_REUSE_CURL:-}" ]; then
    out=$("$SUITE_REUSE_CURL" "$method" "$path" "$bodyf" "$SR_CLASS" 2>/dev/null); rc=$?
  elif [ "$SR_CLASS" = ci ]; then
    out=$(curl -sS --max-time 10 --connect-timeout 3 -w $'\n%{http_code}' -X "$method" \
      -H "x-suite-ledger-token: $SUITE_LEDGER_TOKEN" -H "content-type: application/json" \
      --data-binary "@$bodyf" "${SR_URL%/}$path" 2>/dev/null); rc=$?
  else
    # shellcheck source=bin/lib/jobs/req.sh
    . "$HERE/lib/jobs/req.sh" || return 1
    JOBS_TIMEOUT=10 JOBS_RETRIES=0 _jobs_req_file "$method" "$path" "$bodyf" > /dev/null
    [ -n "$JOBS_HTTP" ] || return 1
    SR_HTTP="$JOBS_HTTP" SR_BODY="$JOBS_BODY"
    return 0
  fi
  [ "$rc" -eq 0 ] || return 1
  SR_HTTP="${out##*$'\n'}"
  SR_BODY="${out%$'\n'*}"
  [ "$out" != "$SR_HTTP" ] || SR_BODY=""
  case "$SR_HTTP" in [0-9][0-9][0-9]) return 0 ;; *) return 1 ;; esac
}

# ── plan ────────────────────────────────────────────────────────────────────
plan_off() { # plan_off <why> — everything runs; the fingerprints stay for record
  cp "$IN" "$RUN" && : > "$REUSED"
  echo "suite-reuse: off ($1)"
  exit 0
}

cmd_plan() {
  local class="" repo="" ctx="" rev=HEAD
  IN="" RUN="" REUSED="" FP=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --class) class="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --ctx) ctx="${2:-}"; shift ;;
      --suites) IN="${2:-}"; shift ;;
      --run) RUN="${2:-}"; shift ;;
      --reused) REUSED="${2:-}"; shift ;;
      --fingerprints) FP="${2:-}"; shift ;;
      --rev) rev="${2:-}"; shift ;;
      *) echo "suite-reuse: plan: unknown argument $1" >&2; usage ;;
    esac
    shift
  done
  [ -r "$IN" ] && [ -n "$RUN" ] && [ -n "$REUSED" ] && [ -n "$FP" ] || {
    echo "suite-reuse: plan needs a readable --suites and --run, --reused, --fingerprints" >&2; usage; }
  cp "$IN" "$RUN" && : > "$REUSED" && : > "$FP" || { echo "suite-reuse: cannot write the outputs" >&2; exit 2; }
  [ -n "$repo" ] && [ -n "$ctx" ] || plan_off "no --repo or --ctx"

  sr_transport
  [ -z "$SR_WHY" ] || plan_off "$SR_WHY"
  [ "$class" = "$SR_CLASS" ] || plan_off "credential is $SR_CLASS, not ${class:-unset}"

  local rc=0
  sfp_compute "$rev" "$IN" "$FP" 2> "$SR_W/sfp.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    : > "$FP"
    [ "$rc" -eq 3 ] && plan_off "dirty tree"
    plan_off "fingerprint failed"
  fi
  echo "suite-reuse: image ${SFP_IMAGE_ID:-}"
  case "${SUITE_REUSE:-on}" in
    on) ;;
    off) plan_off "knob off" ;;
    *) plan_off "bad SUITE_REUSE" ;;
  esac

  # Only suites with a real fingerprint are asked about, 500 to a request; one
  # failed chunk turns the whole run off, never a partial reuse.
  awk -F'\t' '$2 ~ /^[0-9a-f]{64}$/ { print $1 "\t" $2 }' "$FP" > "$SR_W/ask"
  : > "$SR_W/hits"
  local total i=0 n why
  total=$(wc -l < "$SR_W/ask" | tr -d ' ')
  while [ "$i" -lt "$total" ]; do
    sed -n "$((i + 1)),$((i + SR_CHUNK))p" "$SR_W/ask" \
      | jq -R -s --arg repo "$repo" --arg ctx "$ctx" \
          '{repo: $repo, ctx: $ctx, items: [split("\n")[] | select(. != "") | split("\t") | {suite: .[0], fingerprint: .[1]}]}' \
          > "$SR_W/body" || plan_off "fingerprint failed"
    sr_call POST /api/suite-results/lookup "$SR_W/body" || plan_off "ledger unreachable"
    [ "$SR_HTTP" = 200 ] || plan_off "ledger http $SR_HTTP"
    printf '%s' "$SR_BODY" | jq -e 'type == "object" and (.reuse == "on" or .reuse == "off")' > /dev/null 2>&1 \
      || plan_off "bad ledger answer"
    if [ "$(printf '%s' "$SR_BODY" | jq -r '.reuse')" = off ]; then
      why=$(printf '%s' "$SR_BODY" | jq -r '.reason // "no reason"' | tr -cd 'A-Za-z0-9 ._:-' | cut -c1-80)
      plan_off "server knob off: $why"
    fi
    printf '%s' "$SR_BODY" | jq -r '.hits | if type == "array" then .[] else error("hits") end
        | [.suite, .fingerprint, .run_id, (.duration_s | tostring), .class] | @tsv' >> "$SR_W/hits" 2>/dev/null \
      || plan_off "bad ledger answer"
    i=$((i + SR_CHUNK))
  done

  # A hit counts only when its suite AND fingerprint are this run's own row
  # (first hit per suite wins); the rest is IN minus those, in IN's order.
  awk -F'\t' -v hf="$SR_W/hits" '
    FILENAME == hf { if (!($1 in hit) && $3 ~ /^[A-Za-z0-9._:\/-]+$/ && $4 ~ /^[0-9]+$/) hit[$1] = $2 "\t" $3 "\t" $4 "\t" $5; next }
    { split(hit[$1], h, "\t") }
    ($1 in hit) && h[1] == $2 { print $1 "\t" h[2] "\t" h[3] "\t" h[4] }
  ' "$SR_W/hits" "$SR_W/ask" > "$SR_W/reused"
  awk -F'\t' -v rf="$SR_W/reused" 'FILENAME == rf { r[$1] = 1; next } !($1 in r)' "$SR_W/reused" "$IN" > "$SR_W/run"
  [ -n "$(grep -v '^$' "$SR_W/run")" ] || plan_off "would run nothing"
  cp "$SR_W/run" "$RUN" && cp "$SR_W/reused" "$REUSED" || plan_off "cannot write the outputs"

  awk -F'\t' '{ print "suite-reuse: reused " $1 " from " $2 " (" $3 "s)" }' "$REUSED"
  local ran reused all saved
  ran=$(grep -c . "$RUN"); reused=$(grep -c . "$REUSED"); all=$(grep -c . "$IN")
  saved=$(awk -F'\t' '{ s += $3 } END { print s + 0 }' "$REUSED")
  echo "suite-reuse: ran $ran reused $reused of $all (saved ~${saved}s)"
}

# ── record ──────────────────────────────────────────────────────────────────
record_fail() { echo "suite-reuse: record failed ($1)" >&2; exit 0; }

cmd_record() {
  local repo="" ctx="" key="" fp="" results="" gatelog="" reused=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:-}"; shift ;;
      --ctx) ctx="${2:-}"; shift ;;
      --run-key) key="${2:-}"; shift ;;
      --fingerprints) fp="${2:-}"; shift ;;
      --results) results="${2:-}"; shift ;;
      --from-gate-log) gatelog="${2:-}"; shift ;;
      --reused) reused="${2:-}"; shift ;;
      --url) SR_URL_OVERRIDE="${2:-}"; shift ;;
      *) echo "suite-reuse: record: unknown argument $1" >&2; usage ;;
    esac
    shift
  done
  [ -n "$repo" ] && [ -n "$ctx" ] && [ -n "$key" ] && [ -n "$fp" ] || record_fail "needs --repo, --ctx, --run-key and --fingerprints"
  { [ -n "$results" ] && [ -z "$gatelog" ]; } || { [ -z "$results" ] && [ -n "$gatelog" ]; } \
    || record_fail "needs exactly one of --results and --from-gate-log"
  [ -r "$fp" ] || record_fail "cannot read $fp"
  [ -s "$fp" ] || { echo "suite-reuse: record skipped (no fingerprints)"; exit 0; }
  : > "$SR_W/reused"
  if [ -n "$reused" ]; then [ -r "$reused" ] && cp "$reused" "$SR_W/reused" || record_fail "cannot read $reused"; fi

  if [ -n "$gatelog" ]; then
    [ -r "$gatelog" ] || record_fail "cannot read $gatelog"
    # The summary must CLOSE the log (TRACE:, or TRACE: then GATE:): a failing
    # suite's output is dumped into the log whole, so a TRACE: line anywhere
    # else may be a nested gate's and says nothing about this scan finishing.
    if ! awk 'NF { p2 = p1; p1 = $0 } END { exit !(p1 ~ /^TRACE: / || (p1 ~ /^GATE: / && p2 ~ /^TRACE: /)) }' "$gatelog"; then
      echo "suite-reuse: record skipped (no TRACE: summary)"; exit 0
    fi
    # A path with two `---` lines is fail: one of them came out of a dumped
    # nested log, and which one is the scan's own cannot be told.
    awk '
      /^--- tests\/[^ ]+ rc=[0-9]+ [0-9]+s$/ { p = $2; rc = substr($3, 4); d = $4; sub(/s$/, "", d)
        if (!(p in R)) o[++n] = p; else rc = 1
        R[p] = rc; D[p] = d; next }
      /^(HIT|TIMEOUT) / { bad[$2] = 1 }
      END { for (i = 1; i <= n; i++) { p = o[i]; b = p; sub(/.*\//, "", b)
              print p "\t" ((R[p] == 0 && !(b in bad)) ? "ok" : "fail") "\t" D[p] } }
    ' "$gatelog" > "$SR_W/results"
  else
    [ -r "$results" ] && cp "$results" "$SR_W/results" || record_fail "cannot read $results"
  fi
  local badrow
  badrow=$(awk -F'\t' 'NF && !($2 ~ /^(ok|fail|skipped)$/ && $3 ~ /^[0-9]+$/) { print NR; exit }' "$SR_W/results")
  [ -z "$badrow" ] || record_fail "bad results row $badrow"

  # What is written: ran, has a real fingerprint, and was not reused.
  awk -F'\t' -v ff="$fp" -v rf="$SR_W/reused" '
    FILENAME == ff { if ($2 ~ /^[0-9a-f]{64}$/) f[$1] = $2; next }
    FILENAME == rf { r[$1] = 1; next }
    NF && !($1 in r) && ($1 in f) { print $1 "\t" f[$1] "\t" $2 "\t" $3 }
  ' "$fp" "$SR_W/reused" "$SR_W/results" > "$SR_W/write"

  sr_transport
  [ -z "$SR_WHY" ] || record_fail "$SR_WHY"
  local head total i=0 ran nreused saved
  head=$(git rev-parse --verify -q HEAD 2>/dev/null) || head=""
  total=$(grep -c . "$SR_W/write")
  while [ "$i" -lt "$total" ]; do
    sed -n "$((i + 1)),$((i + SR_CHUNK))p" "$SR_W/write" \
      | jq -R -s --arg repo "$repo" --arg ctx "$ctx" --arg key "$key" --arg head "$head" '
          {repo: $repo, ctx: $ctx, run_id: $key,
           items: [split("\n")[] | select(. != "") | split("\t")
                   | {suite: .[0], fingerprint: .[1], status: .[2], duration_s: (.[3] | tonumber)}]}
          + (if ($head | test("^[0-9a-f]{40}$")) then {head_sha: $head} else {} end)' > "$SR_W/body" \
      || record_fail "cannot build the request"
    sr_call PUT /api/suite-results "$SR_W/body" || record_fail "ledger unreachable"
    [ "$SR_HTTP" = 200 ] || record_fail "ledger http $SR_HTTP"
    printf '%s' "$SR_BODY" | jq -r '.contradicted // [] | .[] | [.suite, .prior_run_id] | @tsv' > "$SR_W/miss" 2>/dev/null \
      || record_fail "bad ledger answer"
    while IFS=$'\t' read -r s prior; do
      [ -n "$s" ] || continue
      if [ "${GITHUB_ACTIONS:-}" = true ]; then
        echo "::warning::suite-reuse: MISS $s was ok in $prior, failed in $key"
      else
        echo "suite-reuse: MISS $s was ok in $prior, failed in $key"
      fi
    done < "$SR_W/miss"
    i=$((i + SR_CHUNK))
  done

  ran=$(grep -c . "$SR_W/results"); nreused=$(grep -c . "$SR_W/reused")
  saved=$(awk -F'\t' '$3 ~ /^[0-9]+$/ { s += $3 } END { print s + 0 }' "$SR_W/reused")
  jq -n --arg repo "$repo" --arg ctx "$ctx" --arg key "$key" --arg head "$head" \
      --argjson ran "$ran" --argjson reused "$nreused" --argjson saved "$saved" '
      {repo: $repo, run_key: $key, ctx: $ctx, ran: $ran, reused: $reused, total: ($ran + $reused), saved_s: $saved}
      + (if ($head | test("^[0-9a-f]{40}$")) then {head_sha: $head} else {} end)' > "$SR_W/body" \
    || record_fail "cannot build the run row"
  sr_call PUT /api/suite-results/runs "$SR_W/body" || record_fail "ledger unreachable"
  [ "$SR_HTTP" = 200 ] || record_fail "run row http $SR_HTTP"
  echo "suite-reuse: recorded $total result(s) for $key (ran $ran, reused $nreused)"
}

CMD="${1:-}"
[ $# -gt 0 ] && shift
case "$CMD" in
  plan) cmd_plan "$@" ;;
  record) cmd_record "$@" ;;
  -h|--help|"") usage ;;
  *) echo "suite-reuse: unknown command '$CMD' (plan, record)" >&2; exit 2 ;;
esac
