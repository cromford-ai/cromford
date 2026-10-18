#!/bin/bash
# shellcheck shell=bash
# bin/lib/break-it.sh — the break-it verifier (BH-6970). Sourced by
# bin/lead-review.sh, never run. Defines functions only. The root is
# ${HARNESS:-${H:-}}; an empty root is could-not-run, never a guessed path.
#
# After the lead model's verdict is readable, ONE bounded model call (route
# review-break-it) writes at most break_it.max_tests test cases that try to
# break the patch. They go in ONE file in the repo's framework, which runs
# against a snapshot of the PR head as the user nobody (bi_exec). The result
# word is
#   clean          every case passed (the file is deleted, never committed)
#   failed:<k>     k cases failed (the file is kept in state/break-it/)
#   could-not-run  no framework, no route, no time, a refused or unusable
#                  answer, a syntax error, no way to run as nobody, a
#                  timeout, or result lines that do not match the cases.
#                  Never a BLOCK.
#   skipped:<why>  off | low | unclassified: no call, no file, no record.
#
# Settings rows (bi_knob; each fallback is the value in brackets):
#   break_it.mode [off] off|shadow|enforce, trimmed and lowercased
#   break_it.max_tests [5] 1..20   break_it.budget_usd [1.50] > 0, <= 20
#   break_it.max_diff_bytes [200000] 1000..2000000
#   break_it.cache_days [14] 1..365 (the replay files' age limit)
#
# One attempt per head. The replay file state/break-it/<slug>-<pr>-<sha>.result
# is read before the call and written after every PAID call (a billed answer
# that is unusable is could-not-run, terminal). The call guard on stage
# lead-head with fp lead:<slug>#<pr>@<sha>~breakit refuses a repeat on any box
# before anything is bought. A refusal (rc 74..79) writes no replay file.
#
# bi_review <repo> <pr> <head> <project> <wt> <base> <scope-notes> <title> <out>
#           <left-s> <issue-json|-> <pr-body-file|->
#   The reviewer's entry. The tier is the review-tier token of the LAST notes
#   group (BH-6967). Prints ONE line `<result> <mode> <rewrote>`. rewrote is 1
#   only for enforce + failed:<k>: then <out> ends with a [BLOCK wrong-data]
#   finding and `VERDICT: BLOCK`, and the test file is committed to the PR
#   branch when the head is still <head> and the branch is in <repo>.

_bi_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_bi_log() {
  if command -v log >/dev/null 2>&1; then log "break-it: $*"; else printf 'break-it: %s\n' "$*" >&2; fi
}

# bi_knob <name> — the break_it.<name> row with all space removed. rc 1 = no
# row, an unreadable row or an empty value (the caller uses its fallback).
bi_knob() {
  local v
  command -v setting_get >/dev/null 2>&1 || return 1
  v=$(setting_get "break_it.$1" 2>/dev/null 7>&- 8>&-) || return 1
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}
bi_mode() {
  local m; m=$(bi_knob mode | tr '[:upper:]' '[:lower:]')
  case "$m" in shadow|enforce) printf '%s' "$m" ;; *) printf off ;; esac
}
# _bi_int <name> <lo> <hi> <fallback> — a whole number in lo..hi, else fallback.
_bi_int() {
  local v; v=$(bi_knob "$1") || v=""
  if [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$v))" -ge "$2" ] && [ "$((10#$v))" -le "$3" ]; then printf '%s' "$((10#$v))"
  else printf '%s' "$4"; fi
}
_bi_budget() {
  local v; v=$(bi_knob budget_usd) || v=""
  if [[ "$v" =~ ^[0-9]{1,2}(\.[0-9]{1,4})?$ ]] && awk -v b="$v" 'BEGIN { exit !(b > 0 && b <= 20) }'; then printf '%s' "$v"
  else printf '1.50'; fi
}

# bi_area <wt> <base> <head> <key> — the changed files decide the framework,
# before any spend. Sets BI_FW (shell|node), BI_PATH (the file, repo-relative),
# BI_RUNDIR (where it runs) and BI_RUNREL (the file from there). Most files
# under worker/jobs/ = node in worker/jobs; most under console-ui/ = node in
# console-ui; else (a tie too) shell, when tests/ holds a *-test.sh. rc 1 = no
# known framework, no diff or a missing runner.
bi_area() {
  local wt="$1" base="$2" head="$3" key="$4" files nw nc no all
  BI_FW=""; BI_PATH=""; BI_RUNDIR=""; BI_RUNREL=""
  files=$(git -C "$wt" diff --name-only "origin/$base...$head" 2>/dev/null) || return 1
  [ -n "$files" ] || return 1
  all=$(printf '%s\n' "$files" | wc -l)
  nw=$(printf '%s\n' "$files" | grep -c '^worker/jobs/'); nc=$(printf '%s\n' "$files" | grep -c '^console-ui/')
  no=$((all - nw - nc))
  if [ "$nw" -gt "$nc" ] && [ "$nw" -gt "$no" ]; then
    BI_FW=node; BI_RUNDIR=worker/jobs; BI_RUNREL="test/$key.breakit.test.js"
  elif [ "$nc" -gt "$nw" ] && [ "$nc" -gt "$no" ]; then
    BI_FW=node; BI_RUNDIR=console-ui; BI_RUNREL="tests/$key.breakit.test.js"
  elif compgen -G "$wt/tests/*-test.sh" >/dev/null 2>&1; then
    BI_FW=shell; BI_RUNDIR=.; BI_RUNREL="tests/$key-breakit-test.sh"
  else
    return 1
  fi
  if [ "$BI_RUNDIR" = . ]; then BI_PATH="$BI_RUNREL"; else BI_PATH="$BI_RUNDIR/$BI_RUNREL"; fi
  [ -d "$wt/${BI_PATH%/*}" ] || return 1
  if [ "$BI_FW" = node ]; then command -v node >/dev/null 2>&1 || return 1; fi
  return 0
}

# _bi_accept — stdin markdown; prints its "Acceptance tests" section (the
# heading and every line up to the next heading of the same or a higher level).
_bi_accept() {
  awk '{ l = tolower($0) }
    !f && l ~ /^#+[ \t]*acceptance tests/ { f = 1; lv = match($0, /[^#]/) - 1; print; next }
    f && $0 ~ /^#+[ \t]/ { if (match($0, /[^#]/) - 1 <= lv) exit }
    f { print }'
}

# bi_compose <outdir> <head> — <outdir>/break-it.json (the kept cases) into
# <outdir>/break-it.file, one file in BI_FW. Each case runs alone; a shell case
# prints `BREAKIT PASS|FAIL <name>`, a node case is one test() in TAP.
bi_compose() {
  local od="$1" head="$2" j="$1/break-it.json"
  if [ "$BI_FW" = shell ]; then
    {
      printf '#!/bin/bash\n# %s: break-it cases for %s (BH-6970, model-written; bin/lib/break-it.sh)\n' "$BI_PATH" "${head:0:12}"
      # shellcheck disable=SC2016
      printf 'ROOT=$(cd "$(dirname "$0")/.." && pwd); export ROOT\n'
      jq -r '.cases | to_entries[] | "bi_case_\(.key + 1)() {\n:\n\(.value.body)\n}"' "$j"
      printf 'BI_NAMES=(%s)\n' "$(jq -r '[.cases[].name | @sh] | join(" ")' "$j")"
      # shellcheck disable=SC2016
      printf '%s\n' 'fail=0' \
        'for i in "${!BI_NAMES[@]}"; do' \
        '  if ( cd "$ROOT" && "bi_case_$((i + 1))" ) </dev/null; then echo "BREAKIT PASS ${BI_NAMES[$i]}"' \
        '  else echo "BREAKIT FAIL ${BI_NAMES[$i]}"; fail=1; fi' \
        'done' 'exit "$fail"'
    } > "$od/break-it.file"
  else
    {
      printf '// %s: break-it cases for %s (BH-6970, model-written; bin/lib/break-it.sh)\n' "$BI_PATH" "${head:0:12}"
      printf "import test from 'node:test';\nimport assert from 'node:assert/strict';\n"
      jq -r '.imports[]' "$j"
      jq -r '.cases[] | "test(\(.name | tojson), async () => {\n\(.body)\n});"' "$j"
    } > "$od/break-it.file"
  fi
}

# bi_exec <wt> <outdir> <left-s> <n> <head> — run the file at <head> as the
# user nobody (security review, BH-6970). A snapshot of <head> (`git archive`)
# plus the file goes in a fresh temp dir that nobody owns. The run is `setpriv
# --reuid/--regid nobody --clear-groups`, with no inherited env but PATH, a
# scratch HOME/TMPDIR, HARNESS_TEST_SANDBOX=1 and fd 7 and 8 closed, under
# `timeout` of half of <left-s>. So a case cannot read the env dir, /root or
# the gh config, and cannot write the review worktree or the harness. No
# setpriv, no nobody user, no snapshot, or a probe (the run's own flags) that
# cannot switch or reach the snapshot: could-not-run, and nothing runs (fail
# closed). Prints the result word and writes the failing names to
# <outdir>/break-it.failed. Only counted result lines decide: clean needs rc 0
# and one PASS line per case.
bi_exec() {
  local wt="$1" od="$2" left="$3" n="$4" head="$5" sb uid gid rc=0 total fails tmo run
  tmo=$((left / 2)); [ "$tmo" -ge 30 ] || tmo=30
  : > "$od/break-it.failed"
  command -v setpriv >/dev/null 2>&1 || { _bi_log "setpriv is not installed; the cases do not run"; printf could-not-run; return 0; }
  uid=$(id -u nobody 2>/dev/null) && gid=$(id -g nobody 2>/dev/null) \
    || { _bi_log "there is no 'nobody' user; the cases do not run"; printf could-not-run; return 0; }
  sb=$(mktemp -d "${TMPDIR:-/tmp}/break-it.XXXXXX") && [ -n "$sb" ] || { printf could-not-run; return 0; }
  if ! { mkdir -p "$sb/repo" "$sb/home" "$sb/tmp" \
         && git -C "$wt" archive --format=tar -o "$sb/head.tar" "$head" \
         && tar -xf "$sb/head.tar" -C "$sb/repo" && rm -f "$sb/head.tar" \
         && cp -f "$od/break-it.file" "$sb/repo/$BI_PATH" \
         && chmod 711 "$sb" && chown -R "$uid:$gid" "$sb/repo" "$sb/home" "$sb/tmp"; } >/dev/null 2>&1; then
    rm -rf "$sb"; _bi_log "could not build a snapshot of ${head:0:12} for nobody; the cases do not run"; printf could-not-run; return 0
  fi
  if [ "$BI_FW" = shell ]; then run=(bash "$BI_RUNREL"); else run=(node --test --test-reporter=tap "$BI_RUNREL"); fi
  # THE PROBE, with the run's own flags: setpriv switches to nobody, nobody
  # writes the snapshot and its scratch dirs by their full paths, and the
  # runner is on PATH. As in bin/test-impact-gate.sh isolated_run, a setpriv
  # that cannot switch is could-not-run, never a failed case.
  # shellcheck disable=SC2016
  if ! ( cd "$sb/repo/$BI_RUNDIR" && setpriv --reuid="$uid" --regid="$gid" --clear-groups \
           env -i PATH="$PATH" sh -c '[ "$(id -u)" = "$1" ] && test -w "$2/repo/$3" && test -w "$2/home" && test -w "$2/tmp" && command -v "$4"' \
           _ "$uid" "$sb" "$BI_RUNDIR" "${run[0]}" ) < /dev/null > /dev/null 2>&1 7>&- 8>&-; then
    rm -rf "$sb"
    _bi_log "setpriv cannot run the cases as nobody here (not root, no CAP_SETUID/SETGID, or nobody cannot reach the snapshot); the cases do not run"
    printf could-not-run; return 0
  fi
  ( cd "$sb/repo/$BI_RUNDIR" && timeout -k 5 "$tmo" setpriv --reuid="$uid" --regid="$gid" --clear-groups \
      env -i PATH="$PATH" HOME="$sb/home" TMPDIR="$sb/tmp" LANG=C.UTF-8 HARNESS_TEST_SANDBOX=1 "${run[@]}" ) \
    < /dev/null > "$od/break-it.txt" 2>&1 7>&- 8>&- || rc=$?
  if [ "$BI_FW" = shell ]; then
    total=$(grep -cE '^BREAKIT (PASS|FAIL) ' "$od/break-it.txt")
    grep -E '^BREAKIT FAIL ' "$od/break-it.txt" | sed 's/^BREAKIT FAIL //' > "$od/break-it.failed"
  else
    total=$(grep -cE '^(not )?ok [0-9]+ - c[0-9]+ ' "$od/break-it.txt")
    grep -E '^not ok [0-9]+ - c[0-9]+ ' "$od/break-it.txt" | sed -E 's/^not ok [0-9]+ - //' > "$od/break-it.failed"
  fi
  rm -rf "$sb"
  fails=$(grep -c . "$od/break-it.failed")
  case "$rc" in 124|137) _bi_log "the run timed out after ${tmo}s"; printf could-not-run; return 0 ;; esac
  if [ "$total" != "$n" ]; then _bi_log "$total result line(s) for $n case(s) (rc $rc)"; printf could-not-run; return 0; fi
  if [ "$fails" -gt 0 ]; then printf 'failed:%s' "$fails"; return 0; fi
  if [ "$rc" = 0 ]; then printf clean; return 0; fi
  _bi_log "no failing case but rc $rc"; printf could-not-run
}

# _bi_done <word> — record a paid result: the replay file (word, path, count,
# failing names), and the file itself for failed:<k>. Prints the word.
_bi_done() {
  local w="$1" t
  if [ -n "$_BI_REPLAY" ]; then
    t="$_BI_REPLAY.tmp.$$"
    { printf '%s\npath=%s\nn=%s\n' "$w" "$BI_PATH" "${_BI_N:-0}"; sed 's/^/fail=/' "$_BI_OD/break-it.failed" 2>/dev/null; } > "$t" \
      && mv -f "$t" "$_BI_REPLAY" || _bi_log "could not write $_BI_REPLAY"
    case "$w" in failed:*) cp -f "$_BI_OD/break-it.file" "${_BI_REPLAY%.result}.file" 2>/dev/null || _bi_log "could not keep the test file" ;; esac
  fi
  printf 'path=%s\nn=%s\n' "$BI_PATH" "${_BI_N:-0}" >> "$_BI_OD/break-it.meta"
  printf '%s\n' "$w"
}

# bi_run <repo> <pr> <head> <project> <wt> <base> <tier> <ticket-key> <outdir>
#        <left-s> <issue-json|-> <pr-body-file|->
#   Prints ONE result word. Writes <outdir>/break-it.{mode,meta,prompt,answer,
#   json,cases,file,txt,failed}. Each step fails closed to could-not-run.
bi_run() {
  local repo="$1" pr="$2" head="$3" project="$4" wt="$5" base="$6" tier="$7" key="$8" od="$9" left="${10}"
  local issue="${11:--}" pbody="${12:--}" root mode slug sd days w max maxd bud model fp rc=0 total kept bad
  root=$(_bi_root); _BI_REPLAY=""; _BI_OD="$od"; _BI_N=0; BI_PATH=""
  mkdir -p "$od" 2>/dev/null || { printf 'could-not-run\n'; return 0; }
  : > "$od/break-it.meta"; : > "$od/break-it.failed"
  mode=$(bi_mode); printf '%s\n' "$mode" > "$od/break-it.mode"
  [ "$mode" != off ] || { printf 'skipped:off\n'; return 0; }
  case "$tier" in medium|high) ;; low) printf 'skipped:low\n'; return 0 ;; *) printf 'skipped:unclassified\n'; return 0 ;; esac
  [ -n "$root" ] || { _bi_log "no harness root"; printf 'could-not-run\n'; return 0; }
  slug=$(printf '%s' "$repo" | tr '/' '_' | tr -cd 'A-Za-z0-9._-')
  sd="$root/state/break-it"; mkdir -p "$sd" 2>/dev/null
  if [ -z "${_BI_PRUNED:-}" ]; then
    days=$(_bi_int cache_days 1 365 14)
    find "$sd" -maxdepth 1 -type f \( -name '*.result' -o -name '*.file' \) -mtime +"$days" -delete 2>/dev/null
    _BI_PRUNED=1
  fi
  # 3. replay: this head was paid for on this box.
  if [ -s "$sd/$slug-$pr-$head.result" ]; then
    w=$(head -n 1 "$sd/$slug-$pr-$head.result")
    if [[ "$w" =~ ^(clean|could-not-run|failed:[1-9][0-9]{0,2})$ ]]; then
      BI_PATH=$(sed -n 's/^path=//p' "$sd/$slug-$pr-$head.result" | head -n 1)
      _BI_N=$(sed -n 's/^n=//p' "$sd/$slug-$pr-$head.result" | head -n 1)
      sed -n 's/^fail=//p' "$sd/$slug-$pr-$head.result" > "$od/break-it.failed"
      cp -f "$sd/$slug-$pr-$head.file" "$od/break-it.file" 2>/dev/null
      printf '(replayed from an earlier break-it run on this head)\n' > "$od/break-it.txt"
      _bi_log "$repo#$pr @${head:0:12}: replayed $w; no call"
      _BI_REPLAY=""; _bi_done "$w"; return 0
    fi
  fi
  # 4. the framework, before any spend.
  key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'); [ -n "$key" ] || key="pr$pr"
  bi_area "$wt" "$base" "$head" "$key" || { _bi_log "$repo#$pr: no known test framework for this diff; no call"; printf 'could-not-run\n'; return 0; }
  # 5. the route and the time.
  model=$(model_for review-break-it "$project" 2>/dev/null 7>&- 8>&-) && [ -n "$model" ] \
    || { _bi_log "no review-break-it route; no call"; printf 'could-not-run\n'; return 0; }
  [[ "$left" =~ ^[0-9]+$ ]] && [ "$left" -ge 120 ] || { _bi_log "${left}s left; no call"; printf 'could-not-run\n'; return 0; }
  [ -r "$root/prompts/lead-review.d/break-it.md" ] || { _bi_log "prompts/lead-review.d/break-it.md missing; no call"; printf 'could-not-run\n'; return 0; }
  # 6. the prompt: break-it.md, the limits, the acceptance tests, the diff.
  max=$(_bi_int max_tests 1 20 5); maxd=$(_bi_int max_diff_bytes 1000 2000000 200000); bud=$(_bi_budget)
  git -C "$wt" diff "origin/$base...$head" > "$od/break-it.diff" 2>/dev/null || { printf 'could-not-run\n'; return 0; }
  {
    cat "$root/prompts/lead-review.d/break-it.md"
    printf '\n## Limits\n\n- framework: %s\n- at most %s cases\n- the harness writes the cases to ONE file, %s, and runs it at the PR head\n\n' "$BI_FW" "$max" "$BI_PATH"
    w=""
    [ "$issue" != - ] && [ -s "$issue" ] && w=$(jq -r '.body // ""' "$issue" 2>/dev/null | _bi_accept | head -c 8192)
    [ -z "$w" ] && [ "$pbody" != - ] && [ -s "$pbody" ] && w=$(_bi_accept < "$pbody" | head -c 8192)
    if [ -n "$w" ]; then printf '%s\n' "$w"; else printf '## Acceptance tests\n\n(the ticket and the PR body name no acceptance tests)\n'; fi
    printf '\n## Diff\n\n'
    head -c "$maxd" "$od/break-it.diff"
    [ "$(wc -c < "$od/break-it.diff")" -le "$maxd" ] || printf '\n[the diff is cut at %s bytes]\n' "$maxd"
  } > "$od/break-it.prompt"
  # 7. the call: the one marked site (catalog/llm-sites.d/6970-break-it.json).
  if command -v lead_fp >/dev/null 2>&1; then fp=$(lead_fp "$repo" "$pr" "$head" breakit); else fp="lead:$repo#$pr@$head~breakit"; fi
  AGENT_CALL_NO_TOOLS=1 AGENT_CALL_BUDGET_USD="$bud" AGENT_CALL_GUARD_STAGE=lead-head AGENT_CALL_FP="$fp" AGENT_CALL_ROW_NOTE=break-it \
  AGENT_CALL_PR="https://github.com/$repo/pull/$pr" AGENT_CALL_ROLE=review-break-it "$root/bin/agent-call.sh" break-it "$project" "$model" "$left" "$od/break-it.answer" "@$od/break-it.prompt" \
    >/dev/null 2>&1 7>&- 8>&- || rc=$?
  if [ "$rc" -ge 74 ] && [ "$rc" -le 79 ]; then
    _bi_log "$repo#$pr @${head:0:12}: agent-call refused (rc $rc, nothing billed); no replay file"; printf 'could-not-run\n'; return 0
  fi
  # Paid from here on: every result is recorded.
  _BI_REPLAY="$sd/$slug-$pr-$head.result"
  # 8. the answer: the first JSON object, its cases cut to max, names made plain.
  if ! jq -Rs 'capture("(?s)(?<j>\\{.*\\})").j | fromjson
        | if type == "object" and (.cases | type) == "array" then . else error("no cases array") end' \
        "$od/break-it.answer" > "$od/break-it.raw" 2>/dev/null; then
    _bi_log "$repo#$pr @${head:0:12}: no usable JSON answer (agent rc $rc)"; _bi_done could-not-run; return 0
  fi
  jq -c --argjson max "$max" '
    def nm: tostring | gsub("[^A-Za-z0-9 _.,:()/=-]"; "") | .[0:72];
    { framework: (.framework // ""), total: (.cases | length),
      imports: ((.imports // []) | if type == "array" then map(tostring) else [] end),
      cases: ([.cases[] | select(type == "object" and (.name | type) == "string" and (.body | type) == "string")][0:$max]
              | to_entries | map({name: ("c\(.key + 1) " + (.value.name | nm)), body: .value.body})) }' \
    "$od/break-it.raw" > "$od/break-it.json" 2>/dev/null || { _bi_done could-not-run; return 0; }
  total=$(jq -r .total "$od/break-it.json"); kept=$(jq -r '.cases | length' "$od/break-it.json")
  [ "$kept" -gt 0 ] 2>/dev/null || { _bi_log "$repo#$pr @${head:0:12}: the answer holds no case"; _bi_done could-not-run; return 0; }
  [ "$total" = "$kept" ] || _bi_log "$repo#$pr @${head:0:12}: $total cases, kept $kept"
  w=$(jq -r .framework "$od/break-it.json")
  [ -z "$w" ] || [ "$w" = "$BI_FW" ] || { _bi_log "the answer is framework '$w', not $BI_FW"; _bi_done could-not-run; return 0; }
  if [ "$BI_FW" = node ]; then
    bad=$(jq -r '.imports[]' "$od/break-it.json" | grep -cvE "^import [^;'\"]* from '(node:[a-z_/]+|\\.\\./src/[A-Za-z0-9_./-]+)';?\$")
    jq -r '.imports[]' "$od/break-it.json" | grep -q '/\.\./' && bad=1
    [ "$bad" = 0 ] || { _bi_log "the answer imports outside node: and ../src/"; _bi_done could-not-run; return 0; }
  else
    jq -c '.imports = []' "$od/break-it.json" > "$od/break-it.json.t" && mv -f "$od/break-it.json.t" "$od/break-it.json"
  fi
  _BI_N="$kept"; jq -r '.cases[].name' "$od/break-it.json" > "$od/break-it.cases"
  # 9. one file, syntax checked where it runs.
  bi_compose "$od" "$head"
  cp -f "$od/break-it.file" "$wt/$BI_PATH" 2>/dev/null || { _bi_done could-not-run; return 0; }
  if [ "$BI_FW" = shell ]; then bash -n "$wt/$BI_PATH" > "$od/break-it.txt" 2>&1; rc=$?
  else ( cd "$wt/$BI_RUNDIR" && node --check "$BI_RUNREL" ) > "$od/break-it.txt" 2>&1; rc=$?; fi
  rm -f "$wt/$BI_PATH"
  [ "$rc" = 0 ] || { _bi_log "the composed file does not parse"; _bi_done could-not-run; return 0; }
  # 10. run it at the head, as nobody, in a snapshot (bi_exec).
  _bi_done "$(bi_exec "$wt" "$od" "$left" "$kept" "$head")"
}

# bi_commit <repo> <pr> <head> <path> <file> — commit <file> to the PR branch
# as <path> through the contents API. Prints the commit sha. rc 3 = the head
# is not <head> any more, 4 = the branch is in a fork, 5 = no file, 6 = the PR
# is unreadable, 7 = the write was refused. Nothing is written on rc 3..6.
bi_commit() {
  local repo="$1" pr="$2" head="$3" path="$4" file="$5" d br csha resp sha
  [ -s "$file" ] || return 5
  command -v gh_rest >/dev/null 2>&1 || return 6
  # Each gh_rest runs as a plain command into a file (gh-rest-no-subshell-lint):
  # in $( ) its GH_REST_STATUS would die with the subshell.
  d=$(mktemp -d "${TMPDIR:-/tmp}/break-it-put.XXXXXX") || return 7
  gh_rest GET "repos/$repo/pulls/$pr" > "$d/pr.json" 2>/dev/null 7>&- 8>&- || { rm -rf "$d"; return 6; }
  [ "$(jq -r '.head.sha // ""' "$d/pr.json" 2>/dev/null)" = "$head" ] || { rm -rf "$d"; return 3; }
  [ "$(jq -r '.head.repo.full_name // ""' "$d/pr.json" 2>/dev/null)" = "$repo" ] || { rm -rf "$d"; return 4; }
  br=$(jq -r '.head.ref // ""' "$d/pr.json" 2>/dev/null); [ -n "$br" ] || { rm -rf "$d"; return 6; }
  gh_rest GET "repos/$repo/contents/$path?ref=$br" > "$d/cur.json" 2>/dev/null 7>&- 8>&- || : > "$d/cur.json"
  csha=$(jq -r '.sha // empty' "$d/cur.json" 2>/dev/null)
  jq -n --arg m "test: break-it cases for ${head:0:12} (failing, BH-6970)" --arg c "$(base64 < "$file" | tr -d '\n')" \
    --arg b "$br" --arg s "$csha" '{message:$m, content:$c, branch:$b} + (if $s == "" then {} else {sha:$s} end)' > "$d/put.json" \
    || { rm -rf "$d"; return 7; }
  gh_rest PUT "repos/$repo/contents/$path" --input "$d/put.json" > "$d/resp.json" 2>/dev/null 7>&- 8>&- || { rm -rf "$d"; return 7; }
  resp=$(cat "$d/resp.json"); rm -rf "$d"
  sha=$(jq -r '.commit.sha // empty' <<<"$resp" 2>/dev/null)
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 7
  printf '%s\n' "$sha"
}

bi_review() {
  local repo="$1" pr="$2" head="$3" project="$4" wt="$5" base="$6" notes="$7" title="$8" out="$9" left="${10}"
  local issue="${11:--}" pbody="${12:--}" od tier="" key="" re res mode k n path names csha crc cline last v
  od="$wt.bi"
  re='(^|; )review-tier:(low|medium|high) review-mode:(full|intent)$'
  [[ "$notes" =~ $re ]] && tier="${BASH_REMATCH[2]}"
  re='^\[?([A-Za-z][A-Za-z0-9]*-[0-9]+)'
  [[ "$title" =~ $re ]] && key="${BASH_REMATCH[1]}"
  res=$(bi_run "$repo" "$pr" "$head" "$project" "$wt" "$base" "$tier" "$key" "$od" "$left" "$issue" "$pbody")
  mode=$(cat "$od/break-it.mode" 2>/dev/null); mode="${mode:-off}"
  case "$res" in failed:*) ;; *) printf '%s %s 0\n' "$res" "$mode"; return 0 ;; esac
  [ "$mode" = enforce ] || { printf '%s %s 0\n' "$res" "$mode"; return 0; }
  k="${res#failed:}"; path=$(sed -n 's/^path=//p' "$od/break-it.meta" | head -n 1); n=$(sed -n 's/^n=//p' "$od/break-it.meta" | head -n 1)
  names=$(paste -sd ';' "$od/break-it.failed" | sed 's/;/; /g')
  crc=0; csha=$(bi_commit "$repo" "$pr" "$head" "$path" "$od/break-it.file") || crc=$?
  case "$crc" in
    0) cline="committed to the PR branch as ${csha:0:12}" ;;
    3) cline="not committed: the PR head moved off ${head:0:12}" ;;
    4) cline="not committed: the PR branch is in a fork" ;;
    5) cline="not committed: the test file is not on this box" ;;
    6) cline="not committed: the PR could not be read" ;;
    *) cline="not committed: the contents API refused the write" ;;
  esac
  _bi_log "$repo#$pr @${head:0:12}: enforce failed:$k; test file $cline"
  cp -f "$out" "$out.bikeep" 2>/dev/null || { printf '%s %s 0\n' "$res" "$mode"; return 0; }
  last=$(awk 'NF { l = NR } END { print l + 0 }' "$out")
  {
    awk -v l="$last" 'NR == l && $0 ~ /^[*]*VERDICT:/ { next } { print }' "$out.bikeep"
    printf '\n- [BLOCK wrong-data] break-it: %s failed %s of %s case(s): %s. Test file %s. Output below.\n\n```text\n' \
      "$path" "$k" "$n" "$names" "$cline"
    grep -vE '^BREAKIT PASS |^ok [0-9]+ - ' "$od/break-it.txt" 2>/dev/null | tr -d '[]`' | head -n 40
    printf '```\n\nVERDICT: BLOCK\n'
  } > "$out" 2>/dev/null
  v=unknown
  if command -v lr_verdict >/dev/null 2>&1; then v=$(lr_verdict "$out")
  elif [ "$(awk 'NF { l = $0 } END { print l }' "$out")" = "VERDICT: BLOCK" ]; then v=BLOCK; fi
  if [ "$v" != BLOCK ]; then
    mv -f "$out.bikeep" "$out" 2>/dev/null
    _bi_log "the BLOCK rewrite left no readable verdict; the answer is restored"
    printf '%s %s 0\n' "$res" "$mode"; return 0
  fi
  rm -f "$out.bikeep"
  printf '%s %s 1\n' "$res" "$mode"
}
