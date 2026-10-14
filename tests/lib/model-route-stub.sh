# tests/lib/model-route-stub.sh — a stubbed harness-jobs worker for the
# model_routes read path (BH-1510.1), so a suite drives bin/lib/model-route.sh
# and every lane that reads it FOR REAL, the way tests/model-route-lib.bh-1510-test.sh
# does: a fake `curl` on PATH, never a re-implementation of the resolver.
# Sourced, never run. Not a suite: tests/*.sh does not glob tests/lib/.
#
#   mrs_install <fakebin>            write the fake curl into <fakebin>
#   mrs_route <dir> <role> [project] <model:runner>...
#                                    write one role's ladder the worker answers
#   mrs_table_1523 <dir>             every build-lane role at the values main ran
#                                    after #1523 (BH-1507) — the rows the lead
#                                    moves through the audited API before #1510.1
#                                    merges, plus the roles #1510.1 seeds
#   mrs_cache_1523 <harness> [project...]
#                                    the same ladders as the resolver's BOX CACHE
#                                    (state/model-routes/*.tsv), for a suite that
#                                    has no worker at all and only needs the lane
#                                    to find its ladder the way a box whose worker
#                                    is down would
#
# The fake curl answers GET <JOBS_URL>/api/model-routes/<role>[?project=<p>]
# from $MRS_ROUTES/<role>@<p>.json, then $MRS_ROUTES/<role>.json (the hub),
# else an empty ladder with source "none" — the worker's own answer for a role
# nobody routed. MRS_MODE=down makes every call a transport failure (curl rc 7),
# the "worker unreachable" branch. Every other URL is a 404 — a real answer, so
# the jobs client stays quiet about it. Each model-routes request is appended to
# $MRS_SINK when set.
# shellcheck shell=bash
. "$(dirname "${BASH_SOURCE[0]}")/jobs-schema.sh" || return 1

mrs_install() {
  mkdir -p "$1"
  cat > "$1/curl" <<'EOF'
#!/bin/bash
URL="${!#}"
[ "${MRS_MODE:-up}" = down ] && exit 7
case "$URL" in
  */api/model-routes/*)
    [ -n "${MRS_SINK:-}" ] && printf '%s\n' "$URL" >> "$MRS_SINK"
    rest="${URL##*/api/model-routes/}"; role="${rest%%\?*}"; proj=""
    case "$rest" in *\?project=*) proj="${rest##*\?project=}" ;; esac
    if [ -n "$proj" ] && [ -s "$MRS_ROUTES/$role@$proj.json" ]; then cat "$MRS_ROUTES/$role@$proj.json"
    elif [ -s "$MRS_ROUTES/$role.json" ]; then cat "$MRS_ROUTES/$role.json"
    else printf '{"role":"%s","project":null,"ladder":[],"source":"none"}' "$role"; fi
    printf '\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
  chmod +x "$1/curl"
}

mrs_route() { # mrs_route <dir> <role> [project] <model:runner>...
  local dir="$1" role="$2" proj="" f rung pos=0 ladder=""
  shift 2
  case "${1:-}" in *:*) ;; *) proj="${1:-}"; shift ;; esac
  for rung in "$@"; do
    ladder="$ladder${ladder:+,}{\"position\":$pos,\"model\":\"${rung%:*}\",\"runner\":\"${rung##*:}\"}"
    pos=$((pos+1))
  done
  mkdir -p "$dir"
  f="$dir/$role${proj:+@$proj}.json"
  printf '{"role":"%s","project":%s,"ladder":[%s],"source":"%s"}' "$role" \
    "$([ -n "$proj" ] && printf '"%s"' "$proj" || printf null)" "$ladder" "$([ -n "$proj" ] && echo project || echo hub)" > "$f"
}

# The table the PR may merge against. Each line is: role, then its rungs.
_mrs_1523_rows() {
  cat <<'ROWS'
build.plan claude-fable-5-1:claude
build.execute claude-opus-5-5:claude claude-opus-5:claude
build.execute.fallback claude-opus-5-5:claude claude-opus-5:claude
build.review claude-opus-5-5:claude claude-fable-5-1:claude
build.review.t0 claude-opus-5-5:claude claude-fable-5-1:claude
build.fix claude-opus-5-5:claude claude-opus-5:claude
build.qa claude-opus-5-5:claude claude-opus-5:claude
rescue.review claude-opus-5-5:claude claude-fable-5-1:claude
postmerge.qa claude-opus-5-5:claude claude-opus-5:claude
orchestrate claude-fable-5-1:claude claude-opus-5-5:claude
claude.ladder claude-fable-5-1:claude claude-opus-5-5:claude claude-opus-5:claude
codex.default gpt-6-astra:codex
grok.default grok-4.6:grok
fireworks.default accounts/fireworks/models/kimi-k2p7-code:fireworks
fireworks.floor accounts/fireworks/models/deepseek-v4-flash-0731:fireworks
openrouter.floor deepseek/deepseek-v4-flash:openrouter
ROWS
}

mrs_table_1523() {
  local role rungs
  while read -r role rungs; do
    # shellcheck disable=SC2086
    mrs_route "$1" "$role" $rungs
  done < <(_mrs_1523_rows)
}

mrs_cache_1523() { # mrs_cache_1523 <harness> [project...] — the cache is per (role, project)
  local role rungs rung pos key d="$1/state/model-routes"
  shift
  mkdir -p "$d"
  while read -r role rungs; do
    for key in "$role" "${@/#/$role@}"; do
      pos=0; : > "$d/$key.tsv"
      for rung in $rungs; do
        printf '%s\t%s\t%s\n' "$pos" "${rung%:*}" "${rung##*:}" >> "$d/$key.tsv"; pos=$((pos+1))
      done
    done
  done < <(_mrs_1523_rows)
}

# mrs_fixture <harness> [project...] — the one line an EXISTING suite needs once
# its lane reads model_routes (BH-1510.1): a fixture box has no worker, so it is
# given what a real box whose worker is down would have — the resolver beside
# the lane (when the fixture copies bin/lib/ piecemeal) and its box cache holding
# #1507's table, for the hub and for each project the suite runs.
mrs_fixture() {
  local h="$1" src
  shift
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/lib/model-route.sh"
  if [ -d "$h/bin/lib" ] && [ ! -e "$h/bin/lib/model-route.sh" ]; then cp "$src" "$h/bin/lib/model-route.sh"; fi
  mrs_cache_1523 "$h" "$@"
}

# ── model_routes_fixture <harness> [project ...]  (BH-1510.2) ─────────────────
# The SEED-derived sibling of mrs_fixture, for the non-build lanes: copies
# bin/lib/lane-model.sh and bin/lib/model-route.sh into <harness>/bin/lib
# (copies, never symlinks: a suite that later cp's the whole lib dir over them
# must not write through into the repo; an existing file — a suite that links
# bin/lib at the repo's own — is left alone), and writes the resolver's box
# cache, state/model-routes/<role>.tsv, for EVERY hub row worker/jobs/schema.sql
# seeds, plus <role>@<project>.tsv for each project named (a project-scoped lane
# caches per project, and in an outage the resolver serves a project the hub's
# cache only on evidence it has no override). mrs_fixture's table is #1507's
# build-lane rows typed by hand; this one APPLIES schema.sql to an in-memory
# SQLite and reads the hub rows back, so every seed shape is covered.
#
# WHY A CACHE AND NOT A STUBBED WORKER. A lane that used to carry
# `${TRIAGE_MODEL:-<literal>}` now asks model_routes and fails CLOSED (rc 75)
# when nothing answers. A suite driving that lane in a scratch tree has no
# worker, so it needs the answer a box would have: the cache, which the
# resolver serves exactly when the worker is unreachable — the same branch a
# real box takes in an outage. Suites that stub curl for their OWN endpoints
# are unaffected: a reply that is not a model-routes answer is read as "worker
# unreachable", and the cache answers.
#
# THE VALUES ARE THE SEED'S, READ OFF schema.sql, never typed here — so a suite
# asserting "the triage tick passed the triage model" asserts it against the
# row the fleet deploys, and a seed change is a change every such suite sees.
# A suite that needs a DIFFERENT model for a role sets the lane's env override
# or rewrites that one role's .tsv after calling this.

model_routes_fixture() {
  local h="${1:?model_routes_fixture <harness> [project ...]}" root; shift
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  mkdir -p "$h/bin/lib" "$h/state/model-routes" || return 1
  local f
  for f in lane-model.sh model-route.sh; do
    # already there (a suite that links bin/lib at the repo's own) = nothing to do
    [ -e "$h/bin/lib/$f" ] || cp "$root/bin/lib/$f" "$h/bin/lib/$f" || return 1
  done
  # The rows are the ones schema.sql ACTUALLY inserts: the file is applied to
  # an in-memory SQLite (as the worker suites and harness-sync apply it) and the
  # hub rows are read back, so every seed shape — VALUES tuples, guarded
  # INSERT…SELECT, FROM (VALUES …) — lands exactly as the fleet deploys it.
  jobs_schema_render "$root" || return 1
  python3 - "$root/worker/jobs/schema.sql" "$h/state/model-routes" "$@" <<'PY' || return 1
import sqlite3, sys, os, collections
src, out, projects = sys.argv[1], sys.argv[2], sys.argv[3:]
db = sqlite3.connect(':memory:')
db.executescript(open(src).read())
rows = collections.defaultdict(list)
for role, pos, model, runner in db.execute(
        "SELECT role, position, model, runner FROM model_routes WHERE project IS NULL ORDER BY role, position"):
    rows[role].append((pos, model, runner))
if not rows:
    sys.exit('model_routes_fixture: schema.sql seeded no model_routes rows — refusing a fixture with no routes')
for role, rungs in rows.items():
    for key in [role] + [role + '@' + p for p in projects]:
        with open(os.path.join(out, key + '.tsv'), 'w') as fh:
            for pos, model, runner in rungs:
                fh.write('%d\t%s\t%s\n' % (pos, model, runner))
PY
}

