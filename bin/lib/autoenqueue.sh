#!/bin/bash
# bin/lib/autoenqueue.sh — BH-1668: a reviewed, green PR of any tier on a
# Mergify repo enqueues ITSELF. Sourced by bin/merge-conductor.sh, never run.
#
# WHY IT EXISTS. On 2026-09-23 the project-5 board had 12, then 20, harness PRs
# with an APPROVE on their head and `Build + Unit tests` green, all sitting at
# Mergify's "tick the box" prompt until a person posted `@mergifyio queue` on
# each. The conductor's own READY enqueue (mc_enqueue_mergify) asks under the App
# token, which Mergify refuses ("sender needs write permission"), and its label
# rule has never queued a PR (docs/MERGIFY.md §2).
#
# ae_project <project> <slug> <provider> <pbase> <tsv-row>...
#   Once per project per conductor tick, after every pr_worker has answered, over
#   the rows the tick's open-PR list already read (no second list call). A row
#   that passes every gate gets ONE `@mergifyio queue` comment per (PR, head),
#   posted with a PAT (gh_repo_use_pat: default, then admin, never the App).
#
# THE CONDUCTOR DECIDES, THIS STEP ONLY ASKS (BH-1668 review F1). A row is
# considered only if its pr_worker reached the READY arm's enqueue point THIS
# tick and said so with `ae_mark <project> ready <key> <head>`: past the
# classifier's provenance, iron-law, tightened, pre-arm and red-twice parks, the
# unread-diff refusal, the main-red freeze and the PR-dependency hold. On a
# Mergify repo `@mergifyio queue` IS a merge, so no subset of those is re-decided
# here. A worker whose own enqueue was witnessed or landed marks `asked`, and the
# row is left alone (no second ask). The mark lives in this tick's file under
# MC_TICK_DIR, keyed by MC_TICK_ID; no tick id = nothing is posted.
#
# THE GATES, cheapest first. A refusal is logged once per (PR, head, gate):
#   G0 provider mergify, MC_AUTOENQUEUE on       G1 not draft, base = pbase, not
#   train/*, not already queued, no hold label    G2 no enqueued row for this
#   head (worker ledger, file fallback, fail closed; an unusable ledger read is
#   read again after 2 s, 5 s and 10 s, BH-5463, BH-6433)   G3 APPROVE bound to THIS
#   head, or a standing MERGE/MERGE-WITH-NOTES on it; any standing non-merge
#   word refuses   GR (harness rows) the conductor's READY mark for this head,
#   this tick   G4 every required check completed/success on the head, latest run (the
#   knob MC_AUTOENQUEUE_CHECK when set, else the repo's .mergify.yml
#   queue_conditions check-success names — _ae_required_checks)   G5 the REST re-read: open, same head, base = pbase,
#   mergeable_state exactly `clean`   IL (external rows, AE_EXTERNAL=1, in GR's
#   place) mc_iron_law_scan on this head's diff, an unread diff refuses   G7 lead fence, ticket hold, PR hold, main-red
#   freeze, block gate, hotfix migration proof   G6 kill switches, MODE and
#   the conductor's own merge switch (MERGES): a
#   `WOULD enqueue` line and no GitHub write   G8 MC_AUTOENQUEUE_CAP posts per
#   tick, the rest DEFERRED and re-offered next tick.
#
# THE WRITE is write -> send -> confirm: `posting` on the ledger BEFORE the POST,
# `enqueued` only after a 201, so "enqueued" never means "not delivered". A crash
# between the two leaves `posting`, and the next tick reads the thread once
# before it sends again. A failed send is `failed-<n>`, and the attempt number
# rides in the status word itself so the 3-per-head cap holds on either ledger
# alone; after the third, one alert and no more sends on that head.
#
# xe_project (bin/lib/mc/external-enqueue.sh, BH-4580) offers the open PRs of
# NON-harness authors through the same _ae_offer with AE_EXTERNAL=1, after
# ae_project and under the same per-tick cap.
#
# It never merges, never labels, never pushes. Mergify's queue conditions and
# the ruleset stay the gates; ejection and re-entry stay the conductor's.
# gh-rest: no-graphql

AE_KIND=autoenqueue
AE_BODY='@mergifyio queue'
AE_MAX_FAILS=3

# The root is the caller's (BH-2613 contract): bin/merge-conductor.sh sets H
# before it sources this. No root = nothing written, nothing posted.
_ae_home() { printf '%s' "${MC_H:-${HARNESS:-${H:-}}}"; }
# The ledger keeps its tier2- name (BH-4572): renaming it would orphan in-flight `posting` lines.
_ae_file() { printf '%s/state/tier2-autoenqueue.txt' "$(_ae_home)"; }
_ae_now()  { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
_ae_log()  { mc_log "AUTOENQUEUE $*"; }
# _ae_once <word...> — rc 0 the first time this exact line is seen in the
# conductor's attempts file, so each refusal and WOULD line is said once per (PR, head).
# Through mc_attempt_has / mc_attempt_put (BH-2360), which bin/lib/mc/locks.sh
# defines: merge-conductor.sh sources merge-conductor-lib.sh before this file.
_ae_once() {
  local line="$*"
  mc_attempt_has "$line" 2>/dev/null && return 1
  mc_attempt_put "$line"
}
_ae_skip() { # _ae_skip <key> <head> <gate> <why>
  _ae_once aeskip "$1" "$2" "$3" && _ae_log "$1 not enqueued at ${2:0:8}: $3 — $4"
  # The holds a person lifts go to mc_hold_comment on every tick (BH-3456), past
  # _ae_once: the contract dedupes. block-gate is not one: bg_refuse comments.
  local hk=""
  case "$3" in hold) hk=hold-label ;; lead|ticket-hold|pr-hold|hotfix) hk="$3" ;; esac
  [ -n "$hk" ] && command -v mc_hold_comment >/dev/null 2>&1 && mc_hold_comment "$1" "$2" "$hk" "$4"
  return 0
}
_ae_alert() { # _ae_alert <key> <line>
  if command -v mc_alert >/dev/null 2>&1; then mc_alert "$1" AUTOENQUEUE "$2"; return; fi
  local r; r=$(_ae_home)
  [ -n "$r" ] && [ -x "$r/bin/alert-line.sh" ] \
    && HARNESS="$r" "$r/bin/alert-line.sh" "[merge-conductor] $1 AUTOENQUEUE — $2" >/dev/null 2>&1
  return 0
}

# _ae_file_status <url> <head> — the last status the file ledger holds, if any.
_ae_file_status() {
  awk -v u="$1" -v h="$2" '$1==u && $2==h {s=$3} END {if (s!="") print s}' "$(_ae_file)" 2>/dev/null
}
# _ae_status <url> <head> — rc 0 prints the row's status (ledger first, then the
# file); rc 2 a miss in both; rc 1 unreadable (worker down AND no file line):
# the caller skips this tick.
#
# ONE BLINK IS NOT AN OUTAGE (BH-5463, BH-6433). On 2026-10-08 08:15:32-39Z the
# ledger answered rc 1 for 18 READY PRs in a row and nothing was sent that tick;
# at 08:21Z the same reads answered rc 2. On 2026-10-13 07:15Z one read answered
# a 500 (`error code: 1101`) and one 2 s retry was too short. A final rc 1 is
# read again after each wait of _ae_backoff (default 2 5 10: four reads); a
# config fault (no-secret, no-url) is read once. Each failed read writes one
# log line with the endpoint, the answer word and the start of the body. Each
# read leaves _jobs_req's answer word in _ae_ledger_code_file and its body in
# <that>.body, and the loop leaves the read count in <that>.tries: a `$( )`
# loses JOBS_HTTP and JOBS_BODY.
AE_LEDGER_EP='GET /api/ledger?kind=autoenqueue'
_ae_status() {
  local st rc fst cf i=0 n w waits key
  cf=$(_ae_ledger_code_file)
  waits=$(_ae_backoff)
  set -- "$1" "$2" $waits
  n=$(( $# - 1 ))
  key="${1#https://github.com/}"; key="${key/\/pull\//#}"
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1)); rc=1
    { : > "$cf"; : > "$cf.body"; } 2>/dev/null
    if command -v job_ledger_get >/dev/null 2>&1; then
      st=$(JOBS_STATUS_FILE="$cf" JOBS_BODY_FILE="$cf.body" job_ledger_get "$AE_KIND" "$1@$2"); rc=$?
    fi
    [ "$rc" = 0 ] && { { echo "$i" > "$cf.tries"; } 2>/dev/null; printf '%s' "$st"; return 0; }
    # A worker miss is NOT "never sent": a PUT that failed while the file write
    # landed leaves the only record here, and the file holds nothing but our own
    # writes. So a file line answers a miss as well as an outage.
    fst=$(_ae_file_status "$1" "$2")
    [ -n "$fst" ] && { printf '%s' "$fst"; return 0; }
    [ "$rc" = 2 ] && return 2
    { echo "$i" > "$cf.tries"; } 2>/dev/null
    _ae_log "$key at ${2:0:8}: ledger read $i/$n failed — $AE_LEDGER_EP $(_ae_ledger_code) body=$(_ae_ledger_body)"
    case "$(_ae_ledger_code)" in no-secret|no-url) return 1 ;; esac
    [ "$i" -lt "$n" ] || break
    w=$((i + 2)); _ae_sleep "${!w}"
  done
  return 1
}
_ae_sleep() { sleep "$1"; }
# _ae_ledger_code_file — where this tick's last ledger read left its answer word.
_ae_ledger_code_file() {
  printf '%s/%s.%s.ae-ledger' "${MC_TICK_DIR:-$(_ae_home)/state/merge-conductor/tick}" \
    "$(_ae_safe "${MC_TICK_ID:-notick}")" "$(_ae_safe "${AE_P:-noproject}")"
}
# _ae_ledger_code — http=<code>, curl_rc=<n>, no-secret, no-url or unknown.
_ae_ledger_code() {
  local c; c=$(head -1 "$(_ae_ledger_code_file)" 2>/dev/null)
  case "$c" in http=2*) c="$c (no status in the answer)" ;; '') c=unknown ;; esac
  printf '%s' "$c"
}
# _ae_ledger_body — the last read's answer body as one line of at most 200
# bytes (CR, LF and TAB to a space, other control bytes dropped), or `-`.
_ae_ledger_body() {
  local b
  b=$(head -c 200 "$(_ae_ledger_code_file).body" 2>/dev/null | tr '\r\n\t' '   ' | tr -d '\000-\037\177')
  printf '%s' "${b:--}"
}
# _ae_ledger_tries — how many reads the last _ae_status made, or `?`.
_ae_ledger_tries() {
  local t; t=$(head -1 "$(_ae_ledger_code_file).tries" 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t='?' ;; esac
  printf '%s' "$t"
}
# _ae_noretry — why an unusable ledger read is NOT read again, or nothing. After
# the burst alert (ae_project) a hard outage would cost every later row ~17 s.
_ae_noretry() {
  if [ "${MC_AE_LEDGER_RETRY:-1}" = 0 ]; then printf 'mc_ae_ledger_retry=0'
  elif [ "${AE_LEDGER_ALERTED:-0}" = 1 ]; then printf 'the ledger burst alert fired this tick'; fi
}
# _ae_backoff — the waits in seconds before each re-read, space separated:
# nothing when _ae_noretry says so, else MC_AE_LEDGER_BACKOFF (1 to 5 integers,
# each 0..60). Unset or empty is the default `2 5 10`; anything else invalid is
# the default and one log line a tick.
_ae_backoff() {
  [ -n "$(_ae_noretry)" ] && return 0
  local v="${MC_AE_LEDGER_BACKOFF:-}" t out="" k=0
  if [ -n "$v" ]; then
    for t in $v; do
      case "$t" in ''|*[!0-9]*) out=""; break ;; esac
      [ "$((10#$t))" -le 60 ] || { out=""; break; }
      k=$((k + 1)); out="${out:+$out }$((10#$t))"
    done
    [ "$k" -le 5 ] || out=""
    if [ -z "$out" ]; then
      _ae_once aebackoff "${MC_TICK_ID:-notick}" "$v" && _ae_log "MC_AE_LEDGER_BACKOFF='$v' is not 1 to 5 integers of 0..60 — using 2 5 10"
    fi
  fi
  printf '%s' "${out:-2 5 10}"
}
# _ae_ledger_why — "<code>, read <n> times, waits 2s 5s 10s", "<code>, retried
# once after <w>s" (one wait) or "<code>, no retry: <why>".
_ae_ledger_why() {
  local n c w waits=""; n=$(_ae_noretry); c=$(_ae_ledger_code)
  if [ -n "$n" ]; then printf '%s, no retry: %s' "$c" "$n"; return; fi
  case "$c" in no-secret|no-url) printf '%s, no retry: a config fault' "$c"; return ;; esac
  set -- $(_ae_backoff)
  if [ "$#" = 1 ]; then printf '%s, retried once after %ss' "$c" "$1"; return; fi
  for w in "$@"; do waits="$waits ${w}s"; done
  printf '%s, read %s times, waits%s' "$c" "$(_ae_ledger_tries)" "$waits"
}
# _ae_record <url> <head> <status> <detail-json> — ledger + file, rc 1 when BOTH failed.
_ae_record() {
  local lrc=1 frc=1
  if command -v job_ledger_put >/dev/null 2>&1; then job_ledger_put "$AE_KIND" "$1@$2" "$3" "$4" && lrc=0; fi
  mkdir -p "$(dirname "$(_ae_file)")" 2>/dev/null
  { printf '%s %s %s %s\n' "$1" "$2" "$3" "$(_ae_now)" >> "$(_ae_file)"; } 2>/dev/null && frc=0
  [ "$lrc" = 0 ] || [ "$frc" = 0 ]
}
_ae_fails() { # _ae_fails <url> <head> [status] — failed sends on this head: the
  # larger of the file's failed lines and the n a `failed-<n>` status carries, so
  # a file append that failed while the ledger PUT landed still counts (review F4).
  local f s="${3:-}" n=0
  f=$(awk -v u="$1" -v h="$2" '$1==u && $2==h && $3 ~ /^failed/ {n++} END {print n+0}' "$(_ae_file)" 2>/dev/null)
  case "$s" in failed-*) n="${s#failed-}" ;; esac
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  case "$f" in ''|*[!0-9]*) f=0 ;; esac
  [ "$f" -gt "$n" ] && n="$f"
  echo "$n"
}
_ae_safe() { printf '%s' "${1//[^A-Za-z0-9._-]/_}"; }
# _ae_tick_file <project> — this tick's hand-off from the project's pr_workers.
_ae_tick_file() {
  printf '%s/%s.%s.autoenqueue' "${MC_TICK_DIR:-$(_ae_home)/state/merge-conductor/tick}" \
    "$(_ae_safe "${MC_TICK_ID:-notick}")" "$(_ae_safe "$1")"
}
# ae_mark <project> ready|asked <key> <head> — called by pr_worker's READY arm.
# `ready`: every conductor hold before the merge switch passed on this head.
# `asked`: the conductor's own enqueue was witnessed (or the PR landed) this tick.
ae_mark() {
  [ -n "${MC_TICK_DIR:-}$(_ae_home)" ] || return 0
  local f; f=$(_ae_tick_file "$1")
  mkdir -p "${f%/*}" 2>/dev/null
  { printf '%s %s %s\n' "$2" "$3" "$4" >> "$f"; } 2>/dev/null
}
_ae_marked() { grep -qxF "$2 $3 $4" "$(_ae_tick_file "$1")" 2>/dev/null; }
_ae_since() { # when this head's last `posting` was written, for the thread read
  awk -v u="$1" -v h="$2" '$1==u && $2==h && $3=="posting" {t=$4} END {print t}' "$(_ae_file)" 2>/dev/null
}

# _ae_pr_hold <num> — IS THE PR ITSELF HELD? (lead round, 2026-09-24). A human
# who writes `HOLD:` on the PR — project-5 #3214, a sign-in identity change —
# must stop the one step here that IS a merge on a Mergify repo. G7's
# to_lane_hold now reads the PR thread too (bin/lib/ticket-ownership.sh); this
# gate asks bin/lib/hold.sh's hold_check_thread directly as well, so the step
# stays fenced on a box whose ticket-ownership lib is absent or older. One
# reader, one classifier: the second read of an unchanged thread is an ETag 304.
#   rc 0 clear · 1 held (AE_PR_HOLD_WHY says which line) · 2 unreadable
_ae_pr_hold() {
  local v rc f
  AE_PR_HOLD_WHY=""
  if ! command -v hold_check_thread >/dev/null 2>&1; then
    for f in "$(dirname "${BASH_SOURCE[0]}")/hold.sh" "$(_ae_home)/bin/lib/hold.sh"; do
      # shellcheck source=bin/lib/hold.sh
      [ -r "$f" ] && { . "$f" 2>/dev/null; break; }
    done
    command -v hold_check_thread >/dev/null 2>&1 || { AE_PR_HOLD_WHY="no hold library on this box"; return 2; }
  fi
  v=$(hold_check_thread "$AE_SLUG" "$1"); rc=$?
  AE_PR_HOLD_WHY="${v#*	}"
  return "$rc"
}

# ae_mergify_admit_checks <slug> — the `check-success` names under
#   `queue_conditions:` in the repo's .mergify.yml queue_rules, one per line (the
#   union over every rule). These are the checks Mergify requires to ADMIT a PR,
#   which is the only question this step asks. `merge_conditions:` are NOT read:
#   Mergify evaluates them on the batch draft, and a check that runs only there
#   reads completed/skipped on the PR head (#2220's .mergify.yml: 3 admission
#   checks, 7 merge checks), so requiring it here would refuse every row for ever
#   (review of #2215). mc_mergify_required_checks (the stuck-batch pass's
#   reader) is the strict union and stays exactly as it is.
#   rc 0 names (possibly none); rc 1 the yml could not be read; rc 2 no policy
#   reader on this box; rc 3 a queue_conditions shape this reader does not
#   understand, with the reason on stdout (review round 2 of #2215).
#   Shapes read: a block list indented under the key OR at the key's own indent
#   (YAML allows both), `- queue_conditions:` as a rule's first key, and a
#   one-line inline list `[ a, "check-success = b" ]` (comma split is
#   quote-aware). `or:` and `not:` subtrees are skipped (alternatives and
#   negations are not requirements); `and:` is read. Refused, never guessed: an inline list that does not close on
#   its own line, and any other scalar after the key.
ae_mergify_admit_checks() {
  local b64 yml out rc
  command -v mc_policy_get >/dev/null 2>&1 || return 2
  mc_policy_get b64 "$1" mergify "repos/$1/contents/.mergify.yml" || return 1
  b64=$(jq -r '.content // empty' <<<"$b64" 2>/dev/null) || return 1
  [ -n "$b64" ] || return 1
  yml=$(printf '%s' "$b64" | tr -d '\n\r ' | base64 -d 2>/dev/null) || yml=""
  [ -n "$yml" ] || yml="$b64"
  out=$(awk -v q="'" '
    function ind(s) { match(s, /^[ ]*/); return RLENGTH }
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function unq(s,  c) {
      c = substr(s, 1, 1)
      if ((c == "\"" || c == q) && length(s) >= 2 && substr(s, length(s), 1) == c) return substr(s, 2, length(s) - 2)
      return s
    }
    # cond <one condition> — print its check-success name, once.
    function cond(s,  v, c, i) {
      s = unq(trim(s))
      if (!match(s, /(^|[[:space:]"\047])check-success[[:space:]]*=[[:space:]]*/)) return
      v = substr(s, RSTART + RLENGTH)
      c = substr(v, 1, 1)
      if (c == "\"" || c == q) { v = substr(v, 2); i = index(v, c); if (i) v = substr(v, 1, i - 1) }
      else { sub(/[[:space:]]+#.*$/, "", v); v = trim(v) }
      if (v != "" && !seen[v]++) print v
    }
    # flow <text inside [ ]> — split on commas outside quotes.
    function flow(s,  i, ch, cur, qc) {
      cur = ""; qc = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (qc != "") { if (ch == qc) qc = ""; cur = cur ch; continue }
        if (ch == "\"" || ch == q) { qc = ch; cur = cur ch; continue }
        if (ch == ",") { cond(cur); cur = ""; continue }
        cur = cur ch
      }
      cond(cur)
    }
    function refuse(why) { print "SHAPE: " why; bad = 1; exit 3 }
    /^queue_rules:/ { inq = 1; inc = 0; next }
    inq && /^[^[:space:]#-]/ { inq = 0; inc = 0 }
    !inq || /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    inc && (ind($0) < cind || (ind($0) == cind && $0 !~ /^[ ]*-/)) { inc = 0; skip = 0 }
    # An `or:` (alternatives) or `not:` subtree is not a list of REQUIRED
    # checks (lead MINOR 2 on #2215): skip it whole; `and:` is descended.
    skip && ind($0) > sind { next }
    skip { skip = 0 }
    inc && /^[ ]*-[ ]*(or|not):/ { skip = 1; sind = ind($0); next }
    /^[ ]*(-[ ]+)?queue_conditions:/ {
      match($0, /^[ ]*(-[ ]+)?/); cind = RLENGTH
      v = $0; sub(/^[ ]*(-[ ]+)?queue_conditions:[[:space:]]*/, "", v)
      if (v ~ /^#/) v = ""
      if (v == "") { inc = 1; next }
      if (substr(v, 1, 1) == "[") {
        v = substr(v, 2); sub(/[[:space:]]+#[^"\047]*$/, "", v); v = trim(v)
        if (substr(v, length(v), 1) != "]") refuse("line " NR ": an inline [ list that does not close on its own line")
        flow(substr(v, 1, length(v) - 1)); next
      }
      refuse("line " NR ": queue_conditions is neither a list nor [ ... ]")
    }
    !inc { next }
    { v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v)
      if (substr(v, 1, 1) != "\"" && substr(v, 1, 1) != q) sub(/[[:space:]]+#.*$/, "", v)
      else sub(/[[:space:]]+#[^"\047]*$/, "", v)
      cond(v) }' <<<"$yml"); rc=$?
  if [ "$rc" = 3 ]; then printf '%s\n' "$(grep '^SHAPE: ' <<<"$out" | tail -1)"; return 3; fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# _ae_required_checks <slug> — the check names G4 requires, one per line.
#   rc 0 with the names; rc 1 = the repo's own list could not be read (G4 then
#   refuses every row this tick — unreadable is never "no checks required").
#   Order (Lane D, 2026-09-24):
#     1. MC_AUTOENQUEUE_CHECK, when an operator set it: that name alone.
#     2. the ADMISSION checks of the repo's .mergify.yml (ae_mergify_admit_checks).
#     3. AE_LEGACY_CHECK, the documented fallback: a box without the policy
#        reader, or queue_conditions that name no check at all.
#   The single hardcoded name was the whole default until this change, and it is
#   project-5's: on cromford no check carries it, so every READY row there
#   was refused "'Build + Unit tests' is absent" and never self-enqueued.
#   The STATUS contexts in qsc_list (bin/lib/queue-status-contexts.sh:
#   `lead-verdict`, BH-3348, and `prequeue-verdict`, BH-5441) are dropped from
#   the list: G4 reads check RUNS, where a commit status never appears, and the
#   conductor publishes both itself (mc_enqueue_mergify, pq_gate). Mergify
#   still refuses a head that lacks one. Without the lib, only the lead-verdict
#   context is dropped, as before.
command -v qsc_list >/dev/null 2>&1 \
  || { [ -r "${BASH_SOURCE[0]%/*}/queue-status-contexts.sh" ] && . "${BASH_SOURCE[0]%/*}/queue-status-contexts.sh"; }
AE_LEGACY_CHECK='Build + Unit tests'
_ae_required_checks() {
  local names rc skip
  [ -n "${MC_AUTOENQUEUE_CHECK:-}" ] && { printf '%s\n' "$MC_AUTOENQUEUE_CHECK"; return 0; }
  names=$(ae_mergify_admit_checks "$1"); rc=$?
  if command -v qsc_list >/dev/null 2>&1; then skip=$(qsc_list)
  else skip=$(command -v vs_context >/dev/null 2>&1 && vs_context || echo "${LEAD_VERDICT_CONTEXT:-lead-verdict}"); fi
  [ "$rc" = 0 ] && names=$(grep -vxF -f <(printf '%s\n' "$skip") <<<"$names")
  [ "$rc" = 1 ] && return 1
  # A shape the reader cannot read is refused LOUDLY, never guessed: guessing
  # read no names and fell back to the legacy name, which a repo may well carry.
  if [ "$rc" = 3 ]; then
    _ae_once aeshape "$1" "$(date -u +%F)" \
      && _ae_log "$1 .mergify.yml queue_conditions shape not understood (${names#SHAPE: }) — no READY row on this repo self-enqueues until it is a block list or a one-line [ ... ] list"
    return 1
  fi
  if [ "$rc" = 0 ] && [ -n "$(tr -d '[:space:]' <<<"$names")" ]; then printf '%s\n' "$names"; return 0; fi
  printf '%s\n' "$AE_LEGACY_CHECK"
}

# _ae_gates <row> — G1..G5 and G7 for one row. rc 0 = eligible, and AE_* are set
# for the action. rc 1 = not this tick (the reason is already logged, or silent).
_ae_gates() {
  local num url head br draft _ms _mg _ps inq lbl base _up _cr
  # For ae_project's burst count (BH-5463): AE_GATE=ledger on a G2 ledger skip,
  # AE_LEDGER_READ=1 when G2 got an answer.
  AE_GATE=""; AE_LEDGER_READ=0; AE_GATE_KEY=""
  IFS=$'\t' read -r num url head br draft _ms _mg _ps inq lbl base _up _cr <<<"$1"
  [ "$lbl" = "-" ] && lbl=""; [ "$base" = "-" ] && base=""
  [ -n "$num" ] && [ -n "$head" ] || return 1
  local key="$AE_SLUG#$num" h st rc
  # G1 — off the list row, no read at all.
  [ "$draft" = true ] && return 1
  case "$br" in train/*) return 1 ;; esac
  [ "$inq" = true ] && return 1
  case ",$lbl," in *,queued,*|*,checking,*) return 1 ;; esac
  [ "$base" = "$AE_PBASE" ] || { _ae_skip "$key" "$head" base "based on ${base:-unknown}, not $AE_PBASE — a stacked PR waits for its parent"; return 1; }
  for h in ${AE_HOLDS//,/ }; do
    case ",$lbl," in *,"$h",*) _ae_skip "$key" "$head" hold "labelled $h"; return 1 ;; esac
  done
  # G2 — this head already enqueued (or out of retries)?
  AE_RECOVER=0; AE_STATUS=""
  st=$(_ae_status "$url" "$head"); rc=$?
  if [ "$rc" = 1 ]; then
    AE_GATE=ledger; AE_GATE_KEY="$key"
    # BH-5617: this skip was silent for 150 rows on 2026-10-08. The reporter
    # caps itself per (lane, project, reason), so one per PR is safe.
    command -v sentry_report >/dev/null 2>&1 && sentry_report warning merge-conductor autoenqueue-ledger-unreadable \
      "$key not enqueued: $AE_LEDGER_EP unreadable after $(_ae_ledger_tries) attempts (last $(_ae_ledger_code))" \
      "$(jq -nc --arg p "${AE_P:-}" --arg k "$key" --arg h "$head" --arg c "$(_ae_ledger_code)" --arg e "$AE_LEDGER_EP" --arg a "$(_ae_ledger_tries)" \
        '{project:$p,pr:$k,head:$h,ledger_code:$c,endpoint:$e,attempts:$a}')"
    _ae_skip "$key" "$head" ledger "the autoenqueue ledger is unreadable ($(_ae_ledger_why)) and the file has no line — nothing sent this tick"; return 1
  fi
  AE_LEDGER_READ=1
  if [ "$rc" = 0 ]; then
    AE_STATUS="$st"
    case "$st" in
      enqueued) return 1 ;;
      posting) AE_RECOVER=1 ;;
      failed*) [ "$(_ae_fails "$url" "$head" "$st")" -lt "$AE_MAX_FAILS" ] || return 1 ;;
    esac
  fi
  # G3 — the verdict is about THIS head.
  local rec v _p rs job sl sw ok=0
  rec=$(mc_record_for "$url" 2>/dev/null || true)
  IFS=$'\t' read -r v _p rs job _ <<<"$(mc_verdict "$url" "$rec" 2>/dev/null)"
  [ "$v" = APPROVE ] && [ "$rs" = "$head" ] && ok=1
  sl=""; rc=1
  if command -v vd_standing >/dev/null 2>&1; then sl=$(vd_standing "$AE_SLUG" "$num" "$head" 2>/dev/null); rc=$?; fi
  sw="${sl%%$'\t'*}"
  if [ "$rc" = 0 ]; then
    case "$sw" in
      MERGE|MERGE-WITH-NOTES) ok=1 ;;
      *) _ae_skip "$key" "$head" verdict "a standing $sw verdict on this head"; return 1 ;;
    esac
  elif [ "$rc" = 2 ] && [ "$ok" = 1 ]; then
    _ae_skip "$key" "$head" standing "the standing-verdict read is unreadable — nothing sent this tick"; return 1
  fi
  if [ "$ok" != 1 ]; then
    case "${v:--}" in
      -) return 1 ;;   # not a harness-reviewed PR: silent
      *) _ae_skip "$key" "$head" verdict "verdict ${v} on ${rs:0:8}, not an APPROVE on this head"; return 1 ;;
    esac
  fi
  # GR — the conductor cleared THIS head READY this tick and did not enqueue it
  # itself. A file read, so it sits before the first network read. An external
  # row (AE_EXTERNAL=1, bin/lib/mc/external-enqueue.sh) never has a pr_worker,
  # so it never gets a mark: IL below stands in for it.
  if [ "${AE_EXTERNAL:-0}" != 1 ]; then
    if _ae_marked "$AE_P" asked "$key" "$head"; then
      _ae_skip "$key" "$head" asked "the conductor's own enqueue was witnessed this tick — no second ask"; return 1
    fi
    _ae_marked "$AE_P" ready "$key" "$head" \
      || { _ae_skip "$key" "$head" conductor "the conductor did not clear this head READY this tick (parked, held or not reached — its own log line says why)"; return 1; }
  fi
  # G4 — every required check, latest run, on this head (AE_CHECKS, resolved
  # once per project in ae_project by _ae_required_checks).
  local t cw c
  if [ -z "$AE_CHECKS" ]; then
    _ae_skip "$key" "$head" check "the repo's required checks could not be read (.mergify.yml unreadable) — asked again next tick"; return 1
  fi
  # ONE unfiltered read per row, however many names are required (review of
  # #2215); a page that does not hold every run is unreadable, never green.
  t=$(mktemp "${TMPDIR:-/tmp}/ae.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$AE_SLUG/commits/$head/check-runs?per_page=100" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; _ae_skip "$key" "$head" check "the check-runs read failed (HTTP ${GH_REST_STATUS:-000}) — asked again next tick"; return 1; fi
  if ! jq -e '((.total_count // 0) <= ((.check_runs // []) | length))' "$t" >/dev/null 2>&1; then
    rm -f "$t"; _ae_skip "$key" "$head" check "the check-runs page does not hold every run on this head — asked again next tick"; return 1
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cw=$(jq -r --arg c "$c" '[.check_runs[]? | select(.name==$c)] | sort_by(.started_at // "") | last
          | if . == null then "absent" else (.status + "/" + (.conclusion // "none")) end' "$t" 2>/dev/null)
    [ "$cw" = completed/success ] || { rm -f "$t"; _ae_skip "$key" "$head" check "'$c' is ${cw:-unreadable} on this head"; return 1; }
  done <<<"$AE_CHECKS"
  rm -f "$t"
  # G5 — the pre-act re-read over REST.
  local pst phd pbs pms login
  t=$(mktemp "${TMPDIR:-/tmp}/ae.XXXXXX") || return 1
  rc=0; gh_rest GET "repos/$AE_SLUG/pulls/$num" > "$t" || rc=$?
  if [ "$rc" != 0 ]; then rm -f "$t"; _ae_skip "$key" "$head" reread "the PR re-read failed (HTTP ${GH_REST_STATUS:-000}) — asked again next tick"; return 1; fi
  read -r pst phd pbs pms login < <(jq -r '[.state // "?", .head.sha // "?", .base.ref // "?", .mergeable_state // "?", .user.login // "-"] | @tsv' "$t" 2>/dev/null)
  rm -f "$t"
  [ "$pst" = open ] && [ "$phd" = "$head" ] && [ "$pbs" = "$AE_PBASE" ] \
    || { _ae_skip "$key" "$head" reread "the re-read says state=${pst:-?} head=${phd:0:8} base=${pbs:-?}"; return 1; }
  [ "$pms" = clean ] || { _ae_skip "$key" "$head" mergeable "mergeable_state $pms, not clean"; return 1; }
  # IL — external rows only (BH-4580): the iron-law scan the READY mark carries
  # for a harness row, on this head's diff. After G4/G5, so a red or unclean PR
  # never buys a diff read. An unread diff, or no scanner, is never "no hits".
  if [ "${AE_EXTERNAL:-0}" = 1 ]; then
    local il
    if ! command -v mc_pr_diff >/dev/null 2>&1 || ! command -v mc_iron_law_scan >/dev/null 2>&1; then
      _ae_skip "$key" "$head" iron-law-read "no iron-law scanner on this box — nothing sent this tick"; return 1
    fi
    t=$(mktemp "${TMPDIR:-/tmp}/ae.XXXXXX") || return 1
    rc=0; mc_pr_diff "$url" "$t" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$t"; _ae_skip "$key" "$head" iron-law-read "the diff could not be read (HTTP ${GH_REST_STATUS:-000}) — nothing sent this tick"; return 1; fi
    il=$(mc_iron_law_scan "$t"); rm -f "$t"
    case "$il" in ''|*[!0-9]*) _ae_skip "$key" "$head" iron-law-read "the iron-law scan answered '${il}' — nothing sent this tick"; return 1 ;; esac
    [ "$il" -gt 0 ] && { _ae_skip "$key" "$head" iron-law "$il iron-law hit(s) on this head"; return 1; }
  fi
  # G7 — the fences the conductor already honours, called, not re-implemented.
  if command -v to_lane_lead_fence >/dev/null 2>&1; then
    TO_LEAD_CLEARED=0; to_lane_lead_fence "$AE_P" "$AE_SLUG" "$num" "$head" "$login"; rc=$?
    # Three gate words, because only a HELD lead PR is a hold comment (BH-3456):
    # an unread fence is not one, and a cleared one is lead-mergify's to say.
    case "$rc" in
      0) _ae_skip "$key" "$head" lead "a lead PR is never enqueued here (BH-1606)"; return 1 ;;
      1) [ "${TO_LEAD_CLEARED:-0}" != 1 ] || { _ae_skip "$key" "$head" lead-cleared "a lead PR is never enqueued here (BH-1606): cleared, left for the lead"; return 1; } ;;
      *) _ae_skip "$key" "$head" lead-read "a lead PR is never enqueued here (BH-1606): the lead fence could not be read (${TO_LEAD_KIND:-unknown})"; return 1 ;;
    esac
  fi
  if command -v to_lane_hold >/dev/null 2>&1 && to_lane_hold "$AE_P" "$AE_SLUG" "$num"; then
    _ae_skip "$key" "$head" ticket-hold "the ticket is held (BH-1526)"; return 1
  fi
  _ae_pr_hold "$num"; rc=$?
  case "$rc" in
    1) _ae_skip "$key" "$head" pr-hold "the PR itself is held (${AE_PR_HOLD_WHY}) — RESUME on the PR lifts it"; return 1 ;;
    2) _ae_skip "$key" "$head" pr-hold-read "the PR thread could not be read for a HOLD (${AE_PR_HOLD_WHY}) — nothing sent this tick"; return 1 ;;
  esac
  if [ -n "${MAIN_RED:-}" ] && ! { command -v main_red_exempt >/dev/null 2>&1 && main_red_exempt "$AE_SLUG" "$num" "$url" "$head" "${lbl:--}"; }; then
    _ae_skip "$key" "$head" main-red "$AE_SLUG main is red (flags/$MAIN_RED)"; return 1
  fi
  # bg_scan_read, not bg_scan: the READY worker already scanned this head this
  # tick and noted the refusal streak once; a second note would halve
  # BLOCK_GATE_STREAK_K (review F3).
  if command -v bg_scan_read >/dev/null 2>&1; then
    local issue=""
    [ "$("$(_ae_home)/bin/fleet-conf.sh" "$AE_P" board_prefix 2>/dev/null)" = "-" ] && issue=$(mc_issue_of "$rec" "$br")
    bg_scan_read "$AE_SLUG" "$num" "$url" "$head" "$issue" >/dev/null 2>&1; rc=$?
    [ "$rc" = 0 ] || { _ae_skip "$key" "$head" block-gate "the block gate answered rc $rc (1 a BLOCK stands, 2 unreadable)"; return 1; }
  fi
  if command -v hotfix_pr_is >/dev/null 2>&1 && hotfix_pr_is "$lbl" "$rec"; then
    local hp; hp=$(mc_hotfix_proof "$AE_SLUG" "$num" "$lbl" "$rec" "${AE_P:-}" 2>/dev/null)
    case "$hp" in ok|n/a) ;; *) _ae_skip "$key" "$head" hotfix "hotfix migration proof $hp (hotfix-migration-hold)"; return 1 ;; esac
  fi
  AE_NUM="$num"; AE_URL="$url"; AE_HEAD="$head"; AE_JOB="${job:--}"; AE_KEY="$key"
  return 0
}

# _ae_send — the one write. rc 0 = posted (or proven already posted).
_ae_send() {
  local num="$AE_NUM" url="$AE_URL" head="$AE_HEAD" key="$AE_KEY" job="$AE_JOB"
  local t rc since cid detail n had tok
  if [ "$AE_RECOVER" = 1 ]; then
    since=$(_ae_since "$url" "$head"); [ -n "$since" ] || since=$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')
    t=$(mktemp "${TMPDIR:-/tmp}/ae.XXXXXX") || return 1
    rc=0; gh_rest GET "repos/$AE_SLUG/issues/$num/comments?since=$since&per_page=100" > "$t" || rc=$?
    if [ "$rc" != 0 ]; then rm -f "$t"; _ae_skip "$key" "$head" recover "a posting row and the thread is unreadable — nothing sent this tick"; return 1; fi
    cid=$(jq -r --arg b "$AE_BODY" '[.[]? | select((.body // "" | gsub("^\\s+|\\s+$";"")) == $b)] | last | .id // empty' "$t" 2>/dev/null)
    rm -f "$t"
    if [ -n "$cid" ]; then
      detail=$(jq -nc --arg a "$(_ae_now)" --arg h "$head" --arg p "$url" --arg j "$job" --arg c "$cid" \
        '{enqueued_at:$a,enqueued_head:$h,pr:$p,job:$j,comment_id:($c|tonumber? // $c),recovered:true}')
      _ae_record "$url" "$head" enqueued "$detail"
      _ae_log "$key a crashed send had landed (comment $cid on the thread) — row set to enqueued at ${head:0:8}, nothing re-sent"
      return 0
    fi
  fi
  # The PAT, never the App token, asked BEFORE anything is written: no PAT means
  # nothing is sent, so no `posting` row may claim otherwise. The caller's token
  # comes back exactly as it was.
  had="${GH_TOKEN+x}"; tok="${GH_TOKEN:-}"
  if ! gh_repo_use_pat "$AE_SLUG"; then
    if [ -n "$had" ]; then export GH_TOKEN="$tok"; else unset GH_TOKEN; fi
    [ "$AE_STATUS" = not-configured ] || _ae_record "$url" "$head" not-configured '{"reason":"no PAT can see the repo"}'
    local day; day="alert $AE_SLUG not-configured $(date -u +%F)"
    if ! grep -qxF "$day" "$(_ae_file)" 2>/dev/null; then
      echo "$day" >> "$(_ae_file)"
      _ae_alert "$AE_SLUG" "no PAT can see $AE_SLUG, so approved green PRs are not enqueued: Mergify refuses @mergifyio queue from the App token. Needs the default gh PAT or GH_ADMIN_TOKEN in env/github-admin.env with write on $AE_SLUG (the operator)"
    fi
    return 1
  fi
  if [ "$AE_RECOVER" != 1 ] && ! _ae_record "$url" "$head" posting "$(jq -nc --arg h "$head" --arg p "$url" --arg j "$job" --arg a "$(_ae_now)" '{head:$h,pr:$p,job:$j,at:$a}')"; then
    if [ -n "$had" ]; then export GH_TOKEN="$tok"; else unset GH_TOKEN; fi
    _ae_log "$key the posting row could not be written (worker and file both refused) — nothing sent"; return 1
  fi
  t=$(mktemp "${TMPDIR:-/tmp}/ae.XXXXXX") || { if [ -n "$had" ]; then export GH_TOKEN="$tok"; else unset GH_TOKEN; fi; return 1; }
  rc=0; gh_rest POST "repos/$AE_SLUG/issues/$num/comments" -f "body=$AE_BODY" > "$t" || rc=$?
  if [ -n "$had" ]; then export GH_TOKEN="$tok"; else unset GH_TOKEN; fi
  if [ "$rc" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ]; then
    cid=$(jq -r '.id // empty' "$t" 2>/dev/null); rm -f "$t"
    detail=$(jq -nc --arg a "$(_ae_now)" --arg h "$head" --arg p "$url" --arg j "$job" --arg c "${cid:-}" \
      '{enqueued_at:$a,enqueued_head:$h,pr:$p,job:$j,comment_id:($c|tonumber? // $c)}')
    _ae_record "$url" "$head" enqueued "$detail" || _ae_log "$key posted but the enqueued row could not be written — the posting row resolves next tick"
    if [ "$job" != "-" ] && command -v job_artifact_put >/dev/null 2>&1; then
      job_artifact_put enqueued "$head" "$(jq -c '{enqueued_at,enqueued_head,pr}' <<<"$detail")" "$job" \
        || _ae_log "$key the enqueued artifact could not be written on job $job — the ledger row stands"
    fi
    _ae_log "$key posted @mergifyio queue at ${head:0:8} as pat:$GH_REPO_PAT_RUNG — Mergify's queue conditions decide from here$([ "${AE_EXTERNAL:-0}" = 1 ] && printf ' (external PR)')"
    return 0
  fi
  n=$(( $(_ae_fails "$url" "$head" "$AE_STATUS") + 1 ))
  _ae_record "$url" "$head" "failed-$n" "$(jq -nc --arg r "HTTP ${GH_REST_STATUS:-000} $(head -c 120 "$t" 2>/dev/null | head -1)" --argjson n "$n" '{reason:$r,attempts:$n}')"
  rm -f "$t"
  _ae_log "$key the @mergifyio queue POST failed (HTTP ${GH_REST_STATUS:-000}, attempt $n of $AE_MAX_FAILS)"
  [ "$n" -ge "$AE_MAX_FAILS" ] && _ae_alert "$key" "@mergifyio queue failed $n times on ${head:0:8} (HTTP ${GH_REST_STATUS:-000}); not retried on this head. Check the PAT's write access on $AE_SLUG: $url"
  return 1
}

# _ae_send_locked — _ae_send under a per-PR flock, with the ledger re-read
#   inside it (review of #2215, nit 1). A keyed tick (bin/lib/keyed-wake.sh) and
#   the cron tick can both pass the gates for one (PR, head); whichever takes the
#   lock second reads the other's `enqueued` row and asks nothing; a `failed-<n>`
#   row at the AE_MAX_FAILS cap is refused here exactly as at G2. A `posting`
#   row read here was left by a crash (a live sender would still hold the lock),
#   so it takes the thread-read recovery path. No lock in 30 s: nothing sent.
_ae_send_locked() {
  local lk
  lk="$(_ae_home)/locks/autoenqueue-$(_ae_safe "$AE_KEY").lock"
  mkdir -p "${lk%/*}" 2>/dev/null
  (
    flock -w 30 7 2>/dev/null || { _ae_log "$AE_KEY not enqueued at ${AE_HEAD:0:8}: another tick is asking for this PR right now — asked again next tick"; exit 1; }
    st=$(_ae_status "$AE_URL" "$AE_HEAD"); rc=$?
    if [ "$rc" = 0 ]; then
      case "$st" in
        enqueued) _ae_log "$AE_KEY not enqueued at ${AE_HEAD:0:8}: already enqueued by another tick — no second ask"; exit 1 ;;
        posting) AE_RECOVER=1 ;;
        # The same cap G2 applies (review round 2 of #2215): another tick may
        # have spent the last retry between G2 and this lock.
        failed*) [ "$(_ae_fails "$AE_URL" "$AE_HEAD" "$st")" -lt "$AE_MAX_FAILS" ] \
                   || { _ae_log "$AE_KEY not enqueued at ${AE_HEAD:0:8}: out of retries on this head ($st) after another tick's send — no further ask"; exit 1; } ;;
      esac
      AE_STATUS="$st"
    elif [ "$rc" = 1 ]; then
      _ae_log "$AE_KEY not enqueued at ${AE_HEAD:0:8}: the ledger went unreadable before the POST ($(_ae_ledger_why)) — nothing sent this tick"; exit 1
    fi
    _ae_send
  ) 7>>"$lk"
}

# _ae_init <project> <slug> <provider> <pbase> — rc 1 = nothing to do for this
#   project (MC_AUTOENQUEUE=0, not Mergify, no root). Sets AE_P, AE_SLUG,
#   AE_PBASE, AE_HOLDS and AE_CAP. Shared by ae_project and xe_project, so every
#   MC_AUTOENQUEUE* knob is read in this file.
_ae_init() {
  [ "${MC_AUTOENQUEUE:-1}" != 0 ] || return 1
  [ "${3:-}" = mergify ] || return 1
  [ -n "$(_ae_home)" ] || { _ae_log "$2 no harness root — nothing enqueued this tick"; return 1; }
  AE_P="$1"; AE_SLUG="$2"; AE_PBASE="${4:-main}"
  AE_HOLDS="${MC_AUTOENQUEUE_HOLD_LABELS:-hold,do-not-merge}"
  AE_CAP="${MC_AUTOENQUEUE_CAP:-10}"
  case "$AE_CAP" in ''|*[!0-9]*) AE_CAP=10 ;; esac
  AE_BURST="${MC_AE_LEDGER_BURST:-5}"
  case "$AE_BURST" in ''|*[!0-9]*) AE_BURST=5 ;; esac
  [ "$AE_BURST" -ge 1 ] || AE_BURST=1
  return 0
}

# A RUN OF LEDGER SKIPS IS ONE ALERT (BH-5463): more than MC_AE_LEDGER_BURST
# rows in a row skipped at G2 is an outage, not a blink. One _ae_alert per
# project tick, then no more retries this tick (_ae_noretry). The run is counted
# in _ae_offer, so the rows ae_project and xe_project offer in one tick are one
# run, and one alert, as they share one ledger. ae_project resets it.
# _ae_burst_count — after _ae_gates: extend the run on a ledger skip, end it on a read.
_ae_burst_count() {
  if [ "${AE_GATE:-}" = ledger ]; then
    AE_LB_RUN=$((${AE_LB_RUN:-0} + 1)); AE_LB_KEYS="${AE_LB_KEYS:+$AE_LB_KEYS }$AE_GATE_KEY"
    if [ "$AE_LB_RUN" -gt "${AE_BURST:-5}" ] && [ "${AE_LEDGER_ALERTED:-0}" = 0 ]; then
      AE_LEDGER_ALERTED=1; AE_LB_AT="$AE_LB_RUN"
      _ae_alert "$AE_SLUG" "$AE_LB_RUN READY rows in a row were skipped because the autoenqueue ledger was unreadable (last: $(_ae_ledger_code)) — nothing was sent for $AE_LB_KEYS; the next tick reads again"
    fi
  elif [ "${AE_LEDGER_READ:-0}" = 1 ]; then
    _ae_burst_end
  fi
}
# _ae_burst_end — log the end of an alerted run once, and start counting afresh.
_ae_burst_end() {
  [ "${AE_LB_AT:-0}" -gt 0 ] && [ "${AE_LB_RUN:-0}" -gt "$AE_LB_AT" ] && _ae_log "$AE_SLUG ledger skip run ended at $AE_LB_RUN rows (alerted at $AE_LB_AT)"
  AE_LB_RUN=0; AE_LB_KEYS=""; AE_LB_AT=0
  return 0
}

# _ae_offer <row> — the gates, G6, then the cap and the send. AE_POSTED and
#   AE_DEFERRED count across ae_project and xe_project in one tick, so the two
#   share MC_AUTOENQUEUE_CAP.
_ae_offer() {
  local why grc
  _ae_gates "$1"; grc=$?
  _ae_burst_count
  [ "$grc" = 0 ] || return 0
  # G6 — last, so a WOULD line means "every other gate passed".
  why=""
  if command -v flag_active >/dev/null 2>&1; then
    flag_active automerge-disabled && why="flags/automerge-disabled"
    [ -z "$why" ] && flag_active "automerge-disabled-$AE_P" && why="flags/automerge-disabled-$AE_P"
    [ -z "$why" ] && flag_active "paused-$AE_P" && why="flags/paused-$AE_P"
  fi
  [ -z "$why" ] && [ "${MODE:-observe}" != merge ] && why="conductor mode ${MODE:-observe}"
  # The READY arm's own merge switch (security review 4): MODE=merge implies
  # it today, and this keeps the two from drifting apart.
  [ -z "$why" ] && [ "${MERGES:-0}" != 1 ] && why="conductor merges off (MERGES=${MERGES:-0})"
  if [ -n "$why" ]; then
    _ae_once aewould "$AE_KEY" "$AE_HEAD" && _ae_log "WOULD enqueue $AE_KEY @${AE_HEAD:0:8} ($why) — no GitHub write"
    return 0
  fi
  if [ "$AE_POSTED" -ge "$AE_CAP" ]; then AE_DEFERRED=$((AE_DEFERRED + 1)); return 0; fi
  _ae_send_locked && AE_POSTED=$((AE_POSTED + 1))
  return 0
}

ae_project() {
  # FIRST, before any early return: xe_project reads these after this call.
  AE_POSTED=0; AE_DEFERRED=0
  AE_LEDGER_ALERTED=0; AE_LB_RUN=0; AE_LB_KEYS=""; AE_LB_AT=0
  _ae_init "${1:-}" "${2:-}" "${3:-}" "${4:-}" || return 0
  shift 4
  # No tick id = no tick-scoped READY file, and a shared `notick` file would let
  # an old tick's mark stand in for this one. Nothing is posted.
  if [ -z "${MC_TICK_ID:-}" ]; then _ae_log "$AE_SLUG no MC_TICK_ID — the READY hand-off cannot be read, nothing enqueued this tick"; return 0; fi
  AE_CHECKS=$(_ae_required_checks "$AE_SLUG") || AE_CHECKS=""
  [ "$AE_CAP" -gt 0 ] || return 0
  local row
  for row in "$@"; do
    [ -n "$row" ] || continue
    _ae_offer "$row"
  done
  _ae_burst_end
  [ "$AE_DEFERRED" -gt 0 ] && _ae_log "$AE_SLUG DEFERRED $AE_DEFERRED over MC_AUTOENQUEUE_CAP=$AE_CAP — re-offered next tick"
  return 0
}
