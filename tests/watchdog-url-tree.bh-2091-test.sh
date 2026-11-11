#!/bin/bash
# tests/watchdog-url-tree.bh-2091-test.sh — the whole tree reads WATCHDOG_URL
# through bin/lib/watchdog-url.sh and nowhere else (BH-3324, part 4 of BH-2091).
#
# WHY. #3320-#3323 converted every WATCHDOG_URL reader to the contract lib, one
# group of files each. Each of those suites pins only its own files. This one
# pins the tree: a new script that brings back a literal fleet-host default, or
# a lane JSON that re-registers its own WATCHDOG_URL knob, goes red here even
# though no sibling suite looks at that file.
#
# §0      no tracked file outside catalog/, docs/ and .harness/specs/ names the
#         fleet host (with an in-suite positive control, so an empty answer
#         from a broken pipeline can never pass)
# §3b     exactly one WATCHDOG_URL knob in the composed registry: default "",
#         settable false, owned by one lib and by no lane
# §6b     fresh box end to end: bin/harness-sync.sh seeds global.env, then the
#         bin/watchdog-ping.sh it installed curls the catalog URL. A fork's
#         checkout makes 0 calls and logs one [watchdog-ping] line.
# §jobs   this branch touches no bin/lib/jobs/ path (JOBS_URL is #2063)
#
# Fixtures use http://watchdog.invalid; the fleet host is only ever assembled
# from pieces here. Run from anywhere (0 = pass).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v git >/dev/null && command -v flock >/dev/null \
  && command -v rsync >/dev/null || { echo "jq/git/flock/rsync missing — skipping"; exit 0; }

HOST='harness-watchdog.'"operator"'.workers'"."'dev'
CAT="$DIR/catalog/fleet-watchdog.json"

# ── §0 tree-wide literal grep ────────────────────────────────────────────────
# hits <repo> -> tracked files outside the exclusions that name the host
hits() {
  git -C "$1" ls-files -z | grep -zv -e '^catalog/' -e '^docs/' -e '^\.harness/specs/' \
    | (cd "$1" && xargs -0 -r grep -lF "$HOST" --)
}
# §0-ctl: the same pipeline over a scratch repo with the host in all three places.
CTL="$T/ctl"; mkdir -p "$CTL/bin" "$CTL/catalog" "$CTL/docs"; git init -q "$CTL"
for f in bin/x.sh catalog/c.json docs/d.md; do printf 'u=https://%s\n' "$HOST" > "$CTL/$f"; done
printf 'clean\n' > "$CTL/bin/y.sh"
git -C "$CTL" add -A >/dev/null
GOT=$(hits "$CTL")
[ "$GOT" = bin/x.sh ] && ok || bad "§0-ctl the grep must list exactly bin/x.sh in the control repo, got '$(printf '%s' "$GOT" | tr '\n' ' ')'"
# §0-list: an unreadable tree is a failure, never an empty (green) answer.
NT=$(git -C "$DIR" ls-files 2>/dev/null | wc -l)
[ "$NT" -gt 0 ] && ok || bad "§0 could not list tracked files in $DIR (git ls-files gave $NT)"
# §0: the real tree.
GOT=$(hits "$DIR")
[ "$NT" -gt 0 ] && [ -z "$GOT" ] && ok \
  || bad "§0 the fleet host is named outside catalog/, docs/ and .harness/specs/ in: $(printf '%s' "$GOT" | tr '\n' ' ')"

# ── §3b one WATCHDOG_URL registration ────────────────────────────────────────
J=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" 2>"$T/lb.err"); RC=$?
if [ "$RC" != 0 ] || ! jq -e . >/dev/null 2>&1 <<<"$J"; then
  bad "§3b bin/lanes-build.sh must exit 0 with JSON, got rc=$RC: $(head -c 400 "$T/lb.err")"
else
  K=$(jq -c '[.lanes[].knobs[]?, .libs[].knobs[]?] | map(select(.env=="WATCHDOG_URL"))' <<<"$J")
  [ "$(jq length <<<"$K")" = 1 ] && ok || bad "§3b want exactly 1 WATCHDOG_URL knob in the registry, got: $K"
  jq -e '.[0].default=="" and .[0].settable==false' >/dev/null <<<"$K" && ok \
    || bad "§3b the WATCHDOG_URL knob must be default \"\" and settable false, got: $K"
  NL=$(jq '[.libs[] | select(any(.knobs[]?; .env=="WATCHDOG_URL"))] | length' <<<"$J")
  NN=$(jq '[.lanes[] | select(any(.knobs[]?; .env=="WATCHDOG_URL"))] | length' <<<"$J")
  [ "$NL" = 1 ] && [ "$NN" = 0 ] && ok \
    || bad "§3b WATCHDOG_URL must be owned by 1 lib and 0 lanes, got libs=$NL lanes=$NN ($(jq -c '[.lanes[] | select(any(.knobs[]?; .env=="WATCHDOG_URL")) | .id]' <<<"$J"))"
fi

# ── §6b fresh box end to end ─────────────────────────────────────────────────
# Scaffold shape from tests/watchdog-url.bh-2091-test.sh §6 (copied, not
# sourced). Each checkout commits the REAL ping, lib, env-path and catalog.
mkdir -p "$T/fakebin"
NET="$T/net.log"; : > "$NET"
for c in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$NET" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done
# A failure message never echoes a secret: anything but the fixture's `x` is masked.
seen() { sed -E 's/([?&]s=)([^ &]{2,})/\1<redacted>/g' "$1" 2>/dev/null | tr '\n' ' '; }
mkorigin() { # mkorigin <bare> <clone>
  mkdir -p "$(dirname "$1")"; git init -q --bare "$1"
  git clone -q "$1" "$2" 2>/dev/null
  git -C "$2" config user.email t@t; git -C "$2" config user.name t
  mkdir -p "$2/bin/lib" "$2/prompts" "$2/fly" "$2/catalog"
  printf 'p\n' > "$2/prompts/p.md"
  printf 'f\n' > "$2/fly/f.txt"
  printf 'fleet\n' > "$2/fleet.conf"
  printf '#!/bin/bash\nexit 0\n' > "$2/bin/jobs-client.sh"; chmod +x "$2/bin/jobs-client.sh"
  cp "$DIR/bin/watchdog-ping.sh" "$2/bin/watchdog-ping.sh"
  cp "$DIR/bin/lib/watchdog-url.sh" "$DIR/bin/lib/env-path.sh" "$2/bin/lib/"
  cp "$CAT" "$2/catalog/fleet-watchdog.json"
  git -C "$2" add -A >/dev/null
  git -C "$2" commit -qm seed
  git -C "$2" branch -M main 2>/dev/null
  git -C "$2" push -q origin main
  git -C "$2" branch --set-upstream-to=origin/main main >/dev/null 2>&1
}
mkbox() { # mkbox <harness-root> ; a fresh box: global.env holds only the secret
  mkdir -p "$1/bin" "$1/logs" "$1/state" "$1/locks" "$1/prompts" "$1/fly" \
           "$1/catalog" "$1/checks" "$1/guardrails" "$1/config" "$1/env"
  cp "$DIR/bin/alert-line.sh" "$1/bin/"
  printf 'HARNESS_SECRET=x\n' > "$1/env/global.env"
}
# e2e <harness-root> <checkout> -> SRC (sync rc), PRC (ping rc); curl lines in $NET
e2e() {
  : > "$NET"
  env -u WATCHDOG_URL HARNESS="$1" HARNESS_CHECKOUT="$2" \
    bash "$DIR/bin/harness-sync.sh" >"$T/sync.out" 2>&1; SRC=$?
  env -u WATCHDOG_URL PATH="$T/fakebin:$PATH" HARNESS="$1" \
    bash "$1/bin/watchdog-ping.sh" testbox >/dev/null 2>&1; PRC=$?
}
mkorigin "$T/gh/example-org/cromford.git" "$T/ckf"
mkorigin "$T/gh/someone/cromford.git" "$T/ckk"
WANT=$(jq -r .watchdog_url "$CAT" 2>/dev/null)
case "$WANT" in *"$HOST"*) ok ;; *) bad "§6b catalog .watchdog_url must name the fleet host, got '$WANT'" ;; esac

# §6b-fleet
mkbox "$T/hf"
e2e "$T/hf" "$T/ckf"
[ "$SRC" = 0 ] && ok || bad "§6b-fleet harness-sync must exit 0, got $SRC: $(head -c 600 "$T/sync.out")"
GOT=$( set -a; . "$T/hf/env/global.env"; printf '%s' "${WATCHDOG_URL:-}" )
[ -n "$WANT" ] && [ "$GOT" = "$WANT" ] && ok || bad "§6b-fleet global.env must gain the catalog value '$WANT', got '$GOT'"
[ -x "$T/hf/bin/watchdog-ping.sh" ] && ok || bad "§6b-fleet harness-sync must install bin/watchdog-ping.sh"
[ "$PRC" = 0 ] && ok || bad "§6b-fleet the ping must exit 0, got $PRC"
NC=$(grep -c '^curl ' "$NET"); NW=$(grep -c '^wget ' "$NET")
# TEST-CHANGE BH-9264: the ping URL has no ?s= now (the secret rides an
# Authorization header from a curl config), so the URL must END at testbox.
[ "$NC" = 1 ] && [ "$NW" = 0 ] && grep -qE "$WANT/api/ping/testbox( |\$)" "$NET" && ok \
  || bad "§6b-fleet want exactly 1 curl to $WANT/api/ping/testbox, saw: $(seen "$NET")"
grep -qF '?s=' "$NET" && bad "§6b-fleet the secret is in the ping URL: $(seen "$NET")" || ok

# §6b-fork
mkbox "$T/hk"
e2e "$T/hk" "$T/ckk"
[ "$SRC" = 0 ] && ok || bad "§6b-fork harness-sync must exit 0, got $SRC: $(head -c 600 "$T/sync.out")"
[ "$(grep -c WATCHDOG_URL "$T/hk/env/global.env")" = 0 ] && ok \
  || bad "§6b-fork global.env must gain no WATCHDOG_URL line: $(cat "$T/hk/env/global.env")"
[ "$PRC" = 0 ] && [ ! -s "$NET" ] && ok || bad "§6b-fork want rc 0 and 0 curl/wget calls, got rc=$PRC: $(seen "$NET")"
[ "$(grep -cF '[watchdog-ping] WATCHDOG_URL not set' "$T/hk/logs/watchdog-url.log" 2>/dev/null)" = 1 ] && ok \
  || bad "§6b-fork want exactly 1 [watchdog-ping] not-set line, log: $(cat "$T/hk/logs/watchdog-url.log" 2>/dev/null)"

# ── §jobs scope pin ──────────────────────────────────────────────────────────
# Own slice ONLY (the BH-1939 L4/L5 pattern): a later ticket that edits
# bin/lib/jobs/ for its OWN work, or a merge-queue batch carrying one, must not
# be judged by BH-3324's "untouched" rule. So §jobs bites only when this branch
# carries BH-3324's own spec.
JOWN=0; JREF="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
if git -C "$DIR" rev-parse -q --verify origin/main >/dev/null 2>&1; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-3324's own slice
  JFILES=$(git -C "$DIR" diff --name-only origin/main...HEAD 2>/dev/null)
  grep -qE '^\.harness/specs/BH-3324/' <<<"$JFILES" && JOWN=1
  case "$JREF" in mergify/merge-queue/*) JOWN=0 ;; esac
  if [ "$JOWN" = 0 ]; then
    echo "§jobs: SKIP (scoped) judges only BH-3324's own branch; this diff is another ticket's"
  else
    JD=$(git -C "$DIR" diff --name-only origin/main...HEAD -- bin/lib/jobs/ 2>&1); RC=$?
    [ "$RC" = 0 ] && [ -z "$JD" ] && ok || bad "§jobs this branch must touch no bin/lib/jobs/ path (rc=$RC): $JD"
  fi
else
  echo "§jobs: no origin/main here (snapshot/shallow), scope pin not applicable"
fi

echo "watchdog-url-tree.bh-2091-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
