#!/bin/bash
# bin/budget-defaults.sh [--days N] [--now <iso>] [--rows <cost.csv>] — the
# seeded defaults for the budget.* hard caps (BH-4489), as ONE
# `INSERT OR IGNORE INTO settings ...;` statement on stdout.
#
# Each default is p99 x 2 of the window's real totals (nearest-rank p99,
# sorted[ceil(0.99 n) - 1]); calls and tokens round up to an integer, dollars
# up to the cent. Ceilings for runaways, not budgets. Below 100 samples the
# nearest-rank p99 IS the sample max, so a per-key row is 2x the largest value
# the window saw: the window itself trips none, but a key sized on a few dozen
# samples can trip on real growth. That is why the per-key minimums below are
# what they are, and why a key under its minimum falls to the pooled _default.
#
#   budget.stage.<s>.max_calls|max_usd|max_tokens  per (build run, stage)
#       totals. Only build run ids count (<project>-<KEY>-<n>[-r<n>]-<12 digits>,
#       the build-dir basename agent-call stamps). A row per stage with >= 20
#       build runs, plus budget.stage._default.* pooled over every build stage.
#   budget.stage.<s>.day_usd|day_calls             per (stage, project, UTC day)
#       totals. A row per stage with >= 30 such days, plus _default pooled
#       (a lane that ran on 16 days seeded synth.day_calls=2: 2x a max of 1).
#   budget.project.<p>.day_usd                      per (project, UTC day) totals.
#       A row per project with >= 14 distinct days, plus _default pooled.
#
# Rows read: D1 cost_rows for the last --days (default 30) through
# bin/lib/cost-rows-read.sh (GET /api/metrics/cost-rows, paged backwards by
# `until`), or a COST_ROW_HDR csv with --rows. Identical lines count once;
# row_source refused / settled rows are not calls and are dropped.
#
# A failed or capped read exits 1 and prints NOTHING: never a partial seed. A
# key over 64 characters (or outside [a-z0-9_.-]) is skipped and named on
# stderr, and so is an axis whose p99 x 2 is 0 (0 means "refuse everything"). Rows sort by key, so a re-run diffs cleanly. How the seed reaches D1:
# paste the statement into worker/jobs/schema.sql under its own comment;
# bin/harness-sync.sh applies it before deploy, and INSERT OR IGNORE keeps any
# value an operator or the self-host installer already wrote.
set -uo pipefail

usage() { sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; }

DAYS=30; NOW=""; ROWS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:-}"; shift 2 ;;
    --now)  NOW="${2:-}"; shift 2 ;;
    --rows) ROWS="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "budget-defaults.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*|0) echo "budget-defaults.sh: --days must be a positive integer" >&2; exit 2 ;; esac
[ -n "$NOW" ] || NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u -d "$NOW" +%s 2>/dev/null) || { echo "budget-defaults.sh: --now '$NOW' is not a date" >&2; exit 2; }
NOW=$(date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ)
SINCE=$(date -u -d "@$((NOW_EPOCH - DAYS * 86400))" +%Y-%m-%dT%H:%M:%SZ)

TMP=$(mktemp -d "${TMPDIR:-/tmp}/budget-defaults.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
CSV="$TMP/rows.csv"
if [ -n "$ROWS" ]; then
  [ -r "$ROWS" ] || { echo "budget-defaults.sh: --rows $ROWS is not readable" >&2; exit 1; }
  cp "$ROWS" "$CSV"
else
  # shellcheck source=bin/lib/cost-rows-read.sh
  . "$(dirname "$0")/lib/cost-rows-read.sh" || { echo "budget-defaults.sh: bin/lib/cost-rows-read.sh did not load" >&2; exit 1; }
  if ! cost_rows_fetch "$CSV" "$SINCE" "$NOW"; then
    echo "budget-defaults.sh: could not read cost_rows for $SINCE..$NOW (see logs/agent-rules.log); nothing printed" >&2
    exit 1
  fi
fi

# awk: header-name lookup, mawk-safe (no gawk extensions). Emits
# "key<TAB>value<TAB>n<TAB>unit" lines.
awk -F, '
  function ceil(x,  i) { i = int(x); return (x > i) ? i + 1 : i }
  function p99(arr, n,   i, j, t, k) {
    for (i = 2; i <= n; i++) { t = arr[i]; j = i - 1; while (j > 0 && arr[j] > t) { arr[j + 1] = arr[j]; j-- } arr[j + 1] = t }
    k = ceil(0.99 * n); if (k < 1) k = 1; return arr[k]
  }
  function num(x) { return (x ~ /^[0-9]+(\.[0-9]+)?$/) ? x + 0 : 0 }
  function emit(key, kind, v, n, unit,   o) {
    v = v * 2
    if (kind == "usd") o = sprintf("%.2f", ceil(v * 100 - 1e-6) / 100)
    else o = sprintf("%d", ceil(v - 1e-9))
    # 0 is "refuse everything" to the gate, so a window that measured nothing
    # on this axis (infra runs bill no tokens) seeds no cap rather than that.
    if (o + 0 <= 0) { printf "budget-defaults.sh: skipped %s (p99 x 2 is 0 over %d %ss; 0 would refuse every call)\n", key, n, unit > "/dev/stderr"; return }
    printf "%s\t%s\t%d\t%s\n", key, o, n, unit
  }
  # family <prefix> <keys...>: p99 of the values gathered in V[g, i] for group g
  NR == 1 {
    for (i = 1; i <= NF; i++) c[$i] = i
    if (!c["stage"] || !c["cost_usd"] || !c["run_id"] || !c["ts"] || !c["project"]) { bad = 1; exit 1 }
    next
  }
  !seen[$0]++ {
    rs = c["row_source"] ? $c["row_source"] : ""
    if (rs == "refused" || rs == "settled") next
    st = $c["stage"]; pj = $c["project"]; day = substr($c["ts"], 1, 10); rid = $c["run_id"]
    if (st == "" || pj == "" || day == "") next
    usd = num($c["cost_usd"])
    tok = num($c["input_toks"]) + num($c["output_toks"]) + num($c["cache_read"]) + num($c["cache_write"])
    if (rid ~ /^.+-[A-Z]+-[0-9]+(-r[0-9]+)?-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/) {
      k = rid SUBSEP st
      if (!(k in bc)) { bst[++nb] = k }
      bc[k]++; bu[k] += usd; bt[k] += tok
    }
    k = st SUBSEP pj SUBSEP day
    if (!(k in sc)) { sdk[++ns] = k }
    sc[k]++; su[k] += usd
    k = pj SUBSEP day
    if (!(k in pu)) { pdk[++np] = k }
    pu[k] += usd
  }
  END {
    if (bad) exit 1
    # build-stage, per stage and pooled
    for (i = 1; i <= nb; i++) {
      split(bst[i], a, SUBSEP); s = a[2]
      n = ++bn[s]; BC[s, n] = bc[bst[i]]; BU[s, n] = bu[bst[i]]; BT[s, n] = bt[bst[i]]
      m = ++pn; PC[m] = bc[bst[i]]; PU[m] = bu[bst[i]]; PT[m] = bt[bst[i]]
    }
    for (s in bn) {
      n = bn[s]; if (n < 20) continue
      for (j = 1; j <= n; j++) { x[j] = BC[s, j]; y[j] = BU[s, j]; z[j] = BT[s, j] }
      emit("budget.stage." s ".max_calls", "int", p99(x, n), n, "build run")
      emit("budget.stage." s ".max_usd", "usd", p99(y, n), n, "build run")
      emit("budget.stage." s ".max_tokens", "int", p99(z, n), n, "build run")
    }
    if (pn) {
      for (j = 1; j <= pn; j++) { x[j] = PC[j]; y[j] = PU[j]; z[j] = PT[j] }
      emit("budget.stage._default.max_calls", "int", p99(x, pn), pn, "build run")
      emit("budget.stage._default.max_usd", "usd", p99(y, pn), pn, "build run")
      emit("budget.stage._default.max_tokens", "int", p99(z, pn), pn, "build run")
    }
    # stage-day, per stage and pooled
    for (i = 1; i <= ns; i++) {
      split(sdk[i], a, SUBSEP); s = a[1]
      n = ++dn[s]; DC[s, n] = sc[sdk[i]]; DU[s, n] = su[sdk[i]]
      QC[i] = sc[sdk[i]]; QU[i] = su[sdk[i]]
    }
    for (s in dn) {
      n = dn[s]; if (n < 30) continue
      for (j = 1; j <= n; j++) { x[j] = DC[s, j]; y[j] = DU[s, j] }
      emit("budget.stage." s ".day_calls", "int", p99(x, n), n, "stage-day")
      emit("budget.stage." s ".day_usd", "usd", p99(y, n), n, "stage-day")
    }
    if (ns) {
      for (j = 1; j <= ns; j++) { x[j] = QC[j]; y[j] = QU[j] }
      emit("budget.stage._default.day_calls", "int", p99(x, ns), ns, "stage-day")
      emit("budget.stage._default.day_usd", "usd", p99(y, ns), ns, "stage-day")
    }
    # project-day, per project and pooled
    for (i = 1; i <= np; i++) {
      split(pdk[i], a, SUBSEP); p = a[1]
      n = ++pdn[p]; PD[p, n] = pu[pdk[i]]; RU[i] = pu[pdk[i]]
    }
    for (p in pdn) {
      n = pdn[p]; if (n < 14) continue
      for (j = 1; j <= n; j++) y[j] = PD[p, j]
      emit("budget.project." p ".day_usd", "usd", p99(y, n), n, "project-day")
    }
    if (np) {
      for (j = 1; j <= np; j++) y[j] = RU[j]
      emit("budget.project._default.day_usd", "usd", p99(y, np), np, "project-day")
    }
  }' "$CSV" > "$TMP/rows.tsv" || { echo "budget-defaults.sh: the rows could not be read as a cost.csv (no ts/project/stage/cost_usd/run_id header)" >&2; exit 1; }

LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$TMP/rows.tsv" > "$TMP/sorted.tsv"
: > "$TMP/values"
while IFS="$(printf '\t')" read -r key value n unit; do
  if ! grep -Eq '^[a-z0-9_.-]{1,64}$' <<<"$key"; then
    echo "budget-defaults.sh: skipped '$key' (not a legal settings key: [a-z0-9_.-], at most 64 chars)" >&2
    continue
  fi
  printf "  ('%s','%s','BH-4489: p99x2 of %s %ss, %s..%s, bin/budget-defaults.sh','seed','%s')\n" \
    "$key" "$value" "$n" "$unit" "$SINCE" "$NOW" "$NOW" >> "$TMP/values"
done < "$TMP/sorted.tsv"
[ -s "$TMP/values" ] || { echo "budget-defaults.sh: the window held no rows to size a default from; nothing printed" >&2; exit 1; }
echo "INSERT OR IGNORE INTO settings (key,value,note,actor,updated_at) VALUES"
sed '$!s/$/,/; $s/$/;/' "$TMP/values"
