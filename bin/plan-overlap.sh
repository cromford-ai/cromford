#!/bin/bash
# bin/plan-overlap.sh — CONFLICT-AWARE SCHEDULING for the merge funnel (W2-D,
# the operator, 2026-09-14: "every throughput ceiling is a bug").
#
# WHY THIS EXISTS, ON TOP OF bin/conflict-check.sh. Two builds that plan to edit
# the same files do not fail at build time — they fail at MERGE time, as a
# conflict on one line into main, and at 4000 PRs a day that conflict is paid
# twice: once as a rebase and once as the re-review the rebase's moved head
# buys. bin/conflict-check.sh already refuses to co-build two overlapping builds
# it can SEE, and what it can see is this box's own `builds/` directory. That
# was the whole world when one box owned a project. It is not the world with a
# pool: the sibling that is about to conflict with this plan is usually running
# on another machine, and the only place both of them are visible is the jobs
# ledger.
#
# So this asks the same question against a wider set:
#   1. this box's live build dirs           (builds/<project>-*/planned-files.txt)
#   2. the claims ledger                    (state/claims/<project>/<KEY>)
#   3. the queue's CLAIMED rows             (queue_list <project> claimed)
#   4. every box's job_claims row           (fclaim_list_dir, BH-2524; see below)
# (4) is asked FIRST (BH-5002). When the worker answers, it is the claims source
# and (2) is not read; (2) is the fallback when it does not, and each fallback
# appends one FILE_CLAIMS_FALLBACK line to logs/file-claims-fallback.log.
# (3) is what makes it fleet-aware, and it is used two ways: a claim file whose
# row is no longer claimed is a DEAD claim and ignored (better than the 4h mtime
# guess), and a row claimed on a box whose file list never reached this one is
# reported as unjudged rather than silently treated as disjoint. Honest gaps
# beat confident wrong answers here: a missed overlap costs one rebase, and a
# fabricated one costs a build that never runs.
#
# THE OVERLAP RULE IS bin/conflict-check.sh's, deliberately unchanged: two plans
# conflict when any planned path of one equals, or is a path-prefix of, a
# planned path of the other (file == file, dir contains file) — with one prune
# in front of it (see `overlap` below): a bare directory entry that the SAME
# list also names a file under is dropped, because it is where that file lives
# and not a second claim. Since BH-4988 a colliding pair on a FRAGMENT path is
# then filtered out (see `fragment_safe`), and a plan whose every pair is one
# is not deferred: it logs `PLAN_HOTSPOT <KEY> choice=build ... fragment-only`.
#
# usage: plan-overlap.sh <project> <plan.md|build-dir>
#   exit 0  disjoint — nothing in flight claims a file this plan names, or the
#           question could not be asked (no plan data, kill flag). Build.
#   exit 1  overlap. stdout is one line, exactly:
#             OVERLAP_DEFER <KEY> vs <KEY2> files=[a,b,c]
#
# KILL FLAG: OVERLAP_SCHED=0 (env, or env/global.env), or settings row
# switch.plan-overlap-off.<box> or switch.plan-overlap-off (1 = off, read by lane_switch in
# bin/lib/lane-switch.sh; flags/plan-overlap-off decides only when neither row exists).
# Either one exits 0 before reading anything: bin/run-build.sh's hook is a no-op.
#
# THE TOUCH SET (BH-5965). planned-files.txt is every path plan.md mentions, so
# a path a plan cites only as caller evidence or under "Not touched" was on both
# sides of every compare. When a plan declares its files (`## Files to touch`),
# bin/touch-files.sh writes touch-files.txt and touch-source=declared, and that
# list is the side this build is judged on, with no hotspot mention added. A
# local in-flight build that declares its files is judged on its list the same
# way. A plan with no declared section (touch-source=none) keeps the mention
# superset and the BH-5268 hotspot union exactly as before. Switch
# plan-touch-off (settings row) or PLAN_TOUCH_DECLARED=0 turns the touch set
# off here at read time, whatever touch-source says. A defer also appends one
# line to the build's pipeline.log (where gates.sh sends this script's stderr;
# stderr itself is left alone),
# `OVERLAP_DEFER_SRC <KEY> vs <KEY2> touch=<src> src=[path@L<n>:<why>]`,
# naming where each candidate path came from (declared | hotspot | mention).
set -uo pipefail
PROJECT="${1:?project}"
TARGET="${2:?plan.md or build dir}"
HARNESS="${HARNESS:-/root/harness}"

# The kill flag, read before any work. `0`/`off`/`false`/`no` all mean off,
# because env/global.env is edited by hand and a box that wrote `off` meant off.
case "$(printf '%s' "${OVERLAP_SCHED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|off|false|no) exit 0 ;;
esac
# shellcheck source=lib/lane-switch.sh
. "$(dirname "$0")/lib/lane-switch.sh" || exit 1
lane_switch plan-overlap-off && exit 0

# <plan.md> is the documented argument; a build dir is accepted because that is
# what every other gate in this pipeline is handed and a caller should not have
# to remember which one this takes.
if [ -d "$TARGET" ]; then BUILD="$TARGET"; else BUILD=$(dirname "$TARGET"); fi
[ -d "$BUILD" ] || exit 0
[ -s "$BUILD/plan.md" ] || exit 0

# The candidate's file list. planned-files.txt is normally already there —
# bin/run-build.sh writes it for the size gate and again for the claims ledger —
# and re-deriving it is a pure function of plan.md, so an absent one is filled
# in rather than treated as a missing answer.
CFILES="$BUILD/planned-files.txt"
if [ ! -s "$CFILES" ]; then
  "$HARNESS/bin/planned-files.sh" "$BUILD" 2>/dev/null || true
fi
# The touch set (see the header). touch-files.sh is run only when touch-source
# is absent: plan.sh may have applied a test reroute to touch-files.txt, and a
# re-run would undo it.
TOUCH_SRC=absent
case "$(printf '%s' "${PLAN_TOUCH_DECLARED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|off|false|no) TOUCH_SRC=off ;;
esac
[ "$TOUCH_SRC" = off ] || ! lane_switch plan-touch-off || TOUCH_SRC=off
if [ "$TOUCH_SRC" != off ]; then
  if [ ! -e "$BUILD/touch-source" ] && [ -x "$HARNESS/bin/touch-files.sh" ]; then
    "$HARNESS/bin/touch-files.sh" "$BUILD" "$PROJECT" 2>/dev/null || :
  fi
  [ -e "$BUILD/touch-source" ] && TOUCH_SRC=$(cat "$BUILD/touch-source" 2>/dev/null)
fi
touch_list() { # touch_list <build-dir> — prints its touch-files.txt, rc 0, when that build declares its files
  [ "$TOUCH_SRC" != off ] && [ "$(cat "$1/touch-source" 2>/dev/null)" = declared ] \
    && [ -s "$1/touch-files.txt" ] && printf '%s\n' "$1/touch-files.txt"
}

# This build's KEY. The claims ledger is keyed on it, so it is the name both
# sides of the comparison use; the directory name is the fallback for a build
# whose ticket-meta.json never landed (<project>-<KEY>-<stamp>).
KEY=$(jq -r '.key // .ticket_key // empty' "$BUILD/ticket-meta.json" 2>/dev/null)
[ -n "$KEY" ] || KEY=$(basename "$BUILD" | sed -E "s/^${PROJECT}-//; s/-[0-9]{8,}$//")
[ -n "$KEY" ] || KEY=$(basename "$BUILD")

# --- who is in flight --------------------------------------------------------
# LIVE says whether the ledger has a CLAIMED row for a key. It is only consulted
# when the ledger answered at all: an outage must not silently empty the set of
# in-flight builds and turn this gate off.
CLAIMED=$(mktemp); UNJUDGED=$(mktemp); trap 'rm -f "$CLAIMED" "$UNJUDGED"; rm -rf "${PHD:-}"' EXIT
LEDGER=0
if [ -r "$HARNESS/bin/jobs-client.sh" ]; then
  # shellcheck source=/dev/null
  . "$HARNESS/bin/jobs-client.sh" 2>/dev/null || true
fi
# The fleet's job_claims rows (BH-2524), read as source 4 below. A missing lib is
# an outage, and an outage reads the local claim files (BH-5002).
if [ -r "$HARNESS/bin/lib/file-claims.sh" ]; then
  # shellcheck source=bin/lib/file-claims.sh
  . "$HARNESS/bin/lib/file-claims.sh" 2>/dev/null || true
fi
# BH-5268: the project's stored conflict hotspots (bin/lib/plan-hotspots.sh).
# planned-files.sh drops every path outside its directory allowlist, so a plan
# that names a hotspot (bin/deploy.sh, a root config file) only in a task note or
# a caller list claimed nothing. CAND is the candidate's planned files plus the
# hotspots its plan.md names; it is what every comparison below judges. A
# missing lib, TOP=0 or an unread hotspot list leaves CAND = planned-files.txt,
# today's behaviour exactly.
PHD=$(mktemp -d)
HOT="$PHD/hot"; CAND="$PHD/cand"; : > "$HOT"; : > "$PHD/cand-hot"
if [ -r "$HARNESS/bin/lib/plan-hotspots.sh" ]; then
  # shellcheck source=bin/lib/plan-hotspots.sh
  . "$HARNESS/bin/lib/plan-hotspots.sh" 2>/dev/null || true
fi
if command -v ph_hot_list >/dev/null 2>&1 && ph_hot_list "$PROJECT" "$HOT"; then
  ph_mentions "$BUILD/plan.md" "$HOT" > "$PHD/cand-hot"
fi
ph_union "$CFILES" "$PHD/cand-hot" "$CAND" 2>/dev/null || cp "$CFILES" "$CAND" 2>/dev/null
# A declared plan is judged on its declared files and nothing it only mentions.
if TL=$(touch_list "$BUILD"); then
  : > "$PHD/cand-hot"
  cp "$TL" "$CAND"
fi
[ -s "$CAND" ] || { rm -rf "$PHD"; exit 0; }   # no plan data -> cannot judge -> build (old behaviour)
if command -v queue_list >/dev/null 2>&1; then
  if ROWS=$(queue_list "$PROJECT" claimed 2>/dev/null); then
    LEDGER=1
    printf '%s\n' "$ROWS" | awk -F'\t' 'NF>1 && $2!="" {print $2}' | sort -u > "$CLAIMED"
  fi
fi
live() { # live <key> — rc 0 when the ledger does not say this key is finished
  [ "$LEDGER" = 1 ] || return 0                       # no ledger answer: fall back to mtime
  grep -qxF "$1" "$CLAIMED"
}

# overlap <candidate-list> <other-list> -> every colliding pair, or nothing (the
# 3-pair cap is judge's, after the fragment filter)
#
# THE PRUNE IS bin/lib/dep-verify-lib.sh:dep_overlap's, word for word, and for
# the case that found it: a pre-plan file list names BOTH a directory and the
# file it adds under it (`prisma/migrations/manual` AND
# `prisma/migrations/manual/2026-09-14-TK-667-….sql`), so the bare directory
# collided with every sibling's migration and two DIFFERENT new files were
# reported as one shared path. An entry another entry OF THE SAME LIST names a
# file under is dropped before comparing; a directory that appears ALONE keeps
# containing everything under it.
overlap() {
  awk 'NR==FNR{a[++na]=$0;next}
    {b[++nb]=$0}
    END{
      for(i=1;i<=na;i++) for(j=1;j<=na;j++) if(index(a[j],a[i]"/")==1){da[i]=1;break}
      for(i=1;i<=nb;i++) for(j=1;j<=nb;j++) if(index(b[j],b[i]"/")==1){db[i]=1;break}
      for(i=1;i<=nb;i++){
        if(db[i])continue
        for(j=1;j<=na;j++){
          if(da[j])continue
          p=a[j]; q=b[i]
          if(q==p || index(q,p"/")==1 || index(p,q"/")==1) print p" ~ "q
        }
      }
    }' "$1" "$2" 2>/dev/null
}

# po_record <verdict> <other-key> <pairs> — the decision, as a plan_overlap
# artifact on this ticket's job (Mission Control's job page). Only when JOB_ID is
# set and the jobs lib is loaded; in a subshell, output dropped, so a worker
# failure (or an unset variable inside the lib) never changes the verdict.
po_record() {
  [ -n "${JOB_ID:-}" ] && command -v job_artifact_put >/dev/null 2>&1 || return 0
  local files hot detail
  files=$(printf '%s\n' "$3" | sed 's/ ~ /\n/' | grep -v '^$' | sort -u)
  hot=$(printf '%s\n' "$files" | grep -xF -f "$HOT" 2>/dev/null)
  detail=$(jq -cn --arg p "$PROJECT" --arg o "$2" --arg f "$files" --arg h "$hot" \
    --arg s "${PH_SOURCE:-none}" --arg src "${SRC_TAGS:-}" --arg ts "$TOUCH_SRC" \
    '{project:$p, other:$o, files:($f|split("\n")|map(select(.!=""))),
      hot:($h|split("\n")|map(select(.!=""))), hot_source:$s,
      src:($src|split("\n")|map(select(.!=""))), touch_source:$ts}' 2>/dev/null) || return 0
  ( job_artifact_put plan_overlap "$1" "$detail" ) >/dev/null 2>&1 || :
  return 0
}

pairs_csv() { printf '%s\n' "$1" | sed 's/ ~ /,/' | tr '\n' ',' | sed 's/,*$//'; }

# src_tags <pairs> — where each distinct candidate-side path came from:
# <path>@L<n>:declared (a touch row of touch-files.src), <path>@L<n>:hotspot (a
# hotspot plan.md names) or <path>@L<n>:mention; L<n> is the first plan.md line
# naming it there, `?` when no line does.
src_tags() {
  local p n why
  printf '%s\n' "$1" | sed 's/ ~ .*//' | awk 'NF && !s[$0]++' | while IFS= read -r p; do
    n=""; why=mention
    if touch_list "$BUILD" >/dev/null; then
      n=$(awk -F'\t' -v p="$p" '$1==p && $3=="touch" {sub(/^L/, "", $2); print $2; exit}' "$BUILD/touch-files.src" 2>/dev/null)
      [ -n "$n" ] && why=declared
    fi
    if [ -z "$n" ]; then
      grep -qxF -- "$p" "$PHD/cand-hot" 2>/dev/null && why=hotspot
      n=$(grep -nF -- "$p" "$BUILD/plan.md" 2>/dev/null | head -1 | cut -d: -f1)
    fi
    if [ -n "$n" ]; then printf '%s@L%s:%s\n' "$p" "$n" "$why"; else printf '%s@?:%s\n' "$p" "$why"; fi
  done
}

report() { # report <other-key> <pairs>
  local hot
  hot=$(printf '%s\n' "$2" | sed 's/ ~ /\n/' | grep -xF -f "$HOT" 2>/dev/null | sort -u | paste -sd, -)
  [ -n "$hot" ] && echo "PLAN_OVERLAP_HOTSPOT $KEY vs $1 hot=[$hot]" >&2
  SRC_TAGS=$(src_tags "$2")
  { echo "OVERLAP_DEFER_SRC $KEY vs $1 touch=$TOUCH_SRC src=[$(printf '%s\n' "$SRC_TAGS" | paste -sd, -)]" \
      >> "$BUILD/pipeline.log"; } 2>/dev/null || :
  po_record sequenced "$1" "$2"
  printf 'OVERLAP_DEFER %s vs %s files=[%s]\n' "$KEY" "$1" "$(pairs_csv "$2")"
  exit 1
}

# --- fragment files are not held (BH-4988) ------------------------------------
# A collision on a FRAGMENT path is not a conflict anyone pays for at merge: a
# path the target repo's `## Generated files` table declares is regenerated by
# the train, and a fragment directory (catalog/lanes.d, ...) is where each build
# adds its OWN file. So a pair is fragment-safe when
#   (a) both sides name the same path and a Generated-files row matches it
#       (gen_path_matches: the whole path or a whole-path glob, never a prefix);
#   (b) one side is a bare fragment directory and the other a path under it;
#   (c) both sides name the bare fragment directory itself.
# The same FILE inside a fragment dir on both sides is NOT safe: two plans
# editing one lane's json really do collide. The directory list is the knob
# PLAN_OVERLAP_FRAGMENT_DIRS (lib.plan-hotspot, catalog/lanes.d/_lib.plan-hotspot.json):
# a settings row, then env, then env/global.env, then the default below. Read
# lazily, only once a pair exists, so a disjoint plan costs nothing extra.
REPO_DIR="${PLAN_OVERLAP_REPO:-${REPOS_ROOT:-/root/repos}/$PROJECT}"
FRAG_INIT=0; FRAG_DIRS=""; GEN_PATHS=""
frag_init() {
  local v d genv
  [ "$FRAG_INIT" = 1 ] && return 0
  FRAG_INIT=1
  command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply plan-hotspot "$PROJECT" >/dev/null 2>&1
  v="${PLAN_OVERLAP_FRAGMENT_DIRS:-}"
  # shellcheck source=bin/lib/env-path.sh
  . "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
  genv="$(harness_env_dir "$HARNESS")/global.env"
  if [ -z "$v" ] && [ -r "$genv" ]; then
    v=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}PLAN_OVERLAP_FRAGMENT_DIRS=//p' \
        "$genv" | tr -d "\"'" | tail -1)
  fi
  [ -n "$v" ] || v="catalog/lanes.d cron/lanes docs/verification-map/entries worker/jobs/schema.d"
  for d in $v; do
    d="${d%/}"; [ -n "$d" ] && FRAG_DIRS="$FRAG_DIRS $d"
  done
  # shellcheck source=bin/lib/generated-table.sh
  [ -r "$HARNESS/bin/lib/generated-table.sh" ] && . "$HARNESS/bin/lib/generated-table.sh" 2>/dev/null
  if command -v gen_table_paths >/dev/null 2>&1 && [ -d "$REPO_DIR" ]; then
    GEN_PATHS=$(gen_table_paths "$REPO_DIR" HEAD 2>/dev/null) || GEN_PATHS=""
  fi
  return 0
}
is_frag_dir() { local d; for d in $FRAG_DIRS; do [ "$1" = "$d" ] && return 0; done; return 1; }
fragment_safe() { # fragment_safe "<p> ~ <q>" — rc 0 when the collision is on a fragment path
  local p="${1%% ~ *}" q="${1#* ~ }" g
  frag_init
  if [ "$p" = "$q" ]; then
    is_frag_dir "$p" && return 0
    command -v gen_path_matches >/dev/null 2>&1 || return 1
    while IFS= read -r g; do
      [ -n "$g" ] && gen_path_matches "$p" "$g" && return 0
    done <<< "$GEN_PATHS"
    return 1
  fi
  if [ "${#p}" -lt "${#q}" ]; then is_frag_dir "$p"; else is_frag_dir "$q"; fi
}
hotspot_log() { # hotspot_log <line> — stderr (the build's pipeline.log) and logs/plan-hotspot.log
  echo "$1" >&2
  mkdir -p "$HARNESS/logs" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HARNESS/logs/plan-hotspot.log" 2>/dev/null
  return 0
}
judge() { # judge <other-key> <pairs> — report the non-fragment pairs (max 3); all safe -> log and go on
  local pr real=""
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    fragment_safe "$pr" || real="$real$pr"$'\n'
  done <<< "$2"
  [ -n "$real" ] && report "$1" "$(head -3 <<<"$real")"
  hotspot_log "PLAN_HOTSPOT $KEY choice=build vs $1 fragment-only files=[$(pairs_csv "$(head -3 <<<"$2")")]"
}

SEEN=$(mktemp); FCD=$(mktemp -d); trap 'rm -f "$CLAIMED" "$UNJUDGED" "$SEEN"; rm -rf "$FCD" "$PHD"' EXIT
echo "$KEY" > "$SEEN"

# 4 is ASKED here, before 1 (BH-5002), and judged below after 2. rc 0 means the
# worker answered with the contract, and then job_claims IS the claims source:
# the local claim files are not read, so a claim the worker no longer lists
# (job not running, or past files_expires_at) stops deferring even when its
# file lingers here. rc != 0 is no answer, never "nobody claims": the local
# files are read exactly as before, and that is logged to one file (never
# stderr) so a week with no FILE_CLAIMS_FALLBACK line proves the DB carried
# every decision. A missing logs/ dir never changes the verdict.
FC_OK=0
if command -v fclaim_list_dir >/dev/null 2>&1 && fclaim_list_dir "$PROJECT" "$FCD"; then
  FC_OK=1
fi

# 1 + 2. Every claim file this box has published (only when job_claims did not
# answer), and every live build dir that has a file list but no claim (a build
# from before the claims ledger, one whose claim was already released, or one
# whose fclaim_put failed).
if [ "$FC_OK" = 0 ]; then
  { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FILE_CLAIMS_FALLBACK $PROJECT plan-overlap: job_claims unreadable, read state/claims/$PROJECT" \
      >> "$HARNESS/logs/file-claims-fallback.log"; } 2>/dev/null || :
  for F in "$HARNESS/state/claims/$PROJECT"/*; do
    [ -f "$F" ] || continue
    OK=$(basename "$F")
    grep -qxF "$OK" "$SEEN" && continue
    echo "$OK" >> "$SEEN"
    [ -s "$F" ] || continue
    live "$OK" || continue
    HITS=$(overlap "$CAND" "$F")
    [ -n "$HITS" ] && judge "$OK" "$HITS"
  done
fi
for D in "$HARNESS/builds/$PROJECT"-*; do
  [ -d "$D" ] || continue
  [ "$D" = "$BUILD" ] && continue
  [ -f "$D/RESULT" ] && continue                    # finished
  # The other side is its planned files plus the hotspots ITS plan.md names, so a
  # sibling that touches a hotspot only lightly still collides (BH-5268).
  : > "$PHD/other-hot"
  [ -f "$D/plan.md" ] && ph_mentions "$D/plan.md" "$HOT" > "$PHD/other-hot" 2>/dev/null
  ph_union "$D/planned-files.txt" "$PHD/other-hot" "$PHD/other" 2>/dev/null \
    || cp "$D/planned-files.txt" "$PHD/other" 2>/dev/null
  # A sibling that declares its files is judged on that list alone (BH-5965).
  OTL=$(touch_list "$D") && cp "$OTL" "$PHD/other"
  [ -s "$PHD/other" ] || continue
  # Same liveness rule bin/conflict-check.sh uses: touched in the last 4h and no
  # RESULT. The ledger overrides it when it has an answer for the key.
  [ -n "$(find "$D" -maxdepth 1 -mmin -240 -print -quit 2>/dev/null)" ] || continue
  OK=$(jq -r '.key // .ticket_key // empty' "$D/ticket-meta.json" 2>/dev/null)
  [ -n "$OK" ] || OK=$(basename "$D" | sed -E "s/^${PROJECT}-//; s/-[0-9]{8,}$//")
  grep -qxF "$OK" "$SEEN" && continue
  echo "$OK" >> "$SEEN"
  HITS=$(overlap "$CAND" "$PHD/other")
  [ -n "$HITS" ] && judge "$OK" "$HITS"
done

# 4. Every box's job_claims row, through fclaim_list_dir (BH-2524), as fetched
# above. This is the only source that sees another box's plan, and it is judged
# AFTER the local build dirs, so a key this box already judged from its own
# files keeps that verdict.
#
# THE TIE-BREAK IS WHAT MAKES TWO PLANNERS SERIALISE. The local sources are
# symmetric: both sides of an overlap defer. Across the fleet that would defer
# BOTH boxes every tick, so a fleet claim blocks this build only when it came
# first: we have no row of our own, or theirs is older, or the two are equal and
# their key sorts first (byte order). The later claimer defers; the first one
# builds. With no answer (FC_OK=0) nothing is read here, the claim files above
# were, and the UNJUDGED report below fires exactly as it did. Stderr is left alone on purpose,
# so FILE_CLAIMS_INCOMPLETE reaches the build's pipeline.log.
fleet_claim_first() { # fleet_claim_first <other-key> — rc 0 when the other key's claim came first
  local LC_ALL=C THEIRS
  [ -n "$MINE" ] || return 0
  THEIRS=$(awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$FCD/.claimed_at" 2>/dev/null)
  [[ "$THEIRS" < "$MINE" ]] && return 0   # an unstamped peer sorts first: it blocks
  [ "$THEIRS" = "$MINE" ] && [[ "$1" < "$KEY" ]] && return 0
  return 1
}
if [ "$FC_OK" = 1 ]; then
  MINE=$(awk -F'\t' -v k="$KEY" '$1==k{print $2; exit}' "$FCD/.claimed_at" 2>/dev/null)
  for F in "$FCD"/*; do
    [ -f "$F" ] || continue
    OK=$(basename "$F")
    grep -qxF "$OK" "$SEEN" && continue
    echo "$OK" >> "$SEEN"
    [ -s "$F" ] || continue
    HITS=$(overlap "$CAND" "$F")
    [ -n "$HITS" ] || continue
    fleet_claim_first "$OK" || continue
    judge "$OK" "$HITS"
  done
fi

# 3. Rows claimed somewhere this box cannot see the plan of. Not an overlap and
# never reported as one — said out loud in the build's own log so a conflict
# that lands anyway has a written reason, instead of looking like a gate that
# failed.
if [ "$LEDGER" = 1 ]; then
  while IFS= read -r OK; do
    [ -n "$OK" ] || continue
    grep -qxF "$OK" "$SEEN" && continue
    printf '%s\n' "$OK" >> "$UNJUDGED"
  done < "$CLAIMED"
  if [ -s "$UNJUDGED" ]; then
    echo "OVERLAP_UNJUDGED $KEY: $(paste -sd, "$UNJUDGED") claimed on another box, no plan file list here" >&2
  fi
fi
po_record parallel "" ""
exit 0
