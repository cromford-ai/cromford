# shellcheck shell=bash
# Owner: BH-7244.3 (land synth ideas as pm-agent ideas). Built by BH-7260.
#
# pm_ideas_land <project> <cycle_dir> — bin/run-product.sh calls it once after
# SYNTH, inside its product lock, and ignores its rc (`|| true`). It lands the
# SYNTH ideas that cite data evidence as roadmap ideas with source `pm-agent`
# in the Ideas lane. It never drafts, posts or builds: no post-proposal.sh, no
# run-build.sh, no label and no issue. Always rc 0.
#
#   1. Nothing happens (rc 0, no request) when <cycle_dir>/ideas.json is
#      missing or unreadable, or the jobs client (_jobs_req) or jq is not
#      loaded. The settings row pm.land_max (0..100, fallback 20; 0 = off) caps
#      the ideas landed per cycle; a failed read of it is the fallback.
#   2. Evidence is the `ok` rows of <cycle_dir>/data-signals.json. run-product
#      removes a failed day's file, so with no file no idea qualifies.
#   3. An idea qualifies when a token of its evidence_id, evidence_ids[] or
#      evidence (a string, an array or objects; every string leaf) equals an ok
#      id. Tokens split on [^A-Za-z0-9._:-]; a trailing . or : is trimmed. A
#      prefix, a superstring, an id only in the title or summary, or a
#      not-configured or error row never counts.
#   4. A slug that is not ^[A-Za-z0-9._-]{1,77}$ is skipped with a log line:
#      "pm-" plus the slug must fit the worker's idem_key (80 characters).
#   5. POST /api/roadmap/ideas {project, title, note, source:"pm-agent",
#      idem_key:"pm-<slug>", actor:"pm-agent"}. The title is one line, cut
#      to 200 characters; the note is the summary plus "Evidence: <ids>", cut
#      to 4000 (the worker's format bounds in roadmap-ideas.js).
#   6. The answer: 201 landed; 200 replay:true replay (the same payload is
#      already stored); 409 changed (already landed with another payload; it is
#      never overwritten); anything else an error, and the next idea runs.
#   7. ONE summary line, to $LOG when the caller set it, else to stderr:
#      pm-land: project=<p> candidates=<n> evidence=<n> landed=<n> replay=<n> changed=<n> errors=<n> skipped=<n> capped=<n>
#
# Side-effect-free when sourced. Note: docs/notes/2026-10-30-BH-7260-pm-flesh.md.

_pml_log() { # _pml_log <project> <text>
  local line
  line="$(date -u '+%Y-%m-%d %H:%M:%SZ') [$1] $2"
  if [ -n "${LOG:-}" ]; then printf '%s\n' "$line" >> "$LOG" 2>/dev/null || printf '%s\n' "$line" >&2
  else printf '%s\n' "$line" >&2; fi
}

pm_ideas_land() {
  local p="${1:-}" dir="${2:-}" ideas sig max v tmp rc slug body line
  local cand=0 nev=0 landed=0 replay=0 changed=0 errors=0 skipped=0 capped=0
  ideas="$dir/ideas.json"
  [ -n "$p" ] && [ -n "$dir" ] && [ -r "$ideas" ] || return 0
  command -v _jobs_req >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  jq -e '.ideas | type == "array"' "$ideas" >/dev/null 2>&1 || { _pml_log "$p" "pm-land: $ideas does not parse; nothing landed"; return 0; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/pm-land.XXXXXX") || return 0

  # pm.land_max: the settings row; 20 is its documented fallback (BH-7945).
  max=20
  if _jobs_req GET /api/settings/pm.land_max > "$tmp/knob.json" 2>/dev/null; then
    v=$(jq -r '.setting.value // empty' "$tmp/knob.json" 2>/dev/null)
    if [[ $v =~ ^[0-9]+$ ]] && [ "$v" -le 100 ]; then max=$v
    elif [ -n "$v" ]; then _pml_log "$p" "pm-land: warn: pm.land_max=$v is not an integer in 0..100; using 20"; fi
  fi
  if [ "$max" = 0 ]; then
    _pml_log "$p" "pm-land: pm.land_max=0; landing is off"; rm -rf "$tmp"; return 0
  fi

  sig="$dir/data-signals.json"
  if [ -r "$sig" ] && jq -e '.evidence | type == "array"' "$sig" >/dev/null 2>&1; then
    jq -c '[.evidence[] | select(.status == "ok" and (.id | type) == "string") | .id]' "$sig" > "$tmp/ok.json"
  else
    echo '[]' > "$tmp/ok.json"
  fi
  # One line per idea: {slug, title, note, ev} for an idea with data evidence,
  # {skip: slug} for one without.
  jq -c --slurpfile ok "$tmp/ok.json" '
    def u16: explode | map(select(. < 65536)) | implode;
    ($ok[0] | map({key: ., value: true}) | from_entries) as $okset
    | .ideas[] | select(type == "object")
    | ([(.evidence_id, .evidence_ids, .evidence) | .. | strings]
       | map([splits("[^A-Za-z0-9._:-]+")] | .[]) | map(sub("[.:]+$"; ""))
       | map(select(length > 0 and $okset[.])) | unique) as $ev
    | if ($ev | length) == 0 then {none: true}
      else {slug: ((.slug // "") | tostring), ev: $ev,
            title: ((.title // .slug // "") | tostring | u16 | gsub("[\r\n]+"; " ") | sub("^\\s+"; "") | sub("\\s+$"; "") | .[0:200]),
            note: ((((.summary // "") | tostring | u16) + "\n\nEvidence: " + ($ev | join(", "))) | sub("^\\s+"; "") | .[0:4000])}
      end' "$ideas" > "$tmp/cands.jsonl" 2>/dev/null || : > "$tmp/cands.jsonl"
  cand=$(jq '.ideas | map(select(type == "object")) | length' "$ideas")
  nev=$(jq -s 'map(select(.none | not)) | length' "$tmp/cands.jsonl")

  while IFS= read -r line; do
    slug=$(jq -r '.slug' <<<"$line")
    if ! [[ $slug =~ ^[A-Za-z0-9._-]{1,77}$ ]] || [ -z "$(jq -r '.title' <<<"$line")" ]; then
      skipped=$((skipped + 1)); _pml_log "$p" "pm-land: skip slug '${slug:0:80}': the idem key needs ^[A-Za-z0-9._-]{1,77}\$ and a title"; continue
    fi
    if [ $((landed + replay + changed + errors)) -ge "$max" ]; then capped=$((capped + 1)); continue; fi
    body=$(jq -c --arg p "$p" '{project: $p, title, note, source: "pm-agent", idem_key: ("pm-" + .slug), actor: "pm-agent"}' <<<"$line")
    rc=0; _jobs_req POST /api/roadmap/ideas "$body" > "$tmp/ans.json" 2>/dev/null || rc=$?
    case "$rc" in
      0) if [ "$(jq -r '.replay // false' "$tmp/ans.json" 2>/dev/null)" = true ]; then replay=$((replay + 1))
         elif [ "${JOBS_HTTP:-}" = 201 ]; then landed=$((landed + 1))
         else errors=$((errors + 1)); _pml_log "$p" "pm-land: $slug answered http=${JOBS_HTTP:-?} with no idea"; fi ;;
      9) changed=$((changed + 1)) ;;
      *) errors=$((errors + 1))
         _pml_log "$p" "pm-land: $slug not landed: http=${JOBS_HTTP:-none} $(jq -r '.field // empty' <<<"${JOBS_BODY:-}" 2>/dev/null)" ;;
    esac
  done < <(jq -c 'select(.none | not)' "$tmp/cands.jsonl")
  rm -rf "$tmp"
  _pml_log "$p" "pm-land: project=$p candidates=$cand evidence=$nev landed=$landed replay=$replay changed=$changed errors=$errors skipped=$skipped capped=$capped"
  return 0
}
