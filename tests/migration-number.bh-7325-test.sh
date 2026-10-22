#!/bin/bash
# tests/migration-number.bh-7325-test.sh — BH-7325: a build reserves its
# migration number (<dir>/NNNN_<name>.sql) before it writes the file, and the
# pre-review self-check refuses a number main or another open PR holds.
# bin/lib/migration-number.sh, bin/migration-number.sh, the `migration-number`
# row of catalog/pr-self-check.d/ and the plan-stage block in bin/lib/rb/plan.sh.
#
#   C1-C5  the five collisions of 2026-10-17 on example-org/project-6
#          (tests/fixtures/migration-number/bh-7325-project-6-2026-10-17.tsv),
#          replayed through mn_plan_note against one reservation store: each
#          picked number was taken, each allocation is free, C2 != C3
#   R1-R12 the decision table: numbered names, floor sources, taken by main,
#          taken by an open PR, page 2, own PR by ref and by sha, unconfigured
#          project, a modification, a renamed-away number, a closed PR
#   P1-P3  the plan.sh block between its markers: a note and a reserve; no
#          lib = no note; an unconfigured project = no note
#   E1-E3  worker down, GitHub down, both: the build goes on, the line says so
#   K1-K2  MIGRATION_NUMBER_RESERVE=0; main with no numbered file
#   RT1-RT3 the reserve body matches the shared fixture; the
#          migration-number.txt line parses back; the rule's text through
#          bin/pr-self-check.sh check
#   V1-V3  the CLI verbs floor, reserve and taken, as their header documents
#   B1a-B1d two open PRs add one number: only one is refused. The holder of
#          the reservation keeps it; with no holder of the two, the older PR
#          (lower number) keeps it (lead review on 5bf9595a0, BLOCK 1)
#   B2a-B2c settings AND the worker both down: the self-check says so in one
#          NOTE and the plan note tells the builder to reserve by hand, never
#          silence (lead review on 5bf9595a0, BLOCK 2)
#   K3     the settings row migration_number.reserve = 0 turns the plan note off
#
# The worker (`_jobs_req`) and settings (`setting_get`) are a stub
# bin/jobs-client.sh in the scratch harness; GitHub is a stub `gh` on PATH that
# bin/lib/gh-rest.sh calls exactly as it calls the real one.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/migration-number.bh-7325-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset PR_SELF_CHECK_CATALOG PR_SELF_CHECK_ONLY PSC_TICKET_FILE PSC_PR_KEY PSC_PROJECT MIGRATION_NUMBER_RESERVE GH_TOKEN BUILD

LIB="$SRC/bin/lib/migration-number.sh"
CLI="$SRC/bin/migration-number.sh"
ROW="$SRC/catalog/pr-self-check.d/bh-7325-migration-number.tsv"
FIX="$SRC/tests/fixtures/migration-number/bh-7325-project-6-2026-10-17.tsv"
BODYFIX="$SRC/tests/fixtures/migration-number/bh-7325-reserve-body.json"
for f in "$LIB" "$CLI" "$ROW"; do [ -r "$f" ] || bad "missing: ${f#"$SRC"/}"; done
[ "$FAIL" = 0 ] || { echo "migration-number.bh-7325: PASS=$PASS FAIL=$FAIL"; exit 1; }

H="$T/h"; mkdir -p "$H/bin" "$T/stub" "$T/tmp" "$T/b" "$T/gh"
# The stub client, installed BEFORE the closure so the closure keeps it.
cat > "$T/jc-stub.sh" <<'STUB'
# test stub: settings from $MNT_SETTINGS, the reserve route over $MNT_RES with
# the worker's rule (max(floor, top + 1); a key at or above the floor keeps it)
setting_get() {
  local v
  [ -e "$MNT_SET_DOWN" ] && return 1
  v=$(awk -F'\t' -v k="$1" '$1 == k { print $2; f = 1 } END { exit !f }' "$MNT_SETTINGS" 2>/dev/null) || return 2
  printf '%s\n' "$v"
}
_jobs_req() {
  if [ "$1" = GET ] && [[ "$2" == /api/migration-numbers/holder\?* ]]; then
    [ -e "$MNT_DOWN" ] && return 1
    local q="${2#*\?}" hp hn hk
    hp=$(sed -n 's/.*project=\([^&]*\).*/\1/p' <<<"$q"); hn=$(sed -n 's/.*number=\([0-9]*\).*/\1/p' <<<"$q")
    hk=$(awk -F'\t' -v p="$hp" -v n="$hn" '$1 == p && $3 + 0 == n + 0 { print $2; exit }' "$MNT_RES" 2>/dev/null)
    if [ -n "$hk" ]; then printf '{"ticket_key":"%s","as_of":"x"}' "$hk"; else printf '{"ticket_key":null,"as_of":"x"}'; fi
    return 0
  fi
  [ "$1" = POST ] && [ "$2" = /api/migration-numbers/reserve ] || return 1
  printf '%s\n' "$3" >> "$MNT_REQ"
  [ -e "$MNT_DOWN" ] && return 1
  local p k f cur top n reused=false
  p=$(jq -r .project <<<"$3"); k=$(jq -r .ticket_key <<<"$3"); f=$(jq -r .floor <<<"$3")
  touch "$MNT_RES"
  cur=$(awk -F'\t' -v p="$p" -v k="$k" '$1 == p && $2 == k { print $3 }' "$MNT_RES")
  top=$(awk -F'\t' -v p="$p" '$1 == p && $3 + 0 > m { m = $3 + 0 } END { print m + 0 }' "$MNT_RES")
  n=$((top + 1)); [ "$f" -gt "$n" ] && n=$f
  if [ -n "$cur" ] && [ "$cur" -ge "$f" ]; then n=$cur; reused=true
  else
    awk -F'\t' -v p="$p" -v k="$k" '!($1 == p && $2 == k)' "$MNT_RES" > "$MNT_RES.n"; mv "$MNT_RES.n" "$MNT_RES"
    printf '%s\t%s\t%s\n' "$p" "$k" "$n" >> "$MNT_RES"
  fi
  printf '{"number":%d,"reused":%s,"as_of":"2026-10-17T12:00:00Z"}' "$n" "$reused"
}
STUB
cp "$T/jc-stub.sh" "$H/bin/jobs-client.sh"
for s in bin/migration-number.sh bin/pr-self-check.sh bin/lib/migration-number.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure of $s"; exit 1; }
done
# The stub gh: the open PR list and each PR's files from $MNT_GH; a missing
# page is []; $MNT_GH/fail answers 502 to everything, fail-<n> to #n's files.
cat > "$T/stub/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$MNT_GH_LOG"
p=""; for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
[ -e "$MNT_GH/fail" ] && { printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; }
f=/nonexistent
case "$p" in
  repos/*/pulls\?state=open*) f="$MNT_GH/pulls-${p##*page=}.json" ;;
  repos/*/pulls/*/files\?*) n=${p#*/pulls/}; n=${n%%/*}
    [ -e "$MNT_GH/fail-$n" ] && { printf 'HTTP/2 502\r\n\r\n{"message":"bad gateway"}\n'; exit 1; }
    f="$MNT_GH/files-$n-${p##*page=}.json" ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
esac
printf 'HTTP/2 200\r\n\r\n'
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
STUB
printf '#!/bin/bash\ntouch "%s/model-called"\n' "$T" > "$T/stub/claude"
chmod +x "$T/stub/gh" "$T/stub/claude"
export HARNESS="$H" FLEET_CONF="$T/fleet.conf" PATH="$T/stub:$PATH" GH_ETAG=0 TMPDIR="$T/tmp"
export MNT_SETTINGS="$T/settings.tsv" MNT_RES="$T/res.tsv" MNT_REQ="$T/req.jsonl" MNT_DOWN="$T/jobs.down" MNT_SET_DOWN="$T/settings.down" \
       MNT_GH="$T/gh" MNT_GH_LOG="$T/gh.log"
cat > "$FLEET_CONF" <<'CONF'
project-6-os  example-org/project-6  -  -  1  box-mk  192.0.2.10
app-os        Example/app          -  -  1  box-app 192.0.2.11
other         Example/other        -  -  1  box-app 192.0.2.11
CONF
printf 'migrations_glob.project-6-os\tprisma/sql/*.sql\nmigrations_glob.app-os\tprisma/sql/*.sql\n' > "$MNT_SETTINGS"

# ── GitHub stub helpers ───────────────────────────────────────────────────────
gh_reset() { scratch_rm "$MNT_GH"; mkdir -p "$MNT_GH"; echo '[]' > "$MNT_GH/pulls-1.json"; : > "$MNT_GH_LOG"; }
gh_pr() { # <n> <head-ref> <head-sha>
  jq -c --argjson n "$1" --arg r "$2" --arg s "$3" '. + [{number: $n, head: {ref: $r, sha: $s}}]' \
    "$MNT_GH/pulls-1.json" > "$MNT_GH/p.tmp" && mv "$MNT_GH/p.tmp" "$MNT_GH/pulls-1.json"
}
gh_file() { # <n> <status> <path> [page]
  local f="$MNT_GH/files-$1-${4:-1}.json"
  [ -f "$f" ] || echo '[]' > "$f"
  jq -c --arg p "$3" --arg s "$2" '. + [{filename: $p, status: $s}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
# drive <code> — the lib sourced in a fresh shell (stub client first, as
# run-build has it), then <code>
drive() { bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/migration-number.sh"; eval "$1"' _ "$1"; }
has() { grep -qF -- "$2" <<<"$1"; }

# ════════════════════════════════════════════════════════════════════════════
# C1-C5: the replay. One repo whose main is rebuilt per case; one store.
# ════════════════════════════════════════════════════════════════════════════
MK="$T/mk"; mkdir -p "$MK"; git -C "$MK" init -q -b main
git -C "$MK" remote add origin https://github.com/example-org/project-6.git
: > "$MNT_RES"; : > "$MNT_REQ"
declare -A GOT
while IFS=$'\t' read -r cs tu pr key picked main open taken want; do
  case "$cs" in C[0-9]*) ;; *) continue ;; esac
  scratch_rm "$MK/prisma"; mkdir -p "$MK/prisma/sql"
  for m in ${main//,/ }; do echo "-- $m" > "$MK/prisma/sql/$m.sql"; done
  git -C "$MK" add -A; git -C "$MK" commit -qm "main at $tu" --allow-empty
  git -C "$MK" update-ref refs/remotes/origin/main HEAD
  gh_reset
  for o in ${open//,/ }; do
    n=${o%%:*}; n=${n#\#}; gh_pr "$n" "replay/pr$n" "0000000000000000000000000000000000$n"
    gh_file "$n" added "prisma/sql/${o#*:}.sql"
  done
  mkdir -p "$T/build-$cs"
  NOTE=$(cd "$MK" && BUILD="$T/build-$cs" drive "mn_plan_note project-6-os $key . origin/main ticket/${key,,}")
  LINE=$(cat "$T/build-$cs/migration-number.txt" 2>/dev/null)
  n=$(awk '{print $2}' <<<"$LINE"); GOT[$cs]=$n
  [ "$n" = "$want" ] && ok || bad "$cs ($pr at $tu): want $want, got '${n}' (line: $LINE)"
  has "$LINE" " reserved " && ok || bad "$cs: want a reserved number, got: $LINE"
  # the collision was real: every picked number is in taken_by
  tk=$(tr ',' '\n' <<<"$taken" | sed 's/.*://')
  for p in ${picked//,/ }; do grep -qx "$p" <<<"$tk" && ok || bad "$cs: picked $p is not in taken_by ($taken)"; done
  # the allocation is free: not on main, in an open PR, a holder, or another key's reservation
  used=$( { tr ',' '\n' <<<"$main" | cut -c1-4; tr ',' '\n' <<<"$open" | sed 's/^#[0-9]*://' | cut -c1-4; printf '%s\n' "$tk";
            awk -F'\t' -v k="$key" '$2 != k { printf "%04d\n", $3 }' "$MNT_RES"; } )
  grep -qx "$n" <<<"$used" && bad "$cs: $n is already used ($(tr '\n' ' ' <<<"$used"))" || ok
  has "$NOTE" "name it prisma/sql/${want}_<name>.sql" && has "$NOTE" "$want is reserved for $key" \
    && ok || bad "$cs: the note does not name $want for $key: $NOTE"
  if [ "$cs" = C2 ]; then
    tail -1 "$MNT_REQ" > "$T/c2-body.json"
    # a rebuild of the same ticket on the same state keeps its number
    (cd "$MK" && BUILD="$T/build-C2" drive "mn_plan_note project-6-os $key . origin/main") >/dev/null
    has "$(cat "$T/build-C2/migration-number.txt")" "MIGRATION_NUMBER: 0164 reused" && ok || bad "C2 rebuild: want 0164 reused, got $(cat "$T/build-C2/migration-number.txt")"
  fi
  [ "$cs" = C1 ] && cp "$T/build-C1/migration-number.txt" "$T/c1-line.txt"
done < "$FIX"
[ "${#GOT[@]}" = 5 ] && ok || bad "C: want 5 replayed cases, got ${#GOT[@]}"
[ -n "${GOT[C2]:-}" ] && [ "${GOT[C2]:-}" != "${GOT[C3]:-}" ] && ok || bad "C2/C3 same minute: want two numbers, got '${GOT[C2]:-}' and '${GOT[C3]:-}'"
[ ! -e "$T/model-called" ] && ok || bad "P2: the allocator called a model"

# RT1: the body mn_reserve sent for C2 is the shared fixture, field by field
for k in project ticket_key floor; do
  [ "$(jq -c ".$k" "$T/c2-body.json" 2>/dev/null)" = "$(jq -c ".$k" "$BODYFIX")" ] && ok || bad "RT1: .$k differs: $(cat "$T/c2-body.json" 2>/dev/null) vs $(cat "$BODYFIX")"
done
# RT2: the migration-number.txt line parses back
RT_RE='^MIGRATION_NUMBER: ([0-9]{4}) (reserved|reused|unreserved) floor=([0-9]{4}) main_max=([0-9]{4}) pr_max=([0-9]{4}) prs_read=([0-9]+) incomplete=(.+)$'
if [[ "$(cat "$T/c1-line.txt" 2>/dev/null)" =~ $RT_RE ]]; then
  [ "${BASH_REMATCH[1]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[5]} ${BASH_REMATCH[6]} ${BASH_REMATCH[7]}" = "0149 0149 0146 0148 2 no" ] \
    && ok || bad "RT2: C1 fields: ${BASH_REMATCH[*]}"
else bad "RT2: the C1 line does not parse: $(cat "$T/c1-line.txt" 2>/dev/null)"; fi
# A rebuild of C2's ticket on C5's state: 0164 is below the new floor 0167, so
# the row moves up past the top reservation (0168) to 0169
(cd "$MK" && BUILD="$T/build-C2" drive "mn_plan_note project-6-os TK-1149 . origin/main") >/dev/null
has "$(cat "$T/build-C2/migration-number.txt")" "MIGRATION_NUMBER: 0169 reserved floor=0167" && ok || bad "C2 rebuild after C5: want 0169 reserved, got $(cat "$T/build-C2/migration-number.txt")"

# ════════════════════════════════════════════════════════════════════════════
# R: the decision table, through bin/pr-self-check.sh with only the new row
# ════════════════════════════════════════════════════════════════════════════
CAT="$T/cat/pr-self-check.tsv"; mkdir -p "$T/cat/pr-self-check.d"
printf '# scratch catalog: the BH-7325 row only\n' > "$CAT"
cp "$ROW" "$T/cat/pr-self-check.d/"
printf '## Summary\nAdds a migration.\n' > "$T/b/body.md"
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q -b main
git -C "$R" remote add origin https://github.com/Example/app.git
mkdir -p "$R/prisma/sql/sub" "$R/prisma/migrations/0996_x" "$R/src"
for f in prisma/sql/0157_base.sql prisma/sql/0158_agent_tool_call.sql prisma/sql/0999-x.sql prisma/sql/999_x.sql \
         prisma/sql/sub/0998_x.sql prisma/sql/0997_x.sql.bak prisma/migrations/0996_x/migration.sql src/a.ts; do
  echo "-- $f" > "$R/$f"
done
git -C "$R" add -A; git -C "$R" commit -qm M0
br() { git -C "$R" checkout -q main && git -C "$R" checkout -qB "$1"; }
cm() { git -C "$R" add -A && git -C "$R" commit -qm "$1"; }
run() { # <head> [catalog] — the CLI, the rule alone; OUT, RC
  OUT=$(PR_SELF_CHECK_CATALOG="${2:-$CAT}" bash "$H/bin/pr-self-check.sh" check \
        --repo "$R" --base main --head "$1" --body "$T/b/body.md" --only '^migration-number$' 2>/dev/null); RC=$?
}

# R1: main's numbered files only; R2: added and renamed PR files count, a modified one does not
gh_reset
FL=$(bash "$H/bin/migration-number.sh" floor app-os --repo "$R" --ref main 2>/dev/null); FRC=$?
[ "$FRC" = 0 ] && [ "$FL" = 0159 ] && ok || bad "R1 floor: want 0159 (0999-x, 999_x, sub/, .bak, migrations/ ignored), got rc $FRC '$FL'"
gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
gh_pr 1150 r-b bbbb; gh_file 1150 modified prisma/sql/0170_mod.sql
gh_pr 1151 r-c cccc; gh_file 1151 renamed prisma/sql/0165_ren.sql
FL=$(bash "$H/bin/migration-number.sh" floor app-os --repo "$R" --ref main 2>/dev/null)
[ "$FL" = 0166 ] && ok || bad "R2 floor: want 0166 (added 0164, renamed 0165; modified 0170 ignored), got '$FL'"

# R3: the numbered shape
R3=$(drive 'for p in prisma/sql/0158_agent_push_backlog.sql prisma/sql/0183_internal_domain_owner.sql prisma/sql/158_x.sql prisma/sql/0158-x.sql prisma/sql/sub/0158_x.sql prisma/migrations/0158_x/migration.sql prisma/sql/0158_x.sql.bak; do printf "%s=%s " "${p##*/}" "$(mn_num_of prisma/sql "$p" || echo no)"; done')
[ "$R3" = "0158_agent_push_backlog.sql=0158 0183_internal_domain_owner.sql=0183 158_x.sql=no 0158-x.sql=no 0158_x.sql=no migration.sql=no 0158_x.sql.bak=no " ] \
  && ok || bad "R3 numbered shape: $R3"

# R4: taken by main, under another name (C4's shape)
gh_reset
br r4; echo "-- push backlog" > "$R/prisma/sql/0158_agent_push_backlog.sql"; cm r4
run r4
[ "$RC" = 1 ] && has "$OUT" "REFUSE migration-number: migration number 0158 taken by main (prisma/sql/0158_agent_tool_call.sql); next free: 0159" \
  && ok || bad "R4 taken by main: rc $RC: $OUT"
# RT3: the same through the real catalog file and its real .d/ rows
run r4 "$SRC/catalog/pr-self-check.tsv"
[ "$RC" = 1 ] && has "$OUT" "migration number 0158 taken by main" && ok || bad "RT3 real catalog: rc $RC: $OUT"

# R5: taken by another open PR (C5's shape)
gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
br r5; echo "-- mine" > "$R/prisma/sql/0164_mine.sql"; cm r5
run r5
[ "$RC" = 1 ] && has "$OUT" "REFUSE migration-number: migration number 0164 taken by #1149 (prisma/sql/0164_replay_pr1149.sql); next free: 0165" \
  && ok || bad "R5 taken by #1149: rc $RC: $OUT"
has "$(cat "$MNT_GH_LOG")" "pulls?state=open" && ok || bad "R12a: the list read is not state=open: $(cat "$MNT_GH_LOG")"

# R6: the other PR's file is on page 2 of its files
gh_reset; gh_pr 1200 r-d dddd
jq -nc '[range(100) | {filename: "src/f\(.).ts", status: "added"}]' > "$MNT_GH/files-1200-1.json"
gh_file 1200 added prisma/sql/0164_page_two.sql 2
run r5
[ "$RC" = 1 ] && has "$OUT" "taken by #1200 (prisma/sql/0164_page_two.sql)" && ok || bad "R6 page 2: rc $RC: $OUT"

# R7: own PR found by head ref (the local branch) is not a collision
br r7; echo "-- mine" > "$R/prisma/sql/0161_mine.sql"; cm r7
gh_reset; gh_pr 1300 r7 "$(git -C "$R" rev-parse r7)-not"; gh_file 1300 added prisma/sql/0161_mine.sql
run r7
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "R7 own PR by ref: rc $RC: $OUT"
# R8: own PR found by head sha on a detached head (the lead-review clone)
br r8; echo "-- mine" > "$R/prisma/sql/0162_mine.sql"; cm r8
S8=$(git -C "$R" rev-parse r8); git -C "$R" checkout -q --detach "$S8"
gh_reset; gh_pr 1301 some-other-name "$S8"; gh_file 1301 added prisma/sql/0162_mine.sql
run "$S8"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "R8 own PR by sha: rc $RC: $OUT"
git -C "$R" checkout -q main

# R9: a project with no migrations_glob row: silent, no GitHub read
git -C "$R" remote set-url origin https://github.com/Example/other.git
gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
run r5
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$MNT_GH_LOG" ] && ok || bad "R9 unconfigured project: rc $RC, gh calls $(wc -l < "$MNT_GH_LOG"): $OUT"
git -C "$R" remote set-url origin https://github.com/Example/app.git

# R10: a modification of a migration on main is not an add
br r10; echo "-- edited" >> "$R/prisma/sql/0158_agent_tool_call.sql"; cm r10
gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0158_other.sql
run r10
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "R10 modification: rc $RC: $OUT"

# R11: a PR that renamed away from 0161 holds 0165, not 0161; R12: a closed PR
# (not in the open list) and a modified file in an open PR are not holders;
# a non-numbered add and a file outside the dir are not checked
br r11; echo "-- mine" > "$R/prisma/sql/0161_mine.sql"; echo x > "$R/prisma/sql/0161-dash.sql"; echo x > "$R/src/0161_x.sql"; cm r11
gh_reset
gh_pr 1400 r-e eeee; gh_file 1400 renamed prisma/sql/0165_runtime_retention.sql
gh_pr 1501 r-f ffff; gh_file 1501 modified prisma/sql/0161_old.sql
gh_file 1500 added prisma/sql/0161_closed.sql
run r11
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "R11/R12 renamed-away, closed, modified, non-numbered: rc $RC: $OUT"

# NOTE path: GitHub down. Main findings still refuse; a PR-only collision is a NOTE.
gh_reset; touch "$MNT_GH/fail"
run r4
[ "$RC" = 1 ] && has "$OUT" "REFUSE migration-number: migration number 0158 taken by main" \
  && has "$OUT" "NOTE migration-number: open PRs not read (open PR list read failed (HTTP 502)), only main was checked" \
  && ok || bad "E-psc main with GitHub down: rc $RC: $OUT"
run r5
[ "$RC" = 0 ] && ! has "$OUT" REFUSE && has "$OUT" "NOTE migration-number: open PRs not read" && ok || bad "E-psc PR-only with GitHub down: rc $RC: $OUT"
# mode note: the same finding, no refusal
sed 's/^migration-number\trefuse/migration-number\tnote/' "$ROW" > "$T/cat/pr-self-check.d/bh-7325-migration-number.tsv"
gh_reset; run r4
[ "$RC" = 0 ] && has "$OUT" "NOTE migration-number: migration number 0158 taken by main" && ok || bad "mode note: rc $RC: $OUT"
cp "$ROW" "$T/cat/pr-self-check.d/"

# ════════════════════════════════════════════════════════════════════════════
# V1-V3: the CLI verbs
# ════════════════════════════════════════════════════════════════════════════
git -C "$R" checkout -q r5
gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
OUT=$(bash "$H/bin/migration-number.sh" taken --repo "$R" --base main --head r5 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" $'0164\ttaken by #1149 (prisma/sql/0164_replay_pr1149.sql)' && ok || bad "V3 taken: rc $RC: $OUT"
git -C "$R" checkout -q main
: > "$MNT_RES"
OUT=$(bash "$H/bin/migration-number.sh" reserve app-os APP-9 --repo "$R" --ref main 2>/dev/null); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "0165 reserved" ] && ok || bad "V2 reserve: want '0165 reserved', got rc $RC '$OUT'"
OUT=$(bash "$H/bin/migration-number.sh" reserve app-os APP-9 --repo "$R" --ref main 2>/dev/null)
[ "$OUT" = "0165 reused" ] && ok || bad "V2 reserve again: want '0165 reused', got '$OUT'"
OUT=$(bash "$H/bin/migration-number.sh" reserve app-os APP-9.2 --repo "$R" --ref main 2>/dev/null)
[ "$OUT" = "0166 reserved" ] && ok || bad "V2 second migration (KEY.2): want '0166 reserved', got '$OUT'"
touch "$MNT_DOWN"
OUT=$(bash "$H/bin/migration-number.sh" reserve app-os APP-10 --repo "$R" --ref main 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ "$OUT" = "0165 unreserved" ] && ok || bad "V2 worker down: want rc 1 '0165 unreserved', got rc $RC '$OUT'"
rm -f "$MNT_DOWN"
OUT=$(bash "$H/bin/migration-number.sh" floor other --repo "$R" 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "no migrations_glob.other row" && ok || bad "V1 floor, unconfigured: rc $RC: $OUT"
bash "$H/bin/migration-number.sh" bogus >/dev/null 2>&1; [ $? = 2 ] && ok || bad "V usage: want rc 2"

# ════════════════════════════════════════════════════════════════════════════
# E1-E3, K1-K2: the plan note's exit paths (repo R, project app-os)
# ════════════════════════════════════════════════════════════════════════════
git -C "$R" update-ref refs/remotes/origin/main main
note() { # <build-dir> [env...] — NOTE, LINE, REQS (reserve calls made)
  local b="$1" before; shift; mkdir -p "$b"
  before=$(wc -l < "$MNT_REQ")
  NOTE=$(cd "$R" && env BUILD="$b" "$@" bash -c '. "$HARNESS/bin/jobs-client.sh"; . "$HARNESS/bin/lib/migration-number.sh"; mn_plan_note app-os APP-20 . origin/main')
  LINE=$(cat "$b/migration-number.txt" 2>/dev/null); REQS=$(( $(wc -l < "$MNT_REQ") - before ))
}
: > "$MNT_RES"; gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
touch "$MNT_DOWN"; note "$T/e1"; rm -f "$MNT_DOWN"
has "$LINE" "MIGRATION_NUMBER: 0165 unreserved floor=0165" && has "$NOTE" "0165 is NOT reserved" && ! has "$NOTE" "is reserved for" \
  && ok || bad "E1 worker down: $LINE :: $NOTE"
touch "$MNT_GH/fail"; note "$T/e2"
has "$LINE" "MIGRATION_NUMBER: 0159 reserved floor=0159" && has "$LINE" "incomplete=open PR list read failed (HTTP 502)" \
  && has "$NOTE" "not read whole" && ok || bad "E2 GitHub down: $LINE :: $NOTE"
touch "$MNT_DOWN"; note "$T/e3"; rm -f "$MNT_DOWN" "$MNT_GH/fail"
has "$LINE" "MIGRATION_NUMBER: 0159 unreserved" && has "$LINE" "incomplete=open PR list" && has "$NOTE" "NOT reserved" \
  && ok || bad "E3 both down: $LINE :: $NOTE"
note "$T/k1" MIGRATION_NUMBER_RESERVE=0
[ -z "$NOTE" ] && [ -z "$LINE" ] && [ "$REQS" = 0 ] && ok || bad "K1 kill switch: note '$NOTE', line '$LINE', reserve calls $REQS"
K2="$T/k2repo"; mkdir -p "$K2/prisma/sql"; git -C "$K2" init -q -b main; echo x > "$K2/prisma/sql/README.md"
git -C "$K2" add -A; git -C "$K2" commit -qm k2; git -C "$K2" update-ref refs/remotes/origin/main HEAD
mkdir -p "$T/k2"; before=$(wc -l < "$MNT_REQ")
NOTE=$(cd "$K2" && BUILD="$T/k2" drive 'mn_plan_note app-os APP-21 . origin/main')
[ -z "$NOTE" ] && [ ! -e "$T/k2/migration-number.txt" ] && [ "$(wc -l < "$MNT_REQ")" = "$before" ] && ok || bad "K2 no numbered file on main: '$NOTE'"

# ════════════════════════════════════════════════════════════════════════════
# P1-P3: the plan.sh block, extracted between its markers
# ════════════════════════════════════════════════════════════════════════════
PLAN_SH="$SRC/bin/lib/rb/plan.sh"
awk '/^# >>> migration number note \(BH-7325\)/{f=1;next} /^# <<< migration number note \(BH-7325\)/{exit} f' "$PLAN_SH" > "$T/block.sh"
[ -s "$T/block.sh" ] && ok || bad "P: no migration number note (BH-7325) block in bin/lib/rb/plan.sh"
# The block runs before the pre-plan adoption and the CC plan call (pins).
lb=$(grep -n '^# >>> migration number note (BH-7325)' "$PLAN_SH" | cut -d: -f1)
la=$(grep -n '^# >>> preplan adopt' "$PLAN_SH" | cut -d: -f1)
lc=$(grep -n '^CC plan ' "$PLAN_SH" | head -1 | cut -d: -f1)
[ -n "$lb" ] && [ -n "$la" ] && [ -n "$lc" ] && [ "$lb" -lt "$la" ] && [ "$lb" -lt "$lc" ] && ok || bad "P1 order: block $lb, preplan adopt $la, CC plan $lc"
pblock() { # <harness> <project> <build> — UI (the note after), log in <build>/pipeline.log
  mkdir -p "$3"; : > "$3/pipeline.log"
  UI=$(cd "$R" && HARNESS="$1" PROJECT="$2" KEY=APP-30 BUILD="$3" BASE=main BRANCH=ticket/app-30 bash -c '
    . "$0/bin/jobs-client.sh"; STAMP() { echo 2026-10-17T12:00:00Z; }; UI_PLAN_NOTE="prior "
    . "$1"; printf "%s" "$UI_PLAN_NOTE"' "$H" "$T/block.sh")
}
: > "$MNT_RES"; gh_reset; before=$(wc -l < "$MNT_REQ")
pblock "$H" app-os "$T/p1"
has "$UI" "prior MIGRATION NUMBER (BH-7325): if this ticket adds a migration under prisma/sql/, name it prisma/sql/0159_<name>.sql" \
  && has "$UI" "0159 is reserved for APP-30" && ok || bad "P1 note: $UI"
grep -q "migration-number: MIGRATION_NUMBER: 0159 reserved" "$T/p1/pipeline.log" && [ "$(wc -l < "$MNT_REQ")" = $((before + 1)) ] \
  && ok || bad "P1 log/reserve: $(cat "$T/p1/pipeline.log")"
mkdir -p "$T/nolib/bin"; cp "$T/jc-stub.sh" "$T/nolib/bin/jobs-client.sh"
pblock "$T/nolib" app-os "$T/p2"
[ "$UI" = "prior " ] && [ ! -e "$T/p2/migration-number.txt" ] && ok || bad "P2 no lib: '$UI'"
before=$(wc -l < "$MNT_REQ")
pblock "$H" other "$T/p3"
[ "$UI" = "prior " ] && [ ! -e "$T/p3/migration-number.txt" ] && [ "$(wc -l < "$MNT_REQ")" = "$before" ] && ok || bad "P3 unconfigured project: '$UI'"

# ════════════════════════════════════════════════════════════════════════════
# B1: two open PRs add one number. Exactly one is refused.
# ════════════════════════════════════════════════════════════════════════════
br ticket/app-40; echo "-- forty" > "$R/prisma/sql/0170_forty.sql"; cm b1-40
S40=$(git -C "$R" rev-parse HEAD)
br ticket/app-41; echo "-- forty-one" > "$R/prisma/sql/0170_forty_one.sql"; cm b1-41
S41=$(git -C "$R" rev-parse HEAD)
b1_gh() { gh_reset
  gh_pr 1149 ticket/app-41 "$S41"; gh_file 1149 added prisma/sql/0170_forty_one.sql
  gh_pr 1500 ticket/app-40 "$S40"; gh_file 1500 added prisma/sql/0170_forty.sql; }
# B1a no reservation: the newer PR (#1500) is refused, the older (#1149) gets a NOTE
: > "$MNT_RES"; b1_gh
git -C "$R" checkout -q ticket/app-40; run ticket/app-40
[ "$RC" = 1 ] && has "$OUT" "REFUSE migration-number: migration number 0170 taken by #1149 (prisma/sql/0170_forty_one.sql)" \
  && ok || bad "B1a newer PR, no holder: want REFUSE, rc $RC: $OUT"
git -C "$R" checkout -q ticket/app-41; run ticket/app-41
[ "$RC" = 0 ] && ! has "$OUT" REFUSE && has "$OUT" "NOTE migration-number: migration number 0170 also added by #1500 (prisma/sql/0170_forty.sql), a newer PR (this is #1149)" \
  && ok || bad "B1b older PR, no holder: want a NOTE and rc 0, rc $RC: $OUT"
# B1c APP-40 (the newer PR) holds 0170: the newer keeps it, the older is refused
printf 'app-os\tAPP-40\t170\n' > "$MNT_RES"; b1_gh
git -C "$R" checkout -q ticket/app-40; run ticket/app-40
[ "$RC" = 0 ] && ! has "$OUT" REFUSE && has "$OUT" "NOTE migration-number: migration number 0170 also added by #1149 (prisma/sql/0170_forty_one.sql); APP-40 holds 0170 in migration_reservations, so #1149 renumbers" \
  && ok || bad "B1c holder's PR: want a NOTE and rc 0, rc $RC: $OUT"
git -C "$R" checkout -q ticket/app-41; run ticket/app-41
[ "$RC" = 1 ] && has "$OUT" "REFUSE migration-number: migration number 0170 taken by #1500 (prisma/sql/0170_forty.sql)" \
  && has "$OUT" "reserve it first: bin/migration-number.sh reserve app-os" \
  && ok || bad "B1d the other PR holds it: want REFUSE although older, rc $RC: $OUT"
# B1e a branch with no PR yet is newer than every open PR: refused
br ticket/app-42; echo "-- forty-two" > "$R/prisma/sql/0170_forty_two.sql"; cm b1-42
: > "$MNT_RES"; b1_gh; run ticket/app-42
[ "$RC" = 1 ] && has "$OUT" "taken by #1149" && has "$OUT" "taken by #1500" && ok || bad "B1e no PR yet: rc $RC: $OUT"
git -C "$R" checkout -q main

# ════════════════════════════════════════════════════════════════════════════
# B2: the settings read AND the worker both fail (a real outage: setting_get
# and _jobs_req share one service). Never silent.
# ════════════════════════════════════════════════════════════════════════════
touch "$MNT_SET_DOWN" "$MNT_DOWN"
gh_reset; gh_pr 1149 r-a aaaa; gh_file 1149 added prisma/sql/0164_replay_pr1149.sql
git -C "$R" checkout -q r5; run r5; git -C "$R" checkout -q main
[ "$RC" = 0 ] && has "$OUT" "NOTE migration-number: migrations_glob.app-os could not be read (unreadable), so migration numbers are not checked" \
  && ok || bad "B2a self-check with settings down: want one NOTE, rc $RC: '$OUT'"
before=$(wc -l < "$MNT_REQ"); note "$T/b2"
has "$LINE" "MIGRATION_NUMBER: - unreserved floor=- main_max=- pr_max=- prs_read=0 incomplete=settings-unreadable (unreadable)" \
  && ok || bad "B2b plan line with settings down: '$LINE'"
has "$NOTE" "migrations_glob.app-os setting could not be read" && has "$NOTE" "do not take main max + 1" \
  && has "$NOTE" "bin/migration-number.sh reserve app-os APP-20" && ok || bad "B2c plan note with settings down: '$NOTE'"
rm -f "$MNT_SET_DOWN" "$MNT_DOWN"
# K3: the kill switch is the settings row migration_number.reserve
cp "$MNT_SETTINGS" "$T/settings.bak"; printf 'migration_number.reserve\t0\n' >> "$MNT_SETTINGS"
before=$(wc -l < "$MNT_REQ"); note "$T/k3"
[ -z "$NOTE" ] && [ -z "$LINE" ] && [ "$REQS" = 0 ] && ok || bad "K3 settings kill switch: note '$NOTE', line '$LINE', reserve calls $REQS"
cp "$T/settings.bak" "$MNT_SETTINGS"

echo "migration-number.bh-7325: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
