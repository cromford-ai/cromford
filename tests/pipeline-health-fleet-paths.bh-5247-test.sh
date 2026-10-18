#!/bin/bash
# tests/pipeline-health-fleet-paths.bh-5247-test.sh — BH-5247: pipeline-health's
# fleet checkout freshness check stops paging driftfail for a merge that
# bin/fleet-propagate.sh skipped on purpose (docs/tests only), and both read the
# one list of fleet paths, bin/lib/fleet-paths.sh.
#
# WHAT IS DRIVEN. bin/pipeline-health.sh's `fleet checkout freshness` block,
# extracted VERBATIM by its markers (as tests/pipeline-health-box-head.bh-2529-test.sh
# does), against a scratch tree holding the real bin/fleet-conf.sh,
# bin/box-for.sh, bin/lib/cron-lines.sh and bin/lib/fleet-paths.sh, and a
# scratch git origin whose commits carry pinned dates. box_heads is a TSV stub;
# alert() records to a file. G2 runs the real bin/fleet-propagate.sh.
#
# CASES
#   P0 (BH-7304) a remote box behind a bin/ change, or on an unknown sha:
#      no driftfail and no log line (bin/fleet-version-check.sh owns it)
#   G1 the FLEET_PATHS assignment and its literal live in bin/lib/fleet-paths.sh only
#   G2 the lib defines the list; bin/fleet-propagate.sh without it exits 1 in
#      --check and deploy mode, says fleet-paths.sh missing, records no last_sha
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-fleet-paths.bh-5247-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git awk; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
unset FLEET_PATHS

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>

awk '/^# >>> fleet checkout freshness/{f=1;next} /^# <<< fleet checkout freshness/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/fresh.sh"
[ -s "$T/fresh.sh" ] && ok || bad "could not extract the fleet checkout freshness block — markers missing?"

# ── the scratch harness ──────────────────────────────────────────────────────
F="$T/f"; mkdir -p "$F/bin/lib" "$F/logs" "$F/flags" "$F/state"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$F/bin/"
scratch_install_closure bin/lib/cron-lines.sh "$F" >/dev/null || bad "fixture: cannot install bin/lib/cron-lines.sh"
scratch_install_closure bin/lib/fleet-paths.sh "$F" >/dev/null || bad "fixture: cannot install bin/lib/fleet-paths.sh"
printf 'project-4 Acme/project-4 - - 1 box-project-4-1 10.0.0.4\n' > "$F/fleet.conf"
printf '#!/bin/bash\necho "$*" >> "%s/calls.sync"\n' "$T" > "$F/bin/harness-sync.sh"; chmod +x "$F/bin/harness-sync.sh"

# ── the git fixture: bare origin, a source clone that pushes, the hub checkout ─
G="$T/g"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git init -q "$G/src"
git -C "$G/src" checkout -q -b main
gcf() { # gcf <seconds-ago> <msg> <path>... — write each path (dirs get /f), commit, push
  local at="@$(( NOW - $1 ))" m="$2" p f; shift 2
  for p in "$@"; do
    case "$p" in */) f="$p"f ;; *) f="$p" ;; esac
    mkdir -p "$G/src/$(dirname "$f")"; echo "$m" >> "$G/src/$f"
    git -C "$G/src" add -- "$f"
  done
  GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" git -C "$G/src" -c user.name=t -c user.email=t@t \
    commit -q -m "$m"
  git -C "$G/src" push -q "$G/origin.git" main
}
short() { git -C "$G/src" rev-parse --short HEAD; }
gcf 21600 A bin/a.sh docs/x.md; A=$(short)
gcf 18000 B docs/x.md tests/y.sh; B=$(short)
git clone -q -b main "$G/origin.git" "$G/co" 2>/dev/null
[ "$(git -C "$G/co" rev-parse --short HEAD)" = "$B" ] && ok || bad "fixture: the hub checkout must sit at origin tip"

heads() { printf 'box-project-4-1\t%s\t%s\n' "$1" "$(iso 300)" > "$T/heads.tsv"; }
drive_fresh() {
  : > "$T/alerts.txt"; : > "$F/logs/pipeline-health.log"
  # the hub checkout follows origin, so section 8's hub branch never fires
  git -C "$G/co" fetch -q origin main && git -C "$G/co" reset -q --hard origin/main
  ( export H="$F" HARNESS="$F" NOW FLEET_CONF="$F/fleet.conf" HARNESS_CHECKOUT="$G/co" HARNESS_HEAD_GRACE_S=5400
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
             box_heads() { cat "$T/heads.tsv"; }
             . "$0"' "$T/fresh.sh" ) >"$T/fresh.out" 2>&1
}
drift() { grep "|driftfail:project-4:" "$T/alerts.txt" 2>/dev/null; }
nonfleet() { grep -c 'on non-fleet paths only' "$F/logs/pipeline-health.log" 2>/dev/null; }

# P0 (BH-7304, BH-7191.2): section 8 no longer judges a remote box, so a box
# behind main on a bin/ change, past grace, gives no driftfail: line and no
# log line. bin/fleet-version-check.sh owns it, and its fvc_main_log reads
# the same FLEET_PATHS (tests/fleet-version-check.bh-7191-test.sh L1).
gcf 17940 B2 bin/a.sh docs/x.md
heads "$A"; drive_fresh
[ -z "$(drift)" ] && ok || bad "P0: a remote box behind a bin/ change must give no driftfail (alerts: $(cat "$T/alerts.txt"))"
[ ! -s "$F/logs/pipeline-health.log" ] && ok || bad "P0: a remote box must give no log line (log: $(cat "$F/logs/pipeline-health.log"))"
heads deadbeefcafe; drive_fresh
[ -z "$(drift)" ] && [ ! -s "$F/logs/pipeline-health.log" ] && ok \
  || bad "P0: a remote box on an unknown sha gives no driftfail and no log line (alerts: $(cat "$T/alerts.txt"))"
[ ! -e "$T/calls.sync" ] && ok || bad "fixture: the hub is current, harness-sync must not run"

# G1 a single source
got=$(cd "$DIR" && grep -rlE '^[[:space:]]*FLEET_PATHS=' bin | sort)
[ "$got" = bin/lib/fleet-paths.sh ] && ok || bad "G1: FLEET_PATHS= must be assigned only in bin/lib/fleet-paths.sh (got: $got)"
got=$(cd "$DIR" && grep -rlF 'prompts/ fly/ rules/ skills/' bin | sort)
[ "$got" = bin/lib/fleet-paths.sh ] && ok || bad "G1: the fleet path literal must live only in bin/lib/fleet-paths.sh (got: $got)"

# G2 the lib defines the list; fleet-propagate without it fails closed
( set -u; . "$DIR/bin/lib/fleet-paths.sh" && . "$DIR/bin/lib/fleet-paths.sh" \
  && case " $FLEET_PATHS " in *' bin/ '*' fleet.conf '*' orchestrator/ '*) exit 0 ;; *) exit 1 ;; esac ) 2>/dev/null \
  && ok || bad "G2: sourcing the lib twice under set -u must define FLEET_PATHS with bin/, fleet.conf, orchestrator/"
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/locks" "$H/flags"
cp "$DIR/bin/fleet-propagate.sh" "$H/bin/"
# Everything that could reach a box or the crontab is a recording stub: the
# deploy run must stop before any of it, and none may be the real thing.
mkdir -p "$T/stub"
for s in ssh crontab flyctl pgrep; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.stub"; exit 1\n' "$s" "$T" > "$T/stub/$s"; chmod +x "$T/stub/$s"
done
for mode in --check ""; do
  OUT=$(HARNESS="$H" HARNESS_CHECKOUT="$G/co" FLEET_PROPAGATE_PATH="$T/stub:/usr/local/bin:/usr/bin:/bin" bash "$H/bin/fleet-propagate.sh" $mode 2>&1); RC=$?
  [ "$RC" = 1 ] && grep -q 'fleet-paths.sh missing' <<<"$OUT" && ok \
    || bad "G2: fleet-propagate ${mode:-deploy} without the lib must exit 1 naming fleet-paths.sh missing (rc $RC: $OUT)"
  [ -z "$(jq -r '.last_sha // empty' "$H/state/fleet-propagate.json" 2>/dev/null)" ] && ok \
    || bad "G2: fleet-propagate ${mode:-deploy} without the lib must record no last_sha"
done
grep -q 'fleet-paths.sh missing' "$H/logs/fleet-propagate.log" 2>/dev/null && ok \
  || bad "G2: the deploy run must log fleet-paths.sh missing to logs/fleet-propagate.log"
[ ! -s "$T/calls.stub" ] && ok || bad "G2: fleet-propagate without the lib must reach no box (calls: $(cat "$T/calls.stub"))"

echo "pipeline-health-fleet-paths: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
