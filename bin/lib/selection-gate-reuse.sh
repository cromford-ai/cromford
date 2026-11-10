#!/bin/bash
# shellcheck shell=bash
# bin/lib/selection-gate-reuse.sh — the selection gate reads and writes the
# suite ledger (BH-9177, slice C1 of #9063). Sourced by bin/selection-gate.sh
# when SELECTION_GATE_SUITE_REUSE=1, never run.
#
#   sgr_plan    after step 2. Asks the runner for the test host's image
#               (`<runner> --image-id`, under `timeout SELECTION_GATE_IMAGE_PROBE_S`),
#               keys the ledger with SUITE_IMAGE_ID=<fly id>+rg:<12 hex of
#               bin/remote-gate.sh's blob at HEAD> (the runner script decides
#               results, so a change to it moves the key), and runs
#               `bin/suite-reuse.sh plan --class builder --ctx fly-testhost
#               --reds` over the selection (with --rerun-red unless
#               SELECTION_GATE_RERUN_RED=0). It sets SUITES to the suites
#               still to send, SGR_REDS to the ledger reds (a red without a
#               run) and SGR_LINE to gate.txt's `reuse:` value.
#   sgr_record  before the final gate.txt. Writes what the run decided: a
#               `PASS <s>` is ok, a `FAIL <s> (rc N)` with N not 127 is fail,
#               with the `TIME <secs> <s>` line as the duration (else 0). No
#               row for rc 127, BLIND, a host-noted red, a reused suite, a
#               ledger red, or any suite when run.txt's IMAGE line is not the
#               probed image (another machine ran it). Never changes RC.
#
# Every failure is reuse off with a reason, and the whole selection is sent:
#   off (image probe rc N)  off (the test host has no image ref)
#   off (bad image ref)  off (no runner blob)  off (image id too long)
#   off (no helper in the tree)  off (no repo)  off (<the helper's own why>)
#   off (helper answer did not match its input)
# The repo is SUITE_REUSE_REPO, else REPO_SLUG, else origin's <owner>/<name>;
# the run key SUITE_REUSE_RUN_KEY, else selection-<host>-<epoch>-<pid>.
# Reads TREE, OUT, RUNNER, SUITES and HNOTED from bin/selection-gate.sh.

# shellcheck source=bin/lib/suite-fingerprint.sh
. "$(dirname "${BASH_SOURCE[0]}")/suite-fingerprint.sh" || return 1

SGR_REDS=(); SGR_LINE="-"; SGR_ID=""; SGR_HOST=""; SGR_REPO=""; SGR_REC=0

_sgr_off() { SGR_LINE="off ($1)"; echo "selection-gate: reuse: $SGR_LINE"; }

sgr_plan() {
  local probe rc out ref blob f n run reused red
  local -a rerun=()
  SGR_REDS=(); SGR_REC=0
  # lane.fly-pool.selection_gate_image_probe_s (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_IMAGE_PROBE_S.json)
  probe="${SELECTION_GATE_IMAGE_PROBE_S:-60}"; [[ "$probe" =~ ^[1-9][0-9]*$ ]] || probe=60
  # lane.fly-pool.selection_gate_rerun_red (catalog/lanes.d/fly-pool.knobs.d/SELECTION_GATE_RERUN_RED.json)
  [ "${SELECTION_GATE_RERUN_RED:-1}" = 0 ] || rerun=(--rerun-red)
  [ -x "$TREE/bin/suite-reuse.sh" ] || { _sgr_off "no helper in the tree"; return 0; }
  rc=0; out=$(timeout -k 10 "$probe" "$RUNNER" --image-id 2> "$OUT/reuse-probe.err") || rc=$?
  [ "$rc" = 0 ] || { _sgr_off "image probe rc $rc"; return 0; }
  ref=$(sed -n 's/^IMAGE //p' <<<"$out" | head -n 1)
  { [ -n "$ref" ] && [ "$ref" != - ]; } || { _sgr_off "the test host has no image ref"; return 0; }
  SGR_HOST=$(sfp_fly_image_id "$ref") || { _sgr_off "bad image ref"; return 0; }
  blob=$(git -C "$TREE" rev-parse --verify -q "HEAD:bin/remote-gate.sh" 2>/dev/null) || blob=""
  [[ "$blob" =~ ^[0-9a-f]{40,64}$ ]] || { _sgr_off "no runner blob"; return 0; }
  SGR_ID="$SGR_HOST+rg:${blob:0:12}"
  [ "${#SGR_ID}" -le 128 ] || { _sgr_off "image id too long"; return 0; }
  SGR_REPO="${SUITE_REUSE_REPO:-${REPO_SLUG:-}}"
  if [ -z "$SGR_REPO" ]; then
    SGR_REPO=$(git -C "$TREE" remote get-url origin 2>/dev/null | sed -e 's#\.git/*$##' -e 's#/*$##' -e 's#:#/#g' \
      | awk -F/ 'NF >= 2 && $(NF - 1) != "" && $NF != "" { print $(NF - 1) "/" $NF }')
  fi
  [ -n "$SGR_REPO" ] || { _sgr_off "no repo"; return 0; }

  f="$OUT/reuse"
  printf '%s\n' "${SUITES[@]}" > "$f.in"
  rm -f "$f.run" "$f.reused" "$f.reds" "$f.fp"
  ( cd "$TREE" && SUITE_IMAGE_ID="$SGR_ID" bin/suite-reuse.sh plan --class builder --repo "$SGR_REPO" --ctx fly-testhost \
      --suites "$f.in" --run "$f.run" --reused "$f.reused" --reds "$f.reds" --fingerprints "$f.fp" \
      ${rerun[@]+"${rerun[@]}"} ) > "$f.plan.out" 2>&1
  cat "$f.plan.out"
  # The run, the reused and the reds together must be the input, once each.
  if ! [ -r "$f.run" ] || ! [ -r "$f.reused" ] || ! [ -r "$f.reds" ] \
     || [ "$({ cat "$f.run"; cut -f1 "$f.reused"; cut -f1 "$f.reds"; } | grep -v '^$' | LC_ALL=C sort)" \
          != "$(grep -v '^$' "$f.in" | LC_ALL=C sort)" ]; then
    _sgr_off "helper answer did not match its input"; return 0
  fi
  # A helper that is off still wrote the fingerprints: what runs is recorded.
  [ -s "$f.fp" ] && SGR_REC=1
  n=$(grep -m 1 '^suite-reuse: off (' "$f.plan.out")
  if [ -n "$n" ]; then n=${n#suite-reuse: off (}; _sgr_off "${n%)}"; return 0; fi
  mapfile -t SUITES < <(grep -v '^[[:space:]]*$' "$f.run")
  mapfile -t SGR_REDS < <(cut -f1 "$f.reds" | grep -v '^$')
  run=${#SUITES[@]}; reused=$(grep -c . "$f.reused"); red=${#SGR_REDS[@]}
  SGR_LINE="ran $run reused $reused green, $red red of $(grep -c . "$f.in") (image $SGR_ID)"
  echo "selection-gate: reuse: $SGR_LINE"
}

# sgr_record — after the verdict; appends `; recorded N result(s)`, `; record
# skipped (<why>)` or `; record failed` to SGR_LINE.
sgr_record() {
  local f="$OUT/reuse" imgs out n
  [ "$SGR_REC" = 1 ] && [ -n "$SGR_ID" ] || return 0
  [ -s "$OUT/run.txt" ] || return 0
  if [ "${#SUITES[@]}" = 0 ]; then SGR_LINE="$SGR_LINE; record skipped (nothing ran)"; return 0; fi
  # Every IMAGE line of the run must be the probed host image.
  imgs=$(sed -n 's/^IMAGE //p' "$OUT/run.txt" | LC_ALL=C sort -u)
  if [ -z "$imgs" ] || [ "$(grep -c . <<<"$imgs")" != 1 ] || [ "$(sfp_fly_image_id "$imgs")" != "$SGR_HOST" ]; then
    SGR_LINE="$SGR_LINE; record skipped (image moved)"; return 0
  fi
  printf '%s\n' "${SUITES[@]}" > "$f.sent"
  tr ',' '\n' <<<"$HNOTED" | sed 's/=.*//' > "$f.noted"
  awk -v sf="$f.sent" -v nf="$f.noted" '
    FILENAME == sf { sent[$0] = 1; next }
    FILENAME == nf { hn[$0] = 1; next }
    /^PASS tests\/[^ ]+\.sh$/ { s = $2; st[s] = st[s] "ok "; next }
    /^FAIL tests\/[^ ]+\.sh \(rc [0-9]+\)$/ { s = $2; r = $4; sub(/\)$/, "", r); st[s] = st[s] (r == "127" ? "x " : "fail "); next }
    /^(BLIND|RUNNER-FAILURE) / { st[$2] = st[$2] "x "; next }
    /^TIME [0-9]+ tests\/[^ ]+\.sh$/ { d[$3] = $2; next }
    END { for (s in st) if ((s in sent) && !(s in hn) && (st[s] == "ok " || st[s] == "fail "))
            printf "%s\t%s\t%s\n", s, substr(st[s], 1, length(st[s]) - 1), ((s in d) ? d[s] : 0) }
  ' "$f.sent" "$f.noted" "$OUT/run.txt" | LC_ALL=C sort > "$f.results"
  out=$(cd "$TREE" && bin/suite-reuse.sh record --repo "$SGR_REPO" --ctx fly-testhost \
      --run-key "${SUITE_REUSE_RUN_KEY:-selection-$(hostname 2>/dev/null || echo box)-$(date +%s)-$$}" \
      --fingerprints "$f.fp" --results "$f.results" --reused "$f.reused" 2>&1)
  printf '%s\n' "$out"
  n=$(sed -n 's/^suite-reuse: recorded \([0-9][0-9]*\) result(s) .*/\1/p' <<<"$out" | head -n 1)
  if [ -n "$n" ]; then SGR_LINE="$SGR_LINE; recorded $n result(s)"; else SGR_LINE="$SGR_LINE; record failed"; fi
}
