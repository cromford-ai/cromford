#!/bin/bash
# shellcheck shell=bash
# bin/lib/archie-merge.sh — BH-9212: the gates of Archie's merge. Sourced by
# bin/archie-merge.sh, never run: no `set -e`, no `exit`, nothing at source time.
#
# Most gates call an existing conductor or queue-doctor reader. This file adds
# the authority row (am_authority), the hold-label check, the check-run ids
# (am_checks), the iron-law accept for this head (am_iron_law) and the audit
# claim (am_audit_claim), and it orders the head-bound chain (am_gates).
#
# The root is ${HARNESS:-${H:-}}; an empty root refuses (D43).
# gh-rest: no-graphql

am_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# am_authority -> rc 0 when Archie may merge, 3 when merges are ask-first,
#   75 unreadable. AM_DETAIL says why. Settings row archie.merge.authority
#   (worker/jobs/schema.d/*-bh-9212-archie-merge-authority.sql):
#   `merge` = Archie may merge through bin/archie-merge.sh under its gates;
#   anything else, `ask_first` included, = ask the operator first. No row is the code
#   fallback ask_first. The worker refuses a bearer PUT of any value but
#   ask_first (routes/settings.js leadLoosening), so only the operator's human token
#   (bin/protected-setting.sh) sets merge. The value is compared exactly: a
#   near miss (`Merge`, `merge `, `merged`) is ask-first. A 409 (setting_get
#   rc 9) is a row whose signature does not verify under sig enforce: ask-first.
am_authority() {
  local v rc
  AM_DETAIL=""
  v=$(setting_get archie.merge.authority); rc=$?
  case "$rc" in
    0) ;;
    2) AM_DETAIL="no archie.merge.authority row; the fallback is ask_first; ask the operator"; return 3 ;;
    9) AM_DETAIL="unproven: the archie.merge.authority signature does not verify; read as ask_first; ask the operator"; return 3 ;;
    *) AM_DETAIL="the settings row archie.merge.authority could not be read (rc $rc)"; return 75 ;;
  esac
  [ "$v" = merge ] && return 0
  AM_DETAIL="archie.merge.authority is '$v', not merge: ask the operator first"
  return 3
}

# am_checks <slug> <head> <required-names> -> rc 0 green and prints the id of
#   the newest run of each required name, comma-joined; rc 1 not green
#   (AM_DETAIL names the first name that is not); rc 2 unreadable (a failed
#   read, a page that is not all of the runs, or no required names).
#   Green is completed AND success, neutral or skipped. One check-runs read.
am_checks() {
  local slug="$1" head="$2" req="$3" j ans
  AM_DETAIL=""
  [ -n "$(tr -d '[:space:]' <<<"$req")" ] || { AM_DETAIL="no required check names"; return 2; }
  gh_rest_var j GET "repos/$slug/commits/$head/check-runs?per_page=100" \
    || { AM_DETAIL="the check-runs read failed (HTTP ${GH_REST_STATUS:-000})"; return 2; }
  jq -e '(.check_runs | type) == "array" and (.total_count // 0) <= (.check_runs | length)' <<<"$j" >/dev/null 2>&1 \
    || { AM_DETAIL="the check-runs page is not all of the runs"; return 2; }
  ans=$(jq -r --arg req "$req" '
    def ok: .status == "completed" and ((.conclusion // "") | IN("success", "neutral", "skipped"));
    .check_runs as $r
    | [$req | split("\n")[] | select(length > 0)
       | . as $n | {name: $n, run: ([$r[] | select(.name == $n)] | sort_by(.id) | last)}]
    | (map(select(.run == null or (.run | ok | not))) | first) as $bad
    | if $bad == null then "ok\t" + (map(.run.id | tostring) | join(","))
      elif $bad.run == null then "bad\t" + $bad.name + " has no run on this head"
      else "bad\t" + $bad.name + " is " + ($bad.run.status // "?") + "/" + ($bad.run.conclusion // "none")
      end' <<<"$j" 2>/dev/null) || { AM_DETAIL="the check-runs page did not parse"; return 2; }
  case "$ans" in
    ok$'\t'*) printf '%s' "${ans#ok$'\t'}"; return 0 ;;
    bad$'\t'*) AM_DETAIL="${ans#bad$'\t'}"; return 1 ;;
  esac
  AM_DETAIL="the check-runs page did not parse"; return 2
}

# am_iron_law <url> <head> -> rc 0 clean or accepted for this head, 1 hits with
#   no accept for this head, 75 unreadable (no diff, a scan that is not a
#   number, an accept read that failed). AM_DETAIL says which.
am_iron_law() {
  local url="$1" head="$2" f hits rc by
  AM_DETAIL=""
  f=$(mktemp "${TMPDIR:-/tmp}/am-diff.XXXXXX") || { AM_DETAIL="no temp file"; return 75; }
  mc_pr_diff "$url" "$f" || { rm -f "$f"; AM_DETAIL="the diff could not be read"; return 75; }
  hits=$(mc_iron_law_scan "$f" 2>/dev/null); rm -f "$f"
  [[ $hits =~ ^[0-9]+$ ]] || { AM_DETAIL="the iron-law scan answered '$hits'"; return 75; }
  [ "$hits" = 0 ] && { AM_DETAIL="clean"; return 0; }
  rc=0; by=$(ila_accepted "$url" "$head") || rc=$?
  case "$rc" in
    0) AM_DETAIL="$hits hit(s), accepted for this head by ${by:-?}"; return 0 ;;
    1) AM_DETAIL="$hits hit(s) and no accept for this head"; return 1 ;;
    *) AM_DETAIL="$hits hit(s); the accept could not be read (rc $rc)"; return 75 ;;
  esac
}

# am_gates <project> <slug> <n> <head> -> every gate on the exact head, in order.
#   rc 0 pass: AM_VERDICT_ID, AM_VERDICT, AM_RUN_IDS, AM_REQ and AM_IL are set.
#   rc 3 HOLD, rc 75 UNREADABLE, rc 4 ALREADY queued; AM_GATE and AM_DETAIL
#   say which gate and why. The caller holds the PR lock already (gate `lock`).
am_gates() {
  local p="$1" slug="$2" n="$3" head="$4" url rc r line hl lbl
  url="https://github.com/$slug/pull/$n"
  AM_GATE=""; AM_DETAIL=""; AM_VERDICT_ID=""; AM_VERDICT=""; AM_RUN_IDS=""; AM_REQ=""; AM_IL=""
  # head-moved / state / mergeable: one uncached pulls read.
  AM_GATE=state
  afq_pr_fresh "$slug" "$n" || { AM_DETAIL="the pulls read failed (HTTP ${GH_REST_STATUS:-000})"; return 75; }
  [ "$AFQ_PR_STATE" = open ] || { AM_DETAIL="the PR is $AFQ_PR_STATE${AFQ_PR_MERGED_AT:+ (merged $AFQ_PR_MERGED_AT)}"; return 3; }
  [ "$AFQ_PR_DRAFT" = false ] || { AM_DETAIL="the PR is a draft"; return 3; }
  if [ "$AFQ_PR_HEAD" != "$head" ]; then
    AM_GATE="head-moved"; AM_DETAIL="the PR head is now ${AFQ_PR_HEAD:0:12}"; return 3
  fi
  [ "$AFQ_PR_BASE" = "$(mc_project_base "$p")" ] || { AM_DETAIL="the base is $AFQ_PR_BASE, not $(mc_project_base "$p")"; return 3; }
  if [ "$AFQ_PR_MS" != clean ]; then
    AM_GATE=mergeable; AM_DETAIL="mergeable_state is ${AFQ_PR_MS:-empty}, not clean"; return 3
  fi
  # queued: Mergify already holds it, or the tier-2 ledger asked on this head.
  AM_GATE=queued
  rc=0; mc_mergify_witness "$slug" "$url" "$head" || rc=$?
  case "$rc" in
    0) AM_DETAIL="Mergify already witnesses this head"; return 4 ;;
    1) ;;
    *) AM_DETAIL="the Mergify witness could not be read (rc $rc)"; return 75 ;;
  esac
  r=$(am_root)
  [ -n "$r" ] || { AM_DETAIL="no harness root, so the tier-2 ledger cannot be read"; return 75; }
  if awk -v u="$url" -v h="$head" '$1 == u && $2 == h && ($3 == "enqueued" || $3 == "posting") { f = 1 } END { exit !f }' \
       "$r/state/tier2-autoenqueue.txt" 2>/dev/null; then
    AM_DETAIL="the tier-2 ledger already asked on this head"; return 4
  fi
  # hold: a hold label, the conductor's own READY gates, a HOLD on the PR thread.
  AM_GATE=hold
  hl="${MC_AUTOENQUEUE_HOLD_LABELS:-hold,do-not-merge}"
  for lbl in ${hl//,/ }; do
    case ",$AFQ_PR_LABELS," in *",$lbl,"*) AM_DETAIL="the PR carries the $lbl label"; return 3 ;; esac
  done
  if ! afq_conductor_gates "$p" "$slug" "$n" "$url" "$head" "$AFQ_PR_USER" "$AFQ_PR_REF"; then
    AM_DETAIL="held by ${AFQ_GATE:-a conductor gate}"; return 3
  fi
  rc=0; AE_SLUG="$slug" _ae_pr_hold "$n" || rc=$?
  case "$rc" in
    0) ;;
    1) AM_DETAIL="a HOLD on the PR thread (${AE_PR_HOLD_WHY:-})"; return 3 ;;
    *) AM_DETAIL="the PR thread could not be read for a HOLD (${AE_PR_HOLD_WHY:-})"; return 75 ;;
  esac
  # main-red
  AM_GATE=main-red
  if main_red_hold "$p" "$slug" "$n" "$url" "$head" "${AFQ_PR_LABELS:-none}"; then
    AM_DETAIL="main is red (${MRG_FLAG:-freeze})"; return 3
  fi
  # verdict: a standing head-bound MERGE / MERGE-WITH-NOTES, no CHANGES_REQUESTED.
  AM_GATE=verdict
  rc=0; afq_approved "$slug" "$n" "$head" || rc=$?
  case "$rc" in
    0) ;;
    2) AM_DETAIL="the verdict or the reviews could not be read"; return 75 ;;
    3) AM_DETAIL="a BLOCK verdict stands on this head"; return 3 ;;
    *) AM_DETAIL="no MERGE verdict stands on this head, or a reviewer's latest review is CHANGES_REQUESTED"; return 3 ;;
  esac
  rc=0; line=$(vd_standing "$slug" "$n" "$head") || rc=$?
  [ "$rc" = 0 ] || { AM_DETAIL="the verdict id could not be read (rc $rc)"; return 75; }
  AM_VERDICT=$(cut -f1 <<<"$line"); AM_VERDICT_ID=$(cut -f3 <<<"$line")
  case "$AM_VERDICT" in MERGE|MERGE-WITH-NOTES) ;; *) AM_DETAIL="the standing verdict is now ${AM_VERDICT:-none}"; return 3 ;; esac
  [[ $AM_VERDICT_ID =~ ^[0-9]+$ ]] || { AM_DETAIL="the verdict id '$AM_VERDICT_ID' is not a number"; return 75; }
  # checks: every required check green on the head.
  AM_GATE=checks
  AM_REQ=$(_ae_required_checks "$slug") || { AM_DETAIL="the required check names could not be read"; return 75; }
  rc=0; AM_RUN_IDS=$(am_checks "$slug" "$head" "$AM_REQ") || rc=$?
  case "$rc" in 0) ;; 1) return 3 ;; *) return 75 ;; esac
  # iron-law
  AM_GATE=iron-law
  rc=0; am_iron_law "$url" "$head" || rc=$?
  case "$rc" in 0) AM_IL=$AM_DETAIL ;; 1) return 3 ;; *) return 75 ;; esac
  # cap: Archie's merges count against the queue-enqueue day cap.
  AM_GATE=cap
  afq_cap_ok queue-enqueue "$p" || { AM_DETAIL="the archie.cap.queue-enqueue day cap is full or unreadable (logs/archie-merge.log)"; return 3; }
  AM_GATE=""; AM_DETAIL=""
  return 0
}

# am_audit_claim <key> <project> <slug> <n> <reason> <evidence-json> -> the
#   audit row in archie_actions, written BEFORE the send (playbook
#   queue-enqueue, so the archie.cap.queue-enqueue day cap counts it).
#   rc 0 claimed (AFM_ROW is the row); rc 4 a row for this key already exists
#   (or exists with another payload): send nothing; rc 75 not claimed: send
#   nothing (AM_DETAIL says why).
am_audit_claim() {
  local rc=0
  AM_DETAIL=""
  afq_claim queue-enqueue "$1" "$2" "$3" "$4" on enqueue "archie-merge: $5" "$6" || rc=$?
  case "$rc" in
    0) return 0 ;;
    3|9) AM_DETAIL="an archie-merge row for this head already exists; nothing sent, not retried on this head"; return 4 ;;
    *) AM_DETAIL="the audit row could not be claimed (rc $rc); nothing sent"; return 75 ;;
  esac
}
