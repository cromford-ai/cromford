## Findings

- [BLOCK wrong-data] bin/a.sh:12: x
- [BLOCK secret] bin/a.sh:3: x
- [BLOCK] bin/a.sh:3: x
- [BLOCK needs-human] bin/a.sh:3: x
- [BLOCK split-required] x
- [BLOCK red-build] bin/a.sh:3: x
- [BLOCK wrong-data] break-it: tests/x failed 1 of 3
- [BLOCK wrong-data] the whole flow is wrong
  - [BLOCK wrong-data] bin/a.sh:3: nested
```text
- [BLOCK x] a:1
```
- [NOTE unchanged-since abc123] bin/a.sh:3
- [BLOCK model-id] `bin/a.sh:7`: a backticked location
- [BLOCK wrong-data] bin/a.sh:0: line zero

VERDICT: BLOCK
