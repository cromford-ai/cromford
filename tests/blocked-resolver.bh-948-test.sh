#!/bin/bash
# tests/blocked-resolver.bh-948-test.sh — BH-487.2, the TICKET-KEY CACHE: a key
# `br_one` derived under the repo's own token is carried beside the resolver row
# so the NEXT tick of the same park does not buy it again.
#
# WHY IT MATTERS. Discovery (`br_conductor_emit`) asks gh for the head branch
# BEFORE `br_one` installs the repo's installation token, so on a repo the
# default token cannot see it reads an empty branch and the candidate arrives
# keyless. `br_one` then derives the key from the PR title — two `gh pr view`
# reads — and says so in the log. Every ten minutes. For ever. The cache is the
# persisted "already derived?" answer: written once by `br_tkey_put`, read by
# `br_tkey_sync` at the next discovery, and overwritten the moment gh itself
# answers with a different key.
#
# HOW IT DRIVES. Section 1 calls the three functions IN PROCESS over the
# resolver's own `br_key_shape` (extracted, never paraphrased). Sections 2-4 run
# the REAL bin/blocked-resolver.sh end to end from a scratch $HARNESS, in ACT
# mode, with a stubbed gh/ssh/lane-alert, and assert on artifacts: the `.tkey`
# file, the state row the tick landed under, the gh calls it made and the lines
# it logged.
#
# MUTATION NOTES (each applied once during the build, red observed, restored):
#   * drop the overwrite in `br_tkey_sync` (never rewrite a disagreeing cache)
#     -> section 3 red: the `.tkey` still reads TK-8 after gh answered ticket/TK-9.
#   * make `br_tkey_put` a no-op again -> section 2 red: no `.tkey` file, the
#     derivation line logged twice, and a `--json title` read on tick 2.
#   * drop the `br_key_shape` guard in `br_cached_tkey` -> section 4 red: the
#     hand-edited `not a key` is carried as a key and the tick lands under
#     `tproj-not-a-key.json` instead of the PR-number rkey.
#
# The clock is not read anywhere: the `pr-state.tsv` epoch column is a literal.
# Run from anywhere: tests/blocked-resolver.bh-948-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "blocked-resolver.bh-948-test: SKIPPED — jq is required"; exit 0; }

# ════════════════════════════════════════════════════════════════════════════
# Fixture A — the lib IN PROCESS, over the resolver's OWN shape guard.
# br_key_shape is extracted from bin/blocked-resolver.sh rather than re-written
# here: it is the guard every other key source passes through, and a paraphrase
# of it would pass while the lane changed.
# ════════════════════════════════════════════════════════════════════════════
ST="$T/st"; mkdir -p "$ST"
# BH-6461: the key family moved to bin/lib/br/keys.sh; the corpus is the driver
# plus bin/lib/br/*.sh (tests/lib/br-corpus.sh), so the extraction finds it there.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
awk '$0 ~ /^br_key_shape\(\)/ {f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh" > "$T/keylib.sh"
grep -q '^br_key_shape()' "$T/keylib.sh" \
  && ok || bad "could not extract br_key_shape from bin/blocked-resolver.sh — section 1 would test a paraphrase"
# shellcheck source=/dev/null
. "$T/keylib.sh"
[ -r "$DIR/bin/lib/rebuild-ledger.sh" ] && ok || bad "bin/lib/rebuild-ledger.sh is missing"
# shellcheck source=/dev/null
. "$DIR/bin/lib/rebuild-ledger.sh" || bad "bin/lib/rebuild-ledger.sh does not source"

TK="$ST/tproj/o-tproj-9.tkey"
seed() { mkdir -p "$ST/tproj"; printf '%s\n' "$1" > "$TK"; }

# ══ 1. put, sync and the shape guard, as a table ════════════════════════════
br_tkey_put tproj o-tproj-9 ''; RC=$?
[ "$RC" = 0 ] && ok || bad "1: br_tkey_put with an EMPTY key must be rc 0, got $RC"
[ ! -e "$TK" ] && ok || bad "1: br_tkey_put with an empty key must write NOTHING, got '$(cat "$TK")'"
br_tkey_put tproj o-tproj-9 -; RC=$?
[ "$RC" = 0 ] && ok || bad "1: br_tkey_put with '-' must be rc 0, got $RC"
[ ! -e "$TK" ] && ok || bad "1: br_tkey_put with '-' must write NOTHING, got '$(cat "$TK")'"

# The cache does not exist yet, so the read answers rc 1 and the sync answers "-".
br_cached_tkey tproj o-tproj-9 >/dev/null 2>&1; RC=$?
[ "$RC" = 1 ] && ok || bad "1: br_cached_tkey with no file must be rc 1, got $RC"
OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = "-" ] && ok || bad "1: sync with no derived key and no cache must print -, got '$OUT'"

br_tkey_put tproj o-tproj-9 TK-9; RC=$?
[ "$RC" = 0 ] && ok || bad "1: br_tkey_put must be rc 0 on a real key, got $RC"
[ "$(head -1 "$TK" 2>/dev/null)" = TK-9 ] && ok \
  || bad "1: br_tkey_put must write the key to \$ST/<project>/<rkey>.tkey, got '$(cat "$TK" 2>/dev/null)'"
[ "$(wc -l < "$TK")" = 1 ] && ok || bad "1: the cache must be ONE line, got $(wc -l < "$TK")"

OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = TK-9 ] && ok || bad "1: sync with a '-' derived key must carry the cache, got '$OUT'"
OUT=$(br_tkey_sync tproj o-tproj-9 '')
[ "$OUT" = TK-9 ] && ok || bad "1: sync with an EMPTY derived key must carry the cache, got '$OUT'"
OUT=$(br_tkey_sync tproj o-tproj-9)
[ "$OUT" = TK-9 ] && ok || bad "1: sync with NO third argument must carry the cache, got '$OUT'"

# An AGREEING cache is never rewritten: this runs on every park on every tick.
MT=$(stat -c %y "$TK" 2>/dev/null)
OUT=$(br_tkey_sync tproj o-tproj-9 TK-9)
[ "$OUT" = TK-9 ] && ok || bad "1: sync with the same derived key must print it, got '$OUT'"
[ "$(stat -c %y "$TK" 2>/dev/null)" = "$MT" ] && ok \
  || bad "1: an identical cache must not be rewritten (mtime moved)"

# A DISAGREEING cache loses: gh answered, and gh is the better source.
OUT=$(br_tkey_sync tproj o-tproj-9 TK-10)
[ "$OUT" = TK-10 ] && ok || bad "1: sync must print the DERIVED key, got '$OUT'"
[ "$(head -1 "$TK" 2>/dev/null)" = TK-10 ] && ok \
  || bad "1: a cache that disagrees with the derived key must be overwritten, got '$(cat "$TK")'"

# The shape guard, on the FIRST line, upper-casing on the way out.
seed 'TK-9'
OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = TK-9 ] && ok || bad "1: a lower-case cached key must come back upper-cased, got '$OUT'"
seed 'TK-9: nav anchors'
OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = TK-9 ] && ok || bad "1: a decorated cached key must be shaped to TK-9, got '$OUT'"
seed 'not a key'
OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = "-" ] && ok || bad "1: a cache that is not a key must answer -, got '$OUT'"
[ "$(cat "$TK")" = 'not a key' ] && ok \
  || bad "1: a wrong-shaped cache must be LEFT ALONE, got '$(cat "$TK")'"
: > "$TK"
OUT=$(br_tkey_sync tproj o-tproj-9 -)
[ "$OUT" = "-" ] && ok || bad "1: an EMPTY cache file must answer -, got '$OUT'"

# SYNC NEVER CREATES. Only br_one's put does — a park that never reached br_one
# has no cache, and a discovery that derived its own key must not write one.
OUT=$(br_tkey_sync tproj o-tproj-77 TK-9)
[ "$OUT" = TK-9 ] && ok || bad "1: sync with no cache must still print the derived key, got '$OUT'"
[ ! -e "$ST/tproj/o-tproj-77.tkey" ] && ok || bad "1: br_tkey_sync must NEVER create the cache file"
OUT=$(br_tkey_sync tproj o-tproj-78 -)
[ "$OUT" = "-" ] && ok || bad "1: sync with no cache and no derived key must print -, got '$OUT'"
[ ! -e "$ST/tproj/o-tproj-78.tkey" ] && ok || bad "1: br_tkey_sync must NEVER create the cache file"

# Deliberately NOT a *.json: br_from_rebuilds globs "$ST"/*/*.json and would
# read a cache file as a state row.
[ -z "$(find "$ST" -name '*.json' 2>/dev/null)" ] && ok \
  || bad "1: the cache must not be a *.json — br_from_rebuilds would read it as a row"

# ════════════════════════════════════════════════════════════════════════════
# Fixture B — the REAL bin/blocked-resolver.sh, ACT mode, from a scratch
# $HARNESS. No observe flag, no queue client and no fly-pool flag, so the
# enqueue takes the BOX arm: the `commented` row flipped to `cleared`
# (bin/lib/comment-mark.sh), which the jobs client below records (BH-2674).
# ════════════════════════════════════════════════════════════════════════════
H="$T/rh"
RST="$H/state/blocked-resolver"
LOG="$H/logs/blocked-resolver.log"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/rbin" "$T/rrepos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/comment-mark.sh" "$H/bin/lib/" || exit 1
printf 'job_ledger_put() { printf "%%s\\n" "$*" >> %q; }\n' "$T/ledger.txt" > "$H/bin/jobs-client.sh"
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# gh answers the head branch from $T/prbranch and the title from $T/prtitle, so
# each case below decides for itself what discovery can and cannot see. Every
# call is recorded: "did this tick pay for a title read" is then a fact.
cat > "$T/rbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)            printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json headRefName"*)  cat "$T/prbranch" 2>/dev/null ;;
  *"--json title"*)        cat "$T/prtitle" 2>/dev/null ;;
  *"--json state"*)        echo OPEN ;;
  *"pr list"*)             echo "" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/rbin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"; chmod +x "$T/rbin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/rbin/br-ssh"
chmod +x "$T/rbin/br-ssh"
: > "$T/prbranch"; : > "$T/prtitle"; : > "$T/gh.txt"; : > "$T/closed.txt"
: > "$T/lane-alert.txt"; : > "$T/ssh.txt"
export PATH="$T/rbin:$PATH"
export GH_TOKEN=""

RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/rrepos" \
            BR_SSH="$T/rbin/br-ssh" \
            bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>>"$T/run.err" ) ; }
# One parked PR in the conductor's own row shape. The reason has no ladder class,
# so br_action answers rebuild-fresh directly and the tick takes rung 3.
# 1758240000 is a literal epoch: the column is read but never compared.
ROW() {
  printf 'o/tproj#9\tBLOCKED_HUMAN\t1758240000\tabc123\tabc123\t-\tmerge-failed-twice: gh pr merge refused\thttps://github.com/o/tproj/pull/9\n' \
    > "$H/state/merge-conductor/pr-state.tsv"
}
reset_case() {
  scratch_rm "$RST"
  scratch_rm "$H/builds"; mkdir -p "$H/builds"
  : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$T/ssh.txt"
  : > "$LOG"
}
seed_tkey() { mkdir -p "$RST/tproj"; printf '%s\n' "$1" > "$RST/tproj/o-tproj-9.tkey"; }
TKEY()  { cat "$RST/tproj/o-tproj-9.tkey" 2>/dev/null; }
ROWJ()  { cat "$RST/tproj/$1.json" 2>/dev/null; }
DERIVED_LINE='discovery carried no ticket key — derived TK-9 from the PR title'

# ══ 2. Tick 1 derives and caches; tick 2 carries the key ════════════════════
reset_case
: > "$T/prbranch"                       # gh shows discovery nothing
printf 'TK-9: nav anchors\n' > "$T/prtitle"
ROW
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "2: tick 1 exited $RC: $(tail -3 "$T/run.err")"
grep -qF "o-tproj-9: $DERIVED_LINE" "$LOG" && ok \
  || bad "2: tick 1 must log the derivation it paid for: $(cat "$LOG")"
[ "$(TKEY)" = TK-9 ] && ok \
  || bad "2: tick 1 must cache the derived key beside the row, got '$(TKEY)'"
[ "$(ROWJ tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh ] && ok \
  || bad "2: tick 1 must act under the TICKET key, got '$(ROWJ tproj-TK-9 | jq -r '.attempts[-1].action')'"
# The branch and the title are ONE REST PR object now (#783): the read the
# derivation paid for is that object, and it is made inside br_one's token.
grep -q -- '-X GET repos/o/tproj/pulls/9' "$T/gh.txt" && ok \
  || bad "2: tick 1 must have paid for the PR read the title comes from: $(cat "$T/gh.txt")"

: > "$T/gh.txt"
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "2: tick 2 exited $RC: $(tail -3 "$T/run.err")"
[ "$(grep -cF "$DERIVED_LINE" "$LOG")" = 1 ] && ok \
  || bad "2: the derivation line must appear ONCE per park, got $(grep -cF "$DERIVED_LINE" "$LOG")"
grep -q -- '--json title' "$T/gh.txt" \
  && bad "2: tick 2 must not re-derive the key — it paid for a title read: $(cat "$T/gh.txt")" || ok
grep -q 'EVENT resolver_rung tproj/tproj-TK-9' "$LOG" && ok \
  || bad "2: tick 2 must take its rung under the cached ticket key: $(grep EVENT "$LOG")"
N=$(ROWJ tproj-TK-9 | jq -r '.rebuilds')
[ "${N:-0}" -ge 2 ] && ok || bad "2: two ticks must count two rebuilds on the ticket row, got '$N'"
N=$(ROWJ tproj-TK-9 | jq -r '.attempts | length')
[ "${N:-0}" -ge 2 ] && ok || bad "2: the ticket row must hold both attempts, got '$N'"
[ ! -e "$RST/tproj/o-tproj-9.json" ] && ok \
  || bad "2: nothing may land under the PR-number rkey once a key is known: $(ROWJ o-tproj-9)"
grep -q 'pulls/9' "$T/closed.txt" && ok \
  || bad "2: the park must have been ACTED on (the stale PR closed), got '$(cat "$T/closed.txt")'"

# ══ 3. A stale cache follows the branch gh answered with ════════════════════
reset_case
seed_tkey TK-8
printf 'ticket/TK-9\n' > "$T/prbranch"
printf 'TK-9: nav anchors\n' > "$T/prtitle"
ROW
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "3: the tick exited $RC: $(tail -3 "$T/run.err")"
[ "$(TKEY)" = TK-9 ] && ok \
  || bad "3: a cache that disagrees with the branch gh answered must be rewritten, got '$(TKEY)'"
[ "$(ROWJ tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh ] && ok \
  || bad "3: the tick must act under the gh key TK-9, got '$(ROWJ tproj-TK-9 | jq -r '.attempts[-1].action')'"
[ ! -e "$RST/tproj/tproj-TK-8.json" ] && ok \
  || bad "3: nothing may land under the stale cached key: $(ROWJ tproj-TK-8)"
grep -qF "$DERIVED_LINE" "$LOG" \
  && bad "3: discovery carried the key itself — br_one must not have re-derived it" || ok

# ══ 4. A wrong-shaped cache is ignored, and left exactly as written ═════════
# Pre-BH-487 behaviour, to the letter: the row lands under the PR-number rkey,
# the enqueue is refused, and the give-up pages once.
reset_case
seed_tkey 'not a key'
: > "$T/prbranch"; : > "$T/prtitle"
ROW
RUN; RC=$?
[ "$RC" = 0 ] && ok || bad "4: the tick exited $RC: $(tail -3 "$T/run.err")"
[ "$(TKEY)" = 'not a key' ] && ok \
  || bad "4: a wrong-shaped cache must be left alone, got '$(TKEY)'"
[ "$(ROWJ o-tproj-9 | jq -r '.attempts[-1].action')" = rebuild-fresh-nokey ] && ok \
  || bad "4: the row must land under the PR-number rkey, got '$(ROWJ o-tproj-9 | jq -r '.attempts[-1].action')'"
ROWJ o-tproj-9 | jq -r '.attempts[-1].detail' | grep -q 'no ticket key' && ok \
  || bad "4: the attempt must say why it was refused, got '$(ROWJ o-tproj-9 | jq -r '.attempts[-1].detail')'"
[ -z "$(find "$RST" -name 'tproj-*.json' 2>/dev/null)" ] && ok \
  || bad "4: a wrong-shaped cache must never become a cap key: $(find "$RST" -name 'tproj-*.json')"
grep -qF 'no ticket key — cannot enqueue a fresh build' "$LOG" && ok \
  || bad "4: the refusal must be logged: $(cat "$LOG")"
[ "$(wc -l < "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "4: the give-up must page exactly once, got $(wc -l < "$T/lane-alert.txt") line(s)"
[ -e "$RST/tproj/o-tproj-9.nokey-alerted" ] && ok \
  || bad "4: the once-per-park alert marker must be written"

echo "blocked-resolver.bh-948-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
