#!/bin/bash
# shellcheck shell=bash
# module: rules-pack-inputs
# bin/lib/lead-review/rules-pack-inputs.sh — which paths are the rules pack's own
# inputs, and whether a PR's diff touches one. Sourced by bin/lead-review.sh
# through bin/lib/lead-review/load.sh, never run. Defines functions only.
# Sets LR_RP_WHY; reads no host global.

# lr_rp_inputs <root> — the rules pack's own inputs, derived from the TRUSTED
#   install at <root> (the box's copy the lead runs, never the PR's): the pack
#   itself, its libs (bin/lib/rules-pack*.sh), its catalog, every repo path a
#   catalog row's command names (a `cd <dir>` is that whole directory), and every
#   repo path any of those files names (the libs they source, the confs they
#   read, the checks/ tree). One entry a line; a directory ends in `/` and
#   covers everything under it. rc 1 = the list cannot be built (no catalog, or
#   it names nothing): the caller then runs the pack.
lr_rp_inputs() {
  local root="${1:-}" cat f t p l1
  cat="$root/catalog/rules-pack.tsv"
  [ -r "$cat" ] && [ -r "$root/bin/rules-pack.sh" ] || return 1
  l1=$({
    printf '%s\n' bin/rules-pack.sh catalog/rules-pack.tsv
    for f in "$root"/bin/lib/rules-pack*.sh; do [ -e "$f" ] && printf '%s\n' "${f#"$root"/}"; done
    awk -F'\t' '!/^#/ && NF >= 4 {print $4}' "$cat" \
      | grep -oE '(cd[[:space:]]+)?(bin|tests|catalog|checks|worker|config|prompts|cron|env-templates|docs)/[A-Za-z0-9_./*-]*' \
      | sed -E 's/^cd[[:space:]]+(.*[^/])$/\1\//; s/^cd[[:space:]]+//'
  } | sort -u)
  [ -n "$l1" ] || return 1
  {
    printf '%s\n' "$l1"
    while IFS= read -r t; do
      p="$root/$t"
      [ -f "$p" ] || continue
      grep -oE '(bin|tests|catalog|checks|worker|config|prompts)/[A-Za-z0-9_./-]*' "$p" 2>/dev/null
    done <<<"$l1"
  } | sed -E 's/\.+$//; s/\*.*$//; s/\/+$//' | while IFS= read -r t; do
      # A top-level directory (bin, tests, worker, ...) is the tree the pack
      # JUDGES, not the pack: only checks/ holds rules. A name that is not in
      # the install is a fixture name or a fragment (`#!/bin/bash`), never an
      # input, except the generated registry, whose source is catalog/lanes.d/.
      case "$t" in ''|*..*) continue ;; catalog/lanes.json) t=catalog/lanes.d ;; esac
      case "$t" in */*|checks) ;; *) continue ;; esac
      if [ -d "$root/$t" ]; then printf '%s/\n' "$t"
      elif [ -f "$root/$t" ]; then printf '%s\n' "$t"; fi
    done | sort -u
}

# lr_rp_touched <root> <tree> <base-ref> <sha> — rc 0 (and LR_RP_WHY) when the
#   PR's diff base...sha touches any rules-pack input, or when that cannot be
#   known (the list or the diff cannot be read): then the lead's own trusted
#   pack runs. rc 1 only when the diff is read and touches none of them.
lr_rp_touched() {
  local inputs changed hit
  LR_RP_WHY=""
  inputs=$(lr_rp_inputs "$1") && [ -n "$inputs" ] || { LR_RP_WHY="the rules pack's inputs could not be listed"; return 0; }
  changed=$(git -C "$2" diff --no-renames --name-only "$3...$4" 2>/dev/null) || { LR_RP_WHY="the diff ${3}...${4:0:12} could not be read"; return 0; }
  [ -n "$changed" ] || { LR_RP_WHY="the diff ${3}...${4:0:12} is empty"; return 0; }
  hit=$(awk 'NR == FNR { if ($0 ~ /\/$/) d[$0] = 1; else f[$0] = 1; next }
             ($0 in f) { print; exit }
             { for (k in d) if (index($0, k) == 1) { print; exit } }' <(printf '%s\n' "$inputs") <(printf '%s\n' "$changed"))
  [ -n "$hit" ] && { LR_RP_WHY="the PR changes the rules pack's own input $hit"; return 0; }
  return 1
}
