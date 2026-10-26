# Attack-class notes for the security lens (BH-7911)

Doc: REVIEW-LEVELS

## What changed

The security lens (`SECURITY_PROMPT` in `bin/lib/rb/review.sh`) now gets the
attack-class notes for the surface of the diff. It gets at most two classes.

- `prompts/security-classes/<class>.md` holds seven class files from
  https://github.com/cloudflare/security-audit-skill at sha
  `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8` (MIT). The files are verbatim.
  `prompts/security-classes/PROVENANCE.md` gives the sha, the licence text and
  the bytes and git blob sha of each file.
- `catalog/security-classes.tsv` maps a diff to classes. The columns are
  `class<TAB>path-ERE<TAB>diff-ERE<TAB>note`. Matching is case-insensitive.
- `bin/lib/security-lens-classes.sh` has two functions:
  - `slc_check [<tsv>]` validates the table. A bad line is rc 2, and stderr
    names `<tsv>:<line>:`.
  - `slc_for_diff <diff-file> <planned-files-file>` prints
    `SLC_CLASSES: <c1>[ <c2>]` and then the class text. No match prints nothing.
- The security lens prompt also says: "This is the risky-file lens on this
  diff. Never ask for, and never perform, a whole-repo audit here; that is the
  scheduled security-audit lane."
- `prompts/iron-laws.d/20261021-security-audit.md` (stages `review lead-review`)
  and `rules/topics/16-security-audit.md` carry the SECURITY AUDIT rule. It
  includes the sentence "The lens receives the attack-class notes for the
  diff's surface; it does not widen its scope beyond the diff." The pilot
  ticket (#7910) had not merged, so this ticket created the fragment with both
  sentences. #7910 amends it.

## The classes and their triggers

The path-ERE reads the changed paths and the lines of `$BUILD/planned-files.txt`.
The diff-ERE reads the added and removed lines of the diff.

| class | path-ERE | diff-ERE |
|---|---|---|
| data-isolation | `prisma/`, `migrations/`, `rls` as a whole token, `tenant`, `company_id`, `withTenant` | `company_id`, `withTenant` |
| web-auth | `auth`, `middleware`, `api/`, `session`, `clerk`, `cookie`, `redirect` | - |
| ai-llm | `agents/`, `prompts/`, `tool`, `mcp`, `llm`, `anthropic` | - |
| cloud-deploy | `vercel.json`, `wrangler`, `workflows/`, `Dockerfile`, `fly.toml` | - |
| supply-chain | `package.json`, `*-lock.json`, `*-lock.yaml`, `*.lock`, `yarn.lock`, `postinstall` | `postinstall` |
| client-side | - | `dangerouslySetInnerHTML`, `innerHTML`, `postMessage` |
| resource-exhaustion | `cron`, `queue`, `webhook`, `loop` | - |

The ticket wrote `lock` and `rls` as bare words. Bare `lock` matches
`bin/blocked-resolver.sh` and bare `rls` matches `urls`. So the table uses the
lockfile forms and a whole-token `rls`.

## Caps

- The first two matching rows in file order win.
- `SECURITY_LENS_CLASS_MAX_BYTES` (env, default 24000) caps the class text. A
  non-numeric value or 0 uses the default. Over the cap, the text is cut and one
  line follows it:
  `[security-lens-classes: truncated at <cap> bytes, SECURITY_LENS_CLASS_MAX_BYTES]`.
  The two largest files (web-auth 12300 B, ai-llm 10617 B) fit under the default.

## What did not change

- Which PRs get the security lens: `RISKY`, the tier, `KIND_SKIP_SECLENS` and
  `LENSES` are not edited. KIND: copy with no risky file still gets no lens.
- The count of model calls. The block runs only when `security` is on the lens
  list, before the launch, in the parent shell.
- The security re-review prompt (`L_RE`) and the general and refuter prompts.

## Failure behaviour

pipeline.log gets one line per build that has the security lens:

- `SECURITY LENS CLASSES: <c1>[ <c2>]`: the prompt got the notes.
- `SECURITY LENS CLASSES: none`: no row matched. The prompt did not change.
- `security-lens-classes: off (lib missing)`: the box has no lib. The prompt
  did not change.
- `security-lens-classes: off (rc <n>: <first stderr line>)`: a bad table or an
  unreadable diff. The prompt did not change.

The block never writes a RESULT, never exits and never alerts.

## How to update the vendored files

1. Pick the new upstream sha.
2. Clone the upstream repo and check out that sha.
3. Copy the seven class files with `cp`. Do not edit them.
4. Update the sha, the date, the bytes and the git blob sha (`git hash-object <file>`) in `PROVENANCE.md`.
5. Run `tests/security-lens-classes.bh-7911-test.sh`.
