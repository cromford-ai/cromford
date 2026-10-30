# >>> fly cost row (BH-3989)
# The machine's own seconds for this job, as ONE infra row in the build dir's
# cost.csv, so the push_pool_cost_rows call right after it carries the row to
# cost_rows under pool-<p>-<mid>. Start is the job's spawned_at, end is this
# tick, or the listing's updated_at for a machine that is no longer running;
# size comes from the live listing only (unusable listing = unpriced).
# job_id is the build's own, read from its cost.csv by header name, or empty.
# Once per (mid, key, spawned_at) via state/fly-cost/ledger.tsv. Returns 0.
pool_fly_cost_row() {
  local kind="" cpus="" mem="" mst="" mup="" end e s0 job="" out rc word
  command -v fly_cost_row_once >/dev/null 2>&1 || return 0
  if [ -z "${SPAT:-}" ]; then say "fly cost row: skipped:no-spawned-at $MID $KEY"; return 0; fi
  if [ "${LIST_OK:-0}" = 1 ] && [ -s "${LISTING:-}" ]; then
    read -r kind cpus mem mst mup < <(jq -r --arg m "$MID" \
      '.[]|select(.id==$m)|"\(.config.guest.cpu_kind // "-") \(.config.guest.cpus // "-") \(.config.guest.memory_mb // "-") \(.state // "-") \(.updated_at // "-")"' \
      "$LISTING" 2>/dev/null | head -1)
    [ "$kind" = - ] && kind=""; [ "$cpus" = - ] && cpus=""; [ "$mem" = - ] && mem=""
  fi
  # A machine that is no longer running stopped at its listing's updated_at
  # (BH-7719): bill to then, not to this tick, when that time is after the
  # spawn and not in the future. Anything else ends now, as before.
  end=$(date -u +%s)
  case "${mst:-}" in
    stopped|suspended|failed|destroyed)
      e=""; [ -n "${mup:-}" ] && { e=$(date -u -d "${mup:-}" +%s 2>/dev/null) || e=""; }
      s0=""; [ -n "${SPAT:-}" ] && { s0=$(date -u -d "$SPAT" +%s 2>/dev/null) || s0=""; }
      [[ "$e" =~ ^[0-9]+$ ]] && [[ "$s0" =~ ^[0-9]+$ ]] && [ "$e" -gt "$s0" ] && [ "$e" -le "$end" ] && end="$e" ;;
  esac
  [ -s "$LOCAL/cost.csv" ] && job=$(awk -F, 'NR==1{for(i=1;i<=NF;i++) if($i=="job_id") c=i; next}
    c && $c!=""{j=$c} END{print j}' "$LOCAL/cost.csv" 2>/dev/null)
  out=$(fly_cost_row_once "$LOCAL/cost.csv" "$HARNESS/state/fly-cost/ledger.tsv" "$P" "pool-$P-$MID" \
        "$MID" "$KEY" "$job" "$(basename "$LOCAL")" "$SPAT" "$end" \
        "$kind" "$cpus" "$mem" "$HARNESS/catalog/fly-prices.json"); rc=$?
  case "$rc" in 0) word=written ;; 3) word=already ;; 2) word=skipped:bad-interval ;; *) word="skipped:rc$rc" ;; esac
  say "fly cost row: $word $MID $KEY${out:+ ${out%% *}s \$${out##* }}"
  return 0
}
# <<< fly cost row
