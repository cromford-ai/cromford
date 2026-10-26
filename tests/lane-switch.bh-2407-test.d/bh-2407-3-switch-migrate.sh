# S9 — the real switch-migrate walks every registry file: the 40 (the 25, the
# dora-digest pilot, the nine BH-2436 registered and the five sourced-lib
# switches BH-2429 registered, whose own shape is pinned by
# lane-switch-registry.bh-2410) and whatever later slices of BH-2408 register.
C4="split-chain-off state-backup-off test-reroute-off triage-health-off triage-shards-off
triage-shard-caps-off triage-spool-age-off vendor-spend-off wake-lanes-off
pool-account-routing-off pr-create-rest-fallback-off pr-dep-gate-off pr-merge-rest-off resume-disabled"
S="$T/s"; mkdir -p "$S/bin" "$S/flags" "$S/state" "$S/logs" "$S/catalog"
cp -r "$DIR/catalog/switches.d" "$S/catalog/"
cat > "$S/bin/jobs-client.sh" <<'SH'
_jobs_req() { case "$1 $2" in "GET /api/settings") JOBS_HTTP=200; printf '{"settings":[]}' ;; *) return 1 ;; esac; }
SH
env HARNESS="$S" JOBS_BOX=hub-1 "$DIR/bin/switch-migrate.sh" --dry-run > "$T/s.out" 2>&1
eq "S9 dry-run exits 0" "$?" "0"
# Every registry file, not a count frozen at 26: a later slice registers more
# (BH-2444 added six), and each of main's 40 must still be among them.
ALL=$(for f in "$DIR"/catalog/switches.d/*.json; do basename "$f" .json; done | sort | tr '\n' ' ')
GOT=$(grep '^absent ' "$T/s.out" | awk '{print $2}' | sort | tr '\n' ' ')
eq "S9 dry-run names every switch absent" "$(grep -c '^absent ' "$T/s.out")" "$(printf '%s' "$ALL" | wc -w | tr -d ' ')"
eq "S9 the name set" "$GOT" "$ALL"
for n in $SWITCHES dora-digest-off $C4; do
  case " $GOT" in *" $n "*) ok ;; *) bad "S9 $n missing from the dry-run" ;; esac
done

