#!/bin/bash
# bin/lanes-build.sh [--root <dir>] [--write|--check]
#
# Compose catalog/lanes.json from catalog/lanes.d/ — `_registry.json` for the
# file's own version and note, one `<lane-id>.json` per lane, sorted by id, and
# `_lib.json` (optional, BH-1511.1) plus one `_lib.<id>.json` per lib (BH-1937,
# so a lib lands as a NEW file, never an append) for the knobs SHARED libraries
# read, composed as the top-level `libs` array (sorted by id; an id in two files
# is an error naming both). A library is not a lane — no
# cron line, no switch, no script to gate — so it never enters `lanes` and no
# lane reader sees it; bin/lib/lane-gate.sh's lib_env_apply reads `libs`.
#
# A NEW KNOB IS A NEW FILE (BH-4987): `<owner>.knobs.d/<ENV>.json` holds one
# knob object, appended to the owner's `knobs` after its inline knobs, in C
# order of file name. <owner> is a lane id or `_lib.<lib-id>`. Two builds that
# appended to one inline array both edited its last element and conflicted;
# two fragment files never do. The file is named for the env, not `NNNN-`,
# because two branches that pick the same number collide add/add, and an env
# is unique per owner anyway. A fragment with no owner, a name that is not
# `<ENV>.json`, a file that is not one object, an `.env` that is not its name,
# or an env the owner already has is refused (rc 1, the file named).
# bin/lanes-knob-lint.sh keeps new knobs out of the inline arrays.
#
# WHY (BH-1178). The registry is the thing every new lane has to be added to,
# and it is one 3,100-line array: two builds registering two unrelated lanes
# land in adjacent hunks and git calls it a conflict. Splitting it makes adding
# a lane one NEW file — no shared file edited, nothing to conflict with — while
# catalog/lanes.json stays exactly where the fifteen readers already look for
# it (bin/lib/lane-gate.sh, worker/jobs GET /api/lanes/registry, the console's
# settings page, four test suites).
#
# AND IT IS NOT COMMITTED (BH-1247). BH-1178 left the composition in git and
# `--check` compared its bytes, which made the composed file a shared mutable
# cell again: any PR that edited a lane without re-composing turned red, and
# once such a PR merged every OTHER open PR inherited the red on a file its
# ticket never mentioned. Three merge trains died that way on 2026-09-21
# (#1241, #1257, #1263). Same doctrine as BH-1175's docs/verification-map/
# README.md: take the contested cell OUT of git rather than resolve it.
#
# So the path is git-ignored, every reader goes through
# bin/lib/lanes-registry.sh's `lanes_json_path` (which renders on demand), and
# `--check` stops comparing bytes. It validates what IS committed: the sources
# parse, every lane file is named for its id, no id is duplicated, the
# composition is DETERMINISTIC (two runs byte-identical) and no copy is TRACKED
# in git. tests/registry-no-commit-test.sh drives all of it.
#
#   --write            rewrite catalog/lanes.json
#   --to <path>        compose into <path> (what lanes_json_path renders through)
#   --check            the sources are valid, the composition is deterministic,
#                      and no catalog/lanes.json is tracked in git
#   --check-committed  the OLD byte comparison, for a repo that still COMMITS
#                      its registry
#   (neither) print the composition on stdout
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE=print
TO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    ROOT="$2"; shift 2 ;;
    --write)   MODE=write; shift ;;
    --to)      MODE=to; TO="$2"; shift 2 ;;
    --check)   MODE=check; shift ;;
    --check-committed) MODE=check-committed; shift ;;
    # The range is DERIVED: awk stops at the first non-comment line, so a
    # paragraph added to this header is printed rather than silently cut
    # (the literal range in render-crontab.sh grew stale twice).
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *)         echo "lanes-build.sh: unexpected argument $1" >&2; exit 2 ;;
  esac
done

# ABSOLUTE, ALWAYS. The stamp bin/lib/lanes-registry.sh keeps is keyed on a
# digest of the render's absolute path, so `--root .` would stamp
# `./catalog/lanes.json` — a key the loader never looks up, and the convergence
# this script's --write was added for would silently cost a re-render every time
# (BH-1247 review r2, I1). `_lr_root` already normalises; so does this.
ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || { echo "lanes-build.sh: --root is not a directory" >&2; exit 2; }
SRC="$ROOT/catalog/lanes.d"
OUT="$ROOT/catalog/lanes.json"
HDR="$SRC/_registry.json"
LIBF="$SRC/_lib.json"
[ -d "$SRC" ] || { echo "lanes-build.sh: no $SRC" >&2; exit 1; }
[ -f "$HDR" ] || { echo "lanes-build.sh: no $SRC/_registry.json (the version and note)" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "lanes-build.sh: jq is required" >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/lanes-build.XXXXXX"); trap 'rm -f "$TMP" "$TMP.ids" "$TMP.2"' EXIT

# compose <outfile> — the whole composition, in a function so `--check` can run
# it TWICE over the same sources and compare. That second run is what replaced
# the byte comparison against a committed copy: "the registry is what its parts
# say" used to be proved by a file in git, and since BH-1247 there is no such
# file, so the property that remains provable is that the parts compose to one
# answer rather than to whichever answer the machine felt like.
N=0
compose() {
  local dst="$1" f bn id composed dupes ids
  ids="$TMP.ids"; : > "$ids"
  local -a lane_files=()
  N=0
  # Each lane file must BE that lane: a file named for one id holding another is
  # a lane that silently disappears from the composition the next time somebody
  # sorts the directory, and the registry would still look complete.
  #
  # LC_ALL=C so the directory listing does not depend on the operator's locale.
  # The composition sorts by .id afterwards, so this only pins which file is read
  # first — but a locale-dependent read order is how two machines disagree about
  # a byte-identical artifact.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    bn=$(basename "$f" .json)
    [ "$bn" = "_registry" ] && continue
    case "$bn" in _lib|_lib.*) continue ;; esac
    jq -e . "$f" >/dev/null 2>&1 || { echo "lanes-build.sh: $f is not valid JSON" >&2; return 1; }
    id=$(jq -r '.id // ""' "$f")
    [ "$id" = "$bn" ] || { echo "lanes-build.sh: $f holds lane id '$id' — a lane file is named for its id" >&2; return 1; }
    printf '%s\n' "$bn" >> "$ids"
    lane_files+=("$f")
    N=$((N+1))
  done <<<"$(printf '%s\n' "$SRC"/*.json | LC_ALL=C sort)"
  [ "$N" -gt 0 ] || { echo "lanes-build.sh: $SRC holds no lane files" >&2; return 1; }

  # The header is read with --slurpfile rather than as the first slurped input,
  # so the lane list can never accidentally contain it. Sorting by id here (not
  # by filename) is what makes the composition independent of the locale the
  # glob expanded under.
  # The libs scope: absent file = no libs, a present one must be well formed —
  # a lib with no id or no file is a knob nobody can key or check.
  # `_lib.json` first, then `_lib.<id>.json` in C order; each file gets the same
  # shape check, and each lib carries its file's name until the dupe check.
  local libs='[]' lf all='[]' lbtmp n=0
  local -a lib_files=("$LIBF") lib_jsons=()
  # The composition goes through files, never argv: the libs scope passed
  # 124 KB on 2026-10-08 and one --argjson argument may not exceed
  # MAX_ARG_STRLEN (128 KiB), so a batch adding a few knobs failed with
  # "jq: Argument list too long".
  lbtmp=$(mktemp -d "${TMPDIR:-/tmp}/lanes-build.XXXXXX") || { echo "lanes-build.sh: cannot make a temp dir" >&2; return 1; }
  while IFS= read -r lf; do [ -f "$lf" ] && lib_files+=("$lf"); done \
    <<<"$(printf '%s\n' "$SRC"/_lib.*.json | LC_ALL=C sort)"
  for lf in "${lib_files[@]}"; do
    [ -f "$lf" ] || continue
    libs=$(jq -ce --arg f "$(basename "$lf")" '.libs | if type=="array" and all(.[]; (.id|type)=="string" and (.id|length)>0 and (.file|type)=="string") then map(. + {_lb_src: $f}) else error("bad") end' "$lf" 2>/dev/null) \
      || { echo "lanes-build.sh: $lf must hold {\"libs\":[{\"id\":…,\"file\":…,\"knobs\":[…]}]}" >&2; rm -rf -- "$lbtmp"; return 1; }
    n=$((n + 1)); printf '%s' "$libs" > "$lbtmp/$n.json"; lib_jsons+=("$lbtmp/$n.json")
  done
  [ "${#lib_jsons[@]}" -eq 0 ] || all=$(jq -cs 'add' "${lib_jsons[@]}")
  dupes=$(printf '%s' "$all" | jq -r 'group_by(.id)[] | select(length>1) | "lanes-build.sh: duplicate lib id \u0027\(.[0].id)\u0027 in \(map(._lb_src) | join(" and "))"')
  [ -z "$dupes" ] || { printf '%s\n' "$dupes" >&2; rm -rf -- "$lbtmp"; return 1; }
  printf '%s' "$all" | jq -c 'map(del(._lb_src)) | sort_by(.id)' > "$lbtmp/libs.json"

  # The knob fragments: `<owner>.knobs.d/<ENV>.json`, one knob object each,
  # collected as [{owner, knob}] in C order of dir, then file name.
  local kd kf kn owner what
  : > "$lbtmp/kn.ndjson"
  while IFS= read -r kd; do
    [ -n "$kd" ] && [ -e "$kd" ] || continue
    owner=$(basename "$kd" .knobs.d)
    case "$owner" in
      _lib.*) jq -e --arg id "${owner#_lib.}" 'any(.[]; .id == $id)' "$lbtmp/libs.json" >/dev/null 2>&1 ;;
      _*)     false ;;
      *)      grep -qxF -- "$owner" "$ids" ;;
    esac || { echo "lanes-build.sh: $kd has no owner: no lane '$owner' and no lib '${owner#_lib.}' (a knob dir is <lane-id>.knobs.d or _lib.<lib-id>.knobs.d)" >&2; rm -rf -- "$lbtmp"; return 1; }
    [ -d "$kd" ] || { echo "lanes-build.sh: $kd is not a directory" >&2; rm -rf -- "$lbtmp"; return 1; }
    while IFS= read -r kf; do
      [ -n "$kf" ] && [ -e "$kf" ] || continue
      kn=$(basename "$kf")
      [[ "$kn" =~ ^[A-Z][A-Z0-9_]*\.json$ ]] && [ -f "$kf" ] \
        || { echo "lanes-build.sh: $kf is not a knob fragment: a file in $(basename "$kd")/ is named <ENV>.json, ENV matching ^[A-Z][A-Z0-9_]*\$" >&2; rm -rf -- "$lbtmp"; return 1; }
      what=$(jq -r --arg e "${kn%.json}" 'if type != "object" then "not one knob object" elif .env != $e then "holds env \(.env | tojson), not \($e)" else "ok" end' "$kf" 2>/dev/null) || what="not valid JSON"
      [ "$what" = ok ] || { echo "lanes-build.sh: $kf: $what — a knob fragment holds ONE knob object whose .env is its file name" >&2; rm -rf -- "$lbtmp"; return 1; }
      jq -c --arg o "$owner" '{owner: $o, knob: .}' "$kf" >> "$lbtmp/kn.ndjson"
    done <<<"$(printf '%s\n' "$kd"/* | LC_ALL=C sort)"
  done <<<"$(printf '%s\n' "$SRC"/*.knobs.d | LC_ALL=C sort)"
  jq -s . "$lbtmp/kn.ndjson" > "$lbtmp/kn.json"

  jq -s --slurpfile hdr "$HDR" --slurpfile libs "$lbtmp/libs.json" --slurpfile kn "$lbtmp/kn.json" \
    'def frags($o): $kn[0] | map(select(.owner == $o) | .knob);
     def addk($o): frags($o) as $f | if ($f | length) > 0 then .knobs = ((.knobs // []) + $f) else . end;
     {version: $hdr[0].version, note: $hdr[0].note,
      lanes: (map(addk(.id)) | sort_by(.id)),
      libs: ($libs[0] | map(addk("_lib." + .id)))}' \
    "${lane_files[@]}" > "$dst" || { echo "lanes-build.sh: jq refused the composition" >&2; rm -rf -- "$lbtmp"; return 1; }
  # A fragment may not repeat an env its owner already has inline: two knobs
  # with one env is one setting read two ways. Only owners with fragments are
  # checked; two fragments of one owner cannot collide (the file name is the env).
  dupes=$(jq -r --slurpfile kn "$lbtmp/kn.json" --arg src "$SRC" '
      ($kn[0] | map(.owner) | unique) as $own
      | ([.lanes[] | {o: .id, k: .knobs}] + [.libs[] | {o: ("_lib." + .id), k: .knobs}])[]
      | select(.o as $o | $own | index($o))
      | .o as $o | (.k | map(.env) | group_by(.) | map(select(length > 1) | .[0]))[]
      | "lanes-build.sh: \($src)/\($o).knobs.d/\(.).json: knob \(.) is already in the inline knobs of \($o) — move it, do not repeat it"' "$dst")
  [ -z "$dupes" ] || { printf '%s\n' "$dupes" >&2; rm -rf -- "$lbtmp"; return 1; }
  rm -rf -- "$lbtmp"
  [ -s "$dst" ] || { echo "lanes-build.sh: composed an empty registry — refusing it" >&2; return 1; }
  composed=$(jq -r '.lanes|length' "$dst")
  [ "$composed" = "$N" ] || { echo "lanes-build.sh: composed $composed lanes from $N files" >&2; return 1; }
  dupes=$(sort "$ids" | uniq -d | tr '\n' ' '); rm -f "$ids"
  [ -z "${dupes// /}" ] || { echo "lanes-build.sh: duplicate lane ids:$dupes" >&2; return 1; }
  return 0
}

compose "$TMP" || exit 1

case "$MODE" in
  print) cat "$TMP" ;;
  to)    [ -n "$TO" ] || { echo "lanes-build.sh: --to needs a path" >&2; exit 2; }
         cp "$TMP" "$TO" ;;
  write) cp "$TMP" "$OUT"
         # Tell the loader this render is current, so a checkout that
         # harness-sync or CI has just composed is not re-composed by the very
         # next reader. The stamp lives outside the tree (see
         # bin/lib/lanes-registry.sh) — this script never learns where.
         # shellcheck source=bin/lib/lanes-registry.sh
         . "$HERE/lib/lanes-registry.sh" 2>/dev/null \
           && command -v lanes_stamp_write >/dev/null 2>&1 \
           && lanes_stamp_write "$ROOT" >/dev/null 2>&1 || :
         echo "lanes-build.sh: wrote catalog/lanes.json ($N lanes)" ;;
  check)
    # THE SOURCES ARE WHAT IS COMMITTED, so they are what is checked. Nothing
    # here writes: a check that repairs what it was asked to report makes the
    # defect invisible, which is the one thing CI's step must not do.
    BAD=0
    # 1. deterministic. A second composition over the same sources must be the
    #    same bytes — the claim the old byte comparison stood in for.
    if ! compose "$TMP.2"; then
      echo "lanes-build.sh: the second composition of the same sources FAILED" >&2
      BAD=1
    elif ! cmp -s "$TMP" "$TMP.2"; then
      echo "lanes-build.sh: catalog/lanes.d/ does not compose to the same bytes twice:" >&2
      diff -u "$TMP" "$TMP.2" 2>/dev/null | head -20 >&2
      BAD=1
    fi
    # 2. a TRACKED registry, full stop — and NOT "tracked AND ignored". A PR
    #    that deletes the .gitignore line and `git add -f`s the file must not be
    #    able to switch its own gate off (BH-1175's wording, BH-1247's subject).
    if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
      if [ -n "$(git -C "$ROOT" ls-files -- catalog/lanes.json 2>/dev/null)" ]; then
        echo "lanes-build.sh: catalog/lanes.json is TRACKED in git. It is GENERATED and must not be committed (BH-1247):" >&2
        echo "lanes-build.sh:   git rm --cached catalog/lanes.json   — the source is catalog/lanes.d/" >&2
        if ! git -C "$ROOT" check-ignore -q --no-index -- catalog/lanes.json 2>/dev/null; then
          echo "lanes-build.sh:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
        fi
        BAD=1
      fi
    fi
    [ "$BAD" = 0 ] || { echo "lanes-build.sh: the source is catalog/lanes.d/ — the registry itself is generated and ignored." >&2; exit 1; }
    echo "lanes-build.sh: catalog/lanes.d/ is valid and composes deterministically ($N lanes); catalog/lanes.json is generated, not committed" ;;
  check-committed)
    # The OLD byte comparison, kept for a repo or a lane that still has a
    # committed registry to compare against (bin/verification-map-build.sh
    # carries the same pair for the same reason). cromford itself reaches
    # this only through tests/registry-no-commit-test.sh.
    if [ -f "$OUT" ] && cmp -s "$OUT" "$TMP"; then
      echo "lanes-build.sh: catalog/lanes.json is in sync ($N lanes)"
    else
      echo "lanes-build.sh: catalog/lanes.json does not match catalog/lanes.d/ (committed vs composed):" >&2
      diff -u "$OUT" "$TMP" 2>/dev/null | head -40 >&2
      echo "lanes-build.sh: run bin/lanes-build.sh --write and commit the result." >&2
      exit 1
    fi ;;
esac
