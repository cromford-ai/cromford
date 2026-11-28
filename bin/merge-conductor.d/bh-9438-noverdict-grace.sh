# shellcheck shell=bash
# bin/merge-conductor.d/bh-9438-noverdict-grace.sh - NO PAID RE-REVIEW BEFORE
# THE FIRST VERDICT CAN BIND (BH-9438 item 1). Sourced by
# bin/merge-conductor.sh (the BH-7453 fragment block); functions only, no side
# effect at source time.
#
# WHY. 2026-10-27..2026-11-10 on the hub: 506 of 921 HEAD_MOVED events were
# "no verdict bound to head" with reviewed=-, and 343 of them were the
# conductor's FIRST sight of a PR before the builder's own verdict bound to it.
# mc_classify answered HEAD_MOVED, and headbound_review bought a paid detached
# re-review of a head the builder was about to verdict anyway. mc_job_running
# only covers a job row still `running`; the gap after the job row settles and
# before the ledger verdict binds was open.
#
# THE RULE. A (PR, head) is in its first-verdict grace when ALL are true:
#   1. the verdict is not APPROVE and not BLOCK;
#   2. the reviewed sha is empty or `-` (no review ever bound: first sight, not
#      a real drift and not a cleared verdict on a reviewed head);
#   3. MC_NOVERDICT_GRACE_S > 0;
#   4. now minus the first-seen epoch of this (PR, head) is less than it.
# The first-seen epoch is the attempt line `nvseen <key> <head> <epoch>`,
# written once (first writer wins) the first time the conductor sees the head
# in this shape. A new head gets its own line and its own grace.
#
# THE VERBS.
#   mc_nvg_in_grace <key> <head> <reviewed> <verdict>
#       rc 0 = in grace. Sets MC_NVG_LEFT (seconds left), MC_NVG_AGE (seconds
#       since first sight) and MC_NVG_GRACE (the window). rc 1 = today's path:
#       any rule above false, a knob or epoch that is not a number, or an
#       attempts ledger that gives no epoch back.
#
# The caller (pr_worker) turns rc 0 into the NAMED variable MC_NV_GRACE=1.
# mc_classify then says `no verdict yet on head <h8> — first-verdict grace`
# (state HEAD_MOVED, unchanged), and headbound_review's moved mode returns
# after its free consumes and before any budget, daily-cap unit or spawn.

# _mc_nvg_knob <ENV> <fallback> — the settings row lane.merge-conductor.<env
#   lower> through lane_knob, else the env var, else <fallback>. Row:
#   lane.merge-conductor.mc_noverdict_grace_s (catalog
#   catalog/lanes.d/merge-conductor.knobs.d/MC_NOVERDICT_GRACE_S.json, fallback
#   900).
_mc_nvg_knob() {
  local v=""
  if command -v lane_knob >/dev/null 2>&1; then v=$(lane_knob merge-conductor "$1" "${P:-}" 2>/dev/null); fi
  [ -n "$v" ] || v="${!1:-}"
  [ -n "$v" ] || v="$2"
  printf '%s' "$v"
}

# mc_nvg_in_grace <key> <head> <reviewed> <verdict> — see the header.
mc_nvg_in_grace() {
  local key="${1:-}" head="${2:-}" rev="${3:-}" v="${4:-}" g now first age
  MC_NVG_LEFT=""; MC_NVG_AGE=""; MC_NVG_GRACE=""
  [ -n "$key" ] && [ -n "$head" ] && [ "$head" != - ] || return 1
  case "$v" in APPROVE|BLOCK) return 1 ;; esac
  case "$rev" in ''|-) ;; *) return 1 ;; esac
  # Fallback 900 s: three */5 conductor ticks, below the 1800 s HEAD_MOVED
  # stuck TTL (bin/lib/mc/locks.sh), so a grace never trips a stuck page.
  g=$(_mc_nvg_knob MC_NOVERDICT_GRACE_S 900)
  case "$g" in ''|*[!0-9]*) g=900 ;; esac
  [ "$g" -gt 0 ] || return 1
  now=$(mc_now 2>/dev/null)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  first=$(mc_attempt_tail nvseen "$key" "$head" first 2>/dev/null)
  if [ -z "$first" ]; then
    mc_attempt_put "nvseen $key $head $now"
    first=$(mc_attempt_tail nvseen "$key" "$head" first 2>/dev/null)
  fi
  first="${first%% *}"
  case "$first" in ''|*[!0-9]*) return 1 ;; esac
  age=$((now - first)); [ "$age" -ge 0 ] || age=0
  [ "$age" -lt "$g" ] || return 1
  MC_NVG_LEFT=$((g - age)); MC_NVG_AGE="$age"; MC_NVG_GRACE="$g"
  return 0
}
