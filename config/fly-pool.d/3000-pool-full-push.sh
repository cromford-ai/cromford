# >>> pool full push (BH-1041)
# pool_push_full <project> <key> <ticket> <local-dir> <box> <pr-url> <tier>
#   THE SSH FALLBACK, lifted out of the reap so the deferral retry below can
#   reach the same code rather than growing a second copy of it. Everything it
#   does, the reap did in line before this ticket: the ingest-shaped json into
#   the box's state/remote-results, the RESULT/review/plan into the box's own
#   build dir, and then the bookkeeping — hub json removed only because the box
#   copy is now live, RELAYED stamped only because both pushes returned 0, and
#   ONE ALERTS line when they did not.
#   rc 0 pushed and stamped; rc 1 the push failed, hub json kept, alert written.
pool_push_full() {
  local p="$1" k="$2" t="$3" loc="$4" box="$5" pr="$6" tier="$7"
  local bd pay ok=1 art mbd
  bd=$(basename "$loc")
  # The MACHINE's own build dir, which is what the ledger row for this build is
  # named after and therefore the only identity the owning box can dedupe this
  # json against. The hub's `build_dir` above is a different name for the same
  # build and always has been.
  mbd=$(grep -oE '^BUILD_DIR: .*' "$loc/RESULT" 2>/dev/null | sed 's/^BUILD_DIR: //' | head -1)
  pay=$(jq -nc --arg k "$k" --arg t "$t" --arg r "$(head -1 "$loc/RESULT")" \
    --arg pr "$pr" --arg tier "$tier" --arg bd "$bd" --arg mbd "$mbd" --arg ts "$(STAMP)" \
    '{key:$k,ticket_id:$t,result:$r,pr_url:$pr,tier:$tier,build_dir:$bd,machine_build_dir:$mbd,ingested_at:$ts,source:"pool"}')
  # NO -n on the payload ssh: the json rides stdin into cat (medic 2026-07-31).
  ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
    "mkdir -p /root/harness/state/remote-results/$p; cat > /root/harness/state/remote-results/$p/$k.json" \
    <<<"$pay" || ok=0
  for art in RESULT review.md plan.md; do
    [ -s "$loc/$art" ] || continue
    ssh -o BatchMode=yes -o ConnectTimeout=15 "root@$box" \
      "mkdir -p /root/harness/builds/$bd; cat > /root/harness/builds/$bd/$art" \
      < "$loc/$art" || ok=0
  done
  if [ "$ok" = 1 ]; then
    rm -f "$HARNESS/state/remote-results/$p/$k.json"
    touch "$loc/RELAYED"
    say "relayed $k result+artifacts to $box (tier=${tier:-?})"
    return 0
  fi
  HARNESS="$HARNESS" "$HARNESS/bin/alert-line.sh" "[pool/$p] $k: RELAY to $box FAILED — result parked hub-side in state/remote-results/$p/$k.json + $loc; hand-deliver or re-run the relay"
  say "RELAY FAILED $k to $box — hub json kept"
  return 1
}
# <<< pool full push

