# shellcheck shell=bash
# bin/blocked-resolver.d/bh-7801-br-attempts.sh — the resolver record's
# attempts as jobs-DB rows (BH-7801, slice C1 of #4157). Sourced by the
# driver's blocked-resolver.d block; functions only.
#
# One ledgers row per attempt: kind `br_attempt`, key
# `<project>/<rkey>#<stamp digits>#<n6>`, status = the action, detail the
# attempt JSON (plus `bump`, and `verdict` + a ruling excerpt for an
# adjudication). bin/lib/br/record.sh br_save writes the rows for the attempts
# a save appends; br_load reads them back through GET /api/br-attempts
# (worker/jobs/src/routes/br-attempts.js) when the record file is gone. The
# record file stays the authority while it exists (dual write).

# bra_key <project> <rkey> <stamp> <n> — the row key. The stamp's digits sort
# by time; project and rkey are [A-Za-z0-9._-] (br_rkey), so `<p>/<rkey>#` is
# the prefix of one record's rows only.
bra_key() {
  local d n="${4:-0}"
  d=$(printf '%s' "${3:-}" | tr -cd '0-9')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s/%s#%s#%06d' "$1" "$2" "$d" "$((10#$n))"
}

# bra_put <project> <rkey> <attempt-json> <n> [bump] — ONE br_attempt row.
#   An `adjudicate` attempt whose detail is `ACCEPT — <path>` or
#   `REJECT — <path>` adds `verdict`. The ruling is read only when <path> is
#   exactly $ST/<project>/<rkey>.adjudication-run.txt: its last 1500 bytes.
#   The worker cuts a detail at 4000 characters, and a cut inside JSON is not
#   JSON, so the detail is kept at 3500 bytes or less: the ruling is cut to its
#   last 400 characters (cut:true), then dropped with the detail cut to 200,
#   then only {at, action, bump, verdict, cut} is kept.
#   rc = job_ledger_put's rc; rc 1 when the client or the input is missing.
bra_put() {
  local p="${1:-}" k="${2:-}" att="${3:-}" n="${4:-0}" bump="${5:-}"
  local act det at verdict="" path="" ruling="" detail
  [ -n "$p" ] && [ -n "$k" ] && [ -n "$att" ] || return 1
  command -v job_ledger_put >/dev/null 2>&1 || return 1
  act=$(printf '%s' "$att" | jq -r '.action // "" | tostring' 2>/dev/null) || return 1
  det=$(printf '%s' "$att" | jq -r '.detail // "" | tostring' 2>/dev/null) || return 1
  at=$(printf '%s' "$att" | jq -r '.at // "" | tostring' 2>/dev/null) || return 1
  if [ "$act" = adjudicate ]; then
    case "$det" in
      "ACCEPT — "*) verdict=ACCEPT; path="${det#ACCEPT — }" ;;
      "REJECT — "*) verdict=REJECT; path="${det#REJECT — }" ;;
    esac
    if [ -n "$verdict" ] && [ -n "${ST:-}" ] && [ "$path" = "$ST/$p/$k.adjudication-run.txt" ] && [ -f "$path" ] && [ -r "$path" ]; then
      ruling=$(tail -c 1500 "$path" 2>/dev/null | tr -d '\000')
    fi
  fi
  detail=$(printf '%s' "$att" | jq -c --arg b "$bump" --arg v "$verdict" --arg r "$ruling" --argjson max 3500 '
    def fits: (tojson | utf8bytelength) <= $max;
    def s: if . == null then "" else tostring end;
    ({at: (.at | s), action: (.action | s), reason: (.reason | s | .[:300]), detail: (.detail | s | .[:800])}
     + (if (.url | type) == "string" and .url != "" then {url: .url[:300]} else {} end)
     + (if (.head | type) == "string" and .head != "" then {head: .head[:64]} else {} end)
     + (if $b != "" then {bump: $b} else {} end)
     + (if $v != "" then {verdict: $v} else {} end)) as $base
    | (if $r == "" then $base else $base + {ruling: $r} end) as $full
    | if ($full | fits) then $full
      else ($base + (if $r == "" then {} else {ruling: $r[-400:]} end) + {cut: true}) as $c
      | if ($c | fits) then $c
        else ($base | .detail = .detail[:200] | .cut = true) as $d
        | if ($d | fits) then $d
          else {at: $base.at[:40], action: $base.action[:64], cut: true}
               + (if $b != "" then {bump: $b} else {} end) + (if $v != "" then {verdict: $v} else {} end)
          end
        end
      end' 2>/dev/null) || return 1
  [ -n "$act" ] || act=attempt
  job_ledger_put br_attempt "$(bra_key "$p" "$k" "$at" "$n")" "${act:0:128}" "$detail"
}

# bra_put_new <project> <rkey> <old-count> <record-json> [bump] — a row for each
#   attempt at index >= old-count (the ones this save appended). An attempt a
#   restore brought back (`restored:"ledger"`) already has its row and is
#   skipped. The bump goes on the last attempt only (br_record appends one).
#   rc 0 always: a missing row is a lost history line, the file holds it.
bra_put_new() {
  local p="$1" k="$2" old="${3:-0}" rec="$4" bump="${5:-}" last i a
  case "$old" in ''|*[!0-9]*) old=0 ;; esac
  last=$(printf '%s' "$rec" | jq -r '(.attempts // []) | length - 1' 2>/dev/null) || return 0
  while IFS=$'\t' read -r i a; do
    [ -n "$a" ] || continue
    if [ "$i" = "$last" ]; then bra_put "$p" "$k" "$a" "$i" "$bump" </dev/null; else bra_put "$p" "$k" "$a" "$i" </dev/null; fi
  done < <(printf '%s' "$rec" | jq -r --argjson o "$old" '
    (.attempts // []) | to_entries[] | select(.key >= $o) | select((.value | type) == "object")
    | select(.value.restored != "ledger") | "\(.key)\t\(.value | tojson)"' 2>/dev/null) >/dev/null 2>&1
  return 0
}

# bra_list <project> <rkey> — the record's attempts from the DB, oldest first,
#   as one compact JSON array in the record's attempt shape plus
#   restored:"ledger" (the ruling stays in the row). A row whose detail does
#   not parse is skipped. rc 1 (prints nothing): no client, an outage, a 404
#   (the route not deployed yet) or a body with no attempts array.
bra_list() {
  local q resp
  command -v _jobs_req >/dev/null 2>&1 || return 1
  q=$(jq -nr --arg p "${1:-}" --arg k "${2:-}" '"project=" + ($p | @uri) + "&rkey=" + ($k | @uri)') || return 1
  resp=$(_jobs_req GET "/api/br-attempts?$q" </dev/null) || return 1
  printf '%s' "$resp" | jq -ce '
    if (.attempts | type) != "array" then error("no attempts array") else
    [.attempts[] | .status as $s | (try (.detail | fromjson) catch null) | select(type == "object")
     | {at: (.at // ""), action: (.action // $s // ""), reason: (.reason // ""), detail: (.detail // "")}
       + (if (.url | type) == "string" then {url} else {} end)
       + (if (.head | type) == "string" then {head} else {} end)
       + (if (.verdict | type) == "string" then {verdict} else {} end)
       + {restored: "ledger"}] end' 2>/dev/null || return 1
}
