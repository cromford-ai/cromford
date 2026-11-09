# >>> fly cost row (BH-3989)
# The machine's own seconds for this job, as ONE infra row in the build dir's
# cost.csv, so the push_pool_cost_rows call right after it carries the row to
# cost_rows under pool-<p>-<mid>. Start is the job's spawned_at, end is this
# tick, or the listing's updated_at for a machine that is no longer running;
# size comes from the live listing; when the listing has no size for the
# machine (it is gone, or the listing failed), from the vm_size/vm_mem the
# spawn wrote on the machine json, and the row's note says state=estimated
# (BH-9065). Neither = unpriced, as before.
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
  local est="" vs vm sp
  if { [ -z "$cpus" ] || [ -z "$mem" ]; } && [ -s "${MF:-}" ] && command -v fly_size_split >/dev/null 2>&1; then
    read -r vs vm < <(jq -r '"\(.vm_size // "-") \(.vm_mem // "-")"' "$MF" 2>/dev/null)
    if sp=$(fly_size_split "${vs:-}") && [[ "${vm:-}" =~ ^[0-9]+$ ]]; then
      read -r kind cpus <<<"$sp"; mem="$vm"; est=estimated
    fi
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
        "$kind" "$cpus" "$mem" "$HARNESS/catalog/fly-prices.json" ${est:+"$est"}); rc=$?
  case "$rc" in 0) word=written ;; 3) word=already ;; 2) word=skipped:bad-interval ;; *) word="skipped:rc$rc" ;; esac
  say "fly cost row: $word $MID $KEY${out:+ ${out%% *}s \$${out##* }}${est:+${out:+ $est}}"
  return 0
}

# pool_fly_orphan_cost_row <mid> (BH-9065): the sweep destroys a machine the
# pool has no tracking file for, and nothing else bills it. One estimated row
# from the listing: start is Fly's created_at, end its updated_at (the stop
# time) or this tick, size from the listing. Key `orphan`. A machine the
# ledger already billed under any key is skipped, so a reap that billed it and
# then lost its file never pays twice. Reads $LISTING, $P, $HARNESS. Returns 0.
pool_fly_orphan_cost_row() {
  local mid="${1:-}" kind cpus mem cat upd e now d out rc word oc_tmp
  local ledger="$HARNESS/state/fly-cost/ledger.tsv"
  command -v fly_cost_row_once >/dev/null 2>&1 && command -v fly_mid_billed >/dev/null 2>&1 || return 0
  [ -n "$mid" ] && [ -s "${LISTING:-}" ] || return 0
  fly_mid_billed "$ledger" "$mid" && return 0
  read -r kind cpus mem cat upd < <(jq -r --arg m "$mid" \
    '.[]|select(.id==$m)|"\(.config.guest.cpu_kind // "-") \(.config.guest.cpus // "-") \(.config.guest.memory_mb // "-") \(.created_at // "-") \(.updated_at // "-")"' \
    "$LISTING" 2>/dev/null | head -1)
  [ "${kind:-}" = - ] && kind=""; [ "${cpus:-}" = - ] && cpus=""; [ "${mem:-}" = - ] && mem=""
  [ -n "${cat:-}" ] && [ "$cat" != - ] || { say "fly cost row: skipped:no-created-at $mid orphan"; return 0; }
  now=$(date -u +%s); e="$now"
  if [ -n "${upd:-}" ] && [ "$upd" != - ]; then
    d=$(date -u -d "$upd" +%s 2>/dev/null) || d=""
    [[ "$d" =~ ^[0-9]+$ ]] && [ "$d" -le "$now" ] && e="$d"
  fi
  oc_tmp=$(mktemp -d "${TMPDIR:-/tmp}/pool-orphan-cost.XXXXXX" 2>/dev/null) || return 0
  out=$(fly_cost_row_once "$oc_tmp/cost.csv" "$ledger" "$P" "pool-$P-$mid" "$mid" orphan "" "" "$cat" "$e" \
        "$kind" "$cpus" "$mem" "$HARNESS/catalog/fly-prices.json" estimated); rc=$?
  case "$rc" in 0) word=written ;; 3) word=already ;; 2) word=skipped:bad-interval ;; *) word="skipped:rc$rc" ;; esac
  say "fly cost row: $word $mid orphan${out:+ ${out%% *}s \$${out##* } estimated}"
  [ "$rc" = 0 ] && command -v push_pool_cost_rows >/dev/null 2>&1 && push_pool_cost_rows "$oc_tmp" "pool-${P}-${mid}"
  case "$oc_tmp" in "${TMPDIR:-/tmp}"/pool-orphan-cost.*) rm -rf -- "$oc_tmp" ;; esac
  return 0
}
# <<< fly cost row
