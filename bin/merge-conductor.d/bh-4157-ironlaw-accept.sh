# shellcheck shell=bash
# bin/merge-conductor.d/bh-4157-ironlaw-accept.sh - AN ACCEPT IN THE DB IS AN
# ACCEPT (BH-4157). Sourced by bin/merge-conductor.sh (the BH-7453 fragment
# block), after bin/lib/ironlaw-carry.sh.
#
# mc_ila_accept — pr_worker calls it as its head ACCEPT check, with
# pr_worker's SCAN, KEY, URL and HEAD in scope. When the scan has hits and an
# ironlaw-head-accept row names this exact head (from the console, the
# resolver or the family carry), it logs the ACCEPT and sets SCAN=0. It needs
# no build record on this hub. A read it cannot prove (ila_gate rc 2) logs one
# line and parks as before. No ila_gate (a tree without the lib): no-op.
mc_ila_accept() {
  [ "${SCAN:-0}" -gt 0 ] 2>/dev/null || return 0
  command -v ila_gate >/dev/null 2>&1 || return 0
  local out rc
  out=$(ila_gate "$URL" "$HEAD"); rc=$?
  case "$rc" in
    0) mc_log "$KEY iron-law scan found $SCAN hit(s) on ${HEAD:0:8}, $out"; SCAN=0 ;;
    2) mc_log "$KEY iron-law: $out" ;;
  esac
  return 0
}
