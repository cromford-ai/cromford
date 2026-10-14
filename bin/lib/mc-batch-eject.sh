#!/bin/bash
# bin/lib/mc-batch-eject.sh — A PR MERGIFY DID NOT NAME GOES BACK IN AFTER A
# BATCH EJECTION; THE ONE IT NAMED IS TOLD WHAT FAILED (BH-4428). Sourced by
# bin/merge-conductor.sh, never executed.
#
# THE CASE (2026-10-04). Ten PRs were ejected from Mergify batches between
# 01:36 and 11:17Z, nine of them innocent, every one green on its own head. The
# BH-636 re-entry arm sat each one on `WAIT_CI queue-ejected — push a fix` for
# good: its only gate (fr_reentry_gate, BH-3776) attributes a batch failure by
# failing SUITE name against the PR's files, the check that failed was
# `Pure-logic gate fixtures` (a job name, so `unknown`), and `unknown` on the
# UNSTABLE head Mergify leaves behind never re-queues. Mergify's own verdict, in
# the same dequeue comment, was never read. No merge to main for seven hours.
#
# WHAT THE PAYLOADS ACTUALLY SAY. Every one of the nine was "identified as the
# failing PR" on a SINGLE-PR draft (`checking #4121 on main (a00ade0)`), most of
# them on the same base a00ade0 with the same check: main itself was red, and
# Mergify's bisect named every PR it tested alone. So "named or alone" cannot
# be the whole rule, or none of the nine is rescued.
#
# THE RULE (bej_reentry_gate, called by the arm in place of fr_reentry_gate).
# The newest dequeued mergify[bot] comment bound to THIS head is read (by
# created_at,id like fr_dequeue_batch), with the title of the draft its last
# `Checks failed` line names:
#   culprit    that line says `identified as the failing PR` on a draft with
#              other PRs in it, or the draft held this PR alone and fewer than
#              MC_BATCH_EJECT_SHARED_MIN PRs were tested alone on that base and
#              failed a check this one failed. fr_reentry_gate decides exactly
#              as before (A2: BH-3776's foreign path still applies); when it
#              does not re-queue, ONE PR comment per head names the draft, the
#              failing checks and their run links. A PR tested alone gets that
#              comment one tick later, from its cached verdict, so a second PR
#              ejected alone on the same base the same tick can still make
#              both `sharedred` first.
#   sharedred  tested alone, and at least MC_BATCH_EJECT_SHARED_MIN distinct
#              PRs were tested alone on the same base and failed a check in
#              common (the `bejsolo` ledger): main was red, not this PR.
#              Re-queued once per head when the main-red freeze is down, the
#              head's own checks are green, and the base branch has moved off
#              that base (one branch read; a failed read waits). No culprit
#              comment.
#   bystander  the draft held two or more PRs, this PR was not named, and
#              Mergify listed the failing checks. Re-queued once per head
#              when the freeze is down and the head's own checks are green,
#              with no suite attribution: Mergify already said whose it was.
#   unknown    anything else (no dequeue comment, another head's, a failed
#              read, a conflict or review dequeue with no `Failing checks:`):
#              fr_reentry_gate exactly as before.
# A bystander first asks the impact map (BH-4980, bin/lib/mc-batch-impact.sh)
# which members reach the failing test. With MC_BATCH_IMPACT=2 and the freeze
# down, exactly one is ejected (`impactculprit`: one comment naming the test)
# and the rest skip the solo re-run; several keeps the solo re-run for the
# candidates only. Mode 1 (the default) only logs.
# The requeue itself is the arm's own branch: BH-636's `requeued` mark first,
# the tick budget, mc_requeue_mergify, and fr_requeue_note's once-per-head PR
# line (FR_LINE). A second ejection of the same head never reaches this gate
# (the arm's strike branch answers BLOCKED_HUMAN queue-ejected-twice first),
# and neither does MC_QUEUE_REENTRY=0.
#
# State, all in MC_ATTEMPTS (append-only):
#   bejsolo <slug> <base7> <check> <key>   one per (base, check, PR): the ledger
#   bejv <key> <head> <word> <base7> <branch> <draft> <checks> <links>
#                                          the verdict, read once per head
#   bejculprit <key> <head>                the culprit comment, written BEFORE
#                                          the post (a crash costs the head its
#                                          comment, never a comment per tick)
#   bejlog <key> <head> <word>             one log line per (head, word)
# A check name is stored %-encoded (space, comma, percent), so every field is
# one word. No root of its own: MC_ATTEMPTS and MC_STATE_DIR are the conductor's.

BEJ_PAYLOAD_RE='-\*- Mergify Payload -\*-(?<p>[\s\S]*?)-\*- Mergify Payload End -\*-'
BEJ_WORD=""; BEJ_BASE=""; BEJ_BRANCH=""; BEJ_DRAFT=""; BEJ_CHECKS=""; BEJ_LINKS=""; BEJ_CACHED=0
BEJ_SOLO_WORD=""; BEJ_IMPACT_UNIT=""; BEJ_IMPACT_N=""; BEJ_IMPACT_LINE=""
# BH-4980: which member of a failed batch can reach the failing test. Absent,
# the gate below decides exactly as before (bim_verdict is never defined).
# shellcheck source=bin/lib/mc-batch-impact.sh
. "${BASH_SOURCE[0]%/*}/mc-batch-impact.sh" 2>/dev/null || true
# BH-6336: a batch that failed only because a CI shard left no verdict.
# Absent, the gate below decides exactly as before (nv_gate is never defined).
# shellcheck source=bin/lib/mc-noverdict.sh
. "${BASH_SOURCE[0]%/*}/mc-noverdict.sh" 2>/dev/null || true

# _bej_knob <ENV> <default> — a merge-conductor lane knob for this project, a
#   non-negative integer, else the default (the _fr_knob pattern).
_bej_knob() {
  local v
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null)
  else v="${!1:-}"; fi
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

# _bej_enc <text> / _bej_dec <text> — one check name as one word, and back.
_bej_enc() { local s="${1//%/%25}"; s="${s// /%20}"; printf '%s' "${s//,/%2C}"; }
_bej_dec() { local s="${1//%20/ }"; s="${s//%2C/,}"; printf '%s' "${s//%25/%}"; }

# bej_parse_dequeue <comments-json> <head>
#   -> "<draft# or ->\t<named 0|1>\t<checks, %-encoded, comma-joined, or ->\t<run links, comma-joined, - per check without one, or ->"
#   rc 0 the newest dequeued mergify[bot] comment is bound to this head
#   rc 1 there is none, or it is about another head
#   rc 2 the JSON could not be read
#   draft and named come from the LAST `Checks failed` line (Mergify appends
#   one per bisect round; the last is the verdict). No network, no clock.
bej_parse_dequeue() {
  local raw="$1" head="$2" line d n s c l
  line=$(jq -r --arg re "$BEJ_PAYLOAD_RE" '
    def enc: gsub("%"; "%25") | gsub(" "; "%20") | gsub(","; "%2C");
    [ .[] | select(type == "object" and (.user.login // "") == "mergify[bot]"
                   and ((.body // "") | type == "string") and ((.body // "") | test($re)))
          | select(((.body | capture($re).p | fromjson? | .state) // "") == "dequeued") ]
    | sort_by([(.created_at // ""), (.id // 0)]) | last
    | if . == null then "NONE" else
        .body as $b
        | ([$b | split("\n")[] | select(test("\\*\\*Checks failed\\*\\*"))] | last // "") as $cf
        | (($cf | capture("on draft #(?<d>[0-9]+)") | .d) // "") as $d
        | (if ($cf | test("identified as the failing PR")) then "1" else "0" end) as $n
        | ([$b | scan("Left the queue\\*\\*[^\\n]*? at `([0-9a-fA-F]{7,40})`")] | last // [""] | .[0]) as $s
        | ($b | split("Failing checks:") | if length > 1 then (.[1] | split("\n## ") | .[0]) else "" end) as $fc
        | [$fc | split("\n")[] | select(test("^[[:space:]]*[-*] "))
                | { c: ((capture("`(?<c>[^`]+)`") | .c) // ""),
                    u: ((capture("\\]\\((?<u>https?://[^)[:space:]]+)\\)") | .u) // "-") }
                | select(.c != "")] as $bul
        | ([$bul[] | .c | enc] | join(",")) as $c
        | ([$bul[] | .u] | join(",")) as $l
        | [$d, $n, $s, $c, $l] | map(if . == "" then "-" else . end) | @tsv end' <<<"$raw" 2>/dev/null) || return 2
  [ -n "$line" ] || return 2
  [ "$line" = NONE ] && return 1
  IFS=$'\t' read -r d n s c l <<<"$line"
  [ "${#s}" -ge 7 ] || return 1
  case "$head" in "$s"*) ;; *) return 1 ;; esac
  printf '%s\t%s\t%s\t%s\n' "$d" "$n" "$c" "$l"
}

# bej_eject_runs_parse <comments-json> <slug> [n] — the failing batch runs of the
#   last <n> (default 2) Mergify dequeues on a PR, newest first, one line per
#   failing check: "<run url> (<check> on draft #<d>, dequeued <created_at>)".
#   A dequeue that names a check without a link gives its draft's URL instead
#   ("<draft url> (<check> on draft #<d>, ...)"); one with no draft and no link
#   is skipped. Pure: reads the JSON only (BH-6000 part 5).
#   rc 0 printed at least one line, 1 none, 2 the JSON could not be read.
bej_eject_runs_parse() {
  local raw="$1" slug="${2:-}" n="${3:-2}" out
  case "$n" in ''|*[!0-9]*) n=2 ;; esac
  out=$(jq -r --arg re "$BEJ_PAYLOAD_RE" --arg repo "https://github.com/$slug" --argjson n "$n" '
    [ .[]? | select(type == "object" and (.user.login // "") == "mergify[bot]"
                    and ((.body // "") | type == "string") and ((.body // "") | test($re)))
           | select(((.body | capture($re).p | fromjson? | .state) // "") == "dequeued") ]
    | sort_by([(.created_at // ""), (.id // 0)]) | reverse | .[:$n][]
    | .created_at as $at
    | .body as $b
    | ([$b | split("\n")[] | select(test("\\*\\*Checks failed\\*\\*"))] | last // "") as $cf
    | (($cf | capture("on draft #(?<d>[0-9]+)") | .d) // "") as $d
    | ($b | split("Failing checks:") | if length > 1 then (.[1] | split("\n## ") | .[0]) else "" end) as $fc
    | $fc | split("\n")[] | select(test("^[[:space:]]*[-*] "))
    | { c: ((capture("`(?<c>[^`]+)`") | .c) // ""),
        u: ((capture("\\]\\((?<u>https?://[^)[:space:]]+)\\)") | .u) // "") }
    | select(.c != "")
    | (if .u != "" then .u elif ($d != "" and $repo != "https://github.com/") then "\($repo)/pull/\($d)" else "" end) as $url
    | select($url != "")
    | "\($url) (\(.c) on draft #\(if $d == "" then "?" else $d end), dequeued \($at // "?"))"' <<<"$raw" 2>/dev/null) || return 2
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# bej_eject_runs <slug> <num> [n] — bej_eject_runs_parse over the PR's comments
#   (one REST read). rc 1 none, 2 unreadable.
bej_eject_runs() {
  local slug="$1" num="$2" n="${3:-2}" raw
  command -v gh_rest_issue_comments >/dev/null 2>&1 || return 2
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || return 2
  bej_eject_runs_parse "$raw" "$slug" "$n"
}

# bej_draft_members <draft title>
#   -> "<member numbers, space-separated>\t<base, lower-case short sha>\t<branch>\t<stacked 0|1>"
#   `merge queue: checking #4121 + #4221 together on main (a00ade0)`. The
#   `, stacked on #P` tail names the PR this draft is built on, never a member.
#   rc 1 the title is not a Mergify checking title. No network, no clock.
bej_draft_members() {
  local t="$1" stacked=0 head base branch m
  case "$t" in *"checking #"*) ;; *) return 1 ;; esac
  case "$t" in *", stacked on #"*) stacked=1; t="${t%%, stacked on #*}" ;; esac
  base=$(sed -nE 's/.* on ([^ ]+) \(([0-9a-fA-F]{7,40})\)$/\2/p' <<<"$t" | tr 'A-F' 'a-f')
  branch=$(sed -nE 's/.* on ([^ ]+) \(([0-9a-fA-F]{7,40})\)$/\1/p' <<<"$t")
  [ -n "$base" ] && [ -n "$branch" ] || return 1
  head="${t%% on "$branch" (*}"; head="${head#*checking }"
  m=$(grep -oE '#[0-9]+' <<<"$head" | tr -d '#' | tr '\n' ' ')
  m="${m% }"
  [ -n "$m" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$m" "$base" "$branch" "$stacked"
}

# bej_word <pr> <named 0|1> <members> -> culprit | solo | bystander | unknown
#   named in a batch = culprit; the draft held this PR alone = solo (a culprit
#   unless the shared-red ledger says otherwise); in a batch of two or more and
#   not named = bystander; a draft that does not hold this PR = unknown.
bej_word() {
  local pr="$1" named="$2" m=" $3 " n
  case "$m" in *" $pr "*) ;; *) echo unknown; return 0 ;; esac
  read -ra n <<<"$3"
  if [ "${#n[@]}" = 1 ]; then echo solo
  elif [ "$named" = 1 ]; then echo culprit
  else echo bystander; fi
}

# bej_solo_note <slug> <base> <checks> <key> — one ledger line per check.
bej_solo_note() {
  local c
  local -a cs
  IFS=, read -ra cs <<<"$3"
  for c in "${cs[@]}"; do
    [ -n "$c" ] && [ "$c" != - ] || continue
    mc_attempt_has "bejsolo $1 $2 $c $4" 2>/dev/null || mc_attempt_put "bejsolo $1 $2 $c $4"
  done
}

# bej_shared_count <slug> <base> <checks> — distinct PRs tested alone on this
#   base that failed at least one of these checks (this PR included once noted).
bej_shared_count() {
  local c pat=""
  local -a cs
  IFS=, read -ra cs <<<"$3"
  for c in "${cs[@]}"; do [ -n "$c" ] && [ "$c" != - ] && pat+="$c"$'\n'; done
  [ -n "$pat" ] && [ -s "${MC_ATTEMPTS:-}" ] || { echo 0; return 0; }
  awk -v s="$1" -v b="$2" -v p="$pat" '
    BEGIN { n = split(p, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    $1 == "bejsolo" && $2 == s && $3 == b && ($4 in want) && !seen[$5]++ { k++ }
    END { print k + 0 }' "$MC_ATTEMPTS"
}

# _bej_log_once <word> <key> <head> <text> — one log line per (head, word).
#   Merge mode marks it; observe mode keeps a marker file (it marks nothing).
_bej_log_once() {
  local mk
  if [ "${MERGES:-0}" = 1 ]; then
    mc_attempt_has "bejlog $2 $3 $1" 2>/dev/null && return 0
    mc_attempt_put "bejlog $2 $3 $1"
  elif [ -n "${MC_STATE_DIR:-}" ]; then
    mk="$MC_STATE_DIR/batch-eject/log_$(printf '%s_%s_%s' "$1" "$2" "$3" | tr -c 'A-Za-z0-9._-' '_')"
    [ -e "$mk" ] && return 0
    mkdir -p "${mk%/*}" 2>/dev/null && : > "$mk" 2>/dev/null
  fi
  mc_log "$1 $2 $3 — $4"
}

# bej_verdict <slug> <num> <key> <head> — sets BEJ_WORD (culprit | solo |
#   bystander | unknown), BEJ_BASE, BEJ_BRANCH, BEJ_DRAFT, BEJ_CHECKS,
#   BEJ_LINKS, and BEJ_CACHED=1 when it came from an earlier tick's `bejv`
#   line (no read at all). Any failed read is `unknown`, never a bystander,
#   and is not cached: the next tick reads again.
bej_verdict() {
  local slug="$1" num="$2" key="$3" head="$4" line raw t d n c l m base br st w rc
  BEJ_WORD=unknown; BEJ_BASE=""; BEJ_BRANCH=""; BEJ_DRAFT=""; BEJ_CHECKS=""; BEJ_LINKS=""; BEJ_CACHED=0
  if [ -s "${MC_ATTEMPTS:-}" ] && line=$(grep -m1 -F "bejv $key $head " "$MC_ATTEMPTS" 2>/dev/null) && [ -n "$line" ]; then
    read -r _ _ _ w base br d c l <<<"$line"
    case "$w" in culprit|solo|bystander) ;; *) return 0 ;; esac
    BEJ_WORD="$w"; BEJ_BASE="$base"; BEJ_BRANCH="$br"; BEJ_DRAFT="$d"; BEJ_CHECKS="$c"; BEJ_LINKS="$l"; BEJ_CACHED=1
    return 0
  fi
  command -v gh_rest_issue_comments >/dev/null 2>&1 || return 0
  mc_rest_var raw gh_rest_issue_comments "$slug" "$num" 1000 || return 0
  rc=0; line=$(bej_parse_dequeue "$raw" "$head") || rc=$?
  [ "$rc" = 0 ] || return 0
  IFS=$'\t' read -r d n c l <<<"$line"
  # No `Failing checks:` list: a conflict or review dequeue, not a red batch.
  [ "$c" != - ] && [ "$d" != - ] || return 0
  mc_rest_var raw gh_rest GET "repos/$slug/pulls/$d" || return 0
  t=$(jq -r '.title // empty' <<<"$raw" 2>/dev/null) || return 0
  st=$(bej_draft_members "$t") || return 0
  IFS=$'\t' read -r m base br _ <<<"$st"
  w=$(bej_word "$num" "$n" "$m")
  [ "$w" = unknown ] && return 0
  BEJ_WORD="$w"; BEJ_BASE="$base"; BEJ_BRANCH="$br"; BEJ_DRAFT="$d"; BEJ_CHECKS="$c"; BEJ_LINKS="$l"
  mc_attempt_put "bejv $key $head $w $base $br $d $c $l"
}

# _bej_head_green <slug> <head> <raw mergeState> — CLEAN, or UNSTABLE only
#   through Mergify's own leftover checks (fr_mergify_only_unstable). rc 1 not.
_bej_head_green() {
  [ "$3" = CLEAN ] && return 0
  [ "$3" = UNSTABLE ] && command -v fr_mergify_only_unstable >/dev/null 2>&1 || return 1
  fr_mergify_only_unstable "$1" "$2"
}

# _bej_checks_text <checks> — "`a`, `b`" for a sentence.
_bej_checks_text() {
  local c out=""
  local -a cs
  IFS=, read -ra cs <<<"$1"
  for c in "${cs[@]}"; do out+="${out:+, }\`$(_bej_dec "$c")\`"; done
  printf '%s' "$out"
}

# _bej_plain <checks> — "a, b" for a reason column.
_bej_plain() {
  local c out=""
  local -a cs
  IFS=, read -ra cs <<<"$1"
  for c in "${cs[@]}"; do out+="${out:+, }$(_bej_dec "$c")"; done
  printf '%s' "$out"
}

# bej_culprit_note <slug> <num> <key> <head> — ONE PR comment per head naming
#   the draft, each failing check and its run link. Merge mode only; the mark
#   goes BEFORE the post; a failed post is logged and never retried.
bej_culprit_note() {
  local slug="$1" num="$2" key="$3" head="$4" bf i lead
  local -a cs ls
  [ "${MERGES:-0}" = 1 ] || return 0
  mc_attempt_has "bejculprit $key $head" 2>/dev/null && return 0
  mc_attempt_put "bejculprit $key $head"
  if [ "$BEJ_WORD" = impactculprit ]; then
    lead="Mergify's batch draft #$BEJ_DRAFT on $BEJ_BRANCH ($BEJ_BASE) failed $(_bej_checks_text "$BEJ_IMPACT_UNIT"). Of the $BEJ_IMPACT_N PRs in it, only this one changes files that test reaches, so it's out of the queue. The others go back in the queue without a bisect."
  elif [ "$BEJ_WORD" = solo ]; then
    lead="Mergify tested this PR alone in draft #$BEJ_DRAFT on $BEJ_BRANCH ($BEJ_BASE) and it failed, so it is out of the queue."
  else
    lead="Mergify's batch draft #$BEJ_DRAFT on $BEJ_BRANCH ($BEJ_BASE) failed and Mergify named this PR as the one that broke it, so it is out of the queue."
  fi
  IFS=, read -ra cs <<<"$BEJ_CHECKS"; IFS=, read -ra ls <<<"$BEJ_LINKS"
  bf=$(mktemp "${TMPDIR:-/tmp}/bej-body.XXXXXX") || return 0
  {
    printf '%s\n\nFailing checks:\n' "$lead"
    for i in "${!cs[@]}"; do
      if [ -n "${ls[$i]:-}" ] && [ "${ls[$i]}" != - ]; then printf -- '- `%s`: %s\n' "$(_bej_dec "${cs[$i]}")" "${ls[$i]}"
      else printf -- '- `%s`\n' "$(_bej_dec "${cs[$i]}")"; fi
    done
    printf '\nPush a fix to this branch and the new head goes back into the queue on its own.\n'
  } > "$bf"
  gh_rest_comment "$slug" "$num" "$bf" \
    || mc_log "$key the culprit comment could not be posted on ${head:0:8} (HTTP ${GH_REST_STATUS:-?}); not retried"
  rm -f "$bf"
  mc_log "BATCH_EJECT_CULPRIT $key $head draft=#$BEJ_DRAFT checks=$(_bej_dec "$BEJ_CHECKS")"
}

# _bej_solo_gate <slug> <num> <key> <head> <raw mergeState> — the batch's solo
#   re-run (bs_batch, bin/lib/mc-prequeue.d/batch-solo.sh, BH-4550), asked in
#   front of the rule below for a member of a multi-PR draft. rc 0 re-queue
#   (clean: the batch's failing suites passed with only this PR on the base),
#   rc 1 not (reproduces: FR_STATE/FR_WHY park it for the resolver; or clean
#   under the freeze or on a red head), rc 2 no solo verdict for this head
#   (pending, could-not-run, none, or a reproduce under the freeze): the rule
#   below decides, unchanged.
_bej_solo_gate() {
  local slug="$1" num="$2" key="$3" head="$4" ms="$5" t w
  BEJ_SOLO_WORD=""
  t=$(mktemp "${TMPDIR:-/tmp}/bej-bs.XXXXXX" 2>/dev/null) || return 2
  # In this shell, so the BS_* it sets survive; its lines come back through a file.
  bs_batch "$slug" "$BEJ_DRAFT" > "$t" 2>/dev/null
  w=$(awk -v n="$num" -v h="$head" '$1 == n && $2 == h { print $3; exit }' "$t" 2>/dev/null); rm -f "$t"
  BEJ_SOLO_WORD="$w"
  case "$w" in
    reproduces)
      [ -n "${MAIN_RED:-}" ] && return 2
      FR_STATE=BLOCKED_HUMAN
      FR_WHY="prequeue-red: $BS_SUITES (reproduced alone on ${BS_BASE:0:12}, batch #$BEJ_DRAFT)"
      _bej_log_once BATCH_SOLO_REPRODUCES "$key" "$head" "draft #$BEJ_DRAFT failed $BS_SUITES, and they fail with only this PR merged onto ${BS_BASE:0:12}: parked for the resolver"
      return 1 ;;
    clean)
      if [ -n "${MAIN_RED:-}" ]; then
        FR_WHY="queue-ejected — main-red freeze is on; re-queued when it lifts"
        return 1
      fi
      _bej_head_green "$slug" "$head" "$ms" || return 1
      FR_FLAKES=""
      FR_LINE="re-queued: the batch's failing suites $(_bej_checks_text "$BS_SUITES") passed with only this PR merged onto $BEJ_BRANCH (${BS_BASE:0:12}), so draft #$BEJ_DRAFT failed on another PR."
      _bej_log_once BATCH_SOLO_CLEAN "$key" "$head" "draft #$BEJ_DRAFT failed $BS_SUITES, and they pass with only this PR merged onto ${BS_BASE:0:12}: re-queue once"
      return 0 ;;
    pending)
      _bej_log_once BATCH_SOLO_PENDING "$key" "$head" "draft #$BEJ_DRAFT's solo re-run of $BS_SUITES has no verdict for this head yet; #4428's rule decides this tick"
      return 2 ;;
    could-not-run)
      _bej_log_once BATCH_SOLO_COULD_NOT_RUN "$key" "$head" "draft #$BEJ_DRAFT's solo re-run of $BS_SUITES gave no verdict this head can be judged on; #4428's rule decides"
      return 2 ;;
  esac
  return 2
}

# bej_reentry_gate <owner/repo> <num> <key> <url> <head> <raw mergeState>
#   fr_reentry_gate's contract: rc 0 the arm may re-queue (FR_LINE is the PR
#   line), rc 1 it may not (FR_WHY is the row's reason when not the arm's own,
#   FR_STATE the row's state when not WAIT_CI).
bej_reentry_gate() {
  local slug="$1" num="$2" key="$3" head="$5" ms="$6" min n mainsha raw rc chk
  local im k1 k2 k3 k4 iskip=0 ihold=0
  FR_WHY=""; FR_LINE=""; FR_STATE=""; BEJ_IMPACT_LINE=""
  case "$ms" in CLEAN|UNSTABLE) ;; *) return 1 ;; esac
  # >>> no-verdict (BH-6336)
  if declare -F nv_gate >/dev/null; then nv_gate "$slug" "$num" "$key" "$head" "$ms"; case $? in 0) return 0 ;; 1|2) return 1 ;; esac; fi
  # <<< no-verdict
  bej_verdict "$slug" "$num" "$key" "$head"
  # >>> impact eject (BH-4980)
  # A member of a multi-PR draft Mergify named nobody in: ask the impact map
  # which members can reach the failing test (bin/lib/mc-batch-impact.sh).
  # Mode 1 logs the answer and changes nothing. Mode 2: exactly one member
  # reaches it -> that one is ejected with a comment naming the test, and the
  # rest skip the solo re-run and take the bystander branch below at once;
  # several -> the candidates ask the solo re-run (a pending answer holds them)
  # and the others go back in; none or unknown, or the main-red freeze on ->
  # nothing changes.
  if [ "$BEJ_WORD" = bystander ] && [ -n "$BEJ_DRAFT" ] && declare -F bim_verdict >/dev/null; then
    im=$(bim_mode)
    if [ "$im" != 0 ]; then
      bim_verdict "$slug" "$BEJ_DRAFT" "$BEJ_CHECKS" >/dev/null
      read -r k1 k2 k3 k4 <<<"$BIM_DECISION"
      if [ "$k1" = eject ]; then k4="$k3"; k3="$k2"; k2=EJECT; fi
      _bej_log_once "BATCH_IMPACT_${k2^^}" "$key" "$head" "draft=#$BEJ_DRAFT $BIM_DECISION mode=$im"
      # Under the main-red freeze the failing test may be main's own, and the
      # branches below hold everyone anyway: nothing is ejected on the map.
      if [ "$im" = 2 ] && [ -z "${MAIN_RED:-}" ]; then
        case "$k2:,$k3," in
          EJECT:,"$num",)
            BEJ_WORD=impactculprit; BEJ_IMPACT_UNIT="$k4"; BEJ_IMPACT_N=$(wc -w <<<"$BIM_MEMBERS" | tr -d ' ')
            bej_culprit_note "$slug" "$num" "$key" "$head"
            FR_WHY="queue-ejected — $(_bej_plain "$k4") failed in draft #$BEJ_DRAFT and only this PR reaches it (impact map)"
            return 1 ;;
          EJECT:*)
            iskip=1
            BEJ_IMPACT_LINE="re-queued: draft #$BEJ_DRAFT failed $(_bej_checks_text "$k4"), and the impact map says only #$k3 reaches it. This head's own checks are green." ;;
          several:*,"$num",*) ihold=1 ;;
          several:*)
            iskip=1
            BEJ_IMPACT_LINE="re-queued: draft #$BEJ_DRAFT failed $(_bej_checks_text "$k4"), and the impact map says only #${k3//,/, #} reach it. This head's own checks are green." ;;
        esac
      fi
    fi
  fi
  # <<<
  case "$BEJ_WORD" in
    culprit|bystander)
      if [ "$iskip" = 0 ] && [ -n "$BEJ_DRAFT" ] && declare -F bs_batch >/dev/null; then
        rc=0; _bej_solo_gate "$slug" "$num" "$key" "$head" "$ms" || rc=$?
        if [ "$rc" = 2 ] && [ "$ihold" = 1 ] && [ "$BEJ_SOLO_WORD" = pending ]; then
          FR_WHY="queue-ejected — draft #$BEJ_DRAFT failed $(_bej_plain "$k4"); $(tr ',' '\n' <<<"$k3" | grep -c .) PRs reach it, waiting on the solo re-run"
          return 1
        fi
        [ "$rc" = 2 ] || return "$rc"
      fi ;;
  esac
  if [ "$BEJ_WORD" = solo ]; then
    bej_solo_note "$slug" "$BEJ_BASE" "$BEJ_CHECKS" "$key"
    min=$(_bej_knob MC_BATCH_EJECT_SHARED_MIN 2)
    [ "$min" -ge 2 ] || min=2
    n=$(bej_shared_count "$slug" "$BEJ_BASE" "$BEJ_CHECKS")
    [ "${n:-0}" -ge "$min" ] && BEJ_WORD=sharedred
  fi
  chk=$(_bej_checks_text "$BEJ_CHECKS")
  case "$BEJ_WORD" in
    bystander|sharedred)
      if [ -n "${MAIN_RED:-}" ]; then
        FR_WHY="queue-ejected — main-red freeze is on; re-queued when it lifts"
        return 1
      fi
      _bej_head_green "$slug" "$head" "$ms" || return 1
      ;;
  esac
  case "$BEJ_WORD" in
    bystander)
      FR_FLAKES=""
      FR_LINE="${BEJ_IMPACT_LINE:-re-queued: Mergify's batch draft #$BEJ_DRAFT failed $chk and named another PR, not this one. This head's own checks are green.}"
      _bej_log_once BATCH_EJECT_BYSTANDER "$key" "$head" "draft #$BEJ_DRAFT on $BEJ_BASE failed $(_bej_dec "$BEJ_CHECKS"); not named, head green: re-queue once"
      return 0 ;;
    sharedred)
      rc=0; mc_rest_var raw gh_rest GET "repos/$slug/branches/$BEJ_BRANCH" || rc=$?
      mainsha=""
      [ "$rc" = 0 ] && mainsha=$(jq -r '.commit.sha // empty' <<<"$raw" 2>/dev/null | tr 'A-F' 'a-f')
      if [ "${#mainsha}" -lt 7 ]; then
        FR_WHY="queue-ejected — $BEJ_BRANCH at $BEJ_BASE failed $chk for $n PRs tested alone; $BEJ_BRANCH could not be read this tick, asked again next tick"
        return 1
      fi
      case "$mainsha" in
        "$BEJ_BASE"*)
          FR_WHY="queue-ejected — $BEJ_BRANCH at $BEJ_BASE failed $chk for $n PRs tested alone; re-queued once $BEJ_BRANCH moves"
          _bej_log_once BATCH_EJECT_SHAREDRED_WAIT "$key" "$head" "$n PRs tested alone on $BEJ_BASE failed $(_bej_dec "$BEJ_CHECKS"); $BEJ_BRANCH has not moved"
          return 1 ;;
      esac
      FR_FLAKES=""
      FR_LINE="re-queued: Mergify tested this PR alone on $BEJ_BRANCH ($BEJ_BASE) and it failed $chk, but $n PRs tested alone on that same base failed it too, so $BEJ_BRANCH was red, not this PR. $BEJ_BRANCH has moved since."
      _bej_log_once BATCH_EJECT_SHAREDRED "$key" "$head" "$n PRs tested alone on $BEJ_BASE failed $(_bej_dec "$BEJ_CHECKS"); $BEJ_BRANCH now ${mainsha:0:8}: re-queue once"
      return 0 ;;
    culprit|solo)
      fr_reentry_gate "$@" && return 0
      # A PR tested alone is told on the tick after its verdict was first
      # read (BEJ_CACHED): long enough for a sibling ejected alone on the same
      # base in the same tick to land in the ledger and make both sharedred.
      if [ "$BEJ_WORD" = culprit ] || [ "$BEJ_CACHED" = 1 ]; then
        bej_culprit_note "$slug" "$num" "$key" "$head"
      fi
      return 1 ;;
  esac
  fr_reentry_gate "$@"
}
