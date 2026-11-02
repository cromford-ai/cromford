#!/bin/bash
# bin/lib/silence-scan.sh — the silence check (BH-5797). Sourced, never
# executed. 5 of the 295 BLOCK findings in the 2026-10 review-block analysis
# were a guard silenced to get green (#5645, #4867, #4811, #4803). Each rule in
# catalog/silence-markers.tsv (its header has the format) carries a ROUTE:
#   human  a public-leak allow-list (KNOWN_FAKE_* / KNOWN_PUBLIC_* entries in
#          bin/share, a gitleaks marker or ignore line, a leak or identifier
#          allow-list file): the PR gets the needs-human label and one comment,
#          and no lead review is asked until a person removes the label.
#   lead   every other allow-list line or lint marker: it goes into the lead
#          review request's scope notes, and the Opus lead judges it. A lead
#          marker must carry its reason on the same line; bin/marker-reason-lint.sh
#          (a rules-pack component) fails the builder verify step without one.
#
# Rows are `<path>\t<enclosing definition>\t<added line>`, one per added line.
# The enclosing definition starts as the hunk header and moves to every later
# line in the hunk (context or added) that opens one at column 0 (git's own
# funcname rule: a letter, `_` or `$`). GitHub's patch is -U3, so a line just
# below `KNOWN_FAKE_SECRETS = {` has an earlier definition in its @@ header
# (lead review lr-5811).
#   ss_rows_compare <compare.json>   from a GitHub compare answer (the one
#       lgc_compare, bin/lib/lead-gates-compare.sh, already read: no extra read).
#       A file shown with no patch is one row whose line is \001.
#       rc 0, 1 no files list (nothing shown), 2 not JSON.
#   ss_rows_git <tree> <base>        from `git diff -U0 <base>...HEAD`.
#       rc 0, 2 not a work tree or base unresolvable.
#   ss_match <rules.tsv> [reasonless] < rows
#       Prints `<route>\t<path>: <rule reason>: <line, cut to 160>`, one per
#       hit, sorted and unique. Only added lines count. A no-patch row is a hit
#       only for a rule with no hunk or line ERE. With `reasonless`, prints
#       instead `<path>: <rule reason> with no reason on the line: <line>` for
#       each lead-route marker hit whose text after the marker has no word of
#       3+ letters. rc 0 hits, 1 none, 2 no rules file.
#   ss_scan <compare.json> <rules.tsv>   ss_rows_compare | ss_match.
#
# ss_gate <slug> <n> <head> <compare.json> <pr.json> <state-dir>
#   The enqueue hook. rc 0 go, 1 hold, 2 unreadable (retried next tick,
#   nothing requested). Human hits: the label goes first; the comment and the
#   state row (<state-dir>/<slug_>-<n>: `<fp>\t<labelled|cleared>`, fp = 12 hex
#   of the sorted human hits) only after it. A labelled fp whose label is gone
#   was cleared by a person: recorded, and it goes on. New human hits are a new
#   fp and are labelled again. Lead hits never hold: they are written to
#   <state-dir>/note-<slug_>-<n>-<head12> for ss_note (the request notes).
#   Go without a check: knob LEAD_REVIEW_SILENCE_CHECK=0, or no rules file.
# ss_note <state-dir> <slug> <n> <head>  prints the stored lead note, or nothing.
# Needs gh_rest, gh_rest_comment (bin/lib/gh-rest.sh) and the caller's log().
# shellcheck shell=bash

[ -n "${_SS_LIB_LOADED:-}" ] && return 0
_SS_LIB_LOADED=1

SS_LABEL=needs-human

ss_rows_compare() {
  local cmp="$1"
  jq -e 'type == "object"' "$cmp" >/dev/null 2>&1 || return 2
  jq -e '(.files | type) == "array"' "$cmp" >/dev/null 2>&1 || return 1
  jq -r '.files[] | .filename as $p
    | if (.patch | type) != "string" then [$p, "", "\u0001"] | @tsv
      else foreach (.patch | split("\n")[]) as $l ({h: "", out: null};
          if ($l | startswith("@@")) then .h = ($l | sub("^@@[^@]*@@ ?"; "")) | .out = null
          elif ($l | startswith("+")) then .out = [$p, .h, ($l | .[1:])]
            | (if ($l | .[1:] | test("^[A-Za-z_$]")) then .h = ($l | .[1:]) else . end)
          elif ($l | startswith(" ")) then .out = null
            | (if ($l | .[1:] | test("^[A-Za-z_$]")) then .h = ($l | .[1:]) else . end)
          else .out = null end;
          .out | select(. != null) | @tsv)
      end' "$cmp" 2>/dev/null || return 2
}

ss_rows_git() {
  local tree="$1" base="$2"
  git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
  git -C "$tree" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || return 2
  git -C "$tree" diff -U0 --no-color --no-ext-diff "$base...HEAD" 2>/dev/null | awk '
    /^\+\+\+ / { p = substr($0, 5); sub(/^b\//, "", p); next }
    /^--- / { next }
    /^@@/ { h = $0; sub(/^@@[^@]*@@ ?/, "", h); next }
    /^\+/ { l = substr($0, 2); gsub(/\t/, "\\t", l); print p "\t" h "\t" l; if (l ~ /^[A-Za-z_$]/) h = l }'
}

ss_match() {
  local rules="$1" mode="${2:-}"
  [ -r "$rules" ] || return 2
  awk -F'\t' -v mode="$mode" '
    FNR == NR { if ($0 ~ /^#/ || NF < 6) next; n++; T[n] = $2; P[n] = $3; K[n] = $4; L[n] = $5; R[n] = $6; next }
    {
      path = $1; hunk = $2; line = $3; nopatch = (line == "\001")
      for (i = 1; i <= n; i++) {
        p = P[i]; neg = 0
        if (substr(p, 1, 1) == "!") { neg = 1; p = substr(p, 2) }
        if (p != "-") { m = (path ~ p); if (neg) m = !m; if (!m) continue }
        if (nopatch) {
          if (K[i] == "-" && L[i] == "-" && mode == "") { print T[i] "\t" path ": " R[i] ": (patch not shown by GitHub)"; break }
          continue
        }
        if (K[i] != "-" && hunk !~ K[i]) continue
        if (L[i] != "-" && line !~ L[i]) continue
        if (mode == "reasonless") {
          if (T[i] != "lead" || L[i] == "-") break
          match(line, L[i]); rest = substr(line, RSTART + RLENGTH)
          if (rest !~ /[A-Za-z][A-Za-z][A-Za-z]/) print path ": " R[i] " with no reason on the line: " substr(line, 1, 160)
          break
        }
        print T[i] "\t" path ": " R[i] ": " substr(line, 1, 160); break
      }
    }' "$rules" - | sort -u | grep . || return 1
  return 0
}

ss_scan() {
  local rows rc
  rows=$(ss_rows_compare "$1"); rc=$?
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$rows" ] || return 1
  ss_match "$2" <<<"$rows"
}

ss_note() {
  cat "$1/note-${2//\//_}-$3-${4:0:12}" 2>/dev/null
}

ss_gate() {
  local slug="$1" n="$2" head="$3" cmp="$4" pr="$5" dir="$6" all hits lead rc fp sf old st body
  local root="${HARNESS:-${H:-}}" rules="${SS_RULES:-}"
  # Unset = the registry was not read: the check runs. Only an explicit 0 is off.
  [ "${LEAD_REVIEW_SILENCE_CHECK:-}" = 0 ] && return 0
  # No root and no rules file named: no path is built from an empty root (D43).
  if [ -z "$rules" ]; then [ -n "$root" ] || return 0; rules="$root/catalog/silence-markers.tsv"; fi
  # No rules file on this box = no check, like a missing lib.
  [ -r "$rules" ] || return 0
  all=$(ss_scan "$cmp" "$rules"); rc=$?
  case "$rc" in 1) return 0 ;; 0) ;; *) log "$slug#$n @${head:0:12}: silence check could not scan the compare (rc $rc); skipped"; return 2 ;; esac
  mkdir -p "$dir" || return 2
  hits=$(awk -F'\t' '$1 == "human" {print $2}' <<<"$all")
  lead=$(awk -F'\t' '$1 == "lead" {print $2}' <<<"$all")
  if [ -n "$lead" ]; then
    printf 'silence markers for the lead to judge (BH-5797): %s\n' "$(head -12 <<<"$lead" | tr '\n' ';' | sed 's/;$//' | cut -c1-900)" \
      > "$dir/note-${slug//\//_}-$n-${head:0:12}" || return 2
  fi
  [ -n "$hits" ] || return 0
  fp=$(printf '%s\n' "$hits" | sha256sum | cut -c1-12)
  sf="$dir/${slug//\//_}-$n"
  old=$(cut -f1 "$sf" 2>/dev/null); st=$(cut -f2 "$sf" 2>/dev/null)
  if [ "$old" = "$fp" ] && [ "$st" = cleared ]; then return 0; fi
  if [ "$old" = "$fp" ] && [ "$st" = labelled ]; then
    if jq -e --arg l "$SS_LABEL" 'any(.labels[]?; .name == $l)' "$pr" >/dev/null 2>&1; then return 1; fi
    printf '%s\tcleared\n' "$fp" > "$sf"
    log "$slug#$n @${head:0:12}: silence check: the $SS_LABEL label was cleared by a human; requesting"
    return 0
  fi
  gh_rest POST "repos/$slug/issues/$n/labels" -f "labels[]=$SS_LABEL" >/dev/null 2>&1 </dev/null || {
    log "$slug#$n @${head:0:12}: silence check: the $SS_LABEL label could not be written; next tick retries"; return 2; }
  body="$dir/comment-${slug//\//_}-$n.md"
  {
    printf '**Needs a human: this diff widens a public-leak allow-list** (BH-5797, prompts/build-discipline.md D59).\n\n'
    printf 'It adds a known-fakes entry or a gitleaks marker, so a string can reach the public mirror unchecked:\n\n```\n%s\n```\n\n' "$(head -20 <<<"$hits")"
    printf 'No lead review is asked while the `%s` label is on. If each entry is a real fake, remove the label and the next tick asks for the review. If not, drop the entry.\n\n<!-- silence-scan:%s -->\n' "$SS_LABEL" "$fp"
  } > "$body"
  if ! gh_rest_comment "$slug" "$n" "$body" </dev/null; then
    log "$slug#$n @${head:0:12}: silence check: labelled, but the comment failed; next tick retries"; return 2
  fi
  printf '%s\tlabelled\n' "$fp" > "$sf"
  log "$slug#$n @${head:0:12}: silence check: labelled $SS_LABEL, no lead review asked: $(head -3 <<<"$hits" | tr '\n' ';')"
  return 1
}
