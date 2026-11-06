#!/bin/bash
# tests/mc-rebind-restamp.bh-9066-test.sh — the merge conductor rebinds an
# approval across a schema RESTAMP AFTER A REBASE (BH-9066, slice C0), against
# real git, through the production entry point rebind_patch_id.
#
#   R1  reviewed R adds a stamp fragment; H is R rebased onto a newer main and
#       restamped (the land-rebase shape, #9000) -> rc 0, reviewed-sha = H, the
#       ledger rebind called, rebind.log and the REBOUND log line say
#       `rebound: restamp-rebase`, the REUSED event has how=restamp-rebase, and
#       no model command ran.
#   R2  the same, plus one changed code line -> rc 1, no rebind.log line, no
#       ledger rebind, reviewed-sha unchanged.
#   R3  mc_patch_same with 4 arguments (the failed-batch module's CI question)
#       on the R1 shape -> rc 1: the byte path is kept.
#   R4  the same 5-argument call with `review` -> same:restamp-rebase.
# A bare remote, the hub's clone under MC_REPOS, the real
# bin/lib/merge-conductor-lib.sh. mc_git_auth, the ledger rebind, the saving
# event and the lead carry are stubbed; a `claude` on PATH counts model calls.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HARNESS="$T/h" MC_REPOS="$T/repos"
mkdir -p "$T/h/config" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/repos" "$T/bin"
cp "$DIR/config/generated-paths.conf" "$T/h/config/" 2>/dev/null || true
printf '#!/bin/bash\necho call >> "%s/model-calls"\n' "$T" > "$T/bin/claude"; chmod +x "$T/bin/claude"
export PATH="$T/bin:$PATH"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh"
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
mc_git_auth() { MC_REMOTE="$T/remote.git"; return 0; }
mc_git_auth_clear() { :; }
job_verdict_rebind() { printf '%s %s\n' "$1" "$2" >> "$T/rebinds"; return 0; }
review_saving_event() { printf '%s\n' "$*" >> "$T/events"; return 0; }
lead_carry() { printf '%s\n' "$*" >> "$T/carries"; return 0; }
mc_rebind_publish() { return 0; }

S=worker/jobs/schema.d
OLD=202611041200-bh-1-a.sql; NEW=202611051300-bh-1-a.sql
W="$T/work"
w() { git -C "$W" "$@"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }

# fixture — main; a PR adding fragment a and a reference; R reviewed; then main
# moves and the PR is rebased onto it and restamped, H not yet committed.
fixture() {
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos/demo-os" 2>/dev/null
  scratch_rm "$T/rec" 2>/dev/null; rm -f "$T/rebinds" "$T/events" "$T/carries" "$T/model-calls"; : > "$MCLOG"
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  mkdir -p "$W/$S"; seq 1 30 | sed 's/^/line /' > "$W/f.txt"
  printf 'CREATE TABLE base (id INTEGER);\n' > "$W/$S/202610010000-bh-0-base.sql"
  commit base >/dev/null; push main
  w checkout -qb pr
  printf 'CREATE TABLE a (id INTEGER);\n' > "$W/$S/$OLD"; printf 'apply %s\n' "$OLD" > "$W/refs.txt"
  sed -i.bak '10s/.*/line 10 CHANGED BY PR/' "$W/f.txt" && rm -f "$W/f.txt.bak"
  R=$(commit pr-change); push pr
  git clone -q "$T/remote.git" "$T/repos/demo-os"
  mkdir -p "$T/rec"; echo "$R" > "$T/rec/reviewed-sha"
  w checkout -q main; printf 'main moved\n' > "$W/o.txt"; commit main-moved >/dev/null; push main
  w checkout -q pr; w rebase -q main >/dev/null 2>&1
  w mv "$S/$OLD" "$S/$NEW"; sed -i.bak "s/$OLD/$NEW/" "$W/refs.txt" && rm -f "$W/refs.txt.bak"
}
rebind() { rebind_patch_id "demo-os#7" demo-os example-org/demo-os 7 https://github.com/example-org/demo-os/pull/7 "$T/rec" "$R" "$1"; }

# ---- R1: restamp after a rebase -> rebound, no model call
fixture; H=$(commit "restamp schema fragments (no SQL change)"); push pr
rebind "$H"; rc=$?
[ "$rc" = 0 ] && ok || bad "R1 a restamp-after-rebase head must rebind (rc 0), got rc=$rc: $(tail -1 "$MCLOG" 2>/dev/null)"
[ "$(cat "$T/rec/reviewed-sha")" = "$H" ] && ok || bad "R1 reviewed-sha must move to the new head"
[ "$(cat "$T/rebinds" 2>/dev/null)" = "https://github.com/example-org/demo-os/pull/7 $H" ] && ok \
  || bad "R1 the ledger verdict must be rebound onto the new head: '$(cat "$T/rebinds" 2>/dev/null)'"
grep -q "approval rebound $R -> $H rebound: restamp-rebase (bin/lib/patch-same.sh; no reviewed content change)" "$T/rec/rebind.log" 2>/dev/null && ok \
  || bad "R1 rebind.log must carry the 'rebound: restamp-rebase' note: $(cat "$T/rec/rebind.log" 2>/dev/null)"
grep -q "REBOUND ${R:0:8} -> ${H:0:8}: rebound: restamp-rebase" "$MCLOG" && ok \
  || bad "R1 the conductor log must name the rung: $(tail -2 "$MCLOG" 2>/dev/null)"
grep -q "REUSED from=${R:0:12} to=${H:0:12} how=restamp-rebase" "$T/events" 2>/dev/null && ok \
  || bad "R1 the REUSED saving event must say how=restamp-rebase: $(cat "$T/events" 2>/dev/null)"
grep -q "same:restamp-rebase" "$T/carries" 2>/dev/null && ok \
  || bad "R1 the lead carry must get the reason same:restamp-rebase: $(cat "$T/carries" 2>/dev/null)"
[ ! -e "$T/model-calls" ] && ok || bad "R1 no model command may run: $(wc -l < "$T/model-calls") call(s)"

# ---- R2: restamp + one code line -> the re-review is bought
fixture; sed -i.bak '20s/.*/line 20 NEW CODE/' "$W/f.txt" && rm -f "$W/f.txt.bak"
H=$(commit "restamp plus code"); push pr
rebind "$H"; rc=$?
[ "$rc" = 1 ] && ok || bad "R2 a restamp with a code change must NOT rebind, got rc=$rc"
[ ! -s "$T/rec/rebind.log" ] && ok || bad "R2 no rebind.log line: $(cat "$T/rec/rebind.log")"
[ ! -s "$T/rebinds" ] && ok || bad "R2 no ledger rebind: $(cat "$T/rebinds")"
[ "$(cat "$T/rec/reviewed-sha")" = "$R" ] && ok || bad "R2 reviewed-sha must stay on the reviewed head"
grep -q "rebound: restamp" "$MCLOG" && bad "R2 the log must not claim a restamp rebind: $(tail -1 "$MCLOG")" || ok

# ---- R3/R4: the byte path stays for a 4-argument caller
fixture; H=$(commit "restamp schema fragments (no SQL change)"); push pr
mc_patch_same example-org/demo-os demo-os "$R" "$H" > "$T/out"; rc=$?; out=$(cat "$T/out")
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "R3 mc_patch_same with 4 args must stay byte (rc 1) on a restamp: rc=$rc out='$out'"
[ "${MC_PATCH_SAME_UNJUDGED:-}" = 0 ] && ok || bad "R3 a judged byte answer must clear MC_PATCH_SAME_UNJUDGED: '${MC_PATCH_SAME_UNJUDGED:-}'"
out=$(mc_patch_same example-org/demo-os demo-os "$R" "$H" review); rc=$?
[ "$rc" = 0 ] && [ "$out" = same:restamp-rebase ] && ok || bad "R4 mc_patch_same ... review must answer same:restamp-rebase: rc=$rc out='$out'"

echo "mc-rebind-restamp.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
