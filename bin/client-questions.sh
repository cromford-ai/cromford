#!/bin/bash
# bin/client-questions.sh — check or render the client-questions block of a
# plan.md (the format: bin/lib/client-questions.sh). The board sweeps run it
# on a PLAN_BLOCKED result and post its output as the questions
# (prompts/TEMPLATE.md, the client-questions rule block).
#
#   bin/client-questions.sh check <plan.md>    rc 0 the block is valid, silent
#   bin/client-questions.sh render <plan.md>   rc 0, prints the four-part questions
#
#   rc 3 the plan has no client-questions block
#   rc 5 refused: a question has no recommended answer, reasons or default, the
#        block does not parse, or no scrubber ("client-questions: <reason>" on stderr)
#   rc 2 usage
. "$(dirname "$0")/lib/client-questions.sh" || exit 1
HARNESS="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
export HARNESS

usage() { echo "usage: client-questions.sh check|render <plan.md>" >&2; exit 2; }
[ "$#" = 2 ] || usage
case "$1" in
  check)  fn=cq_check ;;
  render) fn=cq_render ;;
  *) usage ;;
esac
err=$(mktemp "${TMPDIR:-/tmp}/client-questions.XXXXXX") || { echo "client-questions: no temp file" >&2; exit 5; }
"$fn" "$2" 2>"$err"; rc=$?
[ "$rc" = 5 ] && [ -s "$err" ] && sed 's/^/client-questions: /' "$err" >&2
rm -f "$err"
exit "$rc"
