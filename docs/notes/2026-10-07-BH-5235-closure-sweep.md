# Closure lint sees edited hand lists; a sweep converts old ones (BH-5263, BH-5235.3)

Doc: tests/README.md

## What changed

- `lint()` in `tests/lib/scratch-closure-lint.sh` has a new-line rule. Before,
  it looked only at suites whose hand-copy count went up. An edit that added
  `deployment.sh` to an existing `cp` line kept the count, and the lint did not
  see it. Now each changed suite is also checked line by line:
  `new_hand_lines <base> <head>` prints each head hand-copy line whose
  whitespace-trimmed text has no unused match in the base (a multiset). A new
  suite has no base, so every hand line in it is new. Each such line is red:
  `<rel>:<n>: new or edited hand-copied bin/lib list: use scratch_install_closure <script> <dest>, ...`.
- A delete, a verbatim move, a re-indent and an edit to another line stay green.
  The allow marker and the BH-4632 grace apply to both rules. The count rule,
  its message and `hand_copy_lines` did not change. When the count went up, the
  count rule's lines print as before and cover the new lines too.
- `bin/closure-sweep.sh` is a new dev tool, with no cron line. It reads the
  lint's own `hand_copy_lines`, so a hand line means the same thing to both.

## The sweep's verdicts

First match wins. The full table is in the script header.

| verdict | when |
|---|---|
| `skip:allow` | the suite has `# scratch-closure-allow: <reason>` |
| `skip:no-hand` | no hand line |
| `skip:partial` | `rm -f ...bin/lib/`; `half-synced` or `$T/mut` on a code line; `missing` or `absent` on a code line that also names `bin/lib` |
| `skip:shape` | a hand line is in a `for` loop, copies from anything but `"$DIR/bin/lib/..."`, is chained (`&&`, `\|\|`, `;`; one trailing `\|\| exit N` is allowed), is or continues a `\` line, or the hand lines name more than one dest root |
| `skip:no-target` | no `"$DIR/bin/<x>.sh"` is copied into that dest root |
| `skip:closure-error` | `scratch_closure_list` failed for a target |
| `skip:not-in-closure:<libs>` | a hand-copied lib is outside the targets' closure |
| `skip:no-scratch` | the suite does not source `lib/scratch.sh` |
| `rewrite` / `rewritten` / `reverted:<b>/<a>` | dry run / proven / proof failed and bytes restored |

The ticket's partial-sync rule matched `missing` or `absent` on any code line.
On the 40 wave-1 candidates that marked 21 suites partial, many only on lines
like `echo "jq missing — skipping"`, and left no suite to rewrite. The tool now
needs `bin/lib` on the same line for those two words, and 7 suites stay
partial. The before/after proof still stops a rewrite that changes
what a suite sees.

## The `--apply` proof

For a `rewrite` suite the tool runs
`(cd <root> && HARNESS_TEST_SANDBOX=1 timeout $CS_TIMEOUT_S bash <suite>)` once.
If that is red, the suite is `reverted:<rc>/-` and not edited. Else it deletes
the hand lines, puts one line per target script at the first one's place:
`scratch_install_closure <u> "<root>" >/dev/null || { echo "FAIL: closure <u>"; exit 1; }`,
and runs the suite again. It reports `rewritten` only when both runs exit 0
and their summary lines (`N passed`, `N failed` and kin) are the same. Else it
copies the saved bytes back and reports `reverted`. `CS_TIMEOUT_S` defaults to
900. The tool makes no git writes.

## Wave 1 and what is left

Wave 1 was the 40 suites that name `deployment.sh`, `tier2-autoenqueue.sh` or
`autoenqueue.sh`, minus the suites other BH-5235 children own. The sweep
rewrote 2 of them: `tests/cost-reconcile-openrouter.bh-4000-test.sh` and
`tests/fork-defaults.bh-1957-test.sh`. The tree's `hand_copy_lines` total went
from 2,099 to 2,095.

A dry run over every suite that still has a hand line (897 suites) gave:

| verdict | suites |
|---|---|
| `skip:shape` | 481 (chained 246, continued 121, for loop 65, non-`$DIR` source 18, more than one dest root 18, dest not a bin/lib dir 13) |
| `skip:partial` | 144 |
| `skip:no-target` | 117 |
| `rewrite` | 98 |
| `skip:not-in-closure` | 46 |
| `skip:allow` | 11 |

The 98 `rewrite` suites are the next wave. Each still needs its `--apply`
proof. The chained and continued shapes are the largest group the tool cannot
yet take.
