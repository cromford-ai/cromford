# Account cooldowns are keyed by vendor now, and there is a lever to clear one

Doc: ACCOUNT-ROUTING

**What broke.** On 2026-09-18 the codex `default` account ran out of usage
credits. `bin/agent-call.sh` stamped `state/quota/cooldown/default` and
`bin/account-pick.sh` read `state/quota/cooldown/default` for every vendor, so
the box's perfectly healthy **claude** `default` credentials were refused for the
whole 6-hour window: every claude pick exited 2, every lane logged `no_headroom`
and descended, and `state/quota/default.json` said `ok` the entire time.
`default` is one name all five vendors answer to, and the key was missing the
only field that made it mean anything.

**What changed.** The key is `state/quota/cooldown/<vendor>/<account>`. Four
sites moved in one diff, because a writer and a reader that disagree about a path
is the same bug in a different direction:

- `bin/account-pick.sh` — `account_cooling <vendor> <account>` (two args now; a
  one-arg call returns "not cooling", the fail-open direction), plus
  `account_cooldown_file`, `account_cooldown_stamp` and the legacy sweep;
  `account_pick` passes the vendor it was asked about.
- `bin/agent-call.sh` — the one writer, inside the `account-exhausted|auth`
  branch of `ladder_recover`. `$runner` IS the vendor there. Its `failovers.log`
  note now reads `account <vendor>/<account> cooled down …`.
- `bin/lib/pool-account.sh` — `pool_account_cooldown` writes
  `cooldown/claude/<name>` (the pool leases claude accounts and nothing else) and
  `pool_account_lease` reads `account_cooling claude "$a"`. Sourced beside the
  picker it stamps through `account_cooldown_stamp`; sourced alone it writes the
  same path inline.
- `bin/quota-status.sh` — reads every vendor's cooldown for an account, so a
  codex-cooled `default` has a row to appear on.

**The migration is in the code, not in a runbook.** A regular file directly under
`state/quota/cooldown/` is the old unscoped key. It is never read as a cooldown
for any vendor; the first library call that sees one moves it to
`cooldown/.legacy/<name>` and writes one `,<name>,legacy_cooldown_ignored` row to
`logs/account-routing.log`. Once per process, so a pick over three candidates logs
one row per file and not three. A sweep that cannot write (read-only `state/`)
leaves the file where it is — still never read, so the fail direction stays
"account available". On the hub this means the stuck `cooldown/default` is swept
by the first pick after the rollout and claude routing resumes without waiting for
the window to expire.

**The lever.** `bin/quota-status.sh --clear-cooldown <vendor> <account>` removes
one cooldown, prints what it did, logs a `cooldown_cleared:<vendor>` routing row
and one `failovers.log` line, and exits 0. Nothing to clear is exit 1 with
`no cooldown for <vendor>/<account>` and NO log rows — a `cooldown_cleared` row
for a clear that did not happen is a lie the next operator reads back out of the
log. An unknown vendor or an invalid account name is exit 2 and removes nothing
(the name becomes a path segment under `state/quota/cooldown/`, so `../x` is
refused as a name). It exists because the alternative was
an `rm` under `state/`, which `bin/iron-law-guard.sh` family 6 refuses at session
level — the thing an operator needed most was the thing nobody could type. It is
the only write that script makes and it touches nothing else: not pins, not
leases, not `cooldown/.legacy/`, not `state/model-cooldown-<model>-<account>`.

**What did NOT change.** The fable→opus model cooldown
(`state/model-cooldown-<model>-<account>`) is a different file with a different
meaning and already keys on the account — untouched. `bin/quota-poll.sh`'s sweep
of aged stamps is a `find -type f` over the tree, so it still reaches them.
`quota-status.sh --json` keeps `cooldown_until` (now the ROW vendor's entry) and
gains `cooldowns: {<vendor>: "HH:MMZ"}`; `bin/account-capacity.sh` is the one
in-repo reader of that field and its `.vendor == $v` filter means it now counts a
codex-cooled `default` as claude headroom, which is what it always meant to say.

**How it is pinned.** `tests/account-cooldown-vendor.bh-940-test.sh` drives
`bin/agent-call.sh`, `bin/account-pick.sh`, `bin/quota-status.sh` and
`bin/lib/pool-account.sh` against a scratch `$HARNESS` and asserts on files under
`state/` and lines in `logs/` — isolation both ways, the legacy sweep, the writer,
the branch it must stay inside, the pool, the display, the lever and expiry.
`tests/account-routing-test.sh`, `tests/ladder-recovery-test.sh`,
`tests/pool-account-test.sh` and `tests/pool-account-routing-test.sh` were
re-pointed at the scoped path in the same PR, because their old assertions would
have passed on a key nothing writes any more.
