#!/bin/bash
# shellcheck shell=bash
# bin/lib/pool-result-row.sh — BH-2643: a pool job's result, kept OFF the
# machine. Sourced, never run: fly/builder-runner.sh writes the row, the hub's
# bin/fly-pool.sh REAP reads it. One file so the key cannot drift between them.
#
# WHY. The reap read a machine's result only over ssh, from /run/harness/RESULT
# — tmpfs. A machine that answered `job done` and then idled out to autostop
# (fly/builder-runner.sh, exit 0) took its RESULT with it, the reap found an
# unreachable `stopped` machine and counted a death, and two of those parked a
# healthy ticket (14 tickets on 2026-09-26, every one a pause deferral).
#
# THE ROW. `ledgers` kind=pool-result, key=<project>/<KEY>, upserted on
# (kind,key): one row per pool key, never per machine. detail is
# {"rline":<RESULT line 1, <=500 chars>,"machine":<fly machine id>,"at":<epoch>}.
# A pool REBASE row (RB-<pr>-<head8>, BH-7656) also carries "result": the whole
# RESULT file (<=2000 bytes), because the hub's mc_pool_rebase_apply needs its
# PR:/HEAD:/UNION: lines and not only the first one.
#
# A ROW IS ONLY THIS MACHINE'S RESULT WHEN IT SAYS SO. A reader takes it only
# when detail.machine is the machine being reaped, detail.at is no older than
# that machine's spawned_at (less POOL_RESULT_ROW_SKEW_S of clock slack), and
# rline carries a canonical RESULT prefix (bin/result-prefix-ok.sh). An earlier
# run of the same key, another machine's run, or noise is a MISS, never a
# result — and an unreadable ledger is rc 1, which no caller reads as one.

pool_result_row_key() { # pool_result_row_key <project> <KEY>
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  printf '%s/%s\n' "$1" "$2"
}

# pool_result_row_put <project> <KEY> <machine-id> <result-file> [full]
#   rc 0 written; rc 1 anything missing or the write failed. Never fatal: the
#   reap without a row behaves exactly as it did before this file existed.
#   `full` adds detail.result, the first 2000 bytes of <result-file>.
pool_result_row_put() {
  local p="${1:-}" key="${2:-}" mid="${3:-}" rf="${4:-}" full="${5:-}" k rline detail
  local jc="${HARNESS:-/root/harness}/bin/jobs-client.sh"
  [ -n "$p" ] && [ -n "$key" ] && [ -n "$mid" ] && [ -s "$rf" ] && [ -x "$jc" ] || return 1
  k=$(pool_result_row_key "$p" "$key") || return 1
  rline=$(head -1 "$rf" 2>/dev/null | head -c 500)
  [ -n "$rline" ] || return 1
  detail=$(jq -nc --arg r "$rline" --arg m "$mid" --argjson a "$(date -u +%s)" \
    '{rline:$r,machine:$m,at:$a}' 2>/dev/null) || return 1
  if [ "$full" = full ]; then
    detail=$(printf '%s' "$detail" | jq -c --rawfile res <(head -c 2000 "$rf") '. + {result:$res}' 2>/dev/null) || return 1
  fi
  timeout 30 "$jc" ledger-put pool-result "$k" result "$detail" >/dev/null 2>&1
}

# pool_result_row_get <project> <KEY> <machine-id> <spawned_at> [<outfile>]
#   rc 0 -> prints the row's rline: this machine's result, from this run. With
#           <outfile>, also writes detail.result (else the rline) to it.
#   rc 2 -> no usable row (absent, another machine's, older than the spawn, or
#           not a RESULT line)
#   rc 1 -> could not tell: ledger unreadable, detail unparseable, or a
#           spawned_at not in the shape bin/fly-pool.sh writes
pool_result_row_get() {
  local p="${1:-}" key="${2:-}" mid="${3:-}" spat="${4:-}" outf="${5:-}" k row rc detail rline rmid rat sp skew
  [ -n "$p" ] && [ -n "$key" ] && [ -n "$mid" ] || return 1
  command -v job_ledger_row >/dev/null 2>&1 || return 1
  skew="${POOL_RESULT_ROW_SKEW_S:-60}"
  case "$skew" in ''|*[!0-9]*) skew=60 ;; esac
  # STAMP's shape ('%Y-%m-%d %H:%M:%SZ'), or the ISO one; nothing else reaches
  # date(1), which would happily read "" as today.
  case "$spat" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][\ T][0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  sp=$(date -u -d "${spat/T/ }" +%s 2>/dev/null) || return 1 # determinism: ok date-empty-stamp case above admits only a full YYYY-MM-DD HH:MM:SSZ stamp
  k=$(pool_result_row_key "$p" "$key") || return 1
  row=$(job_ledger_row pool-result "$k"); rc=$?
  case "$rc" in 0) ;; 2) return 2 ;; *) return 1 ;; esac
  detail=$(printf '%s' "$row" | jq -r '.detail // empty' 2>/dev/null)
  [ -n "$detail" ] || return 1
  rline=$(printf '%s' "$detail" | jq -r '.rline // empty' 2>/dev/null) || return 1
  rmid=$(printf '%s' "$detail" | jq -r '.machine // empty' 2>/dev/null) || return 1
  rat=$(printf '%s' "$detail" | jq -r '.at // empty' 2>/dev/null) || return 1
  case "$rat" in ''|*[!0-9]*) return 1 ;; esac
  [ "$rmid" = "$mid" ] || return 2
  [ "$rat" -ge $((sp - skew)) ] || return 2
  [ -n "$rline" ] && "${HARNESS:-/root/harness}/bin/result-prefix-ok.sh" "$rline" || return 2
  if [ -n "$outf" ]; then
    printf '%s' "$detail" | jq -j --arg r "$rline" '(.result // "") | if . == "" then $r + "\n" else . end' > "$outf" 2>/dev/null || return 1
  fi
  printf '%s\n' "$rline"
}
