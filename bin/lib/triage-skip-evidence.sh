#!/bin/bash
# bin/lib/triage-skip-evidence.sh — A "FIX IN PROGRESS" SKIP NAMES ITS EVIDENCE,
# OR IT IS NOT HONOURED (BH-5125, item 2).
#
# WHY IT EXISTS (#5022, 2026-10-07). Triage logged
#   5022 :: skip :: fix round for the lead BLOCK on open PR #5067 is already in progress (orchestrator/operator)
# on tick after tick, and nothing was running: the operator had posted a narrowing
# comment, which was direction for the next agent round, and the model read it
# as a person doing the fix. The DECISION contract let a skip carry any
# one-line reason, and bin/decision-log.sh copied it to logs/decisions.log
# without looking at it. A claim of ownership that nobody checks is the same
# as silence, and the PR sat.
#
# So the contract (catalog/agent-contracts/triage-system-append.txt, EVIDENCE)
# now asks every skip/defer that claims work in progress to end with ONE tag:
#   [evidence: lock <path>]     a lock under $HARNESS/locks/ that is HELD now
#   [evidence: pid <n>]         a process that is running now
#   [evidence: job <id>]        a job row (named; a project box has no hub read)
#   [evidence: hold:human-fix]  the ticket carries Taken by: / [human-fix]
# and this audits the claim after the harvest. lock and pid are verified here;
# job and hold:human-fix are accepted as NAMED evidence, which is what the
# ticket asks for. A claim with no tag, or one that fails, is not honoured:
# one `gate=audit <KEY> :: handoff ::` line in logs/decisions.log on every tick
# (the routing log), and ONE ALERTS line per distinct claim, deduped on
# (project, key, sha256 of the reason) through state/triage-skip-evidence/.
# "Handed to bin/blocked-resolver.sh" is literal: the resolver already owns the
# PR on the hub from its own sources, and the audit line records that triage's
# claim of ownership was void.
#
# Sourced, never executed. FAIL-OPEN like the harvester: no root, a missing
# file, no DECISION lines — rc 0, no output. NO ROOT, NO WRITES (BH-2613): the
# root is ${HARNESS:-${H:-}} and nothing else.
#
#   tse_inprogress <reason>          rc 0 when the reason claims work in progress
#   tse_evidence <reason>            "ok <kind>" rc 0, or "<why>" rc 1
#   tse_audit <project> <session-out>

# THE IN-PROGRESS MATCHER, case-insensitive ERE. It has to catch the incident
# wording and its cousins ("a fix round is in progress on it", "the operator is fixing
# it by hand", "already building", "rebuild under way", "someone is on it")
# and stay quiet on the ordinary skip reasons ("awaiting merge", "verdict
# pending", "build finished", "already shipped"). A state ("pending",
# "open", "waiting") is not a claim that someone is working; an -ing verb with
# is/are, or in progress / under way, is. Pinned both ways in
# tests/triage-skip-evidence.bh-5125-test.sh (E9, E10).
TSE_INPROGRESS_RE="\\b(in[ -]progress|under[ -]?way|ongoing)\\b|\\balready (building|rebuilding|fixing|running|being (built|rebuilt|fixed|worked on))\\b|(\\b(is|are|was)|'s) (already |now |currently |still )?(fixing|building|rebuilding|working on|handling|on it)\\b|\\b(fix|round|build|rebuild) (is )?(already |still )?running\\b"
TSE_TAG_RE='\[evidence:[[:space:]]*([^]]*)\]'

tse_inprogress() {
  grep -Eiq -- "$TSE_INPROGRESS_RE" <<<"${1:-}"
}

# tse__root — the harness root, or rc 1. Trailing slashes dropped so the
# locks/ prefix test compares like with like.
tse__root() {
  local r="${HARNESS:-${H:-}}"
  [ -n "$r" ] || return 1
  while [ "${r%/}" != "$r" ] && [ "$r" != / ]; do r="${r%/}"; done
  printf '%s\n' "$r"
}

# tse_evidence <reason> — the LAST [evidence: …] tag decides.
#   lock <path>  absolute, no `..` segment, under $root/locks/, a regular file,
#                and `flock -n` on it FAILS (someone holds it). Otherwise
#                "lock outside locks/" or "lock not held".
#   pid <n>      digits, > 1, and kill -0 succeeds. Otherwise "pid not running".
#   job <id> / hold:human-fix   accepted as named.
#   no tag: "no evidence tag"; anything else: "unknown evidence tag".
tse_evidence() {
  local reason="${1:-}" tag kind arg root rest rc
  tag=""; rest="$reason"
  while [[ $rest =~ $TSE_TAG_RE ]]; do
    tag="${BASH_REMATCH[1]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  [ -n "$tag" ] || { echo "no evidence tag"; return 1; }
  tag="${tag%"${tag##*[![:space:]]}"}"
  kind="${tag%%[[:space:]]*}"
  arg="${tag#"$kind"}"; arg="${arg#"${arg%%[![:space:]]*}"}"
  case "$kind" in
    lock)
      root=$(tse__root) || { echo "lock outside locks/"; return 1; }
      case "$arg" in
        /*) ;;
        *) echo "lock outside locks/"; return 1 ;;
      esac
      case "/$arg/" in */../*) echo "lock outside locks/"; return 1 ;; esac
      case "$arg" in "$root/locks/"?*) ;; *) echo "lock outside locks/"; return 1 ;; esac
      [ -f "$arg" ] || { echo "lock not held"; return 1; }
      # rc 0 = we took it, so nobody held it; rc 1 = held; anything else (the
      # open failed) is not evidence of a holder either.
      ( exec 8<"$arg" || exit 2; flock -n 8 ) 2>/dev/null; rc=$?
      [ "$rc" = 1 ] || { echo "lock not held"; return 1; }
      echo "ok lock"; return 0 ;;
    pid)
      case "$arg" in ''|*[!0-9]*) echo "pid not running"; return 1 ;; esac
      [ "$((10#$arg))" -gt 1 ] 2>/dev/null && kill -0 "$((10#$arg))" 2>/dev/null \
        || { echo "pid not running"; return 1; }
      echo "ok pid"; return 0 ;;
    job)
      [ -n "$arg" ] || { echo "unknown evidence tag"; return 1; }
      echo "ok job"; return 0 ;;
    hold:human-fix)
      [ -z "$arg" ] || { echo "unknown evidence tag"; return 1; }
      echo "ok hold:human-fix"; return 0 ;;
  esac
  echo "unknown evidence tag"; return 1
}

# tse__trim <s> — leading and trailing whitespace off.
tse__trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# tse_audit <project> <session-out> — the same DECISION lines the harvester
# reads (head -40, cut -c1-330), each `<KEY> :: <action> :: <reason>`. Only
# skip and defer are audited; every other action is the work itself.
tse_audit() {
  local p="${1:-}" out="${2:-}" root stamp line pl key action reason why fp sf prev keyf
  root=$(tse__root) || return 0
  [ -n "$p" ] && [ -n "$out" ] && [ -r "$out" ] || return 0
  stamp=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  while IFS= read -r line; do
    pl="${line#DECISION:}"
    case "$pl" in *' :: '*' :: '*) ;; *) continue ;; esac
    key=$(tse__trim "${pl%% :: *}")
    pl="${pl#* :: }"
    action=$(tse__trim "${pl%% :: *}"); action="${action,,}"
    reason=$(tse__trim "${pl#* :: }")
    case "$action" in skip|defer) ;; *) continue ;; esac
    [ -n "$key" ] || key="-"
    tse_inprogress "$reason" || continue
    why=$(tse_evidence "$reason") && continue
    mkdir -p "$root/logs" 2>/dev/null || return 0
    printf '%s [%s] gate=audit %s :: handoff :: %s claimed work in progress with no evidence (%s) — bin/blocked-resolver.sh owns it\n' \
      "$stamp" "$p" "$key" "$action" "$why" >> "$root/logs/decisions.log" 2>/dev/null
    # ONE ALERTS line per distinct claim. The stamp file holds the last
    # fingerprint; it is written only after the alert was handed over.
    fp=$(printf '%s' "$reason" | sha256sum 2>/dev/null | cut -d' ' -f1)
    keyf=$(printf '%s' "$p-$key" | tr -c 'A-Za-z0-9._-' '_')
    sf="$root/state/triage-skip-evidence/$keyf"
    prev=$(cat "$sf" 2>/dev/null)
    [ -n "$fp" ] && [ "$prev" = "$fp" ] && continue
    # Through bin/alert-line.sh, the one sanctioned ALERTS writer (it notes the
    # console row as well). It always answers 0, so with no helper on the box
    # nothing is written and nothing is stamped: the next tick tries again.
    [ -x "$root/bin/alert-line.sh" ] || continue
    HARNESS="$root" "$root/bin/alert-line.sh" --severity warn --id "triage-skip-evidence:$p:$key" --project "$p" \
      "[$p/$key] TRIAGE SKIP WITHOUT EVIDENCE: $key $action claimed work in progress with no evidence ($why): \"$reason\". The skip is not honoured; bin/blocked-resolver.sh owns it. A real claim ends with [evidence: lock|pid|job|hold:human-fix] (catalog/agent-contracts/triage-system-append.txt, EVIDENCE)." \
      >/dev/null 2>&1 </dev/null
    mkdir -p "$root/state/triage-skip-evidence" 2>/dev/null \
      && printf '%s\n' "$fp" > "$sf" 2>/dev/null
  done < <(grep -a '^DECISION:' "$out" 2>/dev/null | head -40 | cut -c1-330)
  return 0
}
