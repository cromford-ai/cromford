#!/bin/bash
# shellcheck shell=bash
# bin/lib/suite-fingerprint.sh — one input fingerprint per suite (BH-5354.0 / BH-5366).
# Sourced by bin/suite-reuse.sh, never run.
#
#   sfp_compute <rev> <suites-file> <out-tsv>
#
# Writes `<suite>\t<fp>\t<never-reason or ->`, one row per suite in
# <suites-file>, in input order. The fingerprint is
#
#   sha256( "suite-fp v2\n"
#         + "infra\t<infra_hash>\n"
#         + sorted unique "<path>\t<git object id or ->" over the suite's inputs )
#
# where the inputs are the suite's rows in `bin/test-impact.sh inputs` (the
# suite itself, every path its map row names, every tests/lib/ helper those
# helpers reach through the helper closure, every script defining a function
# it names; a directory row hashes as its tree id), and infra_hash is the
# sha256 of the same sorted lines over the `@infra` paths plus this file,
# bin/suite-reuse.sh, bin/ci-plan.sh, bin/test-impact-gate.sh,
# bin/lib/ci-batch-escalate.sh (it decides the `@infra` set) and
# catalog/suite-reuse-never.tsv (read here). A path that does not exist at
# <rev> hashes as `-`. So any input moving, or any of the infra moving, moves
# the fingerprint and the suite runs.
#
# v2 (BH-6406): a tests/lib/ or catalog/ path is NOT infra as a rule. It is
# infra only when the tree's catalog/ci-batch-escalate.tsv escalates it (the
# global helpers, e.g. tests/lib/scratch.sh), when no suite reaches it (a
# helper no suite names after the closure, a catalog/ file with no specific
# map row), or when the rules cannot be read (then every such path is, the
# v1 set). A *.md there is never infra. The header names v2, so no v1 ledger
# row can match a v2 fingerprint.
#
# NEVER REUSED (fp `-`, the reason in column 3), checked in this order:
#   always            the suite runs on every diff (a `*` inputs row)
#   fast-lint         `bin/fast-lints.sh --list` names it
#   never.tsv: <why>  catalog/suite-reuse-never.tsv names it (live-host reads)
#   out-of-tree: <t>  a non-comment line reads something no tree id can see
#                     (another ref, the network, the live harness state)
#   unknown suite     the inputs list has no row for it
#
# rc: 0 written; 2 refused (rev is not HEAD, not a checkout, the inputs or the
# fast-lint list could not be built); 3 dirty tree (stderr says so) — the
# inputs are read from the work tree, so a dirty one has no honest fingerprint.
#
# The root is $HARNESS_CHECKOUT, else the git toplevel of $PWD. No other default.

SFP_OUT_OF_TREE_RE='RATCHET_BASE|origin/main|merge-base|git[ \t]+fetch|ls-remote|gh[ \t]+api|/root/harness/(state|logs|builds)'

_sfp_sha256() { # _sfp_sha256 <file>... — `<hex>  <file>` lines
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

sfp_compute() {
  local rev="${1:-}" suites="${2:-}" out="${3:-}" root rsha hsha st w rc
  [ -n "$rev" ] && [ -r "$suites" ] && [ -n "$out" ] || {
    echo "suite-fingerprint: usage: sfp_compute <rev> <suites-file> <out-tsv>" >&2; return 2; }
  root="${HARNESS_CHECKOUT:-}"
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
  [ -n "$root" ] && [ -d "$root" ] || { echo "suite-fingerprint: not in a git checkout" >&2; return 2; }
  rsha=$(git -C "$root" rev-parse --verify -q "$rev^{commit}" 2>/dev/null) || rsha=""
  hsha=$(git -C "$root" rev-parse --verify -q "HEAD^{commit}" 2>/dev/null) || hsha=""
  [ -n "$rsha" ] && [ "$rsha" = "$hsha" ] || { echo "suite-fingerprint: rev is not HEAD" >&2; return 2; }
  st=$(git -C "$root" status --porcelain 2>/dev/null) || { echo "suite-fingerprint: git status failed" >&2; return 2; }
  [ -z "$st" ] || { echo "suite-fingerprint: dirty tree" >&2; return 3; }

  w=$(mktemp -d "${TMPDIR:-/tmp}/suite-fp.XXXXXX") || return 2
  _sfp_compute "$root" "$rsha" "$suites" "$out" "$w"; rc=$?
  rm -rf "$w"
  return "$rc"
}

_sfp_compute() {
  local root="$1" rsha="$2" suites="$3" out="$4" w="$5" infra_hash
  git -C "$root" ls-tree -r -t --full-tree -z "$rsha" | tr '\0' '\n' \
    | awk '{ i = index($0, "\t"); split(substr($0, 1, i - 1), a, " "); print substr($0, i + 1) "\t" a[3] }' > "$w/tree" \
    || { echo "suite-fingerprint: git ls-tree failed" >&2; return 2; }
  "$root/bin/test-impact.sh" --root "$root" inputs > "$w/inputs" \
    || { echo "suite-fingerprint: bin/test-impact.sh inputs failed" >&2; return 2; }
  [ -s "$w/inputs" ] || { echo "suite-fingerprint: bin/test-impact.sh inputs printed nothing" >&2; return 2; }
  "$root/bin/fast-lints.sh" --list > "$w/fast" 2>/dev/null \
    || { echo "suite-fingerprint: bin/fast-lints.sh --list failed" >&2; return 2; }
  : > "$w/never"
  [ -r "$root/catalog/suite-reuse-never.tsv" ] && cp "$root/catalog/suite-reuse-never.tsv" "$w/never"
  grep -v '^$' "$suites" > "$w/suites" || :

  # infra_hash, over the sorted `<path>\t<id or ->` lines of the infra set.
  { awk -F'\t' '$1 == "@infra" { print $2 }' "$w/inputs"
    printf '%s\n' bin/suite-reuse.sh bin/lib/suite-fingerprint.sh bin/ci-plan.sh bin/test-impact-gate.sh \
      bin/lib/ci-batch-escalate.sh catalog/suite-reuse-never.tsv
  } | LC_ALL=C sort -u | awk -F'\t' -v tf="$w/tree" '
      FILENAME == tf { id[$1] = $2; next }
      { print $1 "\t" (($1 in id) ? id[$1] : "-") }' "$w/tree" - > "$w/infra"
  infra_hash=$(_sfp_sha256 "$w/infra" | awk '{ print $1 }')
  [ -n "$infra_hash" ] || { echo "suite-fingerprint: sha256 failed" >&2; return 2; }

  # The out-of-tree rule: the first non-comment line of each suite that reads
  # something outside the tree, and the token it matched. One awk pass.
  : > "$w/oot"
  local args=() s
  while IFS= read -r s; do
    case "$s" in tests/*) [ -f "$root/$s" ] && args+=("./$s") ;; esac
  done < "$w/suites"
  if [ "${#args[@]}" -gt 0 ]; then
    ( cd "$root" && LC_ALL=C awk -v re="$SFP_OUT_OF_TREE_RE" '
        FNR == 1 { done_ = 0 }
        done_ || /^[ \t]*#/ { next }
        match($0, re) { f = FILENAME; sub(/^\.\//, "", f); print f "\t" substr($0, RSTART, RLENGTH); done_ = 1 }
      ' "${args[@]}" ) > "$w/oot" || { echo "suite-fingerprint: the out-of-tree scan failed" >&2; return 2; }
  fi

  # One canonical text per fingerprinted suite, written to its own file, then
  # ONE sha256 call over all of them.
  mkdir -p "$w/c" || return 2
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2 -u "$w/inputs" > "$w/inputs.sorted"
  LC_ALL=C awk -F'\t' -v tf="$w/tree" -v ff="$w/fast" -v nf="$w/never" -v of="$w/oot" \
      -v sf="$w/suites" -v cdir="$w/c" -v ih="$infra_hash" '
    FILENAME == tf { id[$1] = $2; next }
    FILENAME == ff { if ($1 != "") fast[$1] = 1; next }
    FILENAME == nf { if ($0 !~ /^[ \t]*#/ && $1 != "") never[$1] = $2; next }
    FILENAME == of { oot[$1] = $2; next }
    FILENAME == sf { want[$1] = 1; next }
    $1 == "@infra" || !($1 in want) { next }
    {
      known[$1] = 1
      if ($2 == "*") { always[$1] = 1; next }
      p = $2; sub(/\/$/, "", p)
      rows[$1] = rows[$1] $2 "\t" ((p in id) ? id[p] : "-") "\n"
    }
    END {
      n = 0
      while ((getline s < sf) > 0) {
        n++
        if (s in always) r = "always"
        else if (s in fast) r = "fast-lint"
        else if (s in never) r = "never.tsv: " never[s]
        else if (s in oot) r = "out-of-tree: " oot[s]
        else if (!(s in known)) r = "unknown suite"
        else {
          r = "-"; f = cdir "/" n
          printf "suite-fp v2\ninfra\t%s\n%s", ih, rows[s] > f; close(f)
        }
        print n "\t" s "\t" r
      }
    }' "$w/tree" "$w/fast" "$w/never" "$w/oot" "$w/suites" "$w/inputs.sorted" > "$w/plan" \
    || { echo "suite-fingerprint: the fingerprint pass failed" >&2; return 2; }

  : > "$w/sums"
  if [ -n "$(ls "$w/c")" ]; then
    ( cd "$w/c" && _sfp_sha256 * ) > "$w/sums" || { echo "suite-fingerprint: sha256 failed" >&2; return 2; }
  fi
  awk -F'\t' -v sums="$w/sums" '
    FILENAME == sums { split($0, a, " "); fp[a[2]] = a[1]; next }
    { print $2 "\t" (($3 == "-") ? fp[$1] : "-") "\t" $3 }' "$w/sums" "$w/plan" > "$out" \
    || { echo "suite-fingerprint: cannot write $out" >&2; return 2; }
}
