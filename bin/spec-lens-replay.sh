#!/bin/bash
# bin/spec-lens-replay.sh — BH-6485: replay the spec-trace review lens over
# merged PRs, with the spec lines their tickets should have carried.
#
#   spec-lens-replay.sh <manifest> <repo-clone> <out-dir> [--run] [--max N] [--project P]
#   spec-lens-replay.sh summary <out-dir>
#
# THE MANIFEST, one TSV row per merged PR (a `#` line or a `pr` header is
# skipped): pr, merge-sha, spec-values, cut-values, note. spec-values and
# cut-values are `;`-separated (`docs/prd.md#J01;docs/prd.md#J02`), `-` = none.
# A row with spec-values `-` is UNMAPPED: counted, never replayed.
#
# FOR EACH MAPPED ROW the script writes a scratch ticket (`Spec:` and `Cut:`
# lines), copies each spec file from <merge-sha>^1 into a scratch tree, renders
# st_review_note (bin/lib/spec-trace.sh) there, and adds the diff
# <merge-sha>^1..<merge-sha> (cut at SPEC_LENS_REPLAY_DIFF_MAX bytes, default
# 150000, and the prompt says so).
#
# WITHOUT --run nothing is spent: it prints each prompt's byte size and the row
# counts. WITH --run it calls `bin/agent-call.sh review <project> <model> 1200
# <out>/<pr>.md <prompt>` for at most --max rows (default 10). The model comes
# from bin/lib/review-model.sh, never a literal. Then st_judge reads the rows.
#
# DEDUP BEFORE SPEND. <out-dir>/ledger.tsv is keyed on sha256(merge-sha, spec
# values, cut values, REPLAY_NOTE_VERSION), checked BEFORE each call. A row is
# written only after agent-call rc 0 and an output file: `done`, or `empty`
# when the output has no SPEC-TRACE row (billed, terminal, never re-called).
# rc 74-79 is "not called, not billed": no row, the PR is named as skipped. Any
# other failure is named as failed, with no row.
#
# SUMMARY prints the rows by status, the BLOCK count (the gate's answer over
# the rows, whatever the model's verdict), and how often a Cut: token exempted
# a row (cut-exempt).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="${HARNESS:-$(cd "$SELF_DIR/.." && pwd)}"
# shellcheck source=bin/lib/spec-trace.sh
. "$SELF_DIR/lib/spec-trace.sh" || { echo "spec-lens-replay.sh: bin/lib/spec-trace.sh is missing" >&2; exit 2; }
# shellcheck source=bin/lib/verdict-parse.sh
. "$SELF_DIR/lib/verdict-parse.sh" || { echo "spec-lens-replay.sh: bin/lib/verdict-parse.sh is missing" >&2; exit 2; }
REPLAY_NOTE_VERSION=1
DIFF_MAX="${SPEC_LENS_REPLAY_DIFF_MAX:-150000}"
case "$DIFF_MAX" in ''|*[!0-9]*) DIFF_MAX=150000 ;; esac

summary() { # summary <out-dir>
  local led="$1/ledger.tsv"
  [ -r "$led" ] || { echo "spec-lens-replay: no ledger at $led"; return 1; }
  awk -F'\t' '
    !/^#/ && NF >= 12 {
      n++; if ($3 == "empty") e++
      d += $7; p += $8; m += $9; c += $10; x += $11
      if ($5 == "BLOCK") b++
      ce += $6; if ($6 > 0) cr++
      if ($4 == "BLOCK") mb++
    }
    END {
      printf "- replayed: %d\n- empty: %d\n", n, e
      printf "- rows: delivered=%d partial=%d missing=%d contradicts=%d cut=%d\n", d, p, m, c, x
      printf "- blocked: %d\n- model-blocked: %d\n- cut-exempt: %d (in %d PRs)\n", b, mb, ce, cr
    }' "$led"
}

if [ "${1:-}" = summary ]; then
  [ $# -ge 2 ] || { echo "usage: spec-lens-replay.sh summary <out-dir>" >&2; exit 2; }
  summary "$2"; exit $?
fi

[ $# -ge 3 ] || { sed -n '2,6p' "$0" >&2; exit 2; }
MANIFEST="$1" CLONE="$2" OUT="$3"; shift 3
RUN=0 MAX=10 PROJ=project-6-os
while [ $# -gt 0 ]; do
  case "$1" in
    --run) RUN=1 ;;
    --max) MAX="${2:-}"; shift ;;
    --project) PROJ="${2:-}"; shift ;;
    *) echo "spec-lens-replay.sh: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
case "$MAX" in ''|*[!0-9]*) echo "spec-lens-replay.sh: --max wants a whole number" >&2; exit 2 ;; esac
[ -r "$MANIFEST" ] || { echo "spec-lens-replay.sh: no manifest at $MANIFEST" >&2; exit 2; }
git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1 || { echo "spec-lens-replay.sh: $CLONE is not a git clone" >&2; exit 2; }
mkdir -p "$OUT" || exit 2
LED="$OUT/ledger.tsv"
[ -f "$LED" ] || printf '# fp\tpr\tstatus\tmodel_verdict\tgate\tcut_exempt\tdelivered\tpartial\tmissing\tcontradicts\tcut\treasons\n' > "$LED"

MODEL=""
if [ "$RUN" = 1 ]; then
  # shellcheck source=bin/lib/review-model.sh
  . "$SELF_DIR/lib/review-model.sh" 2>/dev/null
  MODEL=$(review_model "$HARNESS" "$PROJ" 2>/dev/null) || MODEL=""
  [ -n "$MODEL" ] || { echo "spec-lens-replay.sh: no review model route for $PROJ — nothing was called"; exit 0; }
fi

SCR=$(mktemp -d "${TMPDIR:-/tmp}/spec-lens-replay.XXXXXX") || exit 2
trap 'rm -rf "$SCR"' EXIT
rows=0 unmapped=0 calls=0 hits=0 skipped="" failed="" bytes=0
while IFS=$'\t' read -r pr sha specs cuts note; do
  case "$pr" in ''|'#'*|pr) continue ;; esac
  rows=$((rows + 1))
  if [ -z "${specs:-}" ] || [ "$specs" = - ]; then unmapped=$((unmapped + 1)); continue; fi
  [ "${cuts:-}" = - ] && cuts=""
  fp=$(printf '%s\t%s\t%s\t%s' "$sha" "$specs" "${cuts:-}" "$REPLAY_NOTE_VERSION" | sha256sum | awk '{print $1}')
  if grep -q "^$fp	" "$LED" 2>/dev/null; then hits=$((hits + 1)); continue; fi
  W="$SCR/$pr"; rm -rf "$W"; mkdir -p "$W/repo"
  printf 'Replay of #%s (%s)\n\nSpec: %s\n' "$pr" "${note:-}" "${specs//;/, }" > "$W/ticket.md"
  [ -n "${cuts:-}" ] && printf 'Cut: %s\n' "${cuts//;/, }" >> "$W/ticket.md"
  while IFS= read -r v; do
    p="${v%%#*}"
    case "$p" in /*|*..*) continue ;; esac
    mkdir -p "$W/repo/$(dirname "$p")"
    git -C "$CLONE" show "${sha}^1:$p" > "$W/repo/$p" 2>/dev/null || rm -f "$W/repo/$p"
  done < <(st_parse spec "$W/ticket.md")
  NOTE=$(st_review_note "$W/repo" "$W/ticket.md")
  # Written whole first, then cut: a short-circuiting reader on a git pipe
  # turns a true answer red under pipefail.
  git -C "$CLONE" diff "${sha}^1" "$sha" > "$W/diff" 2>/dev/null
  DIFF=$(head -c "$DIFF_MAX" "$W/diff")
  DCUT=""; [ "$(wc -c < "$W/diff")" -gt "$DIFF_MAX" ] && DCUT=" The diff below is cut at $DIFF_MAX bytes; judge the rest as not shown."
  PROMPT="SPEC LENS REPLAY (BH-6485). This is a replay of merged PR #$pr ($sha) of $PROJ, judged against the spec sections its ticket should have named. Do not edit any file. Your final answer is the review itself: the SPEC-TRACE rows, then the last line exactly 'VERDICT: APPROVE' or 'VERDICT: BLOCK'.
$NOTE
THE DIFF ($sha^1..$sha):$DCUT
$DIFF"
  bytes=$((bytes + ${#PROMPT}))
  if [ "$RUN" = 0 ]; then echo "would call #$pr: prompt ${#PROMPT} bytes"; continue; fi
  [ "$calls" -lt "$MAX" ] || continue
  calls=$((calls + 1))
  rm -f "$OUT/$pr.md"
  # The prompt carries a merged PR's diff (untrusted text) and the answer is
  # text only, so the call runs with no tools (BH-7276). A runner that cannot
  # honour that refuses with rc 78, which the case below counts as skipped.
  AGENT_CALL_NO_TOOLS=1 "$SELF_DIR/agent-call.sh" review "$PROJ" "$MODEL" 1200 "$OUT/$pr.md" "$PROMPT" </dev/null >/dev/null 2>&1; rc=$?
  case "$rc" in
    0) ;;
    7[4-9]) skipped="$skipped #$pr(rc $rc)"; continue ;;
    *) failed="$failed #$pr(rc $rc)"; continue ;;
  esac
  [ -s "$OUT/$pr.md" ] || { failed="$failed #$pr(no output)"; continue; }
  mv=$(verdict_parse -L "$OUT/$pr.md" 2>/dev/null) || mv=unknown
  J=$(ST_JUDGE_ROWS=1 st_judge "$OUT/$pr.md" "$W/repo" "$W/ticket.md")
  IFS=$'\t' read -r _ jd jp jm jc jx <<<"$(grep '^ROWS' <<<"$J")"
  IFS=$'\t' read -r gate ex reasons <<<"$(grep -v '^ROWS' <<<"$J" | tail -1)"
  st=done
  grep -qE '^[[:space:]]*([-*][[:space:]]+)?SPEC-TRACE:' "$OUT/$pr.md" || st=empty
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$fp" "$pr" "$st" "$mv" "${gate:-SKIP}" "${ex:-0}" \
    "${jd:-0}" "${jp:-0}" "${jm:-0}" "${jc:-0}" "${jx:-0}" "$(printf '%s' "${reasons:-}" | tr '\t\n' '  ' | cut -c1-600)" >> "$LED"
done < "$MANIFEST"
echo "spec-lens-replay: rows=$rows unmapped=$unmapped ledger-hits=$hits calls=$calls prompt-bytes=$bytes${skipped:+ skipped:$skipped}${failed:+ failed:$failed}"
[ "$RUN" = 1 ] && summary "$OUT"
exit 0
