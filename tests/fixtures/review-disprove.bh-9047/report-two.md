Summary: the patch changes bin/a.sh.

## Findings

- [BLOCK wrong-data] bin/a.sh:12: line 12 drops the name when the input is empty
- [BLOCK core-flow-broken] bin/a.sh:4-5: the flag parse exits before the main call
- [NOTE] bin/a.sh:30: a comment says "lines" for one line

VERDICT: BLOCK
