#!/bin/bash
# bin/lib/queue-partition.sh — IMPACT PARTITIONING IN THE MERGE QUEUE (BH-4979).
# Sourced, never executed.
#
#   qp_impact <changed-file> [map]     the PR's lane: `lane=scoped` + one scope
#                                      per line, or `lane=serial reason=<why>`
#   qp_partition <dir>                 `<pr>\t<partition>` over <dir>/<pr>.impact
#   qp_scopes_json <impact-file>       the Mergify scopes payload
#   qp_upload <slug> <sha> <json> [n]  PUT the scopes for a commit, once per head
#   qp_enqueue_step <slug> <n> <head>  mc_enqueue_mergify's block: rc 0 go on,
#                                      rc 3 hold unlabelled (stdout = why)
#
# WHY. Every PR the conductor enqueued got the same label and joined one serial
# stream of batches of 8, so one red PR failed and bisected PRs it could not
# have affected (2026-10-06: #4958 took #4959-#4962 down with it, 25+ min).
#
# THE CHOICE: MERGIFY PARALLEL MODE + MANUAL SCOPES, COMPUTED HERE. The ticket
# names Mergify "partition rules"; Mergify removed them on 2025-10-31 and the
# successor is `merge_queue.mode: parallel` with `scopes.source.manual`, where
# each commit is told its scopes by a PUT. A scope is an impact suite: PRs that
# share one are batched together in order, PRs with disjoint scopes run in their
# own lanes on fresh main, and `all_scopes: true` is a barrier — the serial lane.
# Static file-glob scopes in .mergify.yml cannot say this (the impact map is
# generated and never committed, BH-1175, and a glob cannot name "a file the map
# cannot place"), and the conductor alone cannot give a PR its own lane (its only
# lever is the merge-queue label). So the conductor computes and Mergify runs.
#
# THE IMPACT SET is the suites `bin/test-impact.sh select --why` maps the changed
# files to, MINUS the always-suites: every selection carries those, so counting
# them would put every PR in one partition. A suite also picked for another
# reason stays. A PR whose selection is only always-suites (docs) gets the one
# synthetic scope `_inert`, so no PR is ever scopeless.
#
# THE SERIAL LANE takes, with the reason on the header line:
#   files-unavailable      the file list is empty or unreadable (never "no impact")
#   too-many-files (N > 25)
#   fix-main-red           QP_LABELS holds it
#   train                  train_is_train on QP_TITLE / QP_HEAD_REF
#   risk-tier high         a loaded risk_tier (#4973) said so
#   serial path (<p>)      a path matches queue_partition.serial_re (settings
#                          row; QP_SERIAL_RE_DEFAULT is only the fallback)
#   serial_re invalid      the row is not an ERE grep accepts
#   full: …                test-impact.sh would run the corpus (infra change,
#                          unknown reach — a file main's map cannot place)
#
# The map is built from $HARNESS, the conductor's own checkout of main, so a file
# a PR adds is unknown to it and goes serial. That over-serialises, which is safe.
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty is serial.
[ -n "${_QP_LOADED:-}" ] && return 0
_QP_LOADED=1

# The paths #4973 lists as high tier, until its lib ships. Fallback only: the
# settings row queue_partition.serial_re is read first.
QP_SERIAL_RE_DEFAULT='^\.mergify\.yml$|^\.github/|^config/mergify/|^worker/jobs/schema\.sql$|(^|/)migrations?/|^bin/lib/jobs/|^bin/merge-|^bin/lead-|^bin/lib/verdicts\.sh$|^bin/lib/mc/|^bin/test-impact|^bin/ci-plan\.sh$'
QP_MAX_FILES=25

_qp_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_qp_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }

qp_impact() {
  local changed="${1:-}" map="${2:-${QP_MAP:-}}" root n re v rc hit ti rows full suites
  if [ -z "$changed" ] || [ ! -r "$changed" ] || ! grep -q . "$changed" 2>/dev/null; then
    echo 'lane=serial reason=files-unavailable'; return 0
  fi
  n=$(grep -c . "$changed")
  [ "$n" -gt "$QP_MAX_FILES" ] && { echo "lane=serial reason=too-many-files ($n > $QP_MAX_FILES)"; return 0; }
  case ",${QP_LABELS:-}," in *,fix-main-red,*) echo 'lane=serial reason=fix-main-red'; return 0 ;; esac
  command -v train_is_train >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/train-shape.sh" ] && . "${BASH_SOURCE[0]%/*}/train-shape.sh"; }
  if ! command -v train_is_train >/dev/null 2>&1; then
    echo 'lane=serial reason=train recogniser unavailable'; return 0
  fi
  train_is_train "${QP_TITLE:-}" "${QP_HEAD_REF:-}" && { echo 'lane=serial reason=train'; return 0; }
  # risk_tier is used only when a caller has already loaded it: risk-tier.sh
  # (#4973) is not on main, and this lib never sources a file main lacks.
  # Without it, QP_SERIAL_RE_DEFAULT below carries #4973's high-tier paths.
  if command -v risk_tier >/dev/null 2>&1 && [ "$(risk_tier "$changed" 2>/dev/null)" = high ]; then
    echo 'lane=serial reason=risk-tier high'; return 0
  fi
  re="$QP_SERIAL_RE_DEFAULT"
  if command -v setting_get >/dev/null 2>&1; then
    v=$(setting_get queue_partition.serial_re 2>/dev/null) && [ -n "$v" ] && re="$v"
  fi
  rc=0; hit=$(grep -E -m1 -e "$re" "$changed" 2>/dev/null) || rc=$?
  case "$rc" in
    0) echo "lane=serial reason=serial path ($hit)"; return 0 ;;
    1) ;;
    *) echo 'lane=serial reason=serial_re invalid'; return 0 ;;
  esac
  root=$(_qp_root)
  [ -n "$root" ] || { echo 'lane=serial reason=no harness root'; return 0; }
  ti="$root/bin/test-impact.sh"
  [ -r "$ti" ] || { echo "lane=serial reason=no test-impact at $ti"; return 0; }
  rc=0
  rows=$(bash "$ti" select --why --changed "$changed" --root "$root" ${map:+--map "$map"} 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] && [ -n "$rows" ] || { echo "lane=serial reason=test-impact failed (rc $rc)"; return 0; }
  full=$(awk -F'\t' '$2 == "full" { print $3; exit }' <<<"$rows")
  [ -n "$full" ] && { echo "lane=serial reason=$full"; return 0; }
  suites=$(awk -F'\t' '$2 != "always" && $1 != "" { print $1 }' <<<"$rows" | LC_ALL=C sort -u)
  echo 'lane=scoped'
  printf '%s\n' "${suites:-_inert}"
}

# qp_partition <dir> — one `<pr>.impact` per queued PR. Serial PRs print
# `serial`; scoped PRs are union-find components over shared scopes (transitive:
# A∩B and B∩C is one partition), id `p<lowest PR in it>`. Sorted by PR.
# mawk-safe: no gawk-only features, no recursion.
qp_partition() {
  local d="${1:-}" f files=()
  [ -d "$d" ] || return 1
  for f in "$d"/*.impact; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    function find(x) { while (par[x] != x) { par[x] = par[par[x]]; x = par[x] } return x }
    function join(a, b) { a = find(a); b = find(b); if (a == b) return
                          if (a + 0 < b + 0) par[b] = a; else par[a] = b }
    FNR == 1 { pr = FILENAME; sub(/^.*\//, "", pr); sub(/\.impact$/, "", pr)
               prs[pr] = 1; par[pr] = pr
               if ($0 !~ /^lane=scoped/) serial[pr] = 1
               next }
    serial[pr] || $0 == "" { next }
    { if ($0 in owner) join(pr, owner[$0]); else owner[$0] = pr }
    END { for (p in prs) print p "\t" (serial[p] ? "serial" : "p" find(p)) }
  ' "${files[@]}" | LC_ALL=C sort -t "$(printf '\t')" -k1,1n
}

# qp_scopes_json <impact-file> — {"scopes":[…],"all_scopes":false}, or the
# serial barrier {"scopes":[],"all_scopes":true}. A scope name is the suite path
# with everything outside [A-Za-z0-9._-] turned into `_`, at most 100 chars.
qp_scopes_json() {
  local f="${1:-}" s names=()
  if [ "$(head -1 "$f" 2>/dev/null)" != lane=scoped ]; then
    jq -nc '{scopes: [], all_scopes: true}'; return
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    s=$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_'); names+=("${s:0:100}")
  done < <(tail -n +2 "$f")
  jq -nc '{scopes: $ARGS.positional, all_scopes: false}' --args "${names[@]}"
}

# qp_upload <slug> <sha> <json> [pr-number] — PUT the scopes for one commit.
#   rc 0 a 2xx (or the ledger already holds this head + payload: no call);
#   rc 1 anything else; rc 2 no usable MERGIFY_CI_KEY, nothing sent.
#   QP_UPLOAD_WHY carries the reason. The key rides `--config -` on stdin, never
#   argv. The ledger ($MC_STATE_DIR/queue-partition/<slug_>_<n>, `<head>\t<sha256>`)
#   is written only after a 2xx: losing it costs one repeat PUT, which Mergify
#   treats as a replace.
qp_upload() {
  local slug="$1" sha="$2" json="$3" num="${4:-}" led="" sum code
  QP_UPLOAD_WHY=""
  case "${MERGIFY_CI_KEY:-}" in
    '') QP_UPLOAD_WHY="MERGIFY_CI_KEY not set"; return 2 ;;
    *[!A-Za-z0-9._~+/=-]*) QP_UPLOAD_WHY="MERGIFY_CI_KEY is malformed"; return 2 ;;
  esac
  sum=$(printf '%s' "$json" | sha256sum 2>/dev/null | cut -d' ' -f1)
  if [ -n "$num" ] && [ -n "${MC_STATE_DIR:-}" ]; then
    led="$MC_STATE_DIR/queue-partition/${slug//\//_}_$num"
    if [ -n "$sum" ] && [ "$(cat "$led" 2>/dev/null)" = "$sha"$'\t'"$sum" ]; then
      QP_UPLOAD_WHY="already uploaded"; return 0
    fi
  fi
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$MERGIFY_CI_KEY" \
    | curl -sS -o /dev/null -w '%{http_code}' --max-time 20 -X PUT \
        -H 'Content-Type: application/json' --data-binary "$json" --config - \
        "${MERGIFY_API_URL:-https://api.mergify.com/v1}/repos/$slug/commits/$sha/scopes" 2>/dev/null)
  case "$code" in
    2[0-9][0-9]) ;;
    *) QP_UPLOAD_WHY="HTTP ${code:-000}"; return 1 ;;
  esac
  if [ -n "$led" ] && [ -n "$sum" ]; then
    mkdir -p "${led%/*}" 2>/dev/null && printf '%s\t%s\n' "$sha" "$sum" > "$led" 2>/dev/null
  fi
  QP_UPLOAD_WHY="HTTP $code"
  return 0
}

# qp_mode — the settings row queue_partition.mode: off|shadow|enforce. No row,
# no jobs client or an outage is shadow (log, upload nothing); an unknown value
# is off, with one log line.
qp_mode() {
  local v rc=0
  command -v setting_get >/dev/null 2>&1 || { printf shadow; return 0; }
  v=$(setting_get queue_partition.mode 2>/dev/null) || rc=$?
  [ "$rc" = 0 ] || { printf shadow; return 0; }
  case "$v" in
    off|shadow|enforce) printf '%s' "$v" ;;
    *) _qp_log "queue_partition.mode '$v' is not off|shadow|enforce — partitioning is off"; printf off ;;
  esac
}

# qp_enqueue_step <slug> <num> <head> — mc_enqueue_mergify's partition block.
# Runs only for a repo whose config/mergify/repos/<repo>.conf names this slug
# AND carries a queue_mode= line: the impact map is the harness's own tree, so
# only the harness repo opts in (project-5's conf has no queue_mode).
#   rc 0  go on to the label;  rc 3  hold, NOT labelled, stdout the reason.
# FAIL-CLOSED: on a queue_mode=parallel conf, a PR whose scopes were not
# uploaded (failed PUT, no key, mode shadow or off) is held, so a scopeless PR
# can never enter a parallel queue whatever the mode row says. On a serial conf
# the queue does not read scopes, so a failed upload is one log line.
qp_enqueue_step() {
  local slug="$1" num="$2" head="$3" root conf qmode mode pj files imp lane k reason json urc=0
  root=$(_qp_root); [ -n "$root" ] || return 0
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null || return 0
  qmode=$(sed -n 's/^queue_mode=\([a-z]*\)[[:space:]]*$/\1/p' "$conf" | tail -1)
  [ -n "$qmode" ] || return 0
  mode=$(qp_mode)
  if [ "$mode" = off ]; then
    [ "$qmode" = parallel ] && { printf 'queue scopes could not be uploaded on %s (partition mode off on a parallel queue) — not labelled' "${head:0:12}"; return 3; }
    return 0
  fi
  files=$(mktemp "${TMPDIR:-/tmp}/qp-files.XXXXXX") || files=""
  imp=$(mktemp "${TMPDIR:-/tmp}/qp-impact.XXXXXX") || imp=""
  if [ -z "$files" ] || [ -z "$imp" ]; then
    rm -f "$files" "$imp"
    [ "$qmode" = parallel ] && { printf 'queue scopes could not be uploaded on %s (no temp file) — not labelled' "${head:0:12}"; return 3; }
    return 0
  fi
  # The PR's title, head ref and labels (train, fix-main-red). An unreadable PR
  # leaves the file list empty, so the answer is serial, never "no impact".
  pj=""
  if command -v gh_rest_var >/dev/null 2>&1 && gh_rest_var pj GET "repos/$slug/pulls/$num" 2>/dev/null && [ -n "$pj" ]; then
    command -v mc_pr_files >/dev/null 2>&1 && mc_pr_files "$slug" "$num" "" "$head" > "$files" 2>/dev/null
  fi
  ( QP_TITLE=$(jq -r '.title // ""' <<<"${pj:-}" 2>/dev/null)
    QP_HEAD_REF=$(jq -r '.head.ref // ""' <<<"${pj:-}" 2>/dev/null)
    QP_LABELS=$(jq -r '[.labels[]?.name] | join(",")' <<<"${pj:-}" 2>/dev/null)
    qp_impact "$files" ) > "$imp"
  lane=$(head -1 "$imp"); reason=""
  case "$lane" in
    lane=scoped) k=$(tail -n +2 "$imp" | grep -c .); reason="$k impact suite(s)"; lane=scoped ;;
    *) k=0; reason="${lane#lane=serial reason=}"; lane=serial ;;
  esac
  _qp_log "PARTITION $slug#$num@${head:0:12} lane=$lane scopes=$k reason=$reason"
  json=$(qp_scopes_json "$imp")
  rm -f "$files" "$imp"
  if [ "$mode" = enforce ]; then
    qp_upload "$slug" "$head" "$json" "$num" || urc=$?
  else
    urc=2; QP_UPLOAD_WHY="partition mode shadow"
  fi
  # urc 0 is enforce only. The line is the hub's record of a real upload:
  # bin/queue-scopes-evidence.sh (probe queue-scopes-uploads) reads it.
  if [ "$urc" = 0 ]; then
    _qp_log "PARTITION $slug#$num: scopes uploaded on ${head:0:12} ($QP_UPLOAD_WHY)"
    return 0
  fi
  if [ "$qmode" = parallel ]; then
    printf 'queue scopes could not be uploaded on %s (%s) — not labelled' "${head:0:12}" "$QP_UPLOAD_WHY"
    return 3
  fi
  [ "$mode" = enforce ] && _qp_log "PARTITION $slug#$num: scopes not uploaded on ${head:0:12} ($QP_UPLOAD_WHY); the queue is serial, enqueue proceeds"
  return 0
}
