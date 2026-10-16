#!/bin/bash
# bin/llm-sites-build.sh — docs/LLM_CALL_SITES.md is an artifact of
# catalog/llm-sites.json (BH-1141 phase 1), and since BH-4987 that catalog is
# itself composed from catalog/llm-sites.d/.
#
#   llm-sites-build.sh [--repo <path>]     compose the catalog, regenerate the doc
#   llm-sites-build.sh --check [--repo …]  the fragments are valid, the catalog
#                                          and the doc are NOT in git, and both
#                                          renders are reproducible
#   llm-sites-build.sh --compose [--repo …] [--to <path>]
#                                          compose the catalog only (to
#                                          catalog/llm-sites.json, or <path>)
#
# THE CATALOG IS COMPOSED, NOT COMMITTED (BH-4987, on BH-1175's rule). Every
# new site used to append to one JSON array, so two builds that each added a
# site both edited the last element's line (its comma) and both inserted before
# the same `  ]`: a guaranteed conflict that the conductor could only settle
# with a union merge over JSON. The sources are now:
#   catalog/llm-sites.d/_head.json       the top-level object without `sites`
#   catalog/llm-sites.d/NNNN-<id>.json   a JSON array of site objects; the
#                                        first line is `[`, the last is `]`
# 0000-base.json holds the 49 sites the catalog had at the split. A NEW site is
# a NEW file. The composition is _head.json minus its closing `}`, then
# `"sites": [`, then each fragment's lines minus its `[` and `]`, joined with
# `,`, in LC_ALL=C file-name order. At the split commit it is the old file byte
# for byte. Any other file name in the directory, a fragment that is not a
# non-empty array of objects with a string `id`, or two fragments with the same
# `id` is rc 2. With no catalog/llm-sites.d/ the committed catalog/llm-sites.json
# is the source, as before (LEGACY: the ratchet suite's scratch repos).
# `--compose` writes only when the bytes differ, so a tick with no change writes
# nothing.
#
# WHY A GENERATOR AND NOT A HAND-WRITTEN DOC. The inventory has to be readable
# by a person AND queryable by the ratchet test, and two hand-maintained copies
# of the same census is two places for it to be wrong — which is the whole
# lesson this ticket is written out of. The JSON is the source; this renders it.
#
# WHY IT IS NOT COMMITTED (BH-1268, on BH-1175's rule). A generated file that is
# committed is a shared mutable cell every build writes. This one re-pointed on
# every marker edit (#1237, #1191), and a PR that touched neither the catalog
# nor the doc was re-reddened whenever a neighbour landed one. So the path is
# git-ignored, this script still writes it (CI, the share mirror and every box
# regenerate it), and `--check` stops comparing bytes against a committed copy —
# there is none. It checks what can still be wrong:
#
#   * the catalog composes and parses (rc 2 below, as before),
#   * catalog/llm-sites.json is NOT TRACKED when catalog/llm-sites.d/ exists:
#     a hand edit of the composed form is red, and the message says to move the
#     site into a fragment (BH-4987),
#   * NO doc is TRACKED in git — whether or not .gitignore still covers it,
#     because a PR that drops the ignore line and forces the file in must not be
#     able to switch its own gate off,
#   * the render is DETERMINISTIC: two renders of the same catalog are the same
#     bytes. That is the claim the byte comparison used to make, minus the
#     committed copy — a render nobody can reproduce is one nobody can publish,
#     and there is no longer a file in git to notice it through.
#
# WHY NO LINE NUMBERS. A checked-in `script:line` drifts every time anything
# above it changes, so the doc would be a daily main-red generator and nobody
# would trust it. Each site carries a `marker` instead — a literal that must
# still be in the script — and the doc prints the grep that finds the line.
# tests/llm-call-ratchet-test.sh case 5 is what keeps a marker honest.
#
# THREE OUTCOMES, NEVER TWO:
#   rc 0  generated (or, with --check, in sync)
#   rc 1  --check only: the doc is tracked in git, or the render is not
#         reproducible. Each verdict names what it is about.
#   rc 2  the catalog is missing, unreadable or not JSON, or a fragment is
#         refused (name, shape, duplicate id). The catalog and the doc are NEVER
#         written on this path — it is composed into a temp file beside the
#         target and moved into place only after the catalog parsed, so a
#         refused run leaves the old doc standing rather than half of a new one.
set -uo pipefail

SELF=llm-sites-build
CHECK=0
COMPOSE=0
TO=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1 ;;
    --compose) COMPOSE=1 ;;
    --to)      shift; TO="${1:-}"; [ -n "$TO" ] || { echo "$SELF: --to needs a path" >&2; exit 2; } ;;
    --repo)    shift; REPO="${1:-}" ;;
    -h|--help) sed -n '2,57p' "$0"; exit 0 ;;
    *) echo "usage: $SELF.sh [--check | --compose [--to <path>]] [--repo <path>]" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$TO" ] || [ "$COMPOSE" = 1 ] || { echo "$SELF: --to goes with --compose" >&2; exit 2; }
[ "$CHECK" = 0 ] || [ "$COMPOSE" = 0 ] || { echo "$SELF: --check and --compose are separate modes" >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$REPO/catalog/llm-sites.json"
FRAGS="$REPO/catalog/llm-sites.d"
DOC="$REPO/docs/LLM_CALL_SITES.md"

die2() { echo "$SELF: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die2 "jq is required"

# compose_catalog <out> — catalog/llm-sites.d/ composed into <out>. rc 0 =
# composed and valid; rc 2 = refused, with the reason on stderr. <out> is a
# temp file the caller owns: this never writes the real catalog.
compose_catalog() {
  local out="$1" f name first last sep="" dups
  [ -r "$FRAGS/_head.json" ] || { echo "$SELF: catalog/llm-sites.d/_head.json is missing" >&2; return 2; }
  jq -e 'type == "object" and (has("sites") | not)' "$FRAGS/_head.json" >/dev/null 2>&1 \
    || { echo "$SELF: catalog/llm-sites.d/_head.json must be a JSON object with no \"sites\" key" >&2; return 2; }
  [ "$(tail -n 1 "$FRAGS/_head.json")" = "}" ] \
    || { echo "$SELF: catalog/llm-sites.d/_head.json must end with a line that is only }" >&2; return 2; }
  local frags=()
  while IFS= read -r name; do
    case "$name" in
      _head.json) continue ;;
    esac
    if ! grep -qE '^[0-9]{4}-[a-z0-9][a-z0-9._-]*\.json$' <<<"$name"; then
      echo "$SELF: catalog/llm-sites.d/$name is not a fragment name (NNNN-<id>.json, lower case) — rename it or move it out" >&2
      return 2
    fi
    frags+=("$name")
  done < <(cd "$FRAGS" && LC_ALL=C ls -A | LC_ALL=C sort)
  [ "${#frags[@]}" -gt 0 ] || { echo "$SELF: catalog/llm-sites.d/ holds no NNNN-<id>.json fragment" >&2; return 2; }
  for name in "${frags[@]}"; do
    f="$FRAGS/$name"
    jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.id | type) == "string")' "$f" >/dev/null 2>&1 \
      || { echo "$SELF: catalog/llm-sites.d/$name must be a non-empty JSON array of site objects, each with a string \"id\"" >&2; return 2; }
    first=$(head -n 1 "$f"); last=$(tail -n 1 "$f")
    [ "$first" = "[" ] && [ "$last" = "]" ] && [ "$(wc -l < "$f")" -ge 2 ] \
      || { echo "$SELF: catalog/llm-sites.d/$name must open with a line that is only [ and close with a line that is only ]" >&2; return 2; }
  done
  {
    printf '%s,\n  "sites": [\n' "$(sed '$d' "$FRAGS/_head.json")"
    for name in "${frags[@]}"; do
      printf '%b%s' "$sep" "$(sed '1d;$d' "$FRAGS/$name")"
      sep=',\n'
    done
    printf '\n  ]\n}\n'
  } > "$out" || { echo "$SELF: could not write the composition" >&2; return 2; }
  jq -e '.sites | type == "array"' "$out" >/dev/null 2>&1 \
    || { echo "$SELF: the fragments in catalog/llm-sites.d/ do not compose to JSON with a .sites array" >&2; return 2; }
  dups=$(jq -r '.sites[].id' "$out" | LC_ALL=C sort | uniq -d)
  [ -z "$dups" ] || { echo "$SELF: catalog/llm-sites.d/ carries a site id twice: $(printf '%s' "$dups" | tr '\n' ' ')" >&2; return 2; }
  return 0
}

# THE COMPOSITION LANDS IN $TMPDIR FIRST, always: it is compared there and, in
# --check, never published. Only a composition that differs from the catalog on
# disk is copied beside it and moved into place, so an unchanged run writes and
# deletes nothing inside the checkout.
TMP="" TMP2="" CTMP2="" CBESIDE=""
CTMP=$(mktemp "${TMPDIR:-/tmp}/.llm-sites-catalog.XXXXXX") || die2 "mktemp failed"
cleanup() {
  rm -f "$CTMP" ${TMP:+"$TMP"} ${TMP2:+"$TMP2"} ${CTMP2:+"$CTMP2"}
  [ -z "$CBESIDE" ] || rm -f "$CBESIDE"
}
trap cleanup EXIT
if [ -d "$FRAGS" ]; then
  compose_catalog "$CTMP" || exit 2
  if [ "$CHECK" = 1 ]; then
    CATALOG="$CTMP"
  elif [ -n "$TO" ]; then
    cmp -s "$CTMP" "$TO" 2>/dev/null || { cat "$CTMP" > "$TO" || die2 "could not write $TO"; }
  elif ! cmp -s "$CTMP" "$CATALOG" 2>/dev/null; then
    CBESIDE=$(mktemp "$REPO/catalog/.llm-sites.json.XXXXXX") || die2 "mktemp beside the catalog failed"
    # mktemp makes the file 0600, and mv keeps it: open it to every reader, as
    # the tracked file was, so a nobody-run suite can still read a root compose.
    cat "$CTMP" > "$CBESIDE" && chmod 644 "$CBESIDE" && mv "$CBESIDE" "$CATALOG" || die2 "could not write $CATALOG"
    CBESIDE=""
    echo "$SELF: composed catalog/llm-sites.json ($(jq '.sites|length' "$CATALOG") sites)"
  fi
else
  # LEGACY: no fragments, the committed catalog is the source.
  [ -r "$CATALOG" ] || die2 "catalog/llm-sites.json is missing or unreadable ($CATALOG), and there is no catalog/llm-sites.d/ to compose it from"
  if [ -n "$TO" ]; then
    cmp -s "$CATALOG" "$TO" 2>/dev/null || { cat "$CATALOG" > "$TO" || die2 "could not write $TO"; }
  fi
fi
[ "$COMPOSE" = 0 ] || exit 0
[ -r "$CATALOG" ] || die2 "catalog/llm-sites.json is missing or unreadable ($CATALOG)"
jq -e '.sites | type == "array"' "$CATALOG" >/dev/null 2>&1 \
  || die2 "catalog/llm-sites.json is not JSON with a .sites array"
[ -d "$(dirname "$DOC")" ] || mkdir -p "$(dirname "$DOC")" || die2 "cannot create $(dirname "$DOC")"

# WHERE THE TEMP FILE LIVES DEPENDS ON WHAT WE ARE DOING WITH IT.
#   write  — beside $DOC, because the publish is a `mv` and a `mv` across
#            filesystems is a copy that can be seen half-written.
#   --check — in $TMPDIR, because nothing is published: the rendered bytes are
#            compared and thrown away. Rendering into the repo would have this
#            script CREATE AND DELETE a path inside a checkout it does not own,
#            which is what checks/tests-scratch-only exists to stop — and it is
#            a runtime tracer, so `tests/llm-call-ratchet-test.sh` calling
#            `--check` against the repo tripped it in CI.
if [ "$CHECK" = 1 ]; then
  TMP=$(mktemp "${TMPDIR:-/tmp}/.llm-sites.XXXXXX") || die2 "mktemp failed"
else
  TMP=$(mktemp "$(dirname "$DOC")/.llm-sites.XXXXXX") || die2 "mktemp failed"
fi

# The render is a FUNCTION because --check runs it twice: determinism is the
# property that replaced the byte comparison against a committed copy, and it
# cannot be asserted by a body that only ever runs once.
render() {
  cat <<'HEAD'
> **GENERATED — do not edit by hand, and do not commit.** `bin/llm-sites-build.sh`
> builds this file from `catalog/llm-sites.json`, which it composes from
> `catalog/llm-sites.d/` (BH-4987). Add or edit a fragment there and re-run the
> script; the fragments are what is committed, this render is git-ignored (BH-1268)
> and CI, the share mirror and every box rebuild it.

# Where this fleet calls a model

Every place the harness invokes a model, fleet-wide (BH-1141 phase 1) — every
site `tests/llm-call-ratchet-test.sh` can see under `bin/`, `cron/`, `checks/`,
`fly/` and `skills/`. Those roots are the scope of the claim: a vendor call built
at runtime, or one outside them, is still uncounted, and the ratchet's own header
says so.

**Why this file exists.** `bin/agent-call.sh` is meant to be the one choke point
where a model call can be seen, priced and — since phase 2 — refused before the
money is spent. That is a claim about the whole repo, and nothing checked it:
`bin/orchestrate.sh` has been calling `codex exec` and `grok -p` with a 1800s
timeout and no cost row at all. A choke point nobody counts is a choke point
with a hole in it. This is the count.

**How to find a site's line.** Sites are named by a literal, never by a line
number — a checked-in line number drifts on every unrelated edit above it, which
would make this inventory a source of red rather than a record. Run
`grep -nF '<marker>' <script>`.

**What the columns mean.**

| column | reading |
|---|---|
| `via agent-call` | whether the call goes through the choke point. `no` is the leak list. |
| `priced` | whether the call leaves a cost row with dollars on it. `no` = spend no ledger can see. |
| `gated` | `agent-call` = BH-1141 phase 2 can refuse it before the call. `claude-cost` = bin/claude-cost.sh consults the same llm-gate and K3 before the call (BH-2534). `none` = nothing can. |
| `dedup` | what stops this site paying twice for the same input. |

**One honest caveat about attribution.** A cost row carries `(stage, project)`
and nothing that names a lane, so `merge-conductor`, `review-autopilot` and
`review-prs` all land as `stage=review` with a real project — three lanes, one
signature. A per-lane USD cap therefore sums the *signature*, not the lane, and
says so in its refusal reason. A `lane_id` column on the row is phase 3.

HEAD

  emit_table() { # emit_table <jq-filter> <title> <lede>
    local filter="$1" title="$2" lede="$3"
    printf '## %s\n\n%s\n\n' "$title" "$lede"
    printf '| site | script | marker | lane | stage | runners | via agent-call | priced | gated | dedup |\n'
    printf '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n'
    jq -r --arg f "$filter" '
      def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
      .sites[] | select('"$filter"') |
      "| `" + (.id|cell) + "` | `" + (.script|cell) + "` | `" + (.marker|cell) + "` | "
      + ((.lane // "—")|cell) + " | " + ((.stage // "—")|cell) + " | "
      + ((.runners // [] | join(", "))|cell) + " | "
      + (if .through_agent_call then "yes" else "**no**" end) + " | "
      + (.priced|cell) + " | " + (.gated|cell) + " | " + ((.dedup // "—")|cell) + " |"
    ' "$CATALOG"
    printf '\n'
  }

  emit_table '.through_agent_call == false' \
    'Calls that do NOT go through agent-call' \
    'The leak list. Each of these is in `tests/llm-call-ratchet-allowlist.txt` with the reason it is not converted; a new one that nobody wrote down turns `tests/llm-call-ratchet-test.sh` red.'

  emit_table '.through_agent_call == true' \
    'Calls that go through agent-call' \
    'These are the ones BH-1141 phase 2 can refuse before a vendor is reached: per-lane `LLM_LANE_ENABLED`, `LLM_RUNNER_ALLOWED` and `LLM_USD_CAP_DAY` (per lane and per lane+project), with the day'"'"'s spend read from D1 `cost_rows`.'

  printf '## Notes, site by site\n\n'
  jq -r '
    def cell: tostring | gsub("\n"; " ");
    .sites[] |
    "- **`" + (.id|cell) + "`** (`" + (.script|cell) + "`) — " + (.note|cell)
  ' "$CATALOG"
  printf '\n'

  printf '## Deterministic replacement candidates\n\n'
  printf 'Named here, not shipped here: replacements are phase 5 of #1141, each with its own red-first test and the model call removed.\n\n'
  printf '| site | candidate | status |\n| --- | --- | --- |\n'
  jq -r '
    def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    .sites[] | select(.deterministic_candidate != null) |
    "| `" + (.id|cell) + "` | " + (.deterministic_candidate|cell) + " | "
    + ((.deterministic_candidate_status // "not built")|cell) + " |"
  ' "$CATALOG"
  printf '\n'
}

render > "$TMP" || die2 "render failed"

if [ "$CHECK" = 1 ]; then
  BAD=0

  # 1. a TRACKED doc, full stop. The .gitignore is the fence; this is the gate.
  #    It deliberately does NOT also require the ignore rule: refusing only
  #    "tracked AND ignored" would leave the obvious way back in open — a PR
  #    that deletes the ignore line and `git add -f`s the render passes, and
  #    main is quietly committing the file again with every lane around it
  #    still assuming otherwise.
  if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$REPO" ls-files -- docs/LLM_CALL_SITES.md 2>/dev/null)" ]; then
      echo "$SELF: docs/LLM_CALL_SITES.md is TRACKED in git. It is GENERATED from catalog/llm-sites.json and must not be committed (BH-1268):" >&2
      echo "$SELF:   git rm --cached docs/LLM_CALL_SITES.md   — the source is catalog/llm-sites.json" >&2
      if ! git -C "$REPO" check-ignore -q --no-index -- docs/LLM_CALL_SITES.md 2>/dev/null; then
        echo "$SELF:   and .gitignore no longer covers it — restore that line too, or the next build commits it again" >&2
      fi
      BAD=1
    fi
  fi

  # 1b. a TRACKED catalog, when the fragments exist (BH-4987). Same rule as the
  #     doc: tracked is red whether or not the bytes match, because a committed
  #     composition is the shared last line every new site edits again.
  if [ -d "$FRAGS" ] && command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -n "$(git -C "$REPO" ls-files -- catalog/llm-sites.json 2>/dev/null)" ]; then
      echo "$SELF: catalog/llm-sites.json is TRACKED in git. It is COMPOSED from catalog/llm-sites.d/ and must not be committed (BH-4987):" >&2
      echo "$SELF:   move the site into a new catalog/llm-sites.d/NNNN-<id>.json fragment (a JSON array, one site), then" >&2
      echo "$SELF:   git rm --cached catalog/llm-sites.json" >&2
      BAD=1
    fi
  fi

  # 1c. the composition reproduces itself: a second compose of the same
  #     fragments, compared byte for byte with the first.
  if [ -d "$FRAGS" ]; then
    CTMP2=$(mktemp "${TMPDIR:-/tmp}/.llm-sites-catalog.XXXXXX") || die2 "mktemp failed"
    if ! compose_catalog "$CTMP2" 2>/dev/null; then
      echo "$SELF: the second compose of catalog/llm-sites.d/ failed — the catalog cannot be reproduced" >&2
      BAD=1
    elif ! cmp -s "$CTMP" "$CTMP2"; then
      echo "$SELF: two compositions of catalog/llm-sites.d/ produced different bytes — the compose is not deterministic" >&2
      BAD=1
    fi
  fi

  # 2. the render reproduces itself. A second render into its own temp file,
  #    compared byte for byte with the first.
  TMP2=$(mktemp "${TMPDIR:-/tmp}/.llm-sites.XXXXXX") || die2 "mktemp failed"
  if ! render > "$TMP2"; then
    echo "$SELF: the second render failed — the doc cannot be reproduced from catalog/llm-sites.json" >&2
    BAD=1
  elif ! cmp -s "$TMP" "$TMP2"; then
    echo "$SELF: two renders of catalog/llm-sites.json produced different bytes — the render is not deterministic:" >&2
    diff -u "$TMP" "$TMP2" 2>/dev/null | head -40 >&2
    BAD=1
  fi

  [ "$BAD" = 0 ] || exit 1
  if [ -d "$FRAGS" ]; then
    echo "$SELF: $(jq '.sites|length' "$CATALOG") sites from $(find "$FRAGS" -maxdepth 1 -name '[0-9]*.json' | wc -l) fragments; catalog/llm-sites.json is composed, not committed"
  fi
  echo "$SELF: catalog/llm-sites.json renders deterministically ($(jq '.sites|length' "$CATALOG") sites); docs/LLM_CALL_SITES.md is generated, not committed"
  exit 0
fi

mv "$TMP" "$DOC" || die2 "could not write $DOC"
TMP=""
echo "$SELF: wrote $DOC ($(jq '.sites|length' "$CATALOG") sites)"
