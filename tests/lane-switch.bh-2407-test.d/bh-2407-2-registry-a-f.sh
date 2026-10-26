# G1/G2 — the a-f registry.
SWITCHES="agent-call-ledger-off alert-quarantine-disabled alert-state-off audit-off batch-resolve-off
bin-self-heal-off blocked-resolver-disabled builder-direct-off call-guard-off cliff-refuse-off
cliff-route-off clock-sync-off context-gate-disabled context-kill-off cost-autohalt-off
cost-reconcile-off cost-row-at-source-off cost-rows-from-db-off cost-rows-push-off dep-verify-off
extra-usage-track-off fastpath-off fixpr-suppress-off fleet-slo-off fly-disabled"
for n in $SWITCHES; do
  f="$DIR/catalog/switches.d/$n.json"
  [ -f "$f" ] || { bad "G1 catalog/switches.d/$n.json is missing"; continue; }
  eq "G1 $n is one line" "$(wc -l < "$f" | tr -d ' ')" "1"
  eq "G1 $n shape" "$(jq -c '[keys_unsorted, .name, .box_scoped, (.readers|type), (.what|type)]' "$f" 2>/dev/null)" \
    "[[\"name\",\"readers\",\"box_scoped\",\"what\"],\"$n\",true,\"array\",\"string\"]"
  RD=$(jq -r '.readers[]' "$f" 2>/dev/null)
  [ -n "$RD" ] && ok || bad "G1 $n has no readers"
  for r in $RD; do
    if [ -f "$DIR/$r" ] && grep -nE "$n([^a-z0-9_-]|$)" "$DIR/$r" | grep -qvE '^[0-9]+:[[:space:]]*#'; then ok
    else bad "G1 $n reader $r does not exist or names $n on no code line"; fi
  done
  case "$(jq -r '.what' "$f")" in "stops "*|"turns off "*) ok ;; *) bad "G1 $n what must start 'stops' or 'turns off'" ;; esac
done
jq -r '.what' "$DIR/catalog/switches.d/fly-disabled.json" 2>/dev/null | grep -qF 'bin/fly-trial-kill.sh' && ok \
  || bad "G2 fly-disabled's what must name bin/fly-trial-kill.sh as its writer"

