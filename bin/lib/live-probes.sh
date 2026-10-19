#!/bin/bash
# bin/lib/live-probes.sh — BH-5801: the live-probe lane. Sourced; defines
# functions only. Run from bin/pr-state-reconcile.sh (its `live probes` block,
# since BH-7235) on the hub, for a head with a builder APPROVE and green CI and
# no lead verdict yet, so the review reads the evidence. The lead review
# worklist gate bin/lib/lead-gates.d/72-probe-hold.sh holds a head that
# declares a catalog probe until that comment is posted.
#
# WHY. 11 lead BLOCKs asked for a live probe (BH-1000) that the PR body did not
# carry: a hub-lease check, /api/flags, the protected-paths route, the npm
# registry. Pool builders cannot run hub or prod probes, so each one waited for
# a person.
#
# SAFETY, which is the point of this file:
#   * Only probes named in catalog/live-probes.tsv run. A PR names a probe in a
#     fenced ```live-probes block (`probe: <name>`); it never supplies the
#     command. A declared command that is not the catalog's, byte for byte, is
#     refused, and so is an unknown name.
#   * GET only. `cmd` runs a bin/*.sh script with its fixed literal arguments,
#     argv split on spaces, never through a shell or eval; `jobs-get` is
#     `_jobs_req GET <path>`; `https-get` is `curl -X GET` on a fixed URL with no
#     redirects. lp_catalog refuses any row that could write, and a declared
#     line that names a write verb is refused before anything else.
#   * Every line posted goes through lp_redact.
#
#   lp_run_for_head <slug> <n> <head> <pr-json-file>
#     Once per head (a done marker under state/live-probes/): run the declared
#     probes, post ONE comment (`<!-- live-probes:<head> -->`, the time, each
#     probe's rc and output) and replace the `## Live probes` section of the PR
#     body. A failed comment post leaves no marker, so the next tick tries
#     again, up to LIVE_PROBES_TRIES (3) times a head. Fail-open: rc 0 always.
#     LIVE_PROBES=0 turns the lane off.

LIVE_PROBES_MAX=5            # probes run per PR head; more are listed as skipped
LIVE_PROBES_OUT_LINES=40     # output lines kept per probe (the tail)
LIVE_PROBES_OUT_BYTES=4000
# The ONE GitHub App the lane posts as (the hub's), and the only author
# lp_evidence trusts. Not HARNESS_SELF_APPS: that list also holds the builders
# App, which pool builders hold a token for, so a builder could post a probe
# report (lead review of 885b5c9f). A trust anchor, so a constant, not a knob.
LIVE_PROBES_APP=cromford

_lp_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_lp_log() { local r; r=$(_lp_root); [ -n "$r" ] || return 0; echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [live-probes] $*" >> "$r/logs/live-probes.log" 2>/dev/null; }

# _lp_notdone <slug> <n> <head> <try> <why> — a try that did not finish: logged
# every time, and on the last allowed try (LIVE_PROBES_TRIES) said once more as
# the try that ends the head, with an ALERTS line when the caller's alert_once
# (bin/pr-state-reconcile.sh) is loaded. The head then gets no evidence until someone looks.
_lp_notdone() {
  local cap="${LIVE_PROBES_TRIES:-3}"
  if [ "$4" -ge "$cap" ]; then
    _lp_log "$1#$2 @${3:0:12}: $5 — $cap tries used, no more for this head"
    command -v alert_once >/dev/null 2>&1 && alert_once "live-probes-$(printf '%s' "$1" | tr '/' '_')-$2-${3:0:12}" warn "$1#$2 @${3:0:12}: the live-probe lane could not post as $LIVE_PROBES_APP after $cap tries ($5); this head has no probe evidence" >/dev/null 2>&1 || true
  else
    _lp_log "$1#$2 @${3:0:12}: $5; the next tick tries again ($4 of $cap)"
  fi
}
# A line that would write, wherever it appears.
_LP_WRITE_RE='(^|[[:space:]])(POST|PUT|PATCH|DELETE)([[:space:]]|$)|(^|[[:space:]])(-X|--request|--data|--data-[a-z]+|-d|-F|--form|-T|--upload-file)([[:space:]=]|$)'

# lp_catalog [file] — the valid rows as "name<TAB>kind<TAB>target"; every
# refused row is named on stderr. The file is the catalog or LIVE_PROBES_CATALOG.
lp_catalog() {
  local f="${1:-${LIVE_PROBES_CATALOG:-}}" name kind target note
  # NO PATH FROM AN EMPTY ROOT (D43): with no file, no LIVE_PROBES_CATALOG and
  # no HARNESS/H there is no catalog to read, not "/catalog/live-probes.tsv".
  if [ -z "$f" ]; then
    [ -n "$(_lp_root)" ] || { echo "live-probes: no harness root and no catalog named" >&2; return 1; }
    f="$(_lp_root)/catalog/live-probes.tsv"
  fi
  [ -r "$f" ] || { echo "live-probes: catalog $f unreadable" >&2; return 1; }
  while IFS=$'\t' read -r name kind target note; do
    case "$name" in ''|'#'*) continue ;; esac
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then echo "live-probes: $name: bad name" >&2; continue; fi
    if [[ "$target" =~ $_LP_WRITE_RE ]]; then echo "live-probes: $name: refused, the target could write" >&2; continue; fi
    case "$target" in *[\;\&\|\`\$\<\>\(\)\\\'\"]*) echo "live-probes: $name: refused, a shell metacharacter" >&2; continue ;; esac
    case "$kind" in
      cmd) [[ "$target" =~ ^bin/[A-Za-z0-9._/-]+\.sh(\ [A-Za-z0-9._=-]+)*$ ]] && [[ "$target" != *..* ]] \
             || { echo "live-probes: $name: refused, a cmd must be bin/<script>.sh with literal arguments" >&2; continue; } ;;
      jobs-get) [[ "$target" =~ ^/api/[A-Za-z0-9/_.=?-]+$ ]] || { echo "live-probes: $name: refused, a jobs-get target is an /api/ path" >&2; continue; } ;;
      https-get) [[ "$target" =~ ^https://[A-Za-z0-9.-]+(/[A-Za-z0-9/_.=?%-]*)?$ ]] || { echo "live-probes: $name: refused, an https-get target is one https URL" >&2; continue; } ;;
      *) echo "live-probes: $name: refused, unknown kind '$kind'" >&2; continue ;;
    esac
    printf '%s\t%s\t%s\n' "$name" "$kind" "$target"
  done < "$f"
}

# lp_declared <body-file> — "name<TAB>declared-command" per `probe:` line inside
# a fenced ```live-probes block, and nowhere else.
lp_declared() {
  awk '
    /^[[:space:]]*```[[:space:]]*live-probes[[:space:]]*$/ { inb = 1; next }
    inb && /^[[:space:]]*```/ { inb = 0; next }
    inb && /^[[:space:]]*probe:[[:space:]]*/ {
      l = $0; sub(/^[[:space:]]*probe:[[:space:]]*/, "", l); sub(/[[:space:]]+$/, "", l)
      n = l; sub(/[[:space:]].*$/, "", n); c = substr(l, length(n) + 1); sub(/^[[:space:]]+/, "", c)
      if (n != "") printf "%s\t%s\n", n, c
    }' "$1" 2>/dev/null
}

# lp_resolve <catalog-rows> <name> <declared-command> — rc 0 and "kind<TAB>target",
# or rc 1 and the refusal on stdout.
lp_resolve() {
  local rows="$1" name="$2" decl="$3" row
  if [[ "$name $decl" =~ $_LP_WRITE_RE ]]; then echo "refused: a probe never writes"; return 1; fi
  row=$(awk -F'\t' -v n="$name" '$1 == n {print $2 "\t" $3; exit}' <<<"$rows")
  [ -n "$row" ] || { echo "refused: not on the allow-list (catalog/live-probes.tsv)"; return 1; }
  if [ -n "$decl" ] && [ "$decl" != "${row#*$'\t'}" ]; then
    echo "refused: the declared command is not the allow-listed one ($(printf '%s' "${row#*$'\t'}"))"; return 1
  fi
  printf '%s\n' "$row"
}

# lp_redact — stdin to stdout, with secrets replaced by [redacted].
# The literal values go through awk index(), never into a regex: a secret is
# often base64 (+ / =) and may hold ( ) { } ?, which an ERE would read as
# syntax, leak through, or fail on and print nothing (lead review of 51ce7b23).
# They reach awk through the environment, never its argv.
lp_redact() {
  local v k lits=""
  for k in HARNESS_SECRET GH_TOKEN GITHUB_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY LEAD_VERDICT_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
    v="${!k:-}"
    [ "${#v}" -ge 8 ] && [[ "$v" != *$'\n'* ]] || continue
    lits="${lits}${v}"$'\n'
  done
  _LP_LITS="$lits" awk '
    BEGIN { n = split(ENVIRON["_LP_LITS"], L, "\n") }
    { for (j = 1; j <= n; j++) if (L[j] != "") {
        out = ""; rest = $0
        while ((i = index(rest, L[j])) > 0) { out = out substr(rest, 1, i - 1) "[redacted]"; rest = substr(rest, i + length(L[j])) }
        $0 = out rest }
      print }' | sed -E '
    s/(gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}/[redacted]/g
    s/sk-(ant-)?[A-Za-z0-9_-]{16,}/[redacted]/g
    s/AKIA[A-Z0-9]{16}/[redacted]/g
    s/xox[abpr]-[A-Za-z0-9-]{8,}/[redacted]/g
    s/([Bb]earer|[Tt]oken|Basic)[[:space:]]+[A-Za-z0-9._~+\/=-]{6,}/\1 [redacted]/g
    s/(([A-Za-z_]*([Ss]ecret|SECRET|[Tt]oken|TOKEN|[Pp]assword|PASSWORD|[Kk]ey|KEY))["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?)[^"'"'"'[:space:],}]+/\1[redacted]/g
  '
}

# lp_run_one <kind> <target> <outfile> — the probe's rc; its output in <outfile>.
lp_run_one() {
  local kind="$1" target="$2" out="$3" to="${LIVE_PROBES_TIMEOUT_S:-60}" root rc argv
  root=$(_lp_root)
  case "$kind" in
    cmd)
      # D43: a cmd probe runs from the harness root, never from the cwd.
      [ -n "$root" ] || { echo "no harness root (HARNESS/H unset); not run" > "$out"; return 2; }
      read -r -a argv <<<"$target"
      ( cd "$root" && timeout "$to" "./${argv[0]}" "${argv[@]:1}" ) </dev/null >"$out" 2>&1; rc=$? ;;
    jobs-get)
      command -v _jobs_req >/dev/null 2>&1 || { echo "the jobs client is not loaded" > "$out"; return 2; }
      # The probe's own timeout and no retries; a non-2xx answer prints nothing,
      # so the worker's payload (JOBS_BODY) is shown with the rc.
      # JOBS_ALERT=0: a failed probe is a probe result, not the daily
      # "harness-jobs unreachable" ALERTS line.
      ( JOBS_TIMEOUT="$to" JOBS_RETRIES=0 JOBS_ALERT=0; _jobs_req GET "$target"; r=$?
        [ "$r" = 0 ] || printf 'HTTP %s %s\n' "${JOBS_HTTP:-?}" "${JOBS_BODY:-}"; exit "$r" ) </dev/null >"$out" 2>&1; rc=$? ;;
    https-get)
      timeout "$to" curl -sS --max-redirs 0 --max-time "$to" -X GET -o "$out" -w '\nHTTP %{http_code}\n' "$target" </dev/null >>"$out" 2>&1; rc=$? ;;
    *) echo "unknown kind" > "$out"; return 2 ;;
  esac
  return "$rc"
}

# lp_report <head> <results-file> — the comment, from "name<TAB>rc-or-refusal<TAB>outfile" lines.
lp_report() {
  local head="$1" res="$2" name st of
  printf '<!-- live-probes:%s -->\n**Live probes** at `%s`, run by the hub at %s (BH-5801). Read only; secrets redacted.\n\n' \
    "$head" "${head:0:12}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS=$'\t' read -r name st of; do
    # A name that is not a catalog name is never printed: this comment is the
    # one the review trusts, and a declared name is builder text.
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || name="(bad name)"
    case "$st" in
      refused:*) printf -- '- `%s`: %s\n' "$name" "$st" ;;
      skipped*) printf -- '- `%s`: %s\n' "$name" "$st" ;;
      *) printf -- '- `%s`: rc %s\n\n```\n%s\n```\n' "$name" "$st" \
           "$(tail -n "$LIVE_PROBES_OUT_LINES" "$of" 2>/dev/null | lp_redact | head -c "$LIVE_PROBES_OUT_BYTES")" ;;
    esac
  done < "$res"
}

# _lp_body <pr-json> <comment-file> <out> — the PR body with the lane's own
# section (`## Live probes` right before `<!-- live-probes:start -->`, through
# `<!-- live-probes:end -->`) replaced, or added at the end. Only that marked
# span is dropped: a hand-written `## Live probes` heading, or a start marker
# with no end, keeps every line below it (lead review of 51ce7b23).
_lp_body() {
  jq -r '.body // ""' "$1" | awk -v sec="$2" '
    BEGIN { while ((getline l < sec) > 0) s = s l "\n" }
    function flush(   k) { for (k = 1; k <= nb; k++) print B[k]; nb = 0 }
    /^## Live probes[[:space:]]*$/ && !skip { if (held != "") print held; held = $0; next }
    /^<!-- live-probes:start -->[[:space:]]*$/ && !skip { skip = 1; nb = 0; if (held != "") B[++nb] = held; held = ""; B[++nb] = $0; next }
    held != "" { print held; held = "" }
    skip && /^<!-- live-probes:end -->[[:space:]]*$/ { skip = 0; nb = 0; next }
    skip { B[++nb] = $0; next }
    { print }
    END { if (held != "") print held
          if (skip) flush()
          printf "\n## Live probes\n<!-- live-probes:start -->\n%s<!-- live-probes:end -->\n", s }' > "$3"
}

# lp_evidence <owner/repo> <pr> <head> — the probe evidence for the lead review:
# the newest PR comment written by the lane's own App (LIVE_PROBES_APP) whose
# first line is
# `<!-- live-probes:<head> -->` for exactly this head. A comment by anyone else,
# the PR body, or another head's report is never evidence: a builder writes the
# body and can post comments (lead review of 51ce7b23). Prints the comment, or
# one line saying there is none or the comments could not be read. Always rc 0.
lp_evidence() {
  local slug="$1" n="$2" head="$3" page=1 raw all="[]" got tf
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || { echo "(no live-probe evidence: bad PR or head)"; return 0; }
  # gh_rest runs as a plain command into a file: GH_REST_STATUS is set in the
  # calling shell, and a $( ) subshell would lose it (tests/gh-rest-no-subshell-lint.sh).
  tf=$(mktemp "${TMPDIR:-/tmp}/lp-evidence.XXXXXX") || { echo "(no live-probe evidence: no temp file)"; return 0; }
  while [ "$page" -le 5 ]; do
    gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&page=$page" > "$tf" 2>/dev/null \
      && raw=$(cat "$tf") && jq -e 'type == "array"' <<<"$raw" >/dev/null 2>&1 \
      || { rm -f "$tf"; echo "(no live-probe evidence: the PR comments could not be read, HTTP ${GH_REST_STATUS:-000})"; return 0; }
    all=$(jq -c --argjson a "$all" '$a + .' <<<"$raw")
    [ "$(jq length <<<"$raw")" -lt 100 ] && break
    page=$((page + 1))
  done
  rm -f "$tf"
  # The lane's App only: its bot login, or a comment GitHub says that App made.
  got=$(jq -r --arg app "$LIVE_PROBES_APP" --arg m "<!-- live-probes:$head -->" '
    [ .[] | select(((.user.login // "") | ascii_downcase) == ($app + "[bot]")
                   or ((.performed_via_github_app.slug // "") | ascii_downcase) == $app)
          | select(((.body // "") | split("\n")[0] | gsub("\r"; "")) == $m) ]
    | last // empty | .body' <<<"$all" 2>/dev/null)
  if [ -n "$got" ]; then printf '%s\n' "$got"
  else printf '(no live-probe comment by the harness App %s for %s on this PR)\n' "$LIVE_PROBES_APP" "${head:0:12}"; fi
  return 0
}

lp_run_for_head() {
  local slug="$1" n="$2" head="$3" prj="$4" root dir mark tries rows decl name cmd k res i=0 of rc row cf bf
  [ "${LIVE_PROBES:-1}" = 1 ] || return 0
  root=$(_lp_root); [ -n "$root" ] && [ -r "$prj" ] || return 0
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$n" =~ ^[0-9]+$ ]] || return 0
  dir="$root/state/live-probes"; mkdir -p "$dir" 2>/dev/null || return 0
  mark="$dir/$(printf '%s' "$slug" | tr '/' '_')-$n-${head:0:12}"
  [ -e "$mark.done" ] && return 0
  # ONE TICK'S PROBE TIME IS BOUNDED (LIVE_PROBES_TICK_BUDGET_S, default 240).
  # Probes run inside the reconcile sweep, under its flock -n: 5 probes x 60 s on
  # each of several PRs would make the next tick skip. Past the budget a head
  # is left for the next tick, with no try counted.
  : "${_LP_TICK_T0:=$(date +%s)}"
  local budget="${LIVE_PROBES_TICK_BUDGET_S:-240}"
  case "$budget" in ''|*[!0-9]*) budget=240 ;; esac
  if [ "$budget" -gt 0 ] && [ $(( $(date +%s) - _LP_TICK_T0 )) -ge "$budget" ]; then
    _lp_log "$slug#$n @${head:0:12}: this tick's probe budget (LIVE_PROBES_TICK_BUDGET_S=$budget) is spent; the next tick runs it"
    return 0
  fi
  tries=$(cat "$mark.tries" 2>/dev/null || echo 0); [[ "$tries" =~ ^[0-9]+$ ]] || tries=0
  [ "$tries" -lt "${LIVE_PROBES_TRIES:-3}" ] || return 0
  jq -r '.body // ""' "$prj" > "$mark.body" 2>/dev/null || return 0
  decl=$(lp_declared "$mark.body"); rm -f "$mark.body"
  [ -n "$decl" ] || return 0
  rows=$(lp_catalog 2>>"$root/logs/live-probes.log") || { _lp_log "$slug#$n: catalog unreadable; nothing run"; return 0; }
  res="$mark.results"; : > "$res"
  while IFS=$'\t' read -r name cmd; do
    i=$((i + 1))
    # A DECLARED NAME IS BUILDER TEXT (review of f5591ee99). It is checked
    # against the catalog's name rule before it is used anywhere, and one that
    # fails is reported as `(bad name)`: printed verbatim it could carry a fake
    # "rc 0" result, or an HTML comment that hides the real refusal, into the
    # App comment the review reads as evidence.
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
      printf '%s\t%s\t\n' "(bad name)" "refused: bad name" >> "$res"
      _lp_log "$slug#$n @${head:0:12} a declared probe name failed the catalog name rule: refused"
      continue
    fi
    if [ "$i" -gt "$LIVE_PROBES_MAX" ]; then printf '%s\tskipped: over %s probes a head\t\n' "$name" "$LIVE_PROBES_MAX" >> "$res"; continue; fi
    if ! row=$(lp_resolve "$rows" "$name" "$cmd"); then printf '%s\t%s\t\n' "$name" "$row" >> "$res"; _lp_log "$slug#$n @${head:0:12} $name: $row"; continue; fi
    of="$mark.out.$i"
    lp_run_one "${row%%$'\t'*}" "${row#*$'\t'}" "$of"; rc=$?
    printf '%s\t%s\t%s\n' "$name" "$rc" "$of" >> "$res"
    _lp_log "$slug#$n @${head:0:12} $name: rc $rc"
  done <<<"$decl"
  cf="$mark.comment"; bf="$mark.newbody"
  lp_report "$head" "$res" > "$cf"
  printf '%s\n' "$((tries + 1))" > "$mark.tries"
  # Posted as LIVE_PROBES_APP, the only author lp_evidence trusts. gh_auth_for
  # hands back the PAT with rc 0 when a mint fails, so the token itself is
  # checked: only an installation token (ghs_) posts, and the answer's author
  # must be the lane's App. Anything else is not done: the next tick tries
  # again, and the last try says so once (D-loud).
  local GH_TOKEN="${GH_TOKEN:-}" resp who
  command -v gh_auth_for >/dev/null 2>&1 || . "$root/bin/lib/gh-app-auth.sh" 2>/dev/null
  if ! { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug"; } || [[ "${GH_TOKEN:-}" != ghs_* ]]; then
    _lp_notdone "$slug" "$n" "$head" "$((tries + 1))" "no App installation token (gh_auth_for gave none, or the PAT); not posted, a PAT comment is not evidence"
    rm -f "$mark".out.* "$res" "$cf"; return 0
  fi
  if ! gh_rest POST "repos/$slug/issues/$n/comments" -F "body=@$cf" > "$mark.resp" 2>/dev/null; then
    _lp_notdone "$slug" "$n" "$head" "$((tries + 1))" "comment not posted (HTTP ${GH_REST_STATUS:-000})"
    rm -f "$mark".out.* "$res" "$cf" "$mark.resp"; return 0
  fi
  resp=$(cat "$mark.resp"); rm -f "$mark.resp"
  who=$(jq -r '(.user.login // "") | ascii_downcase' <<<"$resp" 2>/dev/null)
  if [ "$who" != "${LIVE_PROBES_APP}[bot]" ]; then
    _lp_notdone "$slug" "$n" "$head" "$((tries + 1))" "the comment was posted as '${who:-unknown}', not ${LIVE_PROBES_APP}[bot]; it is not evidence"
    rm -f "$mark".out.* "$res" "$cf"; return 0
  fi
  # The body is read again now: the snapshot is from before the probes ran,
  # and a builder may have edited the body since. No fresh body, no PATCH.
  if gh_rest GET "repos/$slug/pulls/$n" > "$mark.pr" 2>/dev/null && jq -e '.body | type == "string" or . == null' "$mark.pr" >/dev/null 2>&1; then
    _lp_body "$mark.pr" "$cf" "$bf"
    gh_rest PATCH "repos/$slug/pulls/$n" -F "body=@$bf" >/dev/null 2>&1 \
      || _lp_log "$slug#$n @${head:0:12}: the PR body section was not written (HTTP ${GH_REST_STATUS:-000}); the comment stands"
  else
    _lp_log "$slug#$n @${head:0:12}: the PR body could not be read again (HTTP ${GH_REST_STATUS:-000}); the body section was not written, the comment stands"
  fi
  rm -f "$mark.pr"
  : > "$mark.done"
  rm -f "$mark".out.* "$res" "$cf" "$bf" "$mark.tries"
  return 0
}
