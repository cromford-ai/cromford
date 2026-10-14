# bin/lib/prebuild-repro/drive.sh — the drive stage (BH-2041, order 3 of #2004).
# pr_drive <project> <key> <build> <thread-json>: `<REPRODUCED|NOT_REPRODUCED|ALREADY_FIXED|CANNOT_DRIVE><TAB><reason>`, always rc 0.
# One capped, read-only prod QA session through bin/agent-call.sh, behind the
# repro_gate ledger: the row is read BEFORE any spend and written after every
# billed call. Function-only (run-build.sh sources it). docs/repro-gate/drive.md.
# shellcheck shell=bash

# _pr_drive_env <henv> <project> <cmd...> — run cmd in a subshell holding the
# project env; a QA var already in the process env wins over the files.
_pr_drive_env() {
  local henv="$1" p="$2"; shift 2
  ( ck="${QA_CLERK_SECRET_KEY:-}"; uid="${QA_TEST_USER_ID:-}"
    set -a; . "$henv/global.env" 2>/dev/null; . "$henv/$p.env" 2>/dev/null; set +a
    [ -n "$ck" ] && QA_CLERK_SECRET_KEY="$ck"; [ -n "$uid" ] && QA_TEST_USER_ID="$uid"
    "$@" )
}

# _pr_drive_load <function> <file> — source file if function is undefined,
# leaving the caller's shell options as they were (jobs-client sets -uo pipefail).
_pr_drive_load() {
  command -v "$1" >/dev/null 2>&1 && return 0
  local opts; opts=$(set +o)
  # shellcheck disable=SC1090
  . "$2" >/dev/null 2>&1
  eval "$opts"
  command -v "$1" >/dev/null 2>&1
}

# _pr_drive_ledger_detail <key> — the stored row's detail JSON (the whole row
# comes back from GET /api/ledger; job_ledger_get prints only the status).
_pr_drive_ledger_detail() {
  local q resp
  command -v _jobs_req >/dev/null 2>&1 || return 1
  q=$(jq -nr --arg k repro_gate --arg v "$1" '"kind="+($k|@uri)+"&key="+($v|@uri)') || return 1
  resp=$(_jobs_req GET "/api/ledger?$q") || return 1
  printf '%s' "$resp" | jq -er '.ledger.detail // empty | if type == "string" then fromjson else . end | tojson' 2>/dev/null
}

# _pr_drive_md <build> <role> <url> <steps> <observed> — $build/prebuild-repro.md,
# at most 2000 bytes, tmp+mv.
_pr_drive_md() {
  local b="$1" tmp
  tmp=$(mktemp "$b/.prebuild-repro-md.XXXXXX") || return 1
  head -c 2000 < <(printf 'REPRO_ROLE: %s\nREPRO_URL: %s\nREPRO_STEPS: %s\nREPRO_OBSERVED: %s\n' "$2" "$3" "$4" "$5") > "$tmp" \
    && mv -f "$tmp" "$b/prebuild-repro.md" || { rm -f "$tmp"; return 1; }
}

# _pr_origin <url> — lowercased scheme://host[:port]; nothing for a URL with no
# scheme or with userinfo.
_pr_origin() {
  local re='^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#@]+)([/?#].*)?$'
  [[ "${1:-}" =~ $re ]] || return 1
  printf '%s://%s' "${BASH_REMATCH[1],,}" "${BASH_REMATCH[2],,}"
}

# _pr_drive_fence <source> — stdin fenced by ui_wrap (bin/lib/untrusted-input.sh,
# BH-4491): the body and thread below are the client's words, embedded verbatim.
# A box whose sync has not landed the lib sends them unfenced, as before.
_pr_drive_fence() {
  local r="${HARNESS:-${H:-}}"
  command -v ui_wrap >/dev/null 2>&1 || { [ -n "$r" ] && _pr_drive_load ui_wrap "$r/bin/lib/untrusted-input.sh"; } || { cat; return 0; }
  ui_wrap "$1"
}

_pr_drive_prompt() { # <project> <build> <thread> <prod>
  local p="$1" b="$2" th="$3" prod="$4" title
  title=$(jq -r '.title // empty' "$b/ticket-meta.json" 2>/dev/null); title="${title:-(title unavailable)}"
  cat <<EOF
You are reproducing a reported bug on PRODUCTION before anyone builds a fix. Drive the live app and report what you saw. Do not change anything.

PRODUCTION BASE URL: $prod

TICKET TITLE: $title

TICKET BODY:
$(printf '%s' "$th" | jq -r '.body // ""' | _pr_drive_fence ticket-body)

THREAD (oldest first; principal=true is the team, principal=false is the client; truncated=$(printf '%s' "$th" | jq -r '.truncated // false')):
$(printf '%s' "$th" | jq -r '(.comments // []) | sort_by([(.createdAt // "" | tostring), (.id // "" | tostring)]) | .[] | "--- \(.createdAt // "-") principal=\(.principal // false)\n\(.body // "")"' | _pr_drive_fence ticket-thread)

HOW TO DRIVE:
- Follow $HARNESS/skills/qa-prod-drive/SKILL.md. Sign in with $HARNESS/bin/qa-drive.mjs and check the screen at 1280 and 375 widths.
- Find the screen in /root/repos/$p/docs/verification-map/ (README.md is the index, entries/ the rows). Pick the entry for this ticket's screen and use its nav path and selectors.

READ-ONLY RULES (these override everything above):
- Sign in ONLY as the low-privilege QA account named by QA_TEST_USER_ID, with the key in QA_CLERK_SECRET_KEY. Never print either value.
- NEVER run bin/qa-unbanned.sh or change any account.
- If any step would send, pay, delete, submit, or leave the app's origin ($prod), stop and answer CANNOT_DRIVE.

FINAL BLOCK: end your output with exactly these five single lines, last, not in a code fence or a quote:
REPRO_VERDICT: REPRODUCED|NOT_REPRODUCED|ALREADY_FIXED|CANNOT_DRIVE
REPRO_ROLE: <the account you signed in as>
REPRO_URL: <the full production URL where you checked>
REPRO_STEPS: <steps separated by ;>
REPRO_OBSERVED: <what you saw, one line>
EOF
}

# _pr_drive_parse <file> — sets V ROLE URL STEPS OBS from the last 8 non-empty
# lines; rc 1 when the block is poisoned or absent. Fence parity is over the
# whole file, so a fence opened above the window still counts.
_pr_drive_parse() {
  local flag line val verdicts=""
  V=""; ROLE=""; URL=""; STEPS=""; OBS=""
  while IFS=$'\t' read -r flag line; do
    case "$line" in *REPRO_VERDICT:*)
      [ "$flag" = 1 ] && return 1
      [[ "$line" =~ ^[[:space:]]*\> ]] && return 1 ;;
    esac
    [ "$flag" = 1 ] && continue
    val="${line#*:}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    case "$line" in
      REPRO_VERDICT:*)
        case "$val" in REPRODUCED|NOT_REPRODUCED|ALREADY_FIXED|CANNOT_DRIVE) ;; *) return 1 ;; esac
        V="$val"; case " $verdicts " in *" $val "*) ;; *) verdicts="$verdicts $val" ;; esac ;;
      REPRO_ROLE:*) ROLE="$val" ;;
      REPRO_URL:*) URL="$val" ;;
      REPRO_STEPS:*) STEPS="$val" ;;
      REPRO_OBSERVED:*) OBS="$val" ;;
    esac
  done < <(awk '{ fl = ($0 ~ /^[[:space:]]*```/); if (fl) f = !f
                  if ($0 ~ /[^[:space:]]/) { n++; L[n] = $0; F[n] = (f || fl) } }
             END { s = n - 7; if (s < 1) s = 1; for (i = s; i <= n; i++) print F[i] "\t" L[i] }' "$1" 2>/dev/null | tr -d '\r')
  [ -n "$V" ] && [ "$(wc -w <<< "$verdicts")" = 1 ]
}

# _pr_drive_say <verdict> <reason> — the one output line, reason flattened to 160 chars.
_pr_drive_say() { printf '%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n\r' '   ' | cut -c1-160)"; }

pr_drive() {
  local project="${1:-}" key="${2:-}" build="${3:-}" thread="${4:-}" H="${HARNESS:-${H:-}}"
  local prod henv en lkey st rc model cap prompt out verdict status reason detail cost po uo
  local V ROLE URL STEPS OBS kh lf ldet lfd now ttl cst cts

  # 1. Preconditions: no spend, no row, nothing written. No root has no
  # prod-url.sh to ask, which is the no-prod-url answer (BH-2613).
  prod=""
  [ -n "$H" ] && { prod=$("$H/bin/prod-url.sh" "$project" 2>/dev/null) || prod=""; }
  case "$prod" in ""|-) _pr_drive_say CANNOT_DRIVE no-prod-url; return 0 ;; esac
  command -v harness_env_dir >/dev/null 2>&1 || . "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { local r="${1:-${HARNESS:-${H:-}}}"; [ -n "$r" ] || return 0; printf '%s\n' "$r/env"; }
  henv=$(harness_env_dir "$H")
  _pr_drive_env "$henv" "$project" bash -c '[ -n "${QA_CLERK_SECRET_KEY:-}" ] && [ -n "${QA_TEST_USER_ID:-}" ]' \
    || { _pr_drive_say CANNOT_DRIVE no-qa-role; return 0; }
  if command -v lane_knob >/dev/null 2>&1; then en=$(lane_knob prebuild-repro LLM_LANE_ENABLED "$project" 2>/dev/null); fi
  [ "${en:-${LLM_LANE_ENABLED:-1}}" = 0 ] && { _pr_drive_say CANNOT_DRIVE llm-lane-disabled; return 0; }

  # 2. The ledger, before any spend. No key or no answer means no call.
  lkey=$(pr_ledger_key "$project" "$key" "$thread") || { _pr_drive_say CANNOT_DRIVE ledger-unreadable; return 0; }
  _pr_drive_load job_ledger_get "$H/bin/jobs-client.sh" || { _pr_drive_say CANNOT_DRIVE ledger-unreadable; return 0; }
  st=$(job_ledger_get repro_gate "$lkey"); rc=$?
  # BH-2133: a paid drive whose ledger put failed left its answer HERE, on this
  # box. A ledger miss with that record is a reuse, never a second payment; the
  # row is written back best-effort so other boxes see it too.
  kh=$(printf '%s' "$lkey" | sha256sum | cut -c1-16)
  lf="$H/state/repro-gate/$kh.json"; ldet=""
  if [ "$rc" = 2 ] && [ -s "$lf" ] && st=$(jq -er '.status | select(type == "string" and . != "")' "$lf" 2>/dev/null); then
    rc=0; ldet=$(jq -c '.detail // {}' "$lf" 2>/dev/null) || ldet='{}'
    job_ledger_put repro_gate "$lkey" "$st" "$ldet" >/dev/null 2>&1 || true
  fi
  case "$rc" in
    0) case "$st" in
         reproduced) verdict=REPRODUCED ;;
         cannot_drive) verdict=CANNOT_DRIVE ;;
         not_reproduced|not_reproduced_uncommented) verdict=NOT_REPRODUCED ;;
         already_fixed|already_fixed_uncommented) verdict=ALREADY_FIXED ;;
         *) _pr_drive_say CANNOT_DRIVE ledger-unknown-status; return 0 ;;
       esac
       if [ -n "$ldet" ] && detail="$ldet" || detail=$(_pr_drive_ledger_detail "$lkey"); then
         _pr_drive_md "$build" "$(jq -r '.role // ""' <<< "$detail")" "$(jq -r '.url // ""' <<< "$detail")" \
           "$(jq -r '.steps // ""' <<< "$detail")" "$(jq -r '.observed // ""' <<< "$detail")"
       else
         _pr_drive_md "$build" "" "" "" "(ledger detail unreadable; verdict $st reused from an earlier drive)"
       fi
       _pr_drive_say "$verdict" ledger-reuse; return 0 ;;
    2) ;;
    *) _pr_drive_say CANNOT_DRIVE ledger-unreadable; return 0 ;;
  esac

  # 3. The capped call. The model is a model_routes row, never a literal.
  _pr_drive_load lane_role_model "$H/bin/lib/lane-model.sh" || { _pr_drive_say CANNOT_DRIVE no-model; return 0; }
  model=$(lane_role_model postmerge.qa "$project" 2>/dev/null) && [ -n "$model" ] || { _pr_drive_say CANNOT_DRIVE no-model; return 0; }
  if command -v lane_knob >/dev/null 2>&1; then cap=$(lane_knob prebuild-repro REPRO_GATE_MAX_USD "$project" 2>/dev/null); fi
  cap="${cap:-${REPRO_GATE_MAX_USD:-3}}"
  prompt=$(_pr_drive_prompt "$project" "$build" "$thread" "$prod")
  out="$build/repro-run.txt"

  # CLAIM BEFORE SPEND (BH-2133). Two builds of one thread must not both pay.
  # On this box a non-blocking flock per ledger key; across boxes a
  # `repro_gate_claim` row, `driving:<epoch>`, written BEFORE the call and set to
  # `released` after it. A fresh claim held by someone else (younger than
  # REPRO_DRIVE_CLAIM_TTL_S, default 1200 s, above the call's 900 s timeout) is a
  # CANNOT_DRIVE with no spend: the build goes ahead ungated, which is what a
  # CANNOT_DRIVE always means. The ledger has no compare-and-set, so a claim we
  # could not WRITE is logged and the drive goes on under the local lock alone —
  # the same trade the post-spend put makes below, loud rather than silent.
  lfd=""
  if command -v flock >/dev/null 2>&1 && mkdir -p "$H/locks" 2>/dev/null && exec {lfd}>"$H/locks/repro-drive-$kh.lock"; then
    flock -n "$lfd" || { exec {lfd}>&-; _pr_drive_say CANNOT_DRIVE drive-in-flight; return 0; }
  fi
  now=$(date +%s); ttl="${REPRO_DRIVE_CLAIM_TTL_S:-1200}"; case "$ttl" in ''|*[!0-9]*) ttl=1200 ;; esac
  cst=$(job_ledger_get repro_gate_claim "$lkey" 2>/dev/null) && case "$cst" in
    driving:*) cts="${cst#driving:}"
      case "$cts" in ''|*[!0-9]*) ;; *)
        if [ $(( now - cts )) -lt "$ttl" ]; then
          [ -n "$lfd" ] && exec {lfd}>&-
          _pr_drive_say CANNOT_DRIVE drive-in-flight; return 0
        fi ;;
      esac ;;
  esac
  job_ledger_put repro_gate_claim "$lkey" "driving:$now" "$(jq -nc --arg b "$(basename "$build")" '{build:$b}')" \
    || printf '%s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ') repro drive: claim put failed for $lkey — driving under this box's lock only" >> "$build/pipeline.log"

  # THE LANE AND THE BUDGET ARE SET INSIDE _pr_drive_env, AFTER it loads
  # global.env and the project env (BH-1165): as prefix assignments they were
  # overwritten by any AGENT_CALL_LANE / AGENT_CALL_BUDGET_USD_REPRO line in
  # those files, and the call billed and capped under someone else's lane.
  _pr_drive_env "$henv" "$project" env AGENT_CALL_LANE=prebuild-repro AGENT_CALL_BUDGET_USD_REPRO="$cap" \
    "$H/bin/agent-call.sh" repro "$project" "$model" 900 "$out" "$prompt" >/dev/null 2>&1
  rc=$?
  job_ledger_put repro_gate_claim "$lkey" released >/dev/null 2>&1 || true
  [ -n "$lfd" ] && exec {lfd}>&-
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then _pr_drive_say CANNOT_DRIVE "not-billed-rc$rc"; return 0; fi

  # 4. Billed from here on: every outcome writes a row and the .md.
  if [ "$rc" != 0 ]; then verdict=CANNOT_DRIVE; reason=cap-or-error; ROLE=""; URL=""; STEPS=""; OBS=""
  elif ! _pr_drive_parse "$out"; then verdict=CANNOT_DRIVE; reason=unparseable; ROLE=""; URL=""; STEPS=""; OBS=""
  else
    verdict="$V"; reason="${OBS:--}"
    case "$V" in
      NOT_REPRODUCED|ALREADY_FIXED)
        po=$(_pr_origin "$prod"); uo=$(_pr_origin "$URL")
        { [ -n "$ROLE" ] && [ -n "$po" ] && [ "$uo" = "$po" ]; } || { verdict=CANNOT_DRIVE; reason=unverifiable-url; } ;;
      CANNOT_DRIVE) reason="agent: ${OBS:--}" ;;
    esac
  fi
  case "$verdict" in
    REPRODUCED) status=reproduced ;;
    NOT_REPRODUCED) status=not_reproduced_uncommented ;;
    ALREADY_FIXED) status=already_fixed_uncommented ;;
    *) status=cannot_drive ;;
  esac
  cost=$(jq -c '.total_cost_usd // null' "$out.json" 2>/dev/null) || cost=null; cost="${cost:-null}"
  # The worker keeps the first 4000 chars of detail, so every field is cut
  # well under that and a reused row always parses.
  detail=$(jq -nc --arg r "${ROLE:0:200}" --arg u "${URL:0:500}" --arg s "${STEPS:0:1200}" --arg o "${OBS:0:1500}" --argjson c "$cost" --arg b "$(basename "$build")" \
    '{role:$r,url:$u,steps:$s,observed:$o,cost_usd:$c,build:$b}' 2>/dev/null) || detail='{}'
  # A PAID ANSWER IS NEVER LOST SILENTLY (BH-2133). When the put fails the
  # answer is kept on this box (state/repro-gate/<sha16 of the key>.json, read
  # back above on a ledger miss) and ALERTS.log says so once, so the next offer
  # here reuses it instead of paying again.
  if ! job_ledger_put repro_gate "$lkey" "$status" "$detail"; then
    printf '%s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ') repro drive: ledger put failed for $lkey ($status) — kept locally in state/repro-gate/$kh.json" >> "$build/pipeline.log"
    mkdir -p "$H/state/repro-gate" 2>/dev/null
    jq -nc --arg s "$status" --arg k "$lkey" --argjson d "$detail" '{status:$s,key:$k,detail:$d}' > "$lf.tmp" 2>/dev/null \
      && mv -f "$lf.tmp" "$lf" 2>/dev/null
    mkdir -p "$H/logs" 2>/dev/null
    printf '%s [%s] prebuild-repro: %s drive ledger put of %s failed for %s after a paid drive — kept in state/repro-gate/%s.json on %s; this box will not pay for this thread again, other boxes might until the ledger is back\n' \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$project" "$key" "$status" "$lkey" "$kh" "$(hostname 2>/dev/null || echo box)" >> "$H/logs/ALERTS.log"
  fi
  _pr_drive_md "$build" "$ROLE" "$URL" "$STEPS" "$OBS"
  _pr_drive_say "$verdict" "$reason"
  return 0
}
