# bin/lib/needs-human/classify.sh — the BH-3433 classify slice (BH-3444).
# Contracts are in bin/lib/needs-human.sh. Sourced, never executed; the root is
# ${HARNESS:-${H:-}} and nothing else (D43).
# shellcheck shell=bash

# The four human-only shapes (needs a human / run … from the hub / paste …
# output … PR body / a credential or env file the build box lacks) and the
# negatives that cancel a hit. Used with grep -iE. Algorithm constants, not
# settings: a settings edit must never silently change which tickets hold.
# Past-tense `ran`/`executed` are left out of NH_RE_HUB on purpose: history is
# not an ask. So are `runs` and `on the hub` in its first branch: "X runs on the
# hub" is how a reviewer says where code executes, not a request for a person;
# the ask is the imperative "run … from the hub". The noun in NH_RE_HUMAN is
# closed by a non-hyphen, because `\b` would let "a human-readable" match.
NH_RE_HUMAN='\bneeds? (a|an) (human|person|operator)([^-[:alnum:]]|$)|\bonly (a|an) (human|person|operator) can\b'
NH_RE_HUB='\b(run|rerun|re-run|execute|probe)\b.{0,120}\bfrom the hub\b|\b(run|runs)\b.{0,40}\bas the hub( conductor)?(.s)? (github )?(identity|app|token)\b'
NH_RE_PASTE='\bpaste[sd]?\b.{0,120}\boutputs?\b.{0,120}\bpr body\b|\boutputs?\b.{0,40}\b(go|goes|pasted?) (in|into) the pr body\b'
NH_RE_CRED='\b(credential|secret|token|app key|api key|env file|env var)s?\b.{0,80}\b(build|builder|pool) (box|machine)\b.{0,40}\b(lacks?|does ?n.t have|has no|cannot|can.t)\b|\b(build|builder|pool) (box|machine)\b.{0,40}\b(lacks?|does ?n.t have|has no)\b.{0,80}\b(credential|secret|token|app key|api key|env file|env var)'
NH_RE_NEG='\b(no|not|never|without|does ?n.t|do ?n.t)\b.{0,24}\b(need|needs|require|requires)\b.{0,6}\b(a |an )?(human|person|operator)\b|non-blocking|\((minor|nit)\)|\b(now|already|was|been) (answered|resolved|cleared|addressed)\b|\bnot (only |just )?from the hub\b|not verified here|NOTE demoted'

# _nh_final <file> — the final review round: the text after the LAST `=== `
# header (review.sh writes one before a merged re-review, whose VERDICT-*: tags
# it strips), or the whole file when there is none.
_nh_final() {
  awk '/^=== /{n=0; next} {b[++n]=$0} END{for (i = 1; i <= n; i++) print b[i]}' "$1" 2>/dev/null
}

# _nh_lines — stdin to stdout: drops fenced code, `>` quotes and the
# VERDICT/TIER tag lines, so only finding prose is a candidate.
_nh_lines() {
  awk '/^[[:space:]]*```/{f=!f; next} f{next} /^[[:space:]]*>/{next} /^[[:space:]]*(VERDICT|TIER)[-: ]/{next} {print}'
}

# _nh_clean <text> — one line: no CR, tabs to spaces, no `**`, whitespace
# collapsed and trimmed, cut to 160 characters.
_nh_clean() {
  local a
  a=$(printf '%s' "${1:-}" | tr -d '\r' | tr '\t\n' '  ' | sed -E 's/\*\*//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  printf '%s' "${a:0:160}"
}

# _nh_fallback — stdin to stdout: the first candidate line matching a shape
# and no negative, or nothing.
_nh_fallback() {
  local hit
  # BH-7123: NH_RE_CRED is no longer a shape. "The build box lacks the Clerk
  # key" describes a VERIFICATION the box could not run (e2e, design-guard, a
  # Lighthouse run), which the review levels make a `[NOTE] not verified here`,
  # never a hold: 9 of 37 holds in 2026-09-25..10-16 were that sentence. A
  # go-live credential a user depends on is still asked for with an explicit
  # `NEEDS_HUMAN:` line, which the structured path above reads.
  hit=$(_nh_lines | grep -iE "$NH_RE_HUMAN|$NH_RE_HUB|$NH_RE_PASTE" | grep -viE "$NH_RE_NEG" | sed -n 1p) || true
  printf '%s' "$hit"
}

# nh_classify <review.md | --text STRING> — rc 0 "needs-human<TAB><action>",
# rc 1 "none", rc 2 unreadable (nothing printed). A file is read in its final
# round: a structured `NEEDS_HUMAN: <action>` line wins whatever the verdict
# (placeholders like `none` or `<one-line action>` are skipped); the shape
# fallback runs only when the file's last VERDICT line is BLOCK. --text runs
# the fallback alone, for a triage reason that has no verdict.
nh_classify() {
  local f hit line val low verdict
  case "${1:-}" in
    '') return 2 ;;
    --text)
      [ "$#" -ge 2 ] || return 2
      hit=$(printf '%s\n' "$2" | _nh_fallback)
      if [ -n "$hit" ]; then printf 'needs-human\t%s\n' "$(_nh_clean "$hit")"; return 0; fi
      printf 'none\n'; return 1 ;;
  esac
  f=$1
  [ -f "$f" ] && [ -r "$f" ] || return 2
  while IFS= read -r line; do
    val=$(_nh_clean "$(printf '%s' "$line" | sed -E 's/^NEEDS_HUMAN:[[:space:]]*//')")
    low=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "${low%.}" in ''|none|n/a|na|no|nothing|-|'<'*'>') continue ;; esac
    printf 'needs-human\t%s\n' "$val"; return 0
  done < <(_nh_final "$f" | _nh_lines | grep -E '^NEEDS_HUMAN:[ 	]*[^ 	]' || true)
  verdict=$(sed -nE 's/^[[:space:]]*VERDICT:[[:space:]]*(APPROVE|BLOCK)[[:space:]]*$/\1/p' "$f" 2>/dev/null | sed -n '$p')
  if [ "$verdict" = BLOCK ]; then
    hit=$(_nh_final "$f" | _nh_fallback)
    if [ -n "$hit" ]; then printf 'needs-human\t%s\n' "$(_nh_clean "$hit")"; return 0; fi
  fi
  printf 'none\n'; return 1
}

# nh_on_block <project> <issue> <review.md> <build-dir> — prints the RESULT
# suffix " NEEDS_HUMAN:<fp>:<action>" or nothing; never fails the caller.
# GitHub-issues projects only (review.sh sets the issue number only there).
# The suffix means CLASSIFIED: whether bin/needs-human-hold.sh placed a hold is
# recorded as `placer rc=N` in <build-dir>/pipeline.log, and the placer's own
# stdout never reaches the suffix.
nh_on_block() {
  local out action fp root prc
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  out=$(nh_classify "${3:-}" 2>/dev/null) || return 0
  action=$(_nh_clean "${out#*$'\t'}")
  [ -n "$action" ] || return 0
  fp=$(nh_fingerprint "$action" 2>/dev/null) || return 0
  if [ -n "${4:-}" ] && [ -d "$4" ] && [ -w "$4" ]; then
    printf 'action: %s\nfp: %s\n' "$action" "$fp" > "$4/needs-human.txt" 2>/dev/null || true
  fi
  root=${HARNESS:-${H:-}}
  if [ -n "$root" ] && [ -x "$root/bin/needs-human-hold.sh" ]; then
    "$root/bin/needs-human-hold.sh" "$1" "$2" "$fp" "$action" review >/dev/null 2>&1; prc=$?
  else
    prc=127
  fi
  if [ -n "${4:-}" ] && [ -d "$4" ] && [ -w "$4" ]; then
    printf '%s needs-human: %s "%s" — placer rc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$fp" "$action" "$prc" >> "$4/pipeline.log" 2>/dev/null || true
  fi
  printf ' NEEDS_HUMAN:%s:%s' "$fp" "$action"
  return 0
}

# nh_on_golive <project> <issue> <review.md> <build-dir> — BH-7123 wave B: the
# go-live step an APPROVED lens still names. rl_cap --golive note (bin/lib/
# review-level.sh) rewrites a go-live `NEEDS_HUMAN:` line to `HUMAN_GOLIVE:
# <step>` and the verdict no longer waits on it; this reads the first such line
# of the final round, places the hold with source `go-live` (a visible step on
# the ticket that bin/lib/hold.sh reads as clear, never a pause), and prints the
# RESULT suffix " NEEDS_HUMAN:<fp>:go-live: <step>" for the PR_CREATED line. No
# line, no issue number, no fingerprint = nothing printed. Never fails the caller.
nh_on_golive() {
  local f="${3:-}" line val low action="" fp root prc
  case "${2:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$f" ] && [ -r "$f" ] || return 0
  while IFS= read -r line; do
    val=$(_nh_clean "$(printf '%s' "$line" | sed -E 's/^[[:space:]]*HUMAN_GOLIVE:[[:space:]]*//')")
    low=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
    case "${low%.}" in ''|none|n/a|na|no|nothing|-|'<'*'>') continue ;; esac
    action="$val"; break
  done < <(_nh_final "$f" | _nh_lines | grep -E '^[[:space:]]*HUMAN_GOLIVE:[[:space:]]*[^[:space:]]' || true)
  [ -n "$action" ] || return 0
  fp=$(nh_fingerprint "$action" 2>/dev/null) || return 0
  if [ -n "${4:-}" ] && [ -d "$4" ] && [ -w "$4" ]; then
    printf 'action: go-live: %s\nfp: %s\n' "$action" "$fp" > "$4/needs-human.txt" 2>/dev/null || true
  fi
  root=${HARNESS:-${H:-}}
  if [ -n "$root" ] && [ -x "$root/bin/needs-human-hold.sh" ]; then
    "$root/bin/needs-human-hold.sh" "$1" "$2" "$fp" "go-live: $action" go-live >/dev/null 2>&1; prc=$?
  else
    prc=127
  fi
  if [ -n "${4:-}" ] && [ -d "$4" ] && [ -w "$4" ]; then
    printf '%s needs-human go-live: %s "%s" — placer rc=%s; the PR does not wait on it\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$fp" "$action" "$prc" >> "$4/pipeline.log" 2>/dev/null || true
  fi
  printf ' NEEDS_HUMAN:%s:go-live: %s' "$fp" "$action"
  return 0
}

# nh_prompt_field_note — the one reviewer sentence, with a leading space: it is
# spliced straight after "…VERDICT: BLOCK." at the end of REVIEW_PROMPT.
nh_prompt_field_note() {
  printf '%s\n' " Write 'NEEDS_HUMAN: <one-line action>' on its own line above the 'TIER:' line ONLY for a go-live step a user depends on that no build can do (a live connector key, a vendor console, a production credential, a product decision). A verification this box cannot run (a key, env file, browser, prod database or host it lacks) is a '[NOTE] not verified here: <what>', never NEEDS_HUMAN; otherwise write no such line."
}
