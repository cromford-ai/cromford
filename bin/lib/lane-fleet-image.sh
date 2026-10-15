# shellcheck shell=bash
# bin/lib/lane-fleet-image.sh — the image log of the lane-run fleet (BH-6817).
# Sourced by bin/lane-fleet.sh, never run.
#
#   lfi_ref <machine-list-json-file> <machine id>
#       prints `<registry>/<repository>:<tag> digest=<digest|->
#       harness_commit=<label|unknown>` for that machine, from Fly's image_ref
#       (`-` for the ref when the listing has none). The commit is the
#       `harness.commit` label fly/lane-run.Dockerfile sets.
#   lfi_log_images <machine-list-json-file> <state-file> <log-fn>
#       for each Fly `started` machine whose digest is not the one the state
#       file (TSV: id, digest) holds for it, calls <log-fn> with one line
#       `image <id> <lfi_ref>`. Then rewrites the state file to the listed
#       started machines only, so it is bounded by the listing. A machine that
#       stops and starts again is logged again. rc 1 when the listing is not
#       readable; the state file is then unchanged.
#
# Values come only from the listing of the same tick: a missing field is `-`
# or `unknown`, never a guess.

_LFI_REF='(.image_ref // null) as $r
  | (if $r == null or ($r.repository // "") == "" then "-"
     else "\(if ($r.registry // "") == "" then "" else "\($r.registry)/" end)\($r.repository):\($r.tag // "-")" end)
    + " digest=\(($r // {}).digest // "-")"
    + " harness_commit=\((($r // {}).labels // {})["harness.commit"] // "unknown")"'

lfi_ref() {
  jq -r --arg m "${2:-}" "first(.[] | select(.id == \$m)) | $_LFI_REF" "${1:-}" 2>/dev/null
}

lfi_log_images() {
  local list="${1:-}" tsv="${2:-}" logfn="${3:-}" prev line
  [ -r "$list" ] && [ -n "$tsv" ] && [ -n "$logfn" ] || return 1
  jq -e 'type == "array"' "$list" >/dev/null 2>&1 || return 1
  prev=$(jq -Rn '[inputs | split("\t") | select(length == 2) | {(.[0]): .[1]}] | add // {}' < "$tsv" 2>/dev/null) || prev='{}'
  [ -n "$prev" ] || prev='{}'
  while IFS= read -r line; do
    [ -n "$line" ] && "$logfn" "$line"
  done < <(jq -r --argjson prev "$prev" ".[] | select(.state == \"started\")
      | select((\$prev[.id] // null) != ((.image_ref // {}).digest // \"-\"))
      | \"image \\(.id) \" + ($_LFI_REF)" "$list" 2>/dev/null)
  mkdir -p "$(dirname "$tsv")" 2>/dev/null
  jq -r '.[] | select(.state == "started") | "\(.id)\t\((.image_ref // {}).digest // "-")"' "$list" > "$tsv.tmp" 2>/dev/null \
    && mv "$tsv.tmp" "$tsv"
  return 0
}
