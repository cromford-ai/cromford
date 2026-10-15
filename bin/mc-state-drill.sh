#!/bin/bash
# bin/mc-state-drill.sh [--project <p>] [--timeout <s>] [--keep]
#
# The BH-4156 drill: can a fresh hub with an EMPTY state/ resume every open
# PR's merge-conductor state from the DB, with no re-review and no duplicate
# merge? It runs ONE conductor tick in a scratch harness whose state/, logs/,
# locks/ and flags/ are empty, behind a write fence, and compares what that
# tick did with what the DB already records. Hand-run on the hub, after the
# worker that serves GET /api/conductor-state is deployed.
#
#   --project <p>   tick only that fleet.conf project (default: every project)
#   --timeout <s>   the tick's wall clock bound (default 600)
#   --keep          keep the scratch tree (/tmp/mc-drill.*) for a look
#
# The LIVE state/merge-conductor is never moved, read for writing or touched.
# "Moving it aside" is running the tick on an empty scratch state/ instead:
# renaming the live directory would let the live conductor's next cron tick
# run as a fresh hub with its actions on.
#
# THE FENCE. The tick runs with MC_DRILL=1 (bin/lib/mc/tick-scope.sh forces
# observe mode) and with shims first on PATH, each appending one line per call
# to <scratch>/egress.log:
#   curl    GET/HEAD with no body pass; anything else is REFUSED (exit 7, which
#           _jobs_req reads as an outage). Only the jobs worker's path is
#           logged, never a header, a token or another host's path.
#   gh      reads pass (api GET, graphql with no mutation, pr view|list|checks|
#           diff|status, run list|view, repo view, auth status|token); every
#           other call is REFUSED (exit 1).
#   git     push is REFUSED; the rest pass.
#   claude  always REFUSED.
#
# THE VERDICT. The report's first line, also printed on stdout:
#   PASS               the tick exited 0 and F1-F5 are all clear
#   FAIL: <codes>      exit 1
#     F0  the tick exited non-zero
#     F1  a refused merge or enqueue, a git push or a claude call
#     F2  a refused PUT /api/pr-attempts of a row the DB already has (the
#         fresh tick decided "not tried yet" for work the DB records)
#     F3  a PR whose drill row and DB row have the same head, where the DB
#         `reviewed` is a sha and the drill's is `-` or another sha
#     F4  no "rehydrated N pr-state rows from the pr_state view" line
#     F5  a repo whose tick enumerated open PRs made no conductor-state GET
#   COULD NOT RUN: <why>   exit 2: another drill holds the lock, no worker
#                          config, the pr-state-rows flag down, the route not
#                          deployed, a DB read failed, the tick timed out, or
#                          it worked no project.
# Not a FAIL: a refused heartbeat or event POST, a refused PUT of an attempt
# the DB does not have (new work), a PR whose head moved, a PR the DB has no
# row for.
#
# Report: logs/mc-state-drill-<epoch>.md, one summary line appended to
# logs/merge-conductor.log. No ALERTS line and no page: the result is the exit
# code and the report.
set -uo pipefail
H="${HARNESS:-/root/harness}"
USAGE="usage: bin/mc-state-drill.sh [--project <p>] [--timeout <s>] [--keep]"
PROJECT="" TIMEOUT=600 KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ -n "${2:-}" ] || { echo "$USAGE" >&2; exit 2; }; PROJECT="$2"; shift ;;
    --timeout) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { echo "$USAGE" >&2; exit 2; }; TIMEOUT="$2"; shift ;;
    --keep) KEEP=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=bin/lib/env-path.sh
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "${1:-$H}"; }
ENV_DIR=$(harness_env_dir "$H")
set -a
# shellcheck disable=SC1091
. "$ENV_DIR/global.env" 2>/dev/null
set +a
# shellcheck source=bin/jobs-client.sh
. "$H/bin/jobs-client.sh" 2>/dev/null || { echo "COULD NOT RUN: cannot load bin/jobs-client.sh"; exit 2; }

NOW="${MC_DRILL_NOW:-$(date -u +%s)}"
mkdir -p "$H/logs" "$H/locks"
REPORT="$H/logs/mc-state-drill-$NOW.md"
S=""
BODY=$(mktemp) || { echo "COULD NOT RUN: mktemp failed"; exit 2; }

# finish <exit> <first line> — the report, the stdout line, the log line, the
# cleanup. Every exit after the lock goes through here.
finish() {
  local rc="$1" first="$2"
  { printf '%s\n\n' "$first"; cat "$BODY"; } > "$REPORT"
  printf '%s\n' "$first"
  printf '%s merge-conductor state drill: %s (report %s)\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$first" "$REPORT" >> "$H/logs/merge-conductor.log"
  rm -f "$BODY"
  if [ "$KEEP" = 1 ] && [ -n "$S" ]; then echo "kept: $S"
  else case "$S" in /tmp/mc-drill.*) rm -rf "$S" ;; esac; fi
  exit "$rc"
}

exec 9>"$H/locks/mc-state-drill.lock"
flock -n 9 || finish 2 "COULD NOT RUN: another drill is running ($H/locks/mc-state-drill.lock)"

# ── preconditions ────────────────────────────────────────────────────────────
{ [ -n "${HARNESS_SECRET:-}" ] && [ -n "${JOBS_URL:-}" ]; } \
  || finish 2 "COULD NOT RUN: HARNESS_SECRET or JOBS_URL is not set (env $ENV_DIR/global.env)"
flag_active pr-state-rows \
  || finish 2 "COULD NOT RUN: the pr-state-rows flag is down — no attempt or state row is written, so a fresh hub cannot resume from the DB"
CONF="$H/fleet.conf"
REPOS=()
for P in $(FLEET_CONF="$CONF" "$H/bin/fleet-conf.sh" --projects 2>/dev/null); do
  [ -z "$PROJECT" ] || [ "$P" = "$PROJECT" ] || continue
  R=$(FLEET_CONF="$CONF" "$H/bin/fleet-conf.sh" "$P" repo 2>/dev/null)
  [ -n "$R" ] && [ "$R" != - ] && REPOS+=("$R")
done
[ "${#REPOS[@]}" -gt 0 ] || finish 2 "COULD NOT RUN: no conductor project${PROJECT:+ named $PROJECT} in $CONF"
PROBE=$(mktemp)
pr_attempt_batch "${REPOS[0]}" "$PROBE" "$PROBE.cov" 1; rc=$?
rm -f "$PROBE" "$PROBE.cov"
case "$rc" in
  0) : ;;
  2) finish 2 "COULD NOT RUN: GET /api/conductor-state answered 404 — the jobs worker with BH-4156 is not deployed" ;;
  *) finish 2 "COULD NOT RUN: GET /api/conductor-state did not answer (rc $rc)" ;;
esac

# The DB truth, read BEFORE the tick (the fence refuses every write, so the
# tick cannot change it): every pr_state view row, as key/state/head/reviewed.
VIEW=$(mktemp)
before="" pages=0
while :; do
  resp=$(pr_state_page 1000 "$before"); rc=$?
  [ "$rc" = 2 ] && break
  [ "$rc" = 0 ] || { rm -f "$VIEW"; finish 2 "COULD NOT RUN: the pr_state view did not answer (rc $rc)"; }
  printf '%s' "$resp" | jq -r '.rows[] | [((.repo|ascii_downcase) + "#" + (.number|tostring)), (.state // "-"),
    ((.head // "") | if . == "" then "-" else . end), ((.reviewed // "") | if . == "" then "-" else . end)] | @tsv' >> "$VIEW" 2>/dev/null
  n=$(printf '%s' "$resp" | jq -r '.rows | length' 2>/dev/null)
  pages=$((pages + 1))
  [ "${n:-0}" -lt 1000 ] && break
  [ "$pages" -ge 50 ] && { rm -f "$VIEW"; finish 2 "COULD NOT RUN: the pr_state view is over 50 pages"; }
  before=$(printf '%s' "$resp" | jq -r '.rows | last | .id // empty' 2>/dev/null)
  [ -n "$before" ] || { rm -f "$VIEW"; finish 2 "COULD NOT RUN: the pr_state view gave no cursor"; }
done

# ── the scratch harness ──────────────────────────────────────────────────────
S=$(mktemp -d /tmp/mc-drill.XXXXXX) || finish 2 "COULD NOT RUN: mktemp -d failed"
mv "$VIEW" "$S/view.tsv"
mkdir -p "$S/h/state" "$S/h/logs" "$S/h/locks" "$S/shim"
for d in bin catalog prompts; do [ -e "$H/$d" ] && ln -s "$H/$d" "$S/h/$d"; done
if [ -n "$PROJECT" ]; then awk -v p="$PROJECT" '$1 == p' "$CONF" > "$S/h/fleet.conf"; else ln -s "$CONF" "$S/h/fleet.conf"; fi
# The flag is config, not conductor state: the precondition above found it up,
# so it is up in the scratch tree too, or the tick reads no row at all. Every
# reader tests presence only, so a local hold through the flag lib (a file in
# the scratch flags/, or its flags-cache entry when the flag is row-backed) is
# the same answer, with no raw flags/ write (no-flag-files, BH-4154).
JOBS_HARNESS="$S/h" flag_set --local-only pr-state-rows >/dev/null 2>&1 \
  || finish 2 "COULD NOT RUN: could not hold pr-state-rows up in the scratch tree"
EG="$S/egress.log"; : > "$EG"

# The real binaries, resolved before the shims go first on PATH.
REAL_CURL=$(command -v curl) REAL_GH=$(command -v gh) REAL_GIT=$(command -v git)
cat > "$S/shim/curl" <<EOF
#!/bin/bash
EG="$EG" REAL="$REAL_CURL" JU="$JOBS_URL"
EOF
cat >> "$S/shim/curl" <<'EOF'
args=("$@"); M="" URL="" BODY="" data=0
while [ $# -gt 0 ]; do
  case "$1" in
    -X|--request) M="$2"; shift 2 ;;
    -d|--data|--data-binary|--data-raw|--data-ascii|--data-urlencode|--json|-F|--form|-T|--upload-file) data=1; BODY="$2"; shift 2 ;;
    --data=*|--data-binary=*|--data-raw=*|--json=*|--form=*|--upload-file=*) data=1; BODY="${1#*=}"; shift ;;
    -I|--head) M=HEAD; shift ;;
    -K|--config) data=1; shift 2 ;;
    -H|--header|-m|--max-time|--connect-timeout|-w|--write-out|-o|--output|-u|--user|-A|--user-agent|-e|--referer|-b|--cookie|-c|--cookie-jar|--retry|--retry-delay|--retry-max-time) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
[ -n "$M" ] || { [ "$data" = 1 ] && M=POST || M=GET; }
M="${M^^}"
qv() { local x v; local -a kv; IFS='&' read -ra kv <<<"${Q:-}"
  for x in "${kv[@]}"; do [ "${x%%=*}" = "$1" ] || continue; v="${x#*=}"; v="${v//+/ }"; printf '%b' "${v//%/\\x}"; return 0; done; return 1; }
# Only the jobs worker's path is logged; any other host is its host alone (a
# bot token can sit in a URL path).
if [ -n "$JU" ] && [ "${URL#"$JU"}" != "$URL" ]; then
  P="${URL#"$JU"}"; Q=""; [[ "$P" == *\?* ]] && Q="${P#*\?}"; P="${P%%\?*}"
  T="$P"
  case "$P" in
    /api/conductor-state) [ -n "$Q" ] && T="$P"$'\t'"repo=$(qv repo)" ;;
    /api/pr-attempts) [ -n "$Q" ] && T="$P"$'\t'"repo=$(qv repo) number=$(qv number)" ;;
  esac
else
  P=""; h="${URL#*://}"; T="host:${h%%/*}"
fi
if [ "$data" = 0 ] && { [ "$M" = GET ] || [ "$M" = HEAD ]; }; then
  printf 'ALLOW\tcurl\t%s\t%s\n' "$M" "$T" >> "$EG"
  exec "$REAL" "${args[@]}"
fi
# A refused attempt write logs its key, which F2 checks against the DB.
if [ "$M $P" = "PUT /api/pr-attempts" ]; then
  case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
  K=$(printf '%s' "$BODY" | jq -r '[.repo, (.number|tostring), .kind, .sha] | @tsv' 2>/dev/null) && T="$P"$'\t'"$K"
fi
printf 'REFUSE\tcurl\t%s\t%s\n' "$M" "$T" >> "$EG"
exit 7
EOF
cat > "$S/shim/gh" <<EOF
#!/bin/bash
EG="$EG" REAL="$REAL_GH"
EOF
cat >> "$S/shim/gh" <<'EOF'
args=("$@"); all="$*"; sum=$(printf '%s' "$all" | tr '\n\t' '  ' | cut -c1-300)
merge=-
case "${all,,}" in *"pr merge"*|*"/merge "*|*"/merge") merge=merge ;; esac
case "$all" in *[Mm]ergifyio\ queue*|*enqueuePullRequest*|*mergePullRequest*) merge=merge ;; esac
allow=0
case "${1:-}" in
  api)
    method="" field=0 input=0 gql=0 mut=0; shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -X|--method) method="${2^^}"; shift 2 ;;
        --method=*) method="${1#*=}"; method="${method^^}"; shift ;;
        -f|-F|--field|--raw-field) field=1; case "$2" in *mutation*) mut=1 ;; esac; shift 2 ;;
        --input) input=1; shift 2 ;;
        -H|--header|-q|--jq|-t|--template|--hostname|--cache) shift 2 ;;
        graphql) gql=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$gql" = 1 ]; then [ "$mut" = 0 ] && [ "$input" = 0 ] && allow=1
    elif [ "$input" = 0 ] && { [ "$method" = GET ] || { [ -z "$method" ] && [ "$field" = 0 ]; }; }; then allow=1; fi ;;
  pr)   case "${2:-}" in view|list|checks|diff|status) allow=1 ;; esac ;;
  run)  case "${2:-}" in list|view) allow=1 ;; esac ;;
  repo) case "${2:-}" in view) allow=1 ;; esac ;;
  auth) case "${2:-}" in status|token) allow=1 ;; esac ;;
esac
if [ "$allow" = 1 ]; then printf 'ALLOW\tgh\t%s\t%s\n' "$merge" "$sum" >> "$EG"; exec "$REAL" "${args[@]}"; fi
printf 'REFUSE\tgh\t%s\t%s\n' "$merge" "$sum" >> "$EG"
exit 1
EOF
cat > "$S/shim/git" <<EOF
#!/bin/bash
EG="$EG" REAL="$REAL_GIT"
EOF
cat >> "$S/shim/git" <<'EOF'
sub="" i=1
while [ "$i" -le $# ]; do
  a="${!i}"
  case "$a" in
    -C|-c|--git-dir|--work-tree|--namespace) i=$((i + 2)) ;;
    -*) i=$((i + 1)) ;;
    *) sub="$a"; break ;;
  esac
done
if [ "$sub" = push ]; then printf 'REFUSE\tgit\tpush\t-\n' >> "$EG"; exit 1; fi
exec "$REAL" "$@"
EOF
printf '#!/bin/bash\nprintf "REFUSE\\tclaude\\t-\\t-\\n" >> "%s"\nexit 1\n' "$EG" > "$S/shim/claude"
chmod +x "$S/shim/curl" "$S/shim/gh" "$S/shim/git" "$S/shim/claude"

# ── ONE tick ─────────────────────────────────────────────────────────────────
env HARNESS="$S/h" H="$S/h" FLEET_CONF="$S/h/fleet.conf" HARNESS_ENV_DIR="$ENV_DIR" MC_DRILL=1 \
  MC_MAIN_RED_DETECT=0 PATH="$S/shim:$PATH" \
  timeout "$TIMEOUT" "$S/h/bin/merge-conductor.sh" > "$S/tick.out" 2>&1
TICK_RC=$?
TLOG="$S/h/logs/merge-conductor.log"
[ "$TICK_RC" = 124 ] && finish 2 "COULD NOT RUN: the tick hit the ${TIMEOUT}s timeout"
grep -q 'FANIN merge-conductor ' "$TLOG" 2>/dev/null \
  || finish 2 "COULD NOT RUN: the tick worked no project (tick rc $TICK_RC; $(tail -1 "$S/tick.out" 2>/dev/null | cut -c1-200))"

# ── the verdict ──────────────────────────────────────────────────────────────
CODES=""
add() { case " $CODES " in *" $1 "*) ;; *) CODES="${CODES:+$CODES }$1" ;; esac; }
[ "$TICK_RC" = 0 ] || add F0
F1L=$(awk -F'\t' '$1 == "REFUSE" && (($2 == "gh" && $3 == "merge") || $2 == "git" || $2 == "claude")' "$EG")
[ -n "$F1L" ] && add F1
F2L=""
while IFS=$'\t' read -r _ _ _ _ repo num kind sha; do
  [ -n "${sha:-}" ] || continue
  pr_attempt_has "$repo" "$num" "$kind" "$sha"; rc=$?
  case "$rc" in
    0) F2L="${F2L}${repo}#${num} ${kind} ${sha}"$'\n' ;;
    2) : ;;
    *) finish 2 "COULD NOT RUN: GET /api/pr-attempts did not answer while checking refused PUTs (rc $rc)" ;;
  esac
done < <(awk -F'\t' '$1 == "REFUSE" && $2 == "curl" && $3 == "PUT" && $4 == "/api/pr-attempts"' "$EG")
[ -n "$F2L" ] && add F2
ROWS="$S/h/state/merge-conductor/pr-state.tsv"
CMP=$(awk -F'\t' '
  FNR == NR { st[$1] = $2; hd[$1] = $3; rv[$1] = $4; next }
  { k = tolower($1); dst = $2; dhd = $4; drv = $5; if (dhd == "") dhd = "-"; if (drv == "") drv = "-"
    if (!(k in hd)) { print "-\t" $1 "\t(no DB row)\t-\t-\t" dst "\t" dhd "\t" drv; next }
    v = "ok"
    if (hd[k] != dhd) v = "head-moved"
    else if (rv[k] != "-" && rv[k] != drv) v = "F3"
    print v "\t" $1 "\t" st[k] "\t" hd[k] "\t" rv[k] "\t" dst "\t" dhd "\t" drv }' "$S/view.tsv" "$ROWS" 2>/dev/null)
grep -q '^F3' <<<"$CMP" && add F3
grep -qE 'rehydrated [0-9]+ pr-state rows from the pr_state view' "$TLOG" || add F4
F5L=""
while read -r slug n; do
  [ "$n" -gt 0 ] 2>/dev/null || continue
  c=$(awk -F'\t' -v r="repo=$slug" '$1 == "ALLOW" && $2 == "curl" && $4 == "/api/conductor-state" && $5 == r' "$EG" | grep -c .)
  [ "$c" -gt 0 ] || F5L="${F5L}${slug} (${n} open PRs, 0 batch GETs)"$'\n'
done < <(sed -nE 's/.*FANIN merge-conductor ([^ ]+): enumerated ([0-9]+).*/\1 \2/p' "$TLOG")
[ -n "$F5L" ] && add F5

{
  echo "Tick: rc $TICK_RC, timeout ${TIMEOUT}s, project ${PROJECT:-all}, scratch $S"
  echo
  echo "## PRs (drill row against the pr_state view row)"
  echo
  echo "| verdict | PR | DB state | DB head | DB reviewed | drill state | drill head | drill reviewed |"
  echo "|---|---|---|---|---|---|---|---|"
  [ -n "$CMP" ] && printf '%s\n' "$CMP" | awk -F'\t' '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
  echo
  echo "## Reads per repo"
  echo
  for r in "${REPOS[@]}"; do
    b=$(awk -F'\t' -v r="repo=$r" '$1 == "ALLOW" && $4 == "/api/conductor-state" && $5 == r' "$EG" | grep -c .)
    p=$(awk -F'\t' -v r="repo=$r" '$1 == "ALLOW" && $4 == "/api/pr-attempts" && index($5, r " number=") == 1 && $5 !~ /number=$/' "$EG" | grep -c .)
    echo "- $r: conductor-state batch GETs $b, per-PR pr-attempts GETs $p"
  done
  echo
  echo "## Refused calls"
  echo
  awk -F'\t' '$1 == "REFUSE" { $1 = "-"; print }' OFS=' ' "$EG"
  [ -n "$F1L" ] && { echo; echo "F1 (merge, push or model call):"; printf '%s\n' "$F1L"; }
  [ -n "$F2L" ] && { echo; echo "F2 (a refused PUT of an attempt the DB already has):"; printf '%s' "$F2L"; }
  [ -n "$F5L" ] && { echo; echo "F5 (no batch read):"; printf '%s' "$F5L"; }
  case " $CODES " in *" F4 "*) echo; echo "F4: no 'rehydrated N pr-state rows from the pr_state view' line in the tick log." ;; esac
  echo
  echo "## Not in the DB"
  echo
  for d in batch-hold land stuck closed-watch conflict-size; do
    [ -e "$H/state/merge-conductor/$d" ] && echo "- state/merge-conductor/$d/ (file state only; out of BH-4156 scope)"
  done
  echo
} >> "$BODY"

[ -z "$CODES" ] && finish 0 PASS
finish 1 "FAIL: $CODES"
