# shellcheck shell=bash
# bin/merge-conductor.d/bh-9696-ironlaw-rules.sh — THE IRON-LAW BLOCK NAMES THE
# RULE AND THE LINES (BH-9696, BH-9427.4). Sourced by bin/merge-conductor.sh
# (the BH-7453 fragment block). It sources bin/lib/ironlaw-rules.sh and reads
# the knob. pr_worker has two call sites: it sets MC_HIT_RULES (ilr_rules) from
# the diff before the diff file is removed, and it passes WHY through ilr_why
# after the final mc_classify, so a BLOCKED_HUMAN `iron-law (N hit(s))` reads
# `iron-law (N hit(s)): model-id src/a.ts:12; ...`.
# shellcheck source=bin/lib/ironlaw-rules.sh
[ -r "$H/bin/lib/ironlaw-rules.sh" ] && . "$H/bin/lib/ironlaw-rules.sh"

# mc_ilr_max — how many rules the reason names before "+K more".
#   Knob MC_ILR_MAX: catalog/lanes.d/merge-conductor.knobs.d/MC_ILR_MAX.json,
#   settings row lane.merge-conductor.mc_ilr_max (fallback 10, clamp 0..50,
#   0 = off: the bare reason).
mc_ilr_max() {
  local v="${MC_ILR_MAX:-10}"
  case "$v" in ''|*[!0-9]*) v=10 ;; esac
  v=$((10#$v))
  [ "$v" -gt 50 ] && v=50
  printf '%s' "$v"
}
