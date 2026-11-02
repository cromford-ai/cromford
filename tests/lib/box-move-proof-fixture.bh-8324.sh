#!/bin/bash
# tests/lib/box-move-proof-fixture.bh-8324.sh — the fixture of the
# `bin/box-move.sh proof` window suite (BH-8324). Sourced after
# tests/lib/scratch.sh, with REPO set to the checkout. Never executed.
#
# It sources the BH-8410 cutover fixture (and through it the C0 fixture) and
# replaces two PATH stubs with ones that answer from case files:
#   - gh: records argv in $VC; answers from $BMP_DIR/gh-map, lines
#     `<fixed string>\t<file>|FAIL<rc>`; the LAST line whose string is in
#     " <argv> " wins; no match is rc 1.
#   - curl: records argv in $VC; a POST lands in $JOBS_ROWS as before; a GET
#     of /api/fix-rounds?project=<p>&status=<s> answers $BMP_DIR/fr-<p>-<s>.json
#     with HTTP 200 (or the code in fr-<p>-<s>.json.http), and 503 when the
#     case wrote no file.
#
# bmp_newcase <name> builds a BH-8410 case with a seeded new box and the hub
# record of a drill and a real cut-over in steps.tsv (B2 ok at BMP_E2, B5 ok
# at BMP_E5), old-rows.tsv with alpha-os and beta-os, the clock at the end of
# the after window, and every source empty but present: each log has one old
# line, every fix-round answer is empty, every merge search answers 0.
. "$(dirname "${BASH_SOURCE[0]}")/box-move-cutover-fixture.bh-8410.sh" || return 1

BMP_E2=1793059200            # 2026-10-27 00:00:00Z: the last B2 ok
BMP_E5=$(( BMP_E2 + 600 ))   # the last B5 ok
BMP_W=86400

# A real ssh does not carry the hub env to the box: the C0 ssh stub passes it
# through, so the jobs worker URL pf sets for the hub is blanked on the box.
sed -i 's|CRONTAB_FILE="$root/crontab" bash -c|CRONTAB_FILE="$root/crontab" JOBS_URL= bash -c|' "$STUB/ssh"
grep -q 'JOBS_URL= bash -c' "$STUB/ssh" || { echo "proof fixture: cannot patch the ssh stub" >&2; return 1; }
cat > "$STUB/gh" <<'EOF'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$VC"
hit=""
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] || continue
  case " $* " in *"$k"*) hit="$v" ;; esac
done < "$BMP_DIR/gh-map"
[ -n "$hit" ] || { echo "gh stub: no fixture for: $*" >&2; exit 1; }
case "$hit" in FAIL*) exit "${hit#FAIL}" ;; esac
cat "$hit"
EOF
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$VC"
case " $* " in *" -X POST "*|*" -d "*) printf 'row %s\n' "$*" >> "$JOBS_ROWS"; exit 0 ;; esac
url="${*: -1}"
case "$url" in
  *"/api/fix-rounds?"*)
    p=$(sed -n 's/.*[?&]project=\([^&]*\).*/\1/p' <<<"$url")
    s=$(sed -n 's/.*[?&]status=\([^&]*\).*/\1/p' <<<"$url")
    f="$BMP_DIR/fr-$p-$s.json"
    if [ -f "$f" ]; then
      code=200; [ -f "$f.http" ] && code=$(cat "$f.http")
      cat "$f"; printf '\n%s' "$code"
    else
      printf '{"error":"fixture down"}\n503'
    fi ;;
esac
exit 0
EOF
chmod +x "$STUB/gh" "$STUB/curl"

bmp_stamp() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
bmp_iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
bmp_gh_date() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S+00:00'; }
# bmp_log <file> <epoch> <text> — one log line in the format the lanes write.
bmp_log() { mkdir -p "$(dirname "$1")"; printf '%s %s\n' "$(bmp_stamp "$2")" "$3" >> "$1"; }
# bmp_step <epoch> <step> <status> [<detail>] — one steps.tsv row (BH-8410 format).
bmp_step() {
  mkdir -p "$H/state/box-move/$BM_NEW"
  printf '%s\t%s\t%s\t%s\n' "$(bmp_iso "$1")" "$2" "$3" "${4:-}" >> "$H/state/box-move/$BM_NEW/steps.tsv"
}
# bmp_drill <elapsed_s> — a drill cut-over and its rollback, before the real one.
bmp_drill() {
  local s
  for s in B1 B2 B3 B4 B5; do bmp_step $(( BMP_E2 - 9000 )) "$s" ok "drill"; done
  for s in B1 B2 B3 B4 B5; do bmp_step $(( BMP_E2 - 7000 )) "$s" reset rollback; done
  bmp_step $(( BMP_E2 - 7000 )) rollback ok "old crontab 2 lines, rows back on $BM_OLD elapsed_s=$1"
}
bmp_cutover() {
  bmp_step $(( BMP_E2 - 600 )) B1 ok "tick ok"
  bmp_step "$BMP_E2" B2 ok "crontab saved and removed, drained"
  bmp_step $(( BMP_E2 + 200 )) B3 ok "snapshot 20261026T010203Z"
  bmp_step $(( BMP_E2 + 400 )) B4 ok "projects alpha-os,beta-os on $BM_NEW"
  bmp_step "$BMP_E5" B5 ok "tick: lanes=2 ok=2 crontab_active=3"
}
# bmp_gh <fixed string> <json|FAIL<rc>> — one gh answer.
bmp_gh() {
  local f
  case "$2" in FAIL*) printf '%s\t%s\n' "$1" "$2" >> "$BMP_DIR/gh-map"; return ;; esac
  f="$BMP_DIR/gh-$(wc -l < "$BMP_DIR/gh-map").json"
  printf '%s\n' "$2" > "$f"
  printf '%s\t%s\n' "$1" "$f" >> "$BMP_DIR/gh-map"
}
# bmp_search <repo> <since epoch> <until epoch> <json|FAIL<rc>> — the merge
# search answer for one window, keyed by the query the proof builds.
bmp_search() { bmp_gh "q=repo:$1 is:pr is:merged merged:$(bmp_gh_date "$2")..$(bmp_gh_date $(( $3 - 1 )))" "$4"; }
bmp_before() { echo $(( BMP_E2 - BMP_W )) "$BMP_E2"; }
bmp_after() { echo "$BMP_E5" $(( BMP_E5 + BMP_W )); }
# bmp_fr <project> <status> <json> — the fix-round list answer.
bmp_fr() { printf '%s\n' "$3" > "$BMP_DIR/fr-$1-$2.json"; }
# bmp_fr_rows <project> <status> <epoch>... — rows finished at each epoch.
bmp_fr_rows() {
  local p="$1" s="$2" e rows="" i=0
  shift 2
  for e in "$@"; do
    i=$((i+1)); rows+="${rows:+,}{\"id\":$i,\"project\":\"$p\",\"status\":\"$s\",\"finished_at\":\"$(bmp_iso "$e" | sed 's/Z$/.123Z/')\"}"
  done
  bmp_fr "$p" "$s" "{\"fix_round_jobs\":[$rows],\"truncated\":false,\"as_of\":\"2026-10-28T00:00:00Z\"}"
}
# bmp_triage <box root> <project> <epoch> [<n>] — n triage tick lines from <epoch>.
bmp_triage() {
  local i
  for i in $(seq 1 "${4:-1}"); do
    bmp_log "$1/logs/$2.log" $(( $3 + i )) "[$2] rc=0 :: tickets=0 [gate=fixture]"
  done
}

bmp_newcase() {
  local p r s e
  bmc_newcase "$1"; bm_seeded_target
  export BMP_DIR="$C"
  : > "$C/gh-map"
  printf '0.50 2.00 1.00 1/100 1\n' > "$C/loadavg"
  export BOX_MOVE_PROC_LOADAVG="$C/loadavg" BOX_MOVE_NPROC=4
  export HUB_MOVE_NOW=$(( BMP_E5 + BMP_W ))
  unset BOX_MOVE_PROOF_WINDOW_S BOX_MOVE_PROOF_SLACK BOX_MOVE_ROLLBACK_BUDGET_S
  {
    printf 'box\t%s\t%s\t%s\tbuild\n' "$BM_OLD" "${BM_OLD##*-}" "$BM_OLD_IP"
    printf 'project\talpha-os\nproject\tbeta-os\n'
  } > "$H/state/box-move/$BM_NEW/old-rows.tsv"
  bmp_drill 120
  bmp_cutover
  e=$(( BMP_E2 - BMP_W - 3600 ))
  for p in alpha-os beta-os; do
    bmp_log "$OLD/logs/$p.log" "$e" "[$p] paused via console, skipping"
    bmp_log "$NEW/logs/$p.log" "$e" "[$p] paused via console, skipping"
    for s in done adopted; do bmp_fr_rows "$p" "$s"; done
  done
  bmp_log "$H/logs/fly-pool.log" "$e" "[pool/alpha-os] tick start"
  bmp_log "$H/logs/ALERTS.log" "$e" "[jobs-watchdog] fixture start"
  for r in o/alpha o/beta; do
    # shellcheck disable=SC2046
    bmp_search "$r" $(bmp_before) '{"total_count":0,"incomplete_results":false,"items":[]}'
    # shellcheck disable=SC2046
    bmp_search "$r" $(bmp_after) '{"total_count":0,"incomplete_results":false,"items":[]}'
  done
}
# pf — bin/box-move.sh proof, with the jobs worker pointed at the curl stub.
# The rows stay the case's fleet.conf (REGISTRY_SOURCE=file): with a worker
# URL set, the BH-8410 db mode would read the registry through the same stub.
pf() { JOBS_URL=https://jobs.example REGISTRY_SOURCE=file bm proof "$BM_OLD" "$BM_NEW"; }
# bmp_line <output> <prefix> — the one output line that starts with <prefix>.
bmp_line() { grep -F -- "$2" <<<"$1" | head -1; }
