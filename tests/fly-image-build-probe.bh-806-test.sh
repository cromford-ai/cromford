#!/bin/bash
# tests/fly-image-build-probe.bh-806-test.sh — BH-806: `producer | grep -q` under
# `set -o pipefail` reads a PRESENT thing as ABSENT, and the absent-branch is
# destructive.
#
# THE BUG. `grep -q` exits at the first match. The producer still has bytes to
# write, gets SIGPIPE, exits 141, and `pipefail` hands the whole pipeline 141 —
# so `if ! producer | grep -q X` is TRUE exactly when X was found. Measured on
# this box (GNU grep 3.11, bash 5.2, 20 runs each): an external producer of
# 1 MB fails 20/20, and a builtin `printf`/`echo` of a 67 KB multi-line variable
# also fails 20/20 (at 44 KB it is 16/20 — a coin flip, which is worse). Every
# fixture here is sized past one pipe buffer (64 KB) and matches on its FIRST
# line, so the failure is deterministic rather than a race the suite can win.
#
# WHAT THIS PINS:
#   * bin/fly-image-build.sh — an app that IS in a large `fly apps list --json`
#     is never re-created, a FAILED or EMPTY list read never creates (it fails
#     closed, per #820), and an "already been taken" create failure is the
#     success case, not a FATAL. The whole real script runs against a scratch
#     $HARNESS. tests/fly-image-build-probe-test.sh pins the same script from
#     #820's angle; the two must agree, and this one adds the here-string (the
#     captured listing is not piped into grep either) plus the audit below.
#   * bin/load-project.sh — the two ticket-dedup probes never file a duplicate
#     ticket on a client board because the listing was long, and never file one
#     when `gh issue list` FAILED.
#   * bin/lander.sh — the independent conflict verification never reads a
#     conflicted tree as clean (it commits the tree when it does).
#   * bin/run-build.sh — the tier and preview-QA classifiers never read a big
#     diff as "no schema / no UI", which would auto-merge a tier-2 diff at tier
#     1 and skip the preview QA; and no classifier in that file reads a file
#     list through a pipe into an early-exit grep at all.
#
# The production blocks are extracted VERBATIM by their `# >>>`/`# <<<` markers
# or picked out of the script by content, per the repo's driving conventions —
# nothing here restates the logic it is testing.
#
# Run from anywhere: tests/fly-image-build-probe.bh-806-test.sh  (exit 0 = pass)
set -uo pipefail
if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# Extract a marked production block. An empty extraction FAILS the suite — it
# never passes by absence (D3).
extract() { # extract <file> <marker>
  awk -v m="$2" '
    $0 ~ "^[[:space:]]*# >>> " m "$" { f=1; next }
    $0 ~ "^[[:space:]]*# <<< " m "$" { f=0 }
    f' "$1"
}
need_block() { # need_block <text> <what>
  if [ -n "$1" ]; then ok; return 0; fi
  bad "$2: production block not found — nothing was tested"
  return 1
}

# ══ A. bin/fly-image-build.sh: the app-existence probe ═══════════════════════
PROBE_PROJECT=bh806probe
APP="builder-$PROBE_PROJECT"
# $T/h/env is created EMPTY on purpose. bin/lib/env-path.sh prefers $HARNESS/env
# only when it exists as a real directory and otherwise falls back to
# /etc/harness/env, so without it this suite would source the HUB's live
# fly.env: real FLY_ORG and FLY_API_TOKEN in the stub's environment, and case 6
# ("absent + FLY_ORG unset must FATAL") flipping to a successful create — green
# on a GitHub runner, red on the hub. tests/fly-image-build-probe-test.sh
# creates $H/env for the same reason. env-path.sh is copied in beside the script
# so the fixture walks production's real resolution rather than the
# script's last-resort inline fallback.
mkdir -p "$T/checkout/bin/lib" "$T/checkout/fly" "$T/fakebin" "$T/h/env"
cp "$DIR/bin/fly-image-build.sh" "$T/checkout/bin/"
cp "$DIR/bin/lib/env-path.sh" "$T/checkout/bin/lib/"
# BH-1517: fly-image-build.sh pins the image's CLI versions to
# cli.claude_code.version / cli.codex.version (no jobs-client.sh in this
# checkout, so setting_get is never defined and the fallback below always
# fires), falling back to cli_version_of — the shared parser — probing THIS
# host's own claude/codex. Both are required for the fixture's "healthy app"
# path to ever reach the build stage at all.
cp "$DIR/bin/lib/cli-version.sh" "$T/checkout/bin/lib/"
# BH-1528: the other baked dependencies. No jobs-client.sh, so no bake.* rows:
# the build pins what this project's last good image baked
# ($HARNESS/state/fly/<project>.bake).
cp "$DIR/bin/lib/bake-deps.sh" "$T/checkout/bin/lib/"
mkdir -p "$T/h/state/fly"
bash -c ". '$DIR/bin/lib/bake-deps.sh'; bake_dep_names" | sed 's/$/=1.0.0/' > "$T/h/state/fly/$PROBE_PROJECT.bake"
cp "$DIR/fly/Dockerfile" "$T/checkout/fly/"
: > "$T/fleet.conf"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "2.1.280 (Claude Code)"\n' > "$T/fakebin/claude"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "codex-cli 0.153.4"\n' > "$T/fakebin/codex"

# `exec cat`: the process that writes the list IS the one that takes the
# SIGPIPE. Real flyctl is a Go binary; a bash wrapper that printf's the list
# swallows the signal and hides the bug.
# Every knob is STUB_-prefixed on purpose. A bare CREATE_RC would collide with
# the script's OWN variable of that name: bash keeps an inherited variable in
# the export list, so the script's `CREATE_RC=0` would re-export 0 to this stub
# and the "create failed" cases would silently test the success path.
cat > "$T/fakebin/fly" <<'STUB'
#!/bin/bash
case "$1" in
  apps)
    case "${2:-}" in
      list)   echo list >> "$STUB_CALLS"
              [ "${STUB_LIST_RC:-0}" = 0 ] || exit "${STUB_LIST_RC}"
              exec cat "$STUB_LIST" ;;
      create) echo create >> "$STUB_CALLS"
              printf '%s\n' "${STUB_CREATE_MSG:-created}" >&2
              exit "${STUB_CREATE_RC:-0}" ;;
    esac ;;
  deploy) echo deploy >> "$STUB_CALLS"; printf '%s\n' "${STUB_DEPLOY_OUT:-built}"; exit "${STUB_DEPLOY_RC:-0}" ;;
esac
exit 0
STUB
printf '#!/bin/bash\nexit 1\n' > "$T/fakebin/gh"   # no gh token => warm bake stays cold
chmod +x "$T/fakebin"/*

# ~1 MB per list fixture; production's `fly apps list --json` is ~67 KB.
filler() { head -c 1000000 /dev/zero | tr '\0' x; }
{ printf '[{"Name":"%s","Status":"deployed"},\n' "$APP"; filler; printf ']\n'; } > "$T/list-present.json"
{ printf '[{"Name":"builder-other","Status":"deployed"},\n';   filler; printf ']\n'; } > "$T/list-absent.json"
{ printf '[{"Name":"%s-2","Status":"deployed"},\n' "$APP";     filler; printf ']\n'; } > "$T/list-substring.json"
: > "$T/list-empty.json"

probe() { # probe [VAR=VAL ...] — run the REAL script; sets RC, OUT, CALLS
  : > "$T/calls"
  OUT=$(env -u FLY_ORG STUB_CALLS="$T/calls" STUB_LIST="$T/list-present.json" \
            PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/fleet.conf" \
            FLY_ORG=stub-org WARM_BAKE=0 "$@" \
            bash "$T/checkout/bin/fly-image-build.sh" "$PROBE_PROJECT" 2>&1)
  RC=$?
  CALLS=$(tr '\n' ' ' < "$T/calls")
}
ncall() { grep -c "^$1\$" "$T/calls" 2>/dev/null | head -1; }

# ── 1. the app IS in a 1 MB list: no create, exit 0 ─────────────────────────
probe
[ "$RC" = 0 ] && ok || bad "1: a present app must exit 0 (rc=$RC, calls=[$CALLS])
$OUT"
[ "$(ncall create)" = 0 ] && ok || bad "1: a present app must NOT be created (calls=[$CALLS])"
[ "$(ncall deploy)" = 1 ] && ok || bad "1: the build/push step must still run (calls=[$CALLS])"
grep -q "== building + pushing image to registry.fly.io/$APP ==" <<<"$OUT" && ok \
  || bad "1: a present app must fall straight through the probe to the build: $OUT"
grep -q FATAL <<<"$OUT" && bad "1: no FATAL is allowed on a healthy present app: $OUT" || ok

# ── 2. the list read FAILED: that is not "absent" ───────────────────────────
# Fail CLOSED (#820's semantics, endorsed on the ticket thread): a failed read
# is not evidence of absence, so the run stops rather than guessing. The thing
# that must NEVER happen either way is a create on the strength of that read.
probe STUB_LIST_RC=1
[ "$(ncall create)" = 0 ] && ok || bad "2: a FAILED list read must never create (calls=[$CALLS])"
grep -q "FATAL: fly apps list failed (rc=1" <<<"$OUT" && ok || bad "2: must say why it stopped: $OUT"
[ "$RC" != 0 ] && ok || bad "2: a failed list read must fail closed, not carry on (rc=$RC)"
[ "$(ncall deploy)" = 0 ] && ok || bad "2: a failed list read must not go on to build (calls=[$CALLS])"

# ── 3. the app really is absent: create it, once ────────────────────────────
probe STUB_LIST="$T/list-absent.json"
[ "$(ncall create)" = 1 ] && ok || bad "3: a genuinely absent app must be created exactly once (calls=[$CALLS])"
[ "$RC" = 0 ] && [ "$(ncall deploy)" = 1 ] && ok || bad "3: create then build (rc=$RC, calls=[$CALLS])"
grep -qx "created" <<<"$OUT" && ok || bad "3: the real create output must be printed: $OUT"

# ── 4. create says "already been taken": that IS the success case ───────────
probe STUB_LIST="$T/list-absent.json" STUB_CREATE_RC=1 \
      STUB_CREATE_MSG="Error: failed creating app: Validation failed: Name has already been taken"
[ "$RC" = 0 ] && ok || bad "4: 'already been taken' must not fail the run (rc=$RC)
$OUT"
grep -q "WARN: $APP already exists" <<<"$OUT" && ok || bad "4: must say the app already exists: $OUT"
[ "$(ncall deploy)" = 1 ] && ok || bad "4: the image must still be built (calls=[$CALLS])"
grep -q "already been taken" <<<"$OUT" && ok || bad "4: the real create output must be printed: $OUT"

# ── 5. any OTHER create failure is still FATAL (no widening) ────────────────
probe STUB_LIST="$T/list-absent.json" STUB_CREATE_RC=1 \
      STUB_CREATE_MSG="Error: failed creating app: Validation failed: Name is invalid"
[ "$RC" = 1 ] && ok || bad "5: an unrelated create failure must still be FATAL (rc=$RC)"
grep -q "FATAL: apps create failed" <<<"$OUT" && ok || bad "5: must FATAL on it: $OUT"
[ "$(ncall deploy)" = 0 ] && ok || bad "5: a FATAL create must not go on to build (calls=[$CALLS])"

# ── 6. absent + no FLY_ORG: unchanged FATAL ─────────────────────────────────
: > "$T/calls"
OUT=$(env -u FLY_ORG STUB_CALLS="$T/calls" STUB_LIST="$T/list-absent.json" \
          PATH="$T/fakebin:$PATH" HARNESS="$T/h" FLEET_CONF="$T/fleet.conf" \
          WARM_BAKE=0 \
          bash "$T/checkout/bin/fly-image-build.sh" "$PROBE_PROJECT" 2>&1); RC=$?
[ "$RC" = 1 ] && ok || bad "6: absent app with FLY_ORG unset must FATAL (rc=$RC)"
grep -q "FATAL: app $APP missing and FLY_ORG unset" <<<"$OUT" && ok || bad "6: unchanged message: $OUT"
[ "$(ncall create)" = 0 ] && ok || bad "6: must not attempt a create without an org"

# ── 7. rc 0 with an EMPTY body is not "absent" either ───────────────────────
probe STUB_LIST="$T/list-empty.json"
[ "$(ncall create)" = 0 ] && ok || bad "7: an empty list body must never create (calls=[$CALLS])"
grep -q "FATAL: fly apps list failed" <<<"$OUT" && ok || bad "7: must say it cannot prove the app absent: $OUT"
[ "$RC" != 0 ] && ok || bad "7: an empty list body must fail closed (rc=$RC)"
[ "$(ncall deploy)" = 0 ] && ok || bad "7: an empty list body must not go on to build (calls=[$CALLS])"

# ── 8. a LONGER name is not this app (token match, not substring) ───────────
probe STUB_LIST="$T/list-substring.json"
[ "$(ncall create)" = 1 ] && ok || bad "8: \"$APP-2\" must not satisfy \"$APP\" (calls=[$CALLS])"

# ── 9. the pushed ref lands under THIS run's \$HARNESS ──────────────────────
probe STUB_DEPLOY_OUT="  image: registry.fly.io/$APP:deployment-42 (size 1 GB)"
[ "$(cat "$T/h/state/fly/$PROBE_PROJECT.image" 2>/dev/null)" = "registry.fly.io/$APP:deployment-42" ] \
  && ok || bad "9: the image ref must be recorded under \$HARNESS/state/fly, not a hardcoded /root/harness (got: $(cat "$T/h/state/fly/$PROBE_PROJECT.image" 2>/dev/null || echo '<no file>'))"

# ── 10. the fix is the probe, NOT removing pipefail ─────────────────────────
# Guarded source pin for the ticket's explicit negative: an absent line fails
# the assertion, it does not pass by absence.
PF=$(grep -c '^set -uo pipefail$' "$T/checkout/bin/fly-image-build.sh")
[ "$PF" = 1 ] && ok || bad "10: fly-image-build.sh must still set -uo pipefail, exactly once (found $PF)"
grep -q 'set +o pipefail' "$T/checkout/bin/fly-image-build.sh" \
  && bad "10: pipefail must not be switched off" || ok

# ══ B. bin/load-project.sh: the two ticket-dedup probes ══════════════════════
# A long `gh issue list` read as "not there" files a DUPLICATE ticket on a
# client board; a FAILED list read must not file one either.
mkdir -p "$T/lp/docs"
cp "$DIR/docs/VMAP-BACKFILL-TICKET.md" "$DIR/docs/ARCH-AUDIT-TICKET.md" "$T/lp/docs/"
cat > "$T/fakebin/gh-issue" <<'STUB'
#!/bin/bash
# `issue list` is an exec'd cat of a big titles file (real gh is a Go binary);
# `issue create` is recorded and never performed.
# TEST-CHANGE BH-1651: the list is gh_rest_issue_list now — one REST page per
# call, the same titles file, and GH_LIST_RC!=0 answers 403.
# BH-8962: the create is a REST POST, answered from the issue create arm below.
. "$GH_CLI_REST_ADAPTER" || exit 1
gh_cli_rest_create "$0" "$@" && exit 0
if [ "${1:-}" = api ] && [ "${2:-}" = -i ]; then
  [ "${GH_LIST_RC:-0}" = 0 ] || { printf 'HTTP/2 403\r\n\r\n{}'; exit 0; }
  pg=1; for a in "$@"; do case "$a" in page=*) pg="${a#page=}" ;; esac; done
  printf 'HTTP/2 200\r\n\r\n'
  jq -R '{title:.}' "$GH_TITLES" | jq -cs --argjson p "$pg" '.[(($p-1)*100):($p*100)]'
  exit 0
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = list ]; then
  [ "${GH_LIST_RC:-0}" = 0 ] || exit "${GH_LIST_RC}"
  exec cat "$GH_TITLES"
fi
if [ "${1:-}" = issue ] && [ "${2:-}" = create ]; then
  echo create >> "$GH_CALLS"; echo "https://github.com/x/y/issues/1"; exit 0
fi
exit 0
STUB
chmod +x "$T/fakebin/gh-issue"

VTITLE="verification map: explore the app and draft docs/verification-map/"
ATITLE="agent architecture: audit the repo and draft AGENT_ARCHITECTURE.md"
mk_titles() { # mk_titles <file> <first-title> — ~165 KB of listing
  { printf '%s\n' "$2"
    for i in $(seq 1 3000); do printf 'some other ticket title number %s in this repository\n' "$i"; done
  } > "$1"
}
mk_titles "$T/titles-vmap.txt" "$VTITLE"
mk_titles "$T/titles-arch.txt" "$ATITLE"
mk_titles "$T/titles-none.txt" "no ticket like that here at all"

LP_CREATES=0; LP_OUT=""
run_dedup() { # run_dedup <marker> <titles-file> [gh-list-rc]
  local block; block=$(extract "$DIR/bin/load-project.sh" "$1")
  need_block "$block" "load-project $1" || return 1
  : > "$T/gh.calls"
  ( set -euo pipefail
    export PATH="$T/fakebin:$PATH" GH_TITLES="$2" GH_LIST_RC="${3:-0}" GH_CALLS="$T/gh.calls"
    export GH_CLI_REST_ADAPTER="$DIR/tests/lib/gh-cli-rest-adapter.sh"
    # gh-rest-list.sh's ETag cache lives under $HARNESS/state/gh-etag and an
    # unset HARNESS is /root/harness: keep it in this run's scratch tree.
    export HARNESS="$T/h"
    gh() { "$T/fakebin/gh-issue" "$@"; }       # the production block calls `gh`
    . "$DIR/bin/lib/gh-rest-list.sh"           # TEST-CHANGE BH-1651: load-project sources it at the top
    . "$DIR/bin/lib/tracker/gh-issue-create.sh"  # BH-8962: load-project sources it at the top too
    cd "$T/lp"
    PROJECT=probe SLUG=Acme/probe VTITLE="$VTITLE" ATITLE="$ATITLE"
    eval "$block" ) > "$T/lp.out" 2>&1
  LP_OUT=$(cat "$T/lp.out")
  LP_CREATES=$(grep -c '^create$' "$T/gh.calls" 2>/dev/null | head -1)
  return 0
}

for M in "vmap-ticket dedup:$T/titles-vmap.txt:verification-map" \
         "arch-ticket dedup:$T/titles-arch.txt:agent-architecture"; do
  IFS=: read -r MARKER TITLES KIND <<<"$M"
  run_dedup "$MARKER" "$TITLES" || continue
  [ "$LP_CREATES" = 0 ] && ok || bad "B/$KIND: a ticket 3 000 titles deep must not be filed twice (creates=$LP_CREATES)
$LP_OUT"
  grep -q "already exists" <<<"$LP_OUT" && ok || bad "B/$KIND: must say it skipped: $LP_OUT"

  run_dedup "$MARKER" "$TITLES" 3
  [ "$LP_CREATES" = 0 ] && ok || bad "B/$KIND: a FAILED issue list must never file a ticket (creates=$LP_CREATES)"
  grep -q "WARN: could not list issues" <<<"$LP_OUT" && ok || bad "B/$KIND: must say why it did not file: $LP_OUT"

  run_dedup "$MARKER" "$T/titles-none.txt"
  [ "$LP_CREATES" = 1 ] && ok || bad "B/$KIND: a genuinely absent ticket must still be filed once (creates=$LP_CREATES)
$LP_OUT"
done

# ══ C. bin/lander.sh: the independent conflict verification ══════════════════
# A false "clean" here makes the lander `git add -A && git commit` a tree that
# still has unmerged entries or conflict markers in it.
GIT_ID=(-c user.name=t -c user.email=t@x)
big_tree() { # big_tree <dir> — 2 000 modified files: `git status --porcelain` > 64 KB
  local d="$1" i
  git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" checkout -q -b main; }
  mkdir -p "$d/src/mod/deep/segment/very/long/name"
  for i in $(seq 1 2000); do echo v1 > "$d/src/mod/deep/segment/very/long/name/component-$i.tsx"; done
  git -C "$d" add -A
  git -C "$d" "${GIT_ID[@]}" commit -qm base
  for i in $(seq 1 2000); do echo v2 > "$d/src/mod/deep/segment/very/long/name/component-$i.tsx"; done
}

LBLOCK=$(extract "$DIR/bin/lander.sh" "lander conflict check")
if need_block "$LBLOCK" "lander conflict check"; then
  lander_says_conflicted() { # <worktree> -> 0 when the conflicts branch is taken
    ( set -uo pipefail
      WT="$1"; PROJECT=probe; NUM=1; LOG="$T/lander.log"
      STAMP() { echo "2026-09-18 00:00:00Z"; }
      eval "$LBLOCK"
      exit 7 ) >/dev/null 2>&1
    [ "$?" = 1 ]
  }

  # c1. an unmerged index entry in a big tree, with no literal markers left
  big_tree "$T/wt-uu"
  git -C "$T/wt-uu" checkout -q -b other
  printf 'aaa\n' > "$T/wt-uu/aaa-conflict.ts"
  git -C "$T/wt-uu" add aaa-conflict.ts
  git -C "$T/wt-uu" "${GIT_ID[@]}" commit -qm other -- aaa-conflict.ts
  git -C "$T/wt-uu" checkout -q main
  printf 'bbb\n' > "$T/wt-uu/aaa-conflict.ts"
  git -C "$T/wt-uu" add aaa-conflict.ts
  git -C "$T/wt-uu" "${GIT_ID[@]}" commit -qm main -- aaa-conflict.ts
  git -C "$T/wt-uu" "${GIT_ID[@]}" merge -q other >/dev/null 2>&1
  printf 'resolved by hand, never staged\n' > "$T/wt-uu/aaa-conflict.ts"   # markers gone, index still unmerged
  # Read into a variable, then test it — this suite must not trip over the very
  # bug it is pinning.
  ST_FIXTURE=$(cd "$T/wt-uu" && git status --porcelain)
  [ "${#ST_FIXTURE}" -gt 65536 ] && ok \
    || bad "C: the fixture status must exceed one pipe buffer to be a real test (${#ST_FIXTURE} bytes)"
  grep -qE '^(UU|AA|DD|AU|UA)' <<<"$ST_FIXTURE" \
    && ok || bad "C: the fixture must actually carry an unmerged entry"
  lander_says_conflicted "$T/wt-uu" && ok || bad "C: an unmerged entry in a big tree must be caught (it was read as clean)"

  # c2. conflict markers left in files, index clean
  big_tree "$T/wt-mk"
  for i in $(seq 1 2000); do
    printf '<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n' > "$T/wt-mk/src/mod/deep/segment/very/long/name/component-$i.tsx"
  done
  git -C "$T/wt-mk" add -A
  git -C "$T/wt-mk" "${GIT_ID[@]}" commit -qm markers
  lander_says_conflicted "$T/wt-mk" && ok || bad "C: conflict markers in a big tree must be caught (they were read as clean)"

  # c3. a genuinely clean tree is still clean — the fix adds no false positive
  big_tree "$T/wt-ok"
  git -C "$T/wt-ok" checkout -q -- .
  lander_says_conflicted "$T/wt-ok" && bad "C: a clean tree must NOT be reported conflicted" || ok
fi

# ══ D. bin/run-build.sh: the tier and UI classifiers ═════════════════════════
# A false "no schema / no UI" auto-merges a tier-2 diff at tier 1 and skips the
# E2E smoke and the preview QA.
# The pipeline as ONE text (BH-568 seam): bin/run-build.sh is being split into
# stage modules under bin/lib/rb/, and tests/rb-modules-source-test.sh guard (f)
# lets only two suites read the driver raw. Everything below reads $RB_ALL.
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "FAIL: D: rb_all could not flatten the driver"; exit 1; }
pick() { # pick <substr-a> <substr-b> — the one production line holding both
  # Needles travel through ENVIRON, never `awk -v`: a -v assignment is processed
  # for escape sequences, so on gawk (the GitHub runner) 'schema\.prisma'
  # arrives as 'schema.prisma' and index() misses the line that literally
  # contains the backslash. mawk keeps it, which is why this passed on the box
  # and failed in CI (BH-806 fix round).
  A="$1" B="$2" awk 'index($0,ENVIRON["A"])>0 && index($0,ENVIRON["B"])>0 {print; exit}' "$RB_ALL"
}
# The tier classifier is two production lines since the pattern moved into
# PAT= (the console's one-line tier reason greps it a second time): the
# pattern and the decision. Both are picked, and both are eval'd in order.
TIER_PAT_LINE=$(pick "PAT='" 'schema\.prisma')
TIER_LINE=$(pick 'TIER=2' '"$PAT" <<<"$CHANGED"')
QA_LINE=$(pick 'PR_URL' '.(tsx|jsx|css)$')
need_block "$TIER_PAT_LINE" "run-build tier pattern"
need_block "$TIER_LINE" "run-build tier classifier"
need_block "$QA_LINE"   "run-build qa classifier"
[ "$TIER_LINE" != "$QA_LINE" ] && ok || bad "D: the tier and QA classifiers must be two different lines"
# The E2E path gate has its own reader (E2E_UI_DIFF, which already feeds
# `e2e_ui_path_hit`/grep from a here-string), so it is pinned structurally
# rather than by picking a line out of the middle of a function: NO classifier
# in run-build.sh may read a file list through a pipe into an early-exit grep.
if grep -nE '^[^#]*(git diff --name-only[^|#]*|"\$CHANGED"[^|#]*)\|[[:space:]]*grep -q' "$RB_ALL" >/dev/null; then
  bad "D: a diff/file-list classifier is piped into grep -q again (SIGPIPE + pipefail = a schema or UI diff reads as neither): $(grep -nE '^[^#]*(git diff --name-only[^|#]*|"\$CHANGED"[^|#]*)\|[[:space:]]*grep -q' "$RB_ALL" | head -3)"
else ok; fi
# The tier REASON is captured off the same $CHANGED and must not be a pipeline
# either: `grep -oiE ... | head -1` is the same early-exit producer kill, one
# line below the decision this suite pins.
if grep -nE '^[^#]*TIER_HIT=\$\(.*\|' "$RB_ALL" >/dev/null; then
  bad "D: the tier-hit capture is piped into an early-exit reader again: $(grep -nE '^[^#]*TIER_HIT=\$\(.*\|' "$RB_ALL" | head -3)"
else ok; fi

mk_diff_repo() { # mk_diff_repo <dir> <first-path> <ext> — 2 000 long paths, > 64 KB of diff
  local d="$1" first="$2" ext="$3" i
  git init -q -b main "$d" 2>/dev/null || { git init -q "$d"; git -C "$d" checkout -q -b main; }
  echo x > "$d/README.md"
  git -C "$d" add -A; git -C "$d" "${GIT_ID[@]}" commit -qm base
  mkdir -p "$d/$(dirname "$first")" "$d/src/mod/deep/segment/very/long/name"
  echo y > "$d/$first"
  for i in $(seq 1 2000); do echo y > "$d/src/mod/deep/segment/very/long/name/component-$i.$ext"; done
  git -C "$d" add -A; git -C "$d" "${GIT_ID[@]}" commit -qm change
}
mk_diff_repo "$T/diff-schema" "prisma/schema.prisma" ts
mk_diff_repo "$T/diff-ui"     "app/page.tsx"         tsx
mk_diff_repo "$T/diff-plain"  "lib/helper.ts"        ts

tier_of() { # tier_of <repo> — the TIER the production line decides
  ( set -uo pipefail; cd "$1"
    BASE=$(git rev-parse HEAD~1); TIER=1
    CHANGED=$(git diff --name-only "$BASE"...HEAD)
    [ "${#CHANGED}" -gt 65536 ] || { echo "FIXTURE-TOO-SMALL:${#CHANGED}"; exit 0; }
    eval "$TIER_PAT_LINE"
    eval "$TIER_LINE"
    echo "$TIER" )
}
ui_branch() { # ui_branch <repo> <production-line> — 0 when the UI branch is taken
  local cond
  # The production lines are an `if`/`elif` head: drop the keyword and the
  # trailing continuation so the PREDICATE itself is evaluated verbatim.
  cond=$(printf '%s' "$2" | sed -e 's/^[[:space:]]*elif //' -e 's/^[[:space:]]*if //' \
                                -e 's/[[:space:]]*\\$//' -e 's/;[[:space:]]*then$//')
  ( set -uo pipefail; cd "$1"
    BASE=$(git rev-parse HEAD~1); PR_URL="https://github.com/x/y/pull/1"
    eval "if $cond; then exit 0; else exit 1; fi" )
}

[ "$(tier_of "$T/diff-schema")" = 2 ] && ok \
  || bad "D: a schema change 2 000 paths long must be TIER 2 (got $(tier_of "$T/diff-schema"))"
[ "$(tier_of "$T/diff-plain")" = 1 ] && ok \
  || bad "D: a plain diff must stay TIER 1 (got $(tier_of "$T/diff-plain"))"
ui_branch "$T/diff-ui" "$QA_LINE"  && ok || bad "D: a big UI diff must still reach the preview QA"
ui_branch "$T/diff-plain" "$QA_LINE"  && bad "D: a non-UI diff must not trigger the preview QA" || ok

echo "fly-image-build-probe.bh-806-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
