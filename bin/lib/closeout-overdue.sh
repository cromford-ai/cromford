#!/bin/bash
# bin/lib/closeout-overdue.sh — one pipeline-health warn per ticket key whose
# finished build has waited too long for its board close-out (BH-3953).
# Sourced, never executed; defines functions only; set -u safe.
#
# WHY. bin/orphan-reconcile.sh skips a ticket as `awaiting-closeout` while any
# builds/<p>-<KEY>-*/ or builds/pool-<p>-<KEY>-*/ dir has a RESULT and no
# COMMENTED: the results sweep owns it. When the sweep never closes it out, that
# skip repeats every tick and says nothing. BH-3859 (2026-10-03) sat there from
# 15:33Z until a human posted the finding at 16:04Z.
# A RELAYED dir is custody moved to the owning box (BH-6956), the same rule as
# bin/pipeline-health.sh: that box closes it out, so it is not counted here.
#
# closeout_overdue_note <harness> <project> <key> -> rc 0, always
#   Age is the OLDEST un-commented RESULT's mtime. Over CLOSEOUT_OVERDUE_S
#   (default 2700 = 45m; non-numeric -> 2700; below 600 -> 600) it calls
#   bin/lane-alert.sh --id closeout-overdue:<p>:<KEY> --severity warn, whose id
#   state machine sends it once, counts repeats, and closes it once the key stops
#   firing. When bin/box-for.sh answers for <p>, the text names the close-out
#   owner. Local stat/head only, no network. No lane-alert.sh -> nothing.
closeout_overdue_note() {
  local h="${1:-}" p="${2:-}" k="${3:-}" lim now d m old=0 od="" n=0 first own=""
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 0
  [ -x "$h/bin/lane-alert.sh" ] || return 0
  lim="${CLOSEOUT_OVERDUE_S:-2700}"
  case "$lim" in ''|*[!0-9]*) lim=2700 ;; esac
  [ "$lim" -ge 600 ] 2>/dev/null || lim=600
  # The trailing `-` is what keeps BH-38 from matching BH-385's dirs.
  for d in "$h/builds/$p-$k-"*/ "$h/builds/pool-$p-$k-"*/; do
    [ -f "$d/RESULT" ] && [ ! -f "$d/COMMENTED" ] || continue
    [ -f "$d/RELAYED" ] && continue   # custody moved to the owning box's copy
    m=$(stat -c %Y "$d/RESULT" 2>/dev/null) || continue
    n=$((n + 1))
    if [ -z "$od" ] || [ "$m" -lt "$old" ]; then old="$m"; od="${d%/}"; fi
  done
  [ -n "$od" ] || return 0
  now=$(date +%s)
  [ $((now - old)) -gt "$lim" ] || return 0
  first=$(head -c 200 "$od/RESULT" 2>/dev/null | head -1 | cut -c1-120)
  if [ -x "$h/bin/box-for.sh" ] && own=$("$h/bin/box-for.sh" "$p" 2>/dev/null) && [ -n "$own" ]; then
    [ "$own" = local ] && own="local (the hub)"
    own="; close-out owner: $own"
  else own=""; fi
  "$h/bin/lane-alert.sh" --id "closeout-overdue:$p:$k" --severity warn pipeline-health \
    "$p $k has waited $(( (now - old) / 60 ))m for its board close-out: $(basename "$od") (RESULT: $first), $n un-commented dir(s); orphan-reconcile skips it as awaiting-closeout every tick and the results sweep has not closed it$own" \
    >/dev/null 2>&1 || true
  return 0
}
