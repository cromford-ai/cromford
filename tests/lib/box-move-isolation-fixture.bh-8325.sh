#!/bin/bash
# tests/lib/box-move-isolation-fixture.bh-8325.sh — the fixture of the
# `bin/box-move.sh isolation` suite (BH-8325). Sourced after tests/lib/scratch.sh,
# with REPO set to the checkout. Never executed.
#
# It sources the BH-8324 proof fixture (and through it the BH-8410 and C0
# fixtures) and adds:
#   - a curl stub that plays Orgo under https://orgo.fixture/api (state in
#     $C/orgo: comp.json is the old computer, others.json the rest of the
#     account; $C/orgo/stop-code makes POST /stop answer that code) and hands
#     every other URL to the proof fixture's curl stub. Each Orgo call lands
#     in $VC as `orgo <METHOD> <path>`.
#   - bmi_newcase <name>: a proof case after a real cut-over (B5 ok), with the
#     rows moved to the new box (`# @boxrole box-mkfly project-6-os build`,
#     as BH-8322 keeps the box id), the real bin/box-ops.sh closure on the
#     hub, a git checkout with origin/main for the tracked-file check,
#     BOX_MOVE_ISOLATION_PROJECTS=alpha-os and the clock at BMI_T0 (the
#     drill start).
#   - bmi_start: `isolation --step I1 --confirm` through the real CLI at
#     BMI_T0, then the clock at the end of the 72 h window.
#   - bmi_log <file> <epoch> <text>: a log line, with the file mtime pinned to
#     BMI_T0 + 60 (never the wall clock).
. "$(dirname "${BASH_SOURCE[0]}")/box-move-proof-fixture.bh-8324.sh" || return 1

BMI_T0=$(( BMP_E5 + BMP_W + 3600 ))   # the drill start: after the proof window
BMI_W=259200                          # the 72 h default window
BMI_KEY=orgo-key-fixture-8325

mv "$STUB/curl" "$STUB/curl-proof" || return 1
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
m=GET url=""
for a in "$@"; do case "$a" in https://orgo.fixture/*) url="$a" ;; esac; done
[ -n "$url" ] || exec "$(dirname "$0")/curl-proof" "$@"
while [ $# -gt 0 ]; do case "$1" in -X) m="$2"; shift ;; esac; shift; done
p="${url#https://orgo.fixture/api}"
printf 'orgo %s %s\n' "$m" "$p" >> "$VC"
O="$ORGO_D"; C="$O/comp.json"; OID=$(jq -r .id "$C")
case "$m $p" in
  "GET /computers") printf '%s\n%s' "$(jq -c --slurpfile c "$C" '. + $c' "$O/others.json")" 200 ;;
  "GET /computers/$OID") printf '%s\n%s' "$(cat "$C")" 200 ;;
  "POST /computers/$OID/stop")
    code=200; [ -f "$O/stop-code" ] && code=$(cat "$O/stop-code")
    [ "$code" = 200 ] || { printf '%s\n%s' '{}' "$code"; exit 0; }
    jq '.status = "stopped"' "$C" > "$C.t" && mv "$C.t" "$C"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  *) printf '%s\n%s' '{}' 404 ;;
esac
exit 0
EOF
chmod +x "$STUB/curl"

bmi_newcase() {
  bmp_newcase "$1"
  scratch_install_closure bin/box-ops.sh "$H" >/dev/null || bad "$1: box-ops closure into hub"
  printf '#!/bin/bash\necho box-hubfixture\n' > "$H/bin/box-name.sh"; chmod +x "$H/bin/box-name.sh"
  : > "$H/env/global.env"
  # The cut-over moved the rows: the projects are on the new box, which keeps
  # the old box id (BH-8322).
  awk -v o="$BM_OLD" -v n="$BM_NEW" -v i="$BM_NEW_IP" '!/^[[:space:]]*(#|$)/ && $6 == o {$6 = n; $7 = i} {print}' \
    "$H/fleet.conf" > "$H/fleet.conf.t" && mv "$H/fleet.conf.t" "$H/fleet.conf"
  printf '# @box %s %s\n# @boxrole %s project-6-os build\n' "$BM_NEW" "$BM_NEW_IP" "$BM_NEW" >> "$H/fleet.conf"
  export ORGO_D="$C/orgo" ORGO_API_BASE=https://orgo.fixture/api ORGO_API_KEY="$BMI_KEY" \
    BOX_LAUNCH_POLL_S=1 BOX_LAUNCH_DEADLINE_S=5 HARNESS_BOX_PREFIX=box-
  mkdir -p "$ORGO_D"
  printf '{"id":"c-project-6-os-fixture","name":"%s","status":"running"}\n' "$BM_OLD" > "$ORGO_D/comp.json"
  printf '[{"id":"c-other-fixture","name":"box-other","status":"running"}]\n' > "$ORGO_D/others.json"
  unset BOX_MOVE_ISOLATION_WINDOW_S BOX_MOVE_ISOLATION_MIN_PULL BOX_MOVE_ISOLATION_MIN_EACH \
    BOX_MOVE_RETIRE_CLEAN_S BOX_MOVE_ISOLATION_IP_ALLOW BOX_MOVE_ORGO_ACCOUNT
  # The drill judges alpha-os only, as the runbook sets project-6-os; a case
  # that unsets it judges every old-rows project.
  export BOX_MOVE_ISOLATION_PROJECTS=alpha-os
  # The checkout the tracked-file check reads: origin/main without the address.
  mkdir -p "$C/co/docs"
  printf 'fixture checkout\n' > "$C/co/docs/readme.md"
  bmi_git init -q && bmi_commit base || bad "$1: checkout git"
  export HUB_MOVE_NOW="$BMI_T0"
}
bmi_git() { git -C "$C/co" -c user.name=fixture -c user.email=fixture@example.com "$@"; }
# bmi_commit <msg> — commit the checkout tree and point origin/main at it.
bmi_commit() { bmi_git add -A && bmi_git commit -qm "$1" && bmi_git update-ref refs/remotes/origin/main HEAD; }
bmi_log() {
  mkdir -p "$(dirname "$1")"
  printf '%s %s\n' "$(bmp_stamp "$2")" "$3" >> "$1"
  touch -d "@$(( BMI_T0 + 60 ))" "$1"
}
# iso [args] — bin/box-move.sh isolation <args> <oldbox> <newbox>, with the
# jobs worker pointed at the curl stub (as the proof suite's pf).
iso() { JOBS_URL=https://jobs.example REGISTRY_SOURCE=file bm isolation "$@" "$BM_OLD" "$BM_NEW"; }
bmi_start() {
  export HUB_MOVE_NOW="$BMI_T0"
  iso --step I1 --confirm > "$C/out-I1" 2>&1 || bad "$C: setup I1 rc=$? $(tail -3 "$C/out-I1")"
  export HUB_MOVE_NOW=$(( BMI_T0 + BMI_W ))
}
# bmi_fill <project> — the minimum of every AC2/AC3 counter inside the window.
bmi_fill() {
  local p="$1" i r
  for i in 1 2 3 4 5; do
    bmi_log "$H/logs/fly-pool.log" $(( BMI_T0 + 100 * i )) "[pool/$p] m-fixture-$i: seeded 3 file(s) for BH-$i at launch; the machine fetches harness abc123 itself"
    bmi_log "$H/logs/fly-pool.log" $(( BMI_T0 + 100 * i + 50 )) "[pool/$p] reaped BH-$i from m-fixture-$i: DONE"
  done
  bmi_log "$H/logs/fly-pool.log" $(( BMI_T0 + 900 )) "[pool/$p] pool lead review reaped for LR-7 from m-fixture-9: APPROVE — the machine posted its own result"
  bmi_log "$NEW/logs/$p.log" $(( BMI_T0 + 900 )) "[$p] dispatched 2 shards: s1 s2 — skipped 0 held [gate=fixture]"
  bmp_fr_rows "$p" done $(( BMI_T0 + 1000 ))
  r=$(awk -v p="$p" '$1 == p {print $2; exit}' "$H/fleet.conf")
  bmp_search "$r" "$BMI_T0" $(( BMI_T0 + BMI_W )) \
    '{"total_count":1,"incomplete_results":false,"items":[{"number":11}]}'
  bmp_gh "repos/$r/pulls/11" '{"merged_by":{"login":"mergify[bot]"}}'
}
bmi_steps() { bmc_steps; }
bmi_line() { grep -F -- "$2" <<<"$1" | head -1; }
