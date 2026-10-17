#!/bin/bash
# bin/lib/pr-self-check-gating.sh — BH-7074: the body-live-probes-gating rule of
# the pre-review self-check (bin/lib/pr-self-check.sh). Sourced; defines
# functions only.
#
# WHY. Nine lead BLOCKs in 14 days had one cause: a PR that gates a lane
# reached review with no lane-run probe (BH-1000, D44), or with a probe in
# prose, which is not evidence. This rule refuses such a body before a review
# is bought, from git and the body text alone.
#
# A DIFF IS GATING when an added line (git diff -U0, `+` lines only) does one of:
#   settings  in worker/jobs/schema.d/*.sql, not a `--` comment, holds a quoted
#             key 'lane_placement.<x>' or '<x>.require_<y>'.
#   cron      in cron/*.cron, cron/lanes/*.cron or cron/boxes/<box>/*.cron, not
#             a `#` comment, has more `&&` than a removed line with the same
#             final command (the text after the last `&&`, or after the
#             schedule when there is none). Removed lines count across every
#             cron file of the diff, so a line moved to another fragment is not
#             gating, and a brand-new lane line has nothing to gate.
#   route     in bin/**, not a `#` comment, holds the path of a jobs-get row of
#             the head's catalog/live-probes.tsv (query string cut), or the URL
#             of an https-get row, followed by a character that is not a path
#             character, or the end of the line.
# Only a repo whose head has catalog/live-probes.tsv is checked; in any other
# repo the rule prints nothing.
#
# A GATING BODY MUST CARRY a fenced ```live-probes block (read by lp_declared,
# the parser the live-probe lane uses) with:
#   * one or more `probe:` lines, each a probe lp_resolve accepts against the
#     head's catalog, or `probe: hub-request bin/<script>.sh <literal args>`
#     (no write verb, no shell metacharacter, no `..`);
#   * one or more `KILL KNOB: <text>` lines, with text.
# The lane still runs only catalog probes; a hub-request line is listed as
# refused in its comment.
#
# psc_gating_triggers <repo> <base> <head> <catalog-file>
#   `<file>\t<new-line>\t<kind>` per trigger, sorted. rc 0 | 2 the diff or a
#   temp file will not read.
# psc_gating_check <repo> <base> <head> <body> <mode> <id>
#   The rule's lines, `REFUSE <id>: ...` (mode refuse) or `NOTE <id>: ...`.
#   rc 1 when it refused, else 0. Callers: psc_check.

# shellcheck source=bin/lib/live-probes.sh
command -v lp_declared >/dev/null 2>&1 || . "$(dirname "${BASH_SOURCE[0]}")/live-probes.sh" 2>/dev/null || :

psc_gating_triggers() {
  local repo="$1" base="$2" head="$3" cat="$4" df rf kind target
  df=$(mktemp "${TMPDIR:-/tmp}/psc-gdiff.XXXXXX" 2>/dev/null) || return 2
  rf=$(mktemp "${TMPDIR:-/tmp}/psc-groutes.XXXXXX" 2>/dev/null) || { rm -f "$df"; return 2; }
  # Into files first, never a pipe into grep (the SIGPIPE note of psc_plan_missing).
  if ! git -C "$repo" -c core.quotePath=false diff -U0 --no-renames --no-color --no-ext-diff "$base...$head" > "$df" 2>/dev/null; then
    rm -f "$df" "$rf"; return 2
  fi
  while IFS=$'\t' read -r _ kind target; do
    case "$kind" in
      jobs-get) printf '%s\n' "${target%%\?*}" ;;
      https-get) printf '%s\n' "$target" ;;
    esac
  done < <(lp_catalog "$cat" 2>/dev/null) > "$rf"
  awk -v RF="$rf" '
    BEGIN { while ((getline l < RF) > 0) if (l != "") ROUTES[++nr] = l; hdr = 0 }
    function trim(s) { gsub(/[[:space:]]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
    function iscron(f) { return f ~ /^cron\/[^\/]+\.cron$/ || f ~ /^cron\/lanes\/[^\/]+\.cron$/ || f ~ /^cron\/boxes\/[^\/]+\/[^\/]+\.cron$/ }
    # cron_key(t): sets CK (the final command) and CC (the && count)
    function cron_key(t,   n, P, seg) {
      n = split(t, P, /&&/); CC = n - 1
      if (CC > 0) seg = P[n]
      else { seg = trim(t); if (seg ~ /^@/) sub(/^[^ ]+ ?/, "", seg); else sub(/^([^ ]+ ){5}/, "", seg) }
      CK = trim(seg)
    }
    function route_hit(t,   j, r, rest, i, nx) {
      for (j = 1; j <= nr; j++) {
        r = ROUTES[j]; rest = t
        while ((i = index(rest, r)) > 0) {
          nx = substr(rest, i + length(r), 1)
          if (nx == "" || nx !~ /[A-Za-z0-9\/_.-]/) return r
          rest = substr(rest, i + 1)
        }
      }
      return ""
    }
    /^diff --git / { hdr = 1; nf = ""; of = ""; next }
    hdr && /^--- / { f = substr($0, 5); of = (f == "/dev/null") ? "" : substr(f, 3); next }
    hdr && /^\+\+\+ / { f = substr($0, 5); nf = (f == "/dev/null") ? "" : substr(f, 3); next }
    /^@@ / { hdr = 0; s = $3; sub(/^\+/, "", s); split(s, a, ","); ln = a[1] + 0; next }
    hdr { next }
    /^-/ {
      t = substr($0, 2)
      if (iscron(of) && t !~ /^[[:space:]]*(#|$)/) { cron_key(t); if (CK != "" && (!(CK in RM) || CC > RM[CK])) RM[CK] = CC }
      next
    }
    /^\+/ {
      t = substr($0, 2)
      if (nf ~ /^worker\/jobs\/schema\.d\/[^\/]+\.sql$/ && t !~ /^[[:space:]]*--/) {
        if (match(t, /'\''lane_placement\.[A-Za-z0-9_.-]+'\''/) || match(t, /'\''[A-Za-z0-9_.-]+\.require_[A-Za-z0-9_.-]+'\''/))
          printf "%s\t%d\tsettings row %s\n", nf, ln, substr(t, RSTART, RLENGTH)
      } else if (iscron(nf) && t !~ /^[[:space:]]*(#|$)/) {
        cron_key(t); if (CC > 0 && CK != "") { na++; AF[na] = nf; AL[na] = ln; AK[na] = CK; AC[na] = CC }
      } else if (nf ~ /^bin\// && t !~ /^[[:space:]]*#/) {
        r = route_hit(t); if (r != "") printf "%s\t%d\troute %s\n", nf, ln, r
      }
      ln++; next
    }
    END {
      for (i = 1; i <= na; i++)
        if ((AK[i] in RM) && AC[i] > RM[AK[i]]) printf "%s\t%d\tnew && precondition on a cron lane\n", AF[i], AL[i]
    }' "$df" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2n
  rm -f "$df" "$rf"
  return 0
}

# _psc_gating_hub_request <cmd> — rc 0 a valid hub-request command, else rc 1
# and the reason on stdout.
_psc_gating_hub_request() {
  local cmd="$1"
  [ -n "$cmd" ] || { echo "it names no command (probe: hub-request bin/<script>.sh <args>)"; return 1; }
  if [[ "hub-request $cmd" =~ $_LP_WRITE_RE ]]; then echo "a probe never writes"; return 1; fi
  case "$cmd" in *[\;\&\|\`\$\<\>\(\)\\\'\"]*) echo "a shell metacharacter"; return 1 ;; esac
  case "$cmd" in *..*) echo "a path with .."; return 1 ;; esac
  [[ "$cmd" =~ ^bin/[A-Za-z0-9._/-]+\.sh(\ [A-Za-z0-9._=-]+)*$ ]] \
    || { echo "the command must be bin/<script>.sh with literal arguments"; return 1; }
  return 0
}

psc_gating_check() {
  local repo="$1" base="$2" head="$3" body="$4" mode="$5" id="$6" rc=0 cf bf trg n list decl rows name cmd why shown knobs
  git -C "$repo" cat-file -e "$head:catalog/live-probes.tsv" 2>/dev/null || return 0
  command -v lp_declared >/dev/null 2>&1 || { echo "NOTE $id: bin/lib/live-probes.sh not loaded, so gating diffs are not checked"; return 0; }
  _psc_gsay() { case "$mode" in refuse) echo "REFUSE $id: $1"; rc=1 ;; note) echo "NOTE $id: $1" ;; esac; }
  cf=$(mktemp "${TMPDIR:-/tmp}/psc-gcat.XXXXXX" 2>/dev/null) || { echo "NOTE $id: no temp file for the probe catalog"; return 0; }
  if ! git -C "$repo" show "$head:catalog/live-probes.tsv" > "$cf" 2>/dev/null; then
    rm -f "$cf"; echo "NOTE $id: catalog/live-probes.tsv at the head will not read"; return 0
  fi
  if ! trg=$(psc_gating_triggers "$repo" "$base" "$head" "$cf"); then
    rm -f "$cf"; echo "NOTE $id: the diff will not read, so gating is not checked"; return 0
  fi
  [ -n "$trg" ] || { rm -f "$cf"; return 0; }
  n=$(wc -l <<<"$trg")
  list=$(awk -F'\t' 'NR <= 5 { printf "%s%s:%s (%s)", (NR > 1 ? ", " : ""), $1, $2, $3 }' <<<"$trg")
  [ "$n" -gt 5 ] && list="$list, and $((n - 5)) more"
  bf=$(mktemp "${TMPDIR:-/tmp}/psc-gbody.XXXXXX" 2>/dev/null) || { rm -f "$cf"; echo "NOTE $id: no temp file for the body"; return 0; }
  tr -d '\r' < "$body" > "$bf"
  decl=$(lp_declared "$bf")
  if [ -z "$decl" ]; then
    _psc_gsay "the diff is gating ($list), and the body has no fenced \`\`\`live-probes block with a probe: line. Add one that names a catalog/live-probes.tsv probe (probe: <name>), or probe: hub-request bin/<script>.sh <args> for a dependency with no catalog row. A probe in prose does not count"
  else
    rows=$(lp_catalog "$cf" 2>/dev/null)
    while IFS=$'\t' read -r name cmd; do
      [ -n "$name" ] || continue
      if [ "$name" = hub-request ]; then
        why=$(_psc_gating_hub_request "$cmd") && continue
      else
        why=$(lp_resolve "$rows" "$name" "$cmd") && continue
        why="${why#refused: }"
      fi
      # A declared name is builder text: only a name the catalog's name rule
      # accepts is printed into a finding the review posts.
      shown="$name"; [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || shown="(bad name)"
      _psc_gsay "the diff is gating ($list), and probe \`$shown\` in the live-probes block is refused: $why"
    done <<<"$decl"
  fi
  knobs=$(awk '
    /^[[:space:]]*```[[:space:]]*live-probes[[:space:]]*$/ { inb = 1; next }
    inb && /^[[:space:]]*```/ { inb = 0; next }
    inb && /^[[:space:]]*KILL KNOB:[[:space:]]*[^[:space:]]/ { k++ }
    END { print k + 0 }' "$bf")
  [ "$knobs" -gt 0 ] || _psc_gsay "the diff is gating ($list), and the fenced live-probes block has no KILL KNOB: line. Add 'KILL KNOB: <the setting or line that turns the gate off>' inside the block"
  rm -f "$cf" "$bf"
  return "$rc"
}
