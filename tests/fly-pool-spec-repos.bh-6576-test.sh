#!/bin/bash
# tests/fly-pool-spec-repos.bh-6576-test.sh — BH-6576: a ticket that declares
# `Spec-repo: <owner>/<repo>` gets the BH-5910 read-only token for that repo on
# its pool machine, and a ticket without the line does not.
#
# PINNED:
#   S1-S4, S6 the REAL swap block, lifted from bin/fly-pool.sh by its markers
#        (same harness shape as tests/fly-pool-extra-read.bh-5910-test.sh):
#        S1 no SPEC_REPOS, no knob: no read mint, no GH_EXTRA_READ_* line.
#        S2 SPEC_REPOS alone: the read token ships for it, the project token
#           stays, the token value never reaches the log.
#        S3 knob + SPEC_REPOS: one deduped list; a missing ticket-sourced repo
#           pages with the ticket text, once per day.
#        S4 SPEC_REPOS naming only the project: no read mint.
#        S6 a failed read push is said and the spawn goes ahead.
#   S5 the REAL machine-json jq line from spawn_one: spec_repos rides on it
#      only when set, and spec_repos_machine_has reads it back.
#   R1 the REAL next_job_or_destroy: a machine with spec_repos is destroyed,
#      not reused; a queued ticket that declares spec repos is left for a
#      fresh spawn (no job.json push).
#   R2 spawn_one loads SPEC_REPOS above the swap marker.
#   C1 xrepo_gate passes a plan that reads the spec repo when the read token
#      can see it.
#   C2 xrepo_plan_note names the readable repos and git clone.
#   C4 the PLAN_BLOCKED cross-repo-read lines name the Spec-repo remedy.
#   C3 fly/gh-credential.sh answers the read token for the spec repo path
#      and the project token for the project path.
# Run from anywhere: bash tests/fly-pool-spec-repos.bh-6576-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs"
scratch_install_closure bin/lib/gh-app-auth.sh "$H" >/dev/null || { echo "closure install failed for bin/lib/gh-app-auth.sh"; exit 1; }
scratch_install_closure bin/lib/spec-repos.sh "$H" >/dev/null && ok || bad "closure install failed for bin/lib/spec-repos.sh"
: > "$H/env/github-app.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/gh-token.sh"
cat > "$H/bin/alert-line.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.calls"
STUB
chmod +x "$H/bin/"*.sh

# ── S1-S4, S6: the swap block ───────────────────────────────────────────────
BLOCK=$(sed -n '/^ *# >>> pool gh credential swap/,/^ *# <<< pool gh credential swap/p' "$DIR/bin/fly-pool.sh")
[ -n "$BLOCK" ] && ok || bad "swap block markers not found in bin/fly-pool.sh"
cat > "$T/swap.sh" <<EOF
set -uo pipefail
HARNESS="$H"
. "\$HARNESS/bin/lib/gh-app-auth.sh"
. "\$HARNESS/bin/lib/spec-repos.sh"
say() { echo "fly-pool: \$*" >> "$T/pool.log"; }
destroy_machine() { printf '%s\n' "\$*" >> "$T/destroy.calls"; }
pool_unclaim() { printf '%s\n' "\$*" >> "$T/unclaim.calls"; }
pool_spawn_cap_unrecord() { :; }
mput() { printf '%s %s\n' "\$1" "\$3" >> "$T/mput.calls"; cp "\$2" "$T/mput-\$(basename "\$3")"; [ "\${MPUT_FAILS:-0}" != 1 ]; }
pool_gh_answered() { echo builders; }
pool_gh_token() {
  printf '%s\n' "\$*" >> "$T/token.calls"
  case " \$* " in
    *" --extra-read "*) [ -n "\${XERR:-}" ] && printf '%s\n' "\$XERR" >&2
                        [ -n "\${XMINT:-}" ] && echo "\$XMINT"; return 0 ;;
    *" --installation-id "*) echo 4242 ;;
    *" --expires-at "*) [ -n "\${MEXPIRY:-}" ] && echo "\$MEXPIRY" ;;
    *) echo tok-fixture-project ;;
  esac
}
MID=mach1 KEY=TK-3487 P=proj TMP="\$1" POOL_GH_TOKEN_MIN_LIFE=3300
f() {
$BLOCK
}
f; echo "RC=\$?"
EOF
# run_swap [VAR=value ...] -> SRC; bundle in $T/b
run_swap() {
  rm -rf "$T/b" "$T"/mput-*; mkdir -p "$T/b"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=oauth-fixture\nGH_TOKEN=ghp_patfixture\n' > "$T/b/global.env"
  printf 'REPO_SLUG=example-org/proj-repo\n' > "$T/b/proj.env"
  : > "$T/pool.log"; : > "$T/token.calls"; : > "$T/mput.calls"
  SRC=$(env -i PATH="/usr/bin:/bin" HOME="$T" MEXPIRY=2026-10-14T15:00:00Z "$@" bash "$T/swap.sh" "$T/b" 2>"$T/swap.err" | sed -n 's/^RC=//p')
}

# S1 (acceptance 2): no line, no knob -> today's bytes.
run_swap EXTRA_READ_REPOS= SPEC_REPOS= XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ok || bad "S1: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -q -- '--extra-read' "$T/token.calls" && bad "S1: no spec repo and no knob must make no --extra-read call" || ok
grep -q '^GH_EXTRA_READ_' "$T/b/global.env" && bad "S1: no GH_EXTRA_READ_* line without a spec repo" || ok
grep -q 'gh-token-read' "$T/mput.calls" && bad "S1: no read mput without a spec repo" || ok
grep -qx 'GH_TOKEN=tok-fixture-project' "$T/b/global.env" && ok || bad "S1: GH_TOKEN must be the project token"
# ...and the same with SPEC_REPOS unset entirely (set -u).
run_swap EXTRA_READ_REPOS= XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ! grep -q -- '--extra-read' "$T/token.calls" && ok || bad "S1: an unset SPEC_REPOS must run under set -u with no read mint ($(cat "$T/swap.err"))"

# S2 (acceptance 1, hub half): the spec repo alone.
run_swap EXTRA_READ_REPOS= SPEC_REPOS=example-org/project-6 XMINT=tok-fixture-read
[ "$SRC" = 0 ] && ok || bad "S2: rc must be 0, got '$SRC' ($(cat "$T/swap.err"))"
grep -qx -- '--extra-read example-org/project-6 --min-life 3300 example-org/proj-repo' "$T/token.calls" && ok \
  || bad "S2: one --extra-read call for the spec repo, got: $(cat "$T/token.calls")"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/project-6' "$T/b/global.env" && ok || bad "S2: GH_EXTRA_READ_REPOS must name the spec repo, got: $(grep GH_EXTRA "$T/b/global.env")"
grep -qx 'GH_EXTRA_READ_TOKEN=tok-fixture-read' "$T/b/global.env" && ok || bad "S2: GH_EXTRA_READ_TOKEN must ship"
grep -qx 'mach1 /run/harness-env/gh-token-read' "$T/mput.calls" && ok || bad "S2: the read token must be pushed, got: $(cat "$T/mput.calls")"
grep -qx 'GH_TOKEN=tok-fixture-project' "$T/b/global.env" && ok || bad "S2: GH_TOKEN must stay the project token"
grep -q 'read-only token for the extra repos of example-org/proj-repo (example-org/project-6; left out: none)' "$T/pool.log" && ok || bad "S2: the shipped line must be said, got: $(cat "$T/pool.log")"
grep -q 'tok-fixture-read' "$T/pool.log" "$T/swap.err" && bad "S2: the read token value reached the log" || ok

# S3: knob + spec repos -> one list; a missing ticket repo pages with the ticket text.
: > "$T/alerts.calls"
run_swap EXTRA_READ_REPOS=example-org/a SPEC_REPOS=example-org/project-6,example-org/a XMINT=tok-fixture-read
grep -qx -- '--extra-read example-org/a,example-org/project-6 --min-life 3300 example-org/proj-repo' "$T/token.calls" && ok \
  || bad "S3: the mint list must be the knob then the spec repos, got: $(cat "$T/token.calls")"
grep -qx 'GH_EXTRA_READ_REPOS=example-org/a,example-org/project-6' "$T/b/global.env" && ok || bad "S3: the union must be deduped and sorted, got: $(grep GH_EXTRA_READ_REPOS "$T/b/global.env")"
run_swap EXTRA_READ_REPOS=example-org/Gone SPEC_REPOS=example-org/project-6 XMINT=tok-fixture-read \
  XERR=$'gh-token: EXTRA_READ_REPO_MISSING example-org/project-6\ngh-token: EXTRA_READ_REPO_MISSING example-org/Gone'
[ "$(grep -c 'example-org/project-6' "$T/alerts.calls")" = 1 ] && ok || bad "S3: one alert for the missing spec repo, got: $(cat "$T/alerts.calls")"
grep -q 'ticket TK-3487 declares it as Spec-repo' <<<"$(grep 'example-org/project-6' "$T/alerts.calls")" && ok || bad "S3: the spec repo alert must name the ticket and Spec-repo, got: $(cat "$T/alerts.calls")"
grep -q 'extra_read_repos' <<<"$(grep 'example-org/project-6' "$T/alerts.calls")" && bad "S3: a ticket-sourced repo must not blame the setting" || ok
grep -q 'lane.fly-pool.proj.extra_read_repos names it' <<<"$(grep 'example-org/Gone' "$T/alerts.calls")" && ok || bad "S3: a knob repo keeps the BH-5910 text, got: $(cat "$T/alerts.calls")"
run_swap EXTRA_READ_REPOS= SPEC_REPOS=example-org/project-6 XMINT=tok-fixture-read XERR='gh-token: EXTRA_READ_REPO_MISSING example-org/project-6'
[ "$(grep -c 'example-org/project-6' "$T/alerts.calls")" = 1 ] && ok || bad "S3: a second spawn the same day must not page again, got: $(cat "$T/alerts.calls")"

# S4: the project's own slug is not a spec repo.
run_swap EXTRA_READ_REPOS= SPEC_REPOS=example-org/PROJ-repo XMINT=tok-fixture-read
grep -q -- '--extra-read' "$T/token.calls" && bad "S4: the project slug alone must make no --extra-read call, got: $(cat "$T/token.calls")" || ok
grep -q '^GH_EXTRA_READ_' "$T/b/global.env" && bad "S4: no GH_EXTRA_READ_* line for the project slug" || ok

# S6: a failed read push is said; the spawn goes ahead.
run_swap EXTRA_READ_REPOS= SPEC_REPOS=example-org/project-6 XMINT=tok-fixture-read MPUT_FAILS=1
[ "$SRC" = 0 ] && ok || bad "S6: a failed read push must not stop the spawn, got '$SRC'"
grep -q 'gh-token-read push FAILED' "$T/pool.log" && ok || bad "S6: the failed push must be said, got: $(cat "$T/pool.log")"

# ── S5: the machine json line from spawn_one ────────────────────────────────
JQLINE=$(sed -n '/^spawn_one() {/,/^}/p' "$DIR/bin/fly-pool.sh" | sed -n '/^ *jq -nc --arg m "\$MID"/,/> "\$POOL\/\$MID.json"$/p')
[ -n "$JQLINE" ] && ok || bad "S5: the machine json jq line was not found in spawn_one"
mkjson() {
  env -i PATH="/usr/bin:/bin" bash -c '
    STAMP() { echo 2026-10-14T06:00:00Z; }
    MID=mach1 KEY=TK-3487 TICKET=3487 ATT=1 SDEF=0 SDTH=0 SSB="" SHF=false MEXP="" MACCT="" SPAWNCAPTS="" POOL="$1" SPEC_REPOS="$2"
    eval "$3"' _ "$T" "$1" "$JQLINE"
}
mkjson example-org/project-6
[ "$(jq -r '.spec_repos // "absent"' "$T/mach1.json" 2>/dev/null)" = example-org/project-6 ] && ok || bad "S5: spec_repos must ride on the machine json, got: $(cat "$T/mach1.json" 2>/dev/null)"
( . "$H/bin/lib/spec-repos.sh"; spec_repos_machine_has "$T/mach1.json" ) && ok || bad "S5: spec_repos_machine_has must read the written json back"
mkjson ""
[ "$(jq -r 'has("spec_repos")' "$T/mach1.json" 2>/dev/null)" = false ] && ok || bad "S5: no spec repos must write no spec_repos key, got: $(cat "$T/mach1.json" 2>/dev/null)"
( . "$H/bin/lib/spec-repos.sh"; spec_repos_machine_has "$T/mach1.json" ) && bad "S5: a plain machine json must answer rc 1" || ok

# ── R1: next_job_or_destroy ─────────────────────────────────────────────────
FN=$(sed -n '/^next_job_or_destroy() {/,/^}/p' "$DIR/bin/fly-pool.sh")
[ -n "$FN" ] && ok || bad "R1: next_job_or_destroy not found"
printf '%s\n' "$FN" > "$T/nj.sh"
# run_reuse <machine json> <queued ticket body> -> pool log in $T/r.log, calls in $T/r.calls
run_reuse() {
  rm -rf "$T/q" "$T/pool"; mkdir -p "$T/q" "$T/pool"; : > "$T/r.log"; : > "$T/r.calls"
  printf '%s\n' "$1" > "$T/pool/mach1.json"
  printf '{"key":"TK-3600","ticket_id":"3600","attempt":1}\n' > "$T/q/TK-3600.json"
  env -i PATH="/usr/bin:/bin" BODY="$2" bash -c '
    set -uo pipefail
    HH="$1" TT="$2"
    . "$HH/bin/lib/spec-repos.sh"
    say() { echo "fly-pool: $*" >> "$TT/r.log"; }
    pool_slug_token_arm() { POOL_SLUG_TOK=tok-fixture-slug; }
    gh_rest() { echo "gh_rest $* token=${GH_TOKEN:-}" >> "$TT/r.calls"; jq -nc --arg b "$BODY" "{body:\$b}"; }
    mexec() { echo "mexec $1" >> "$TT/r.calls"; }
    mput() { echo "mput $1 $3" >> "$TT/r.calls"; }
    destroy_machine() { echo "destroy $1" >> "$TT/r.calls"; }
    push_preplan() { :; }; push_reroute() { :; }; push_build_note() { :; }; push_bake_evidence() { :; }
    STAMP() { echo 2026-10-14T06:00:00Z; }
    MID=mach1 MSTATE=started KEY=TK-3487 MF="$TT/pool/mach1.json" QDIR="$TT/q" POOL="$TT/pool"
    P=proj APP=app FLY=false HARNESS="$HH" POOL_SLUG=example-org/project-5
    . "$TT/nj.sh"
    next_job_or_destroy' _ "$H" "$T" 2>>"$T/r.err"
}
# a plain machine, a plain queued ticket: reused (the control).
run_reuse '{"machine":"mach1","key":"TK-3487"}' 'Just a report.'
grep -q 'mput mach1 /run/harness/job.json.next' "$T/r.calls" && ok || bad "R1: control: a plain ticket must be handed to a plain machine, got: $(cat "$T/r.calls") / $(cat "$T/r.log")"
grep -qx 'gh_rest GET repos/example-org/project-5/issues/3600 token=tok-fixture-slug' "$T/r.calls" && ok || bad "R1: the candidate's body must be read with the armed repo token, got: $(cat "$T/r.calls")"
# a spec-repo machine: destroyed, never reused.
run_reuse '{"machine":"mach1","key":"TK-3487","spec_repos":"example-org/project-6"}' 'Just a report.'
grep -q 'job.json' "$T/r.calls" && bad "R1: a spec-repo machine must not get a job.json, got: $(cat "$T/r.calls")" || ok
grep -q 'destroy mach1' "$T/r.calls" && ok || bad "R1: a spec-repo machine must be destroyed, got: $(cat "$T/r.calls")"
grep -q 'carries a read token for TK-3487.s spec repos — destroying instead of reusing' "$T/r.log" && ok || bad "R1: the refusal must be said, got: $(cat "$T/r.log")"
# a plain machine, a queued ticket that declares a spec repo: left for a fresh spawn.
run_reuse '{"machine":"mach1","key":"TK-3487"}' $'Report.\n- Spec-repo: example-org/project-6'
grep -q 'job.json' "$T/r.calls" && bad "R1: a spec-repo ticket must not be handed to a reused machine, got: $(cat "$T/r.calls")" || ok
grep -q 'destroy mach1' "$T/r.calls" && ok || bad "R1: with no other job the machine must be destroyed"
grep -q 'TK-3600 declares spec repos — left for a fresh spawn' "$T/r.log" && ok || bad "R1: the skip must be said, got: $(cat "$T/r.log")"
[ -f "$T/q/TK-3600.json" ] && ok || bad "R1: the skipped job must stay queued"

# ── R2: spawn_one loads SPEC_REPOS above the swap marker ────────────────────
SP=$(sed -n '/^spawn_one() {/,/^}/p' "$DIR/bin/fly-pool.sh")
LOADN=$(grep -n 'spec_repos_load "\$POOL_SLUG" "\$TICKET"' <<<"$SP" | head -1 | cut -d: -f1)
SWAPN=$(grep -n '# >>> pool gh credential swap' <<<"$SP" | head -1 | cut -d: -f1)
[ -n "$LOADN" ] && [ -n "$SWAPN" ] && [ "$LOADN" -lt "$SWAPN" ] && ok || bad "R2: spawn_one must call spec_repos_load above the swap marker (load=${LOADN:-none} swap=${SWAPN:-none})"
grep -q '^\[ -r "\$HARNESS/bin/lib/spec-repos.sh" \] && \. "\$HARNESS/bin/lib/spec-repos.sh"' "$DIR/bin/fly-pool.sh" && ok || bad "R2: bin/fly-pool.sh must source bin/lib/spec-repos.sh"

# ── C1-C2: the builder half (bin/lib/rb/cross-repo-read.sh) ─────────────────
XLIB="$DIR/bin/lib/rb/cross-repo-read.sh"
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL=""; TOK=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in "Authorization: token "*) TOK="${2#Authorization: token }" ;; esac; shift 2 ;;
    -m|-o|-w|-X|-d) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
if [ "${URL#*/repos/}" = example-org/project-6 ] && [ "$TOK" = tok-fixture-read ]; then printf 200; else printf 404; fi
SH
chmod +x "$T/fakebin/curl"
printf 'tok-fixture-read\n' > "$T/gh-token-read"
printf '# plan\n\nCROSS-REPO-READ: example-org/project-6\n' > "$T/plan.md"
GOUT=$(env -i PATH="$T/fakebin:/usr/bin:/bin" GH_APP_API_BASE=http://api.test GH_TOKEN_READ_FILE="$T/gh-token-read" GH_TOKEN=tok-fixture-project \
  bash -c '. "$1" && xrepo_gate "$2" example-org/project-5 "$3"' _ "$XLIB" "$T/plan.md" "$T/pl.log"); GRC=$?
[ "$GRC" = 0 ] && [ -z "$GOUT" ] && ok || bad "C1: the gate must pass with the read token, got rc=$GRC out='$GOUT'"
GOUT=$(env -i PATH="$T/fakebin:/usr/bin:/bin" GH_APP_API_BASE=http://api.test GH_TOKEN_READ_FILE="$T/absent" GH_TOKEN=tok-fixture-project \
  bash -c '. "$1" && xrepo_gate "$2" example-org/project-5 "$3"' _ "$XLIB" "$T/plan.md" "$T/pl.log"); GRC=$?
[ "$GRC" = 4 ] && [ "$GOUT" = example-org/project-6 ] && ok || bad "C1: control: without the read token the gate must stop, got rc=$GRC out='$GOUT'"
NOTE0=$(env -i PATH="/usr/bin:/bin" bash -c '. "$1" && xrepo_plan_note' _ "$XLIB")
NOTE1=$(env -i PATH="/usr/bin:/bin" GH_EXTRA_READ_REPOS=example-org/project-6 bash -c '. "$1" && xrepo_plan_note' _ "$XLIB")
grep -q 'CROSS-REPO-READ: <owner>/<repo>' <<<"$NOTE0" && ok || bad "C2: the note must keep the BH-5910 sentence"
grep -q 'READ these repos' <<<"$NOTE0" && bad "C2: no GH_EXTRA_READ_REPOS must add no read sentence" || ok
[ "${NOTE1#"$NOTE0"}" != "$NOTE1" ] && ok || bad "C2: the read sentence must follow the BH-5910 text unchanged"
grep -q 'This build can READ these repos (read-only): example-org/project-6\.' <<<"$NOTE1" && ok || bad "C2: the note must name the readable repo, got: $NOTE1"
grep -q 'git clone --depth 1 https://github.com/<repo>' <<<"$NOTE1" && ok || bad "C2: the note must say how to read it (git clone), got: $NOTE1"

# C4: the REAL plan gate block names the Spec-repo remedy in plan.md and ALERTS.
GB=$(sed -n '/^# >>> cross-repo-read gate (BH-5910)/,/^# <<< cross-repo-read gate/p' "$DIR/bin/lib/rb/plan.sh")
[ -n "$GB" ] && ok || bad "C4: the cross-repo-read gate block is not in bin/lib/rb/plan.sh"
mkdir -p "$T/gb/build"
printf '#!/bin/bash\n[ "${2:-}" = repo ] && echo example-org/project-5\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
cp "$T/plan.md" "$T/gb/build/plan.md"
printf '%s\n' "$GB" > "$T/gb/block.sh"
env -i PATH="$T/fakebin:/usr/bin:/bin" GH_APP_API_BASE=http://api.test GH_TOKEN_READ_FILE="$T/absent" GH_TOKEN=tok-fixture-project \
  bash -c 'HARNESS="$1"; PROJECT=project-5; KEY=TK-3487; BUILD="$2/build"; REPO="$2/norepo"; ALERTS="$2/ALERTS.log"
    STAMP() { echo 2026-10-14T06:00:00Z; }; BB() { :; }; RESULT() { printf "%s\n" "$*" > "$2/result"; }
    GBD="$2"; . "$3"; f() { . "$GBD/block.sh"; }; f' _ "$H" "$T/gb" "$XLIB" >/dev/null 2>&1
head -1 "$T/gb/build/plan.md" | grep -q "or add a 'Spec-repo: example-org/project-6' line to the ticket body" && ok \
  || bad "C4: the BLOCKED line must name the Spec-repo remedy, got: $(head -1 "$T/gb/build/plan.md")"
grep -q "extra_read_repos to include example-org/project-6, or add a 'Spec-repo: example-org/project-6' line to the ticket body" "$T/gb/ALERTS.log" 2>/dev/null && ok \
  || bad "C4: the ALERTS line must name the Spec-repo remedy, got: $(cat "$T/gb/ALERTS.log" 2>/dev/null)"

# ── C3: the credential helper answers the read token for the spec repo ─────
printf 'tok-fixture-project\n' > "$T/gh-token"
ask() {
  { printf 'protocol=https\nhost=github.com\npath=%s\n\n' "$1"; } \
    | env -i PATH="/usr/bin:/bin" GH_TOKEN_LIVE_FILE="$T/gh-token" GH_TOKEN_READ_FILE="$T/gh-token-read" \
        GH_EXTRA_READ_REPOS=example-org/project-6 sh "$DIR/fly/gh-credential.sh" get | sed -n 's/^password=//p'
}
[ "$(ask example-org/project-6.git)" = tok-fixture-read ] && ok || bad "C3: the spec repo path must get the read token, got '$(ask example-org/project-6.git)'"
[ "$(ask example-org/project-5.git)" = tok-fixture-project ] && ok || bad "C3: the project path must get the project token"

echo "fly-pool-spec-repos (BH-6576): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
