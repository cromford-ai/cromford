# Tier 2 pays for a remediation payload once (BH-1038)

Doc: ALERT-REMEDIATION

**What changed.** `bin/remediate-agent.sh` gained a persisted per-payload spend
guard around its one model call. Nothing else moved: the pilot flag, the kill
switch, the daily cap, the evidence rule, the verdict handling and the fail-open
contract are byte-for-byte what they were, and `bin/beat.sh` and
`bin/agent-call.sh` are untouched.

- **The key is the model's input, not the alert.**
  `sha256(akey + "\n" + line + "\n" + jq -cS payload)`, first 32 hex characters.
  `jq -cS` canonicalises key order, so the same facts in a different order are
  one spend; a payload that is not JSON falls back to its raw text. A changed
  alert line is a different question and gets its own call — the dedup never
  widens to akey-only, which is the 6h throttle's job and lives in `beat.sh`.
- **The ledger** is `state/remediation-payload-dedup.tsv`:
  `last_ts, fingerprint, attempts, outcome, sanitised akey`, `outcome ∈
  {pending, ok, empty, failed}`. Writes are an awk rewrite plus `mv -f` under
  `flock -w 5` on a sidecar lock — a millisecond critical section, released long
  before the model call, never a queue. Rows older than twice the window are
  pruned on every write. The name deliberately escapes the
  `remediation-agent-*.count*` glob the daily cap's cleanup deletes.
- **Three touch points, in this order.** A read-only lookup BEFORE the daily-cap
  claim (so a storm of one identical payload costs no cap slot); the claim
  (`attempts+1`, `pending`) under the lock immediately before `agent-call.sh`,
  which re-reads the verdict to close the race between two identical runs; and
  the settle immediately after `AC_RC` is known, before any exit path.
- **The three outcomes.** `AC_RC != 0` → `failed` (124/137 included). rc 0 with
  no `VERDICT:` line → `empty`. Otherwise `ok`. Inside the window `ok` and
  `empty` are terminal on the first answer; `failed`/`pending` retry to a cap of
  3. Knobs: `REMEDIATE_DEDUP_WINDOW` (86400) and `REMEDIATE_DEDUP_CAP` (3),
  numeric-guarded the same way `REMEDIATE_DAILY_CAP` is — garbage or zero falls
  back to the default, never to unlimited.

**Why an empty answer is terminal.** It is the outcome that looks free and is
not. The model ran, the tokens were billed, and the transcript held nothing a
verdict could be read from. Asking the identical question again buys the
identical nothing, so `empty` settles like `ok` and not like `failed`.

**Why a hit still pages.** A hit exits 1 — fail open, with one plain line of
diagnosis that `beat.sh` appends to the alert. Replaying the cached
REMEDIATED/TERMINAL verdict as a suppression was the other available reading of
the ticket, and it is the one the evidence rule already forbids: a suppression
has to quote a check that was re-run, and a check from 23 hours ago is not that.
This guard can only ever refuse to spend; it can never lose an alert.

**Why a marker that will not persist means no call.** If the ledger path is
unwritable or the lock is not taken in 5s, the run refuses the call and logs
`FAILOPEN-dedup`, the same shape the daily cap's failed claim already uses. An
unrecorded spend is precisely the spend this guard cannot bound. A failure on
the other side — the call happened, the outcome write failed — logs one
`dedup-settle` line and leaves the row `pending`, which the verdict rule already
counts as a spent failed attempt. One wasted retry, never a lost page.

**What it touches.**

- State: NEW `state/remediation-payload-dedup.tsv` (+ `.lock`, `.tmp`). Nothing
  else reads it.
- Knobs: NEW `REMEDIATE_DEDUP_WINDOW`, `REMEDIATE_DEDUP_CAP`. Neither is added
  to `env-templates/global.env.example`, matching `REMEDIATE_DAILY_CAP`, which
  is also documented only in `docs/ALERT-REMEDIATION.md`. No new env var needs
  setting anywhere for the shipped defaults to be correct.
- Log lines: NEW verdict labels `FAILOPEN-dedup` (keeps the `FAILOPEN` prefix,
  so `grep FAILOPEN` still means "this alert paged") and `dedup-settle`.
- New hard requirement: `sha256sum` on PATH, checked next to the existing
  `python3` and `jq` checks. Without it there is no fingerprint, and a constant
  fingerprint would dedup every payload against every other one, so the run
  refuses rather than guesses.

**What it does not catch.** `lane-alert.sh` akeys embed a minute stamp
(`orclane:$L:YYYYMMDDHHMM`), so those fingerprints differ every minute and this
guard never sees a repeat. Correct and conservative: the guard exists to stop
paying twice for an identical question, not to widen the akey throttle.

**Tests.** `tests/remediate-agent-dedup-test.sh` (new): the same payload twice →
one call; a failed call retried to the cap then terminal; an empty result
terminal; a timeout is a failed attempt and retryable; same akey with a different
line or a different payload project → two calls; the window boundary in both
directions; the marker is present and `pending` in the ledger the stub agent
copies AT call time; an unwritable ledger → zero calls; and the whole thing once
more through `bin/beat.sh` with the 6h throttle backdated, where the deduped
alert still lands in the quarantine file with the diagnosis attached.
`tests/remediator-agent-test.sh` gained ONE line in `reset()` removing the new
ledger — it fires one identical payload across most of its sections, and without
that line ten of its assertions go red on the new guard rather than on tier 2.
No existing assertion changed.
