#!/bin/sh
# BH-7713 fixture: a stand-in for bin/lead-verdict.sh in the end-to-end cases
# of mcp/test/review-verdict.test.mjs. It appends {"lv":[argv...]} as one
# JSON line to $FAKE_LOG and exits 0. The argv holds no quote character.
sep=''
line='{"lv":['
for a in "$@"; do line="$line$sep\"$a\""; sep=','; done
printf '%s]}\n' "$line" >>"$FAKE_LOG"
echo "lead-verdict: recorded"
