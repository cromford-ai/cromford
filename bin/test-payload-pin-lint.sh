#!/bin/bash
# bin/test-payload-pin-lint.sh [--base <ref>] [--all] [--strict] [root]
#
# The whole-payload pin lint (BH-5792): added test-file lines that compare a
# whole JSON document, so the test breaks the day another ticket adds an
# unrelated key.
#
# WHY: #4126. tests/utilization-tickets.bh-3988-test.sh pinned whole payloads
# ('{"ready":null,"blocked":null,...}' and the full basis object). When main
# (BH-4010) added `pauses` and `prs` keys, T1, T5 and T6 went red, and the fix
# cost a round and a new review. The rule: assert the fields the feature owns.
# A whole-output pin belongs only in a contract test (`*.contract.test.*`, or
# a `# contract-test` / `// contract-test` header line).
#
#   --base <ref>  judge the lines added since the merge-base of <ref> and HEAD,
#                 working-tree edits included (default: origin/main).
#   --all         judge every line of every selected file (an inventory; no git).
#   --strict      findings are errors (rc 1), whatever the conf mode says.
#   root          the checkout to scan (default: the current directory).
#   stdout        one finding per line: `<path>:<line>: payload-pin: <rule>: <hint>`;
#                 with GITHUB_ACTIONS=true also `::warning file=..,line=..::...`
#                 (`::error` in error mode), at most `opt warn_show` of them.
#   stderr        one summary line: files scanned, findings, mode, conf.
#   rc 0 clean, or findings in warn mode (the shipped default)
#   rc 1 findings in error mode (`mode error` in the conf, or --strict)
#   rc 2 bad args, no conf, no rule line, not a git work tree, or unresolvable base
#
# WHAT IT FLAGS (the rule lines of the conf):
#   jq-sort-whole       `jq -S .` (any -S flag cluster) over the identity filter
#   deep-equal-whole    assert.deep[Strict]Equal(<x>, { / expect(<x>).to[Strict]Equal({
#                       where <x> is a bare name, `await <y>.json()` or JSON.parse(...)
#   json-literal-whole  a shell assertion against a '{"..."}' literal of min_keys+ keys
# WHAT MAKES IT QUIET:
#   - a contract test: the path matches `contract_name`, or one of the first
#     `header_lines` lines of the file (working tree) matches `contract_header`
#   - a field-level compare (body.accounts, '.payload.ready', '[.ready]')
#   - a non-test file, and in diff mode a line that was already there
#
# BLIND SPOTS (a line lint):
#   - the whole payload reaching the compare through a variable on another line
#   - a deep-equal whose expected value is a variable, not an object literal
#   - a call split before the `{` (`assert.deepEqual(body,` then `{` next line)
#
# Patterns, thresholds and the mode live in catalog/payload-pin-lint.conf:
#   $PAYLOAD_PIN_LINT_CONF > $HARNESS/flags/payload-pin-lint.conf
#   > <checkout>/catalog/payload-pin-lint.conf > $HARNESS/catalog/payload-pin-lint.conf
# Which files are test files (`file`, `skip`) comes from
# catalog/determinism-lint.conf, resolved the same way with $DETERMINISM_LINT_CONF.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$(cd "$SELF_DIR/.." && pwd)"

die2() { echo "test-payload-pin-lint: $*" >&2; exit 2; }

BASE=origin/main; ALL=0; STRICT=0; ROOT_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    --base) [ $# -ge 2 ] && [ -n "$2" ] || die2 "--base needs a ref"; BASE=$2; shift 2 ;;
    --all) ALL=1; shift ;;
    --strict) STRICT=1; shift ;;
    -*) die2 "unexpected argument $1" ;;
    *)
      [ -z "$ROOT_ARG" ] || die2 "unexpected argument $1"
      [ -d "$1" ] || die2 "root $1 is not a directory"
      ROOT_ARG=$1; shift ;;
  esac
done
ROOT=$(cd "${ROOT_ARG:-.}" && pwd) || die2 "cannot enter root ${ROOT_ARG:-.}"

# ── the confs, or nothing ────────────────────────────────────────────────────
CONF=""
for C in "${PAYLOAD_PIN_LINT_CONF:-}" "$H/flags/payload-pin-lint.conf" \
         "$CHECKOUT/catalog/payload-pin-lint.conf" "$H/catalog/payload-pin-lint.conf"; do
  [ -n "$C" ] && [ -r "$C" ] && { CONF="$C"; break; }
done
[ -n "$CONF" ] || die2 "no conf found (tried \$PAYLOAD_PIN_LINT_CONF, $H/flags/payload-pin-lint.conf, $CHECKOUT/catalog/payload-pin-lint.conf, $H/catalog/payload-pin-lint.conf); refusing to scan for nothing and report green"
DCONF=""
for C in "${DETERMINISM_LINT_CONF:-}" "$H/flags/determinism-lint.conf" \
         "$CHECKOUT/catalog/determinism-lint.conf" "$H/catalog/determinism-lint.conf"; do
  [ -n "$C" ] && [ -r "$C" ] && { DCONF="$C"; break; }
done
[ -n "$DCONF" ] || die2 "no determinism-lint.conf found for the file selectors"

# rest <word1> [word2]: the rest of each line that starts with those words, spaces kept.
rest() {
  awk -v a="$1" -v b="${2:-}" '$1 == a && (b == "" || $2 == b) {
    sub(/^[ \t]*[^ \t]+[ \t]+/, ""); if (b != "") sub(/^[^ \t]+[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print }' "$CONF"
}
MODE=$(rest mode | tail -n 1)
case "$MODE" in
  warn|error) ;;
  *) echo "test-payload-pin-lint: unknown mode '$MODE' in $CONF; reading it as warn" >&2; MODE=warn ;;
esac
[ "$STRICT" -eq 1 ] && MODE=error
MIN_KEYS=$(rest opt min_keys | tail -n 1); HEADER_LINES=$(rest opt header_lines | tail -n 1)
WARN_SHOW=$(rest opt warn_show | tail -n 1)
[[ $MIN_KEYS =~ ^[0-9]+$ ]] || die2 "$CONF: opt min_keys '$MIN_KEYS' is not a number"
[[ $HEADER_LINES =~ ^[0-9]+$ ]] || die2 "$CONF: opt header_lines '$HEADER_LINES' is not a number"
[[ $WARN_SHOW =~ ^[0-9]+$ ]] || die2 "$CONF: opt warn_show '$WARN_SHOW' is not a number"
CNAME=$(rest contract_name | tail -n 1); CHEAD=$(rest contract_header | tail -n 1)
[ -n "$CNAME" ] && [ -n "$CHEAD" ] || die2 "$CONF needs a contract_name and a contract_header line"

FILE_RE=$(awk '$1=="file"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$DCONF")
SKIP_RE=$(awk '$1=="skip"{ $1=""; sub(/^[ \t]+/,""); printf "%s%s", (n++?"|":""), $0 }' "$DCONF")
[ -n "$FILE_RE" ] || die2 "$DCONF has no 'file' selectors"

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
# The rule table: <rule|keys|hint><TAB><id><TAB><text>
awk '$1 == "rule" || $1 == "keys" || $1 == "hint" {
  k = $1; id = $2; sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, ""); sub(/[ \t\r]+$/, "")
  if ($0 != "") print k "\t" id "\t" $0 }' "$CONF" > "$TMP/rules"
grep -q '^rule	' "$TMP/rules" || die2 "$CONF has no 'rule' line; refusing to scan for nothing and report green"

# select: paths on stdin -> the test files among them
select_files() {
  grep -E "$FILE_RE" | { if [ -n "$SKIP_RE" ]; then grep -vE "$SKIP_RE"; else cat; fi; }
}

# ── the line set: path<TAB>line<TAB>text ─────────────────────────────────────
: > "$TMP/lines"; : > "$TMP/files"
if [ "$ALL" -eq 1 ]; then
  find "$ROOT" \( -name .git -o -name node_modules -o -name dist -o -name .wrangler \) -prune -o -type f -print \
    | sed "s|^$ROOT/||" | select_files | sort -u > "$TMP/files"
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    awk -v P="$F" '{ print P "\t" FNR "\t" $0 }' "$ROOT/$F" >> "$TMP/lines"
  done < "$TMP/files"
else
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die2 "$ROOT is not a git work tree (use --all to scan without git)"
  ROOT=$(git -C "$ROOT" rev-parse --show-toplevel) || die2 "cannot find the top of $ROOT"
  git -C "$ROOT" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || die2 "cannot resolve base $BASE"
  FORK=$(git -C "$ROOT" merge-base "$BASE" HEAD 2>/dev/null)
  [ -n "$FORK" ] || die2 "no merge-base between $BASE and HEAD (shallow clone?)"
  git -C "$ROOT" -c core.quotepath=off diff --name-only --diff-filter=AMR "$FORK" -- > "$TMP/changed" \
    || die2 "git diff against $FORK failed"
  select_files < "$TMP/changed" | sort -u > "$TMP/files"
  if [ -s "$TMP/files" ]; then
    mapfile -t FILES < "$TMP/files"
    git -C "$ROOT" -c core.quotepath=off diff -U0 -M --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
      "$FORK" -- "${FILES[@]}" > "$TMP/diff" || die2 "git diff -U0 against $FORK failed"
    # A `+++ b/<path>` is a header only between `diff --git` and the first
    # `@@`; inside a hunk the same bytes are an added line that begins `++ `.
    awk '
      /^diff --git / { hdr = 1; f = ""; next }
      hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
      /^@@ / { hdr = 0; split($3, a, ","); n = substr(a[1], 2) + 0; next }
      !hdr && /^\+/ { if (f != "") print f "\t" n "\t" substr($0, 2); n++ }
    ' "$TMP/diff" > "$TMP/lines"
  fi
fi
NFILES=$(grep -c . "$TMP/files")

# ── the contract tests: decided once per file, from the working tree ────────
: > "$TMP/contract"
cut -f1 "$TMP/lines" | sort -u > "$TMP/judged"
while IFS= read -r F; do
  [ -n "$F" ] || continue
  if grep -qE "$CNAME" <<<"$F" \
     || { [ -f "$ROOT/$F" ] && head -n "$HEADER_LINES" "$ROOT/$F" | grep -qE "$CHEAD"; }; then
    printf '%s\n' "$F" >> "$TMP/contract"
  fi
done < "$TMP/judged"

# ── the judgement ────────────────────────────────────────────────────────────
# Regexes come from a file, not -v, so awk does no escape processing on them.
# One finding per line: the first rule (conf order) that matches.
awk -F'\t' -v MIN="$MIN_KEYS" '
  FILENAME == ARGV[1] { contract[$0] = 1; next }
  FILENAME == ARGV[2] {
    if ($1 == "rule") { nr++; rid[nr] = $2; rre[nr] = $3 }
    else if ($1 == "keys") kre[$2] = $3
    else if ($1 == "hint") hint[$2] = $3
    next
  }
  {
    path = $1; line = $2
    text = $0; sub(/^[^\t]*\t[^\t]*\t/, "", text)
    if (path in contract) next
    for (i = 1; i <= nr; i++) {
      if (text !~ rre[i]) continue
      id = rid[i]
      if (id in kre) {
        if (!match(text, kre[id])) continue
        span = substr(text, RSTART, RLENGTH); k = 0
        while ((p = index(span, "\":")) > 0) { k++; span = substr(span, p + 2) }
        if (k < MIN) continue
      }
      h = (id in hint) ? hint[id] : "a whole-payload compare"
      printf "%s:%s: payload-pin: %s: %s\n", path, line, id, h
      break
    }
  }
' "$TMP/contract" "$TMP/rules" "$TMP/lines" > "$TMP/out"
RC=$?
[ "$RC" -eq 0 ] || die2 "the judging awk failed (rc $RC)"
N=$(grep -c . "$TMP/out")
cat "$TMP/out"

# ── GitHub annotations ───────────────────────────────────────────────────────
if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ "$N" -gt 0 ]; then
  LEVEL=warning; [ "$MODE" = error ] && LEVEL=error
  head -n "$WARN_SHOW" "$TMP/out" | awk -v L="$LEVEL" '
    function esc(s) { gsub(/%/, "%25", s); gsub(/\r/, "%0D", s); gsub(/\n/, "%0A", s); return s }
    function prop(s) { s = esc(s); gsub(/:/, "%3A", s); gsub(/,/, "%2C", s); return s }
    {
      i = index($0, ": payload-pin: "); loc = substr($0, 1, i - 1); msg = substr($0, i + 15)
      n = loc; sub(/^.*:/, "", n); f = substr(loc, 1, length(loc) - length(n) - 1)
      r = msg; sub(/: .*$/, "", r); m = substr(msg, length(r) + 3)
      printf "::%s file=%s,line=%s::payload-pin %s: %s\n", L, prop(f), n, esc(r), esc(m)
    }'
  [ "$N" -gt "$WARN_SHOW" ] && echo "::notice::payload-pin: $((N - WARN_SHOW)) more finding(s) in the log, past warn_show $WARN_SHOW"
fi

echo "test-payload-pin-lint: $NFILES files scanned, $N findings (mode $MODE, conf $CONF)" >&2
[ "$N" -gt 0 ] && [ "$MODE" = error ] && exit 1
exit 0
