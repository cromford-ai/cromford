#!/bin/bash
# tests/model-literal-lint.sh [--warn] [--list] [path ...]
#
# BH-1510.0 — the lint half of "we shouldn't have hardcodes anywhere; all of
# that should be DB values" (the operator, 2026-09-22). A model-id literal in a call
# site is exactly the shape #1510 exists to remove: 136 of them were measured
# on main (b4912c5c) across ~40 files, every one a `${VAR:-claude-fable-5-1}`
# shell default or a bare argv literal, with no table and no resolver behind
# any of them.
#
# WHAT COUNTS AS A LITERAL. Not a regex guess at what a model name looks like
# — that either misses a family this file's author never heard of, or flags an
# unrelated word that happens to rhyme with one. Instead: every KEY in
# catalog/model-prices.json's `per_token` object and catalog/model-slugs.json,
# which is already the fleet's own registry of every model id it has ever
# priced (bin/update-model-prices.sh keeps it current). A literal not in that
# list cannot be priced anyway, so scanning for it here would find nothing this
# lint could act on.
#
# WHERE IT LOOKS: bin/, fly/, worker/jobs/src, console-ui/src, prompts/,
# catalog/lanes.d — the ticket's own list. Nowhere else, on purpose:
#   - worker/jobs/schema.sql (the seed migration) and catalog/model-prices.json
#     / catalog/model-slugs.json (the price data) are DATA HOMES, not call
#     sites, and are not even under the scanned dirs above.
#   - worker/jobs/test/, tests/, console-ui/tests/ and every other *test* tree
#     are exempt: a fixture that pins `model: 'claude-opus-5'` to prove a route
#     records what it was told is not a hardcode, it is a fixture, and this
#     repo's own suites do that throughout (worker/jobs/test/lib/harness.js's
#     TR() helper, to name one already in this diff's own test).
#
# STRICT (the default since BH-1510.4): lists every hit, file:line:literal,
# and exits 1 if there is any. #1510.0 shipped this in WARN mode with a
# baseline of 157 lines (main at b4912c5c, 2026-09-22 — distinct LINES with a
# hit, code or comment, undistinguished); #1510.1-.3 converted the lanes and
# #1510.4 took the count to 0, so 0 is now the pin, not a target:
#
#   MODEL_LITERAL_LINT_BASELINE=0 lines, pinned by BH-1510.4 (2026-09-24).
#
# BARE ALIASES (BH-2535): a second scan over the same files flags `haiku`,
# `sonnet`, `opus` or `fable` in model-argument position only — `--model X`,
# `<ident containing model>[:=] X` (shell, JS, JSON) and a `${...:-X}` default —
# never a case label, a regex vocabulary or prose. A path listed in
# tests/model-literal-alias-allowlist.txt (path<TAB>reason) is reported
# `exempt:` and does not fail; an allowlisted path with no hit left prints a
# `stale alias exemption` note and does not fail either. Its summary line is
# `N bare-alias line(s) found (E exempt)`, and N > 0 fails under STRICT.
#
# CI runs it on every PR as its own step in .github/workflows/harness-ci.yml
# (`model-id literal lint (BH-1510)`), whatever bin/test-impact.sh selects.
# A comment counts too: grep does not read intent, and a comment that names a
# model id is the next call site's copy-paste source. Write `<model id>` or
# name the family in words instead.
#
#   --warn       list every hit and exit 0 (to survey, never in CI)
#   --strict     accepted, a no-op: strict is the default (kept so no caller breaks)
#   --list       print the literal vocabulary being searched for, and exit
#
# Usage:  tests/model-literal-lint.sh [--warn] [--list] [path ...]
set -uo pipefail

ROOT_DEFAULT="$(cd "$(dirname "$0")/.." && pwd)"
# tests-scratch-only (checks/tests-scratch-only, #461): a top-level tests/*.sh
# must source the scratch lib before its first mktemp/rm/trap, so any scratch
# file this script creates lives under $T, never under a bare $TMPDIR path a
# later edit could turn into something harness-derived.
. "$(dirname "$0")/lib/scratch.sh" || exit 1
STRICT=1; MODE=lint
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --warn)   STRICT=0 ;;
    --list)   MODE=list ;;
    -h|--help) sed -n '2,58p' "$0"; exit 0 ;;
    -*) echo "model-literal-lint: unknown flag $1" >&2; exit 2 ;;
    *) PATHS+=("$1") ;;
  esac
  shift
done
ROOT="${PATHS[0]:-$ROOT_DEFAULT}"
ROOT="${ROOT%/}"

PRICES="$ROOT/catalog/model-prices.json"
SLUGS="$ROOT/catalog/model-slugs.json"
if [ ! -r "$PRICES" ] || [ ! -r "$SLUGS" ]; then
  echo "model-literal-lint: cannot read $PRICES or $SLUGS — the vocabulary this lint scans for comes from them, and a lint scanning for nothing must not report green" >&2
  exit 2
fi

VOCAB=$(python3 - "$PRICES" "$SLUGS" <<'PY'
import json, sys
ids = set()
for path in sys.argv[1:]:
    with open(path) as f:
        d = json.load(f)
    keys = d.get("per_token", d) if isinstance(d, dict) else {}
    ids.update(keys.keys())
# Longest first: a literal search is fixed-string, so a shorter id that is a
# PREFIX of a longer one (claude-fable-5 vs claude-fable-5-1) still gets its
# own hit line, and ordering longest-first is what lets the caller dedupe by
# file:line without losing the more specific match.
for i in sorted(ids, key=len, reverse=True):
    print(i)
PY
) || { echo "model-literal-lint: could not read the model vocabulary out of $PRICES / $SLUGS" >&2; exit 2; }
[ -n "$VOCAB" ] || { echo "model-literal-lint: $PRICES / $SLUGS named zero model ids — refusing to scan for nothing" >&2; exit 2; }

if [ "$MODE" = list ]; then
  printf '%s\n' "$VOCAB"
  exit 0
fi

PATFILE="$T/model-literal-lint.pat"
printf '%s\n' "$VOCAB" > "$PATFILE"

# The ticket's own dirs, nothing else. Each is a `git ls-files` scope so a
# gitignored scratch file (catalog/lanes.json itself, generated from
# catalog/lanes.d) can never wander into the count.
SCAN_DIRS=(bin fly worker/jobs/src console-ui/src prompts catalog/lanes.d)
FILES=()
for d in "${SCAN_DIRS[@]}"; do
  [ -d "$ROOT/$d" ] || continue
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    FILES+=("$ROOT/$f")
  done < <(cd "$ROOT" && git ls-files -- "$d" 2>/dev/null)
done
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "model-literal-lint: no files under ${SCAN_DIRS[*]} — nothing to scan" >&2
  exit 2
fi

# grep -F: every vocabulary entry is a literal string, never a pattern —
# claude-fable-5.1's dot must match a dot, not "any character".
RAW=$(grep -rnFf "$PATFILE" "${FILES[@]}" 2>/dev/null || true)

# One finding per file:line, even when several vocabulary entries hit the same
# line (a JSON "default" carrying one id, a comment mentioning two more) — the
# COUNT this lint pins is lines that need a role name, not string occurrences.
HITS=$(printf '%s\n' "$RAW" | awk -F: '
  { key = $1 ":" $2; if (key == "" || (key in seen)) next; seen[key] = 1; print }
' )
N=$(printf '%s\n' "$HITS" | grep -c . || true)

if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS"
fi
echo "model-literal-lint: $N model-id literal line(s) found under ${SCAN_DIRS[*]} (vocabulary: $(printf '%s\n' "$VOCAB" | wc -l | tr -d ' ') ids from catalog/model-prices.json + catalog/model-slugs.json)"

# ── bare aliases (BH-2535) ──────────────────────────────────────────────────
# A model ALIAS (`--model haiku`) is a hardcode the vocabulary above cannot see:
# no price catalog keys it. Only an alias in MODEL-ARGUMENT position counts —
# a bare-word scan hits case labels, `claude-(opus|...)` regex vocabularies and
# prose. The alias must end at a character that cannot continue a model id, so
# `--model sonnet-routed-xyz` and `claude-sonnet-5` are not alias hits.
ALIASES='haiku|sonnet|opus|fable'
END='([^A-Za-z0-9_.-]|$)'
ALIAS_RE="--model[= ]+['\"]?($ALIASES)$END|[A-Za-z0-9_]*model[A-Za-z0-9_]*['\"]?[[:space:]]*[:=][[:space:]]*['\"]?($ALIASES)$END|:-['\"]?($ALIASES)['\"]?\\}"
ALIAS_RAW=$(grep -inE -- "$ALIAS_RE" "${FILES[@]}" 2>/dev/null || true)
# path<TAB>reason, one per line. A missing file is an empty list, not an error:
# a scratch tree need not carry one.
ALIAS_ALLOW="$ROOT/tests/model-literal-alias-allowlist.txt"
ALLOW_PATHS=""
[ -r "$ALIAS_ALLOW" ] && ALLOW_PATHS=$(grep -vE '^[[:space:]]*(#|$)' "$ALIAS_ALLOW" | cut -f1)
NA=0; NE=0
declare -A HIT_PATH=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  rel="${line#"$ROOT"/}"
  path="${rel%%:*}"; HIT_PATH[$path]=1
  if grep -qxF -- "$path" <<<"$ALLOW_PATHS"; then
    echo "exempt: $rel"; NE=$((NE+1))
  else
    echo "$rel"; NA=$((NA+1))
  fi
done <<<"$ALIAS_RAW"
while IFS= read -r ap; do
  [ -n "$ap" ] || continue
  [ -n "${HIT_PATH[$ap]:-}" ] || echo "model-literal-lint: stale alias exemption $ap (no bare-alias hit left there; delete its line from tests/model-literal-alias-allowlist.txt)"
done <<<"$ALLOW_PATHS"
echo "model-literal-lint: $NA bare-alias line(s) found ($NE exempt)"

RC=0
if [ "$STRICT" = 1 ] && [ "$N" -gt 0 ]; then
  echo "model-literal-lint: $N literal line(s) found and the pin is 0 (BH-1510.4) — convert the call site to bin/lib/model-route.sh (model_for <role>), write \`<model id>\` in a comment, or move the value into the seed/price data if it genuinely belongs there" >&2
  RC=1
fi
if [ "$STRICT" = 1 ] && [ "$NA" -gt 0 ]; then
  echo "model-literal-lint: $NA bare-alias line(s) found and the pin is 0 (BH-2535) — resolve the model through bin/lib/model-route.sh (model_for <role>)" >&2
  RC=1
fi
exit "$RC"
