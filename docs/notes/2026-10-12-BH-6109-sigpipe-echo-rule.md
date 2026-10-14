# 2026-10-12 — BH-6109: race-sigpipe-echo, a printf/echo pipe into grep -q or head

Doc: TEST-DETERMINISM

## What changed

**1. A new determinism-lint rule, `race-sigpipe-echo`, at `error`.** It flags a
`printf` or `echo` pipe into a short-circuiting consumer: `grep` with `-q`,
`-m`, `--quiet`, `--silent` or `--max-count`, or `head`. The consumer
alternation is `race-sigpipe`'s, byte for byte. The rule is in
`catalog/determinism-lint.conf`, and its message is in
`bin/test-determinism-lint.sh`.

**2. Every test-file hit is swept.** On this branch the rule found 564 lines in
193 test files. Each one is now a here-string (`grep -q y <<<"$X"`), a process
substitution (`grep -q y < <(printf …)`), or a waiver with a reason.

**3. The first 16 bin/ files are swept.** They held 31 hit lines. The rule does
not scan bin/ yet, so this is a head start for the bin/ sweep, not a ratchet.

## Why

`printf '%s\n' "$X" | grep -q y` under `set -o pipefail` reads a TRUE match as a
miss when `$X` is bigger than one pipe buffer. grep -q exits at the first match.
printf takes SIGPIPE on the rest and exits 141. pipefail gives the pipeline 141.
This is not a coin flip: with ~800 KB in `$X` and the match on line 1, it is a
miss on every run. `tests/llm-call-ratchet-test.sh` hit it (PR #6108).
`race-sigpipe` names only a `git` producer, so no rule caught it.

## Why a new rule and not a wider `race-sigpipe`

- Every existing `race-sigpipe` waiver keeps the meaning it had.
- A later slice can add a bin/ `scope` line for this rule alone.
- The message can name the here-string fix for a variable.

## The ratchet

The rule is `error`, and CI runs the lint on the full tree. A new test-file hit
turns the PR's lint step red. The lever, if a box needs one, is the settings row
`conf.determinism-lint.rule.race-sigpipe-echo` with severity `warn`.

bin/ is not in the rule's scope. Slices C1–C5 sweep the bin/ files in batches.
Slice C6 sweeps the last batch and adds `scope race-sigpipe-echo
(^|/)bin/.*\.sh$` next to `race-sigpipe`'s scope line. C6 must come last,
because that line turns the lint red while any bin/ hit is left.

## The recipe (for every slice)

1. List the hits. For bin/, copy the conf, append the bin/ scope line, and run
   the lint on the slice's files only:
   `DETERMINISM_LINT_CONF=/tmp/scope.conf bin/test-determinism-lint.sh <files> | grep -E '^[^ ].*: race-sigpipe-echo:' | cut -d: -f1,2 > /tmp/findings.txt`
2. Run the rewrite script below on that list:
   `python3 -I /tmp/sweep.py . /tmp/findings.txt /tmp/manual.txt`. Keep the
   script outside the repo; it is a build tool.
3. Fix each line of the manual list by hand, with rules R1–R3.
4. Run `bash -n` on every touched file. The script only rewrites the shape on
   one physical line, and a waiver comment after a trailing `\` breaks the
   continuation.
5. Run the lint again with the scope conf, and run every suite that reads a
   touched file (`bin/test-impact.sh select`).

### Rules for the manual list

- **R1.** The default is `CONSUMER <<<"$V"`. Use `CONSUMER <<<"$(PRODUCER)"`
  for a multi-argument printf (`printf '%s\n%s\n' "$A" "$B"`), for an unquoted
  `echo $V` (a here-string of `"$V"` would not word-split the way the echo
  did), and for a non-printf producer the regex caught through a quoted `echo`
  (`client 1 up '…; echo "rc=$?"' | grep -qx 'rc=0'`).
- **R2.** Keep the bytes exact with `CONSUMER < <(PRODUCER)` in two cases.
  (a) The producer writes no trailing newline (`printf '%s'`, `echo -n`) AND the
  consumer is `-v`, or its pattern can match an empty line. An empty `V` gives
  zero lines to the pipe but one empty line to a here-string. (b) A `head -c N`
  or `head -N | tr '\n' …` whose output is not stripped by a `$(…)`. A
  here-string adds a newline. A process substitution's exit status never
  reaches the consumer's status, so SIGPIPE cannot turn a match into a miss.
- **R3.** Waive, never rewrite, when the hit is not a pipe the shell runs: a
  grep or sed pattern that contains the shape, a `printf` that writes a stub
  whose own pipe is the hit, or lint-suite fixture data. Use
  `# determinism: ok race-sigpipe-echo <reason>` on the reported line, or the
  file's existing `ok-file` list.
- Keep `!`, `&&`/`||` chains, trailing `\` continuations and `2>/dev/null`
  where they were.

### The rewrite script

It rewrites only `printf FMT "$V" | CONSUMER` and `echo "$V" | CONSUMER`, where
FMT is `'%s\n'`, `'%s'`, `"%s\n"`, `"%s"` or `%s`, and V is `$X`, `${X}`,
`${X:-d}`, `$1` or a `$(…)` with no pipe inside. The result is
`CONSUMER <<<"$V"`. It sends a no-newline format with `-v` or `head -c` to the
manual list. The backslash is excluded from ARG on purpose: without that, the
script takes a trailing `\` into the consumer and breaks `bash -n`.

```python
import re, sys
root, ff, manout = sys.argv[1], sys.argv[2], sys.argv[3]
VAR = r'"(?:\$\{?[A-Za-z_0-9][A-Za-z_0-9]*(?::-[^}"]*)?\}?|\$\([^()|"]*\))"'
FMT = r"(?:'%s\\n'|'%s'|\"%s\\n\"|\"%s\"|%s)"
ARG = r"(?:[^|;&)'\"\s\\]|'[^']*'|\"[^\"]*\")+"
PROD = r"(?P<prod>printf[ \t]+(?P<fmt>" + FMT + r")[ \t]+(?P<v1>" + VAR + r")|echo[ \t]+(?P<v2>" + VAR + r"))"
CONS = r"(?P<cons>(?:grep|head)(?:[ \t]+" + ARG + r")+)"
PAT = re.compile(PROD + r"[ \t]*\|[ \t]*" + CONS + r"(?=[ \t]*(?:\|\||&&|;|\||\)|$|[ \t]#|[ \t]*\\$))")
byfile, man = {}, []
for l in open(ff):
    p, n = l.rstrip('\n').rsplit(':', 1); byfile.setdefault(p, set()).add(int(n))
for p, ns in byfile.items():
    fp = root + '/' + p; L = open(fp).read().split('\n')
    for n in sorted(ns):
        s = L[n-1]
        def rep(m):
            v = m.group('v1') or m.group('v2'); c = m.group('cons')
            nonl = (m.group('fmt') or '') in ("'%s'", '"%s"', '%s')
            if nonl and (re.search(r'(^|\s)-[A-Za-z]*v', c) or 'head -c' in c): raise ValueError
            return c + ' <<<' + v
        try: t, k = PAT.subn(rep, s)
        except ValueError: k = 0
        if k: L[n-1] = t
        else: man.append(f"{p}:{n}: {s.strip()}")
    open(fp, 'w').write('\n'.join(L))
open(manout, 'w').write('\n'.join(man) + '\n')
print("manual", len(man))
```

## What C0 found

- 564 test-file lines in 193 files, and 31 lines in the 16 C0 bin/ files.
- The script rewrote 540 lines. 55 lines went to the manual list.
- The manual list: 48 lines took R1 or R2, and 5 lines took an R3 waiver
  (`tests/ready-queue-rows-test.sh` ×2, `tests/size-gate-test.sh`,
  `tests/test-tiers-quarantine.bh-3686-test.sh`, `tests/tracker-port.bh-4075-test.sh`).
  The bh-1818 lint suite's fixtures (3 lines) are data, so that file's `ok-file`
  list names the rule. The script's one rewrite there (case E) was reverted.
- `tests/test-determinism-lint.bh-1261-test.sh` carries the shape in four
  fixture lines whose subject is `branch-arm-ungated`. They now read
  `if grep -q '^worker/' <<<"$CHANGED"; then`, and the case tests the same rule.
