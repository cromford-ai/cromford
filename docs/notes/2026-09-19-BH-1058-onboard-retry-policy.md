# BH-1058 — fly-pool-tick.sh onboard-drain resolves retry policy from retry_policies

Doc: DB-COORDINATION-SPEC, FLY-ONBOARD

**What changed.** Inside the `# >>> fly-onboard-drain` block of `bin/fly-pool-tick.sh`, the per-project attempt cap and retry window are now resolved from `retry_policies` before falling back to the env knobs `FLY_ONBOARD_MAX_ATTEMPTS` / `FLY_ONBOARD_RETRY_MIN`. The lookup is gated by the Fly machine registry contract (`machines_rows_on` from `bin/jobs-client.sh`).

- `bin/jobs-client.sh` is guard-sourced once inside the drain block.
- Env defaults are captured into `BASE_MAXA` / `BASE_RETRY` so each project can override them.
- `machines_rows_on` is read at most once per tick, and only when a project actually reaches the lookup: a project that is already routed, or whose give-up flag exists, is skipped before it, so a tick over a queue of routed projects costs no worker call and no log line. (Review round 1: the read started out eager, ahead of the loop, which is 720 contract reads a day on a hub whose queue holds only routed projects.) Otherwise `job_retry_policy "fly-onboard/$P/hub"` is called.
- A returned TSV row's numeric fields must be digit-only (the same `case ''|*[!0-9]*)` check `job_retry_policy_set` applies on write); a negative, decimal, zero or empty `max_attempts` or `backoff_seconds` falls back to the env defaults — never "retry forever" or "never retry".
- There is no per-tick policy log line. When a row applied, the existing launch line (`attempt N of M (policy fly-onboard/$P/hub max_attempts=M backoff=Ss)`) and the one-time give-up ALERTS line carry the resolved values as a suffix.
- The existing `state/fly-onboard/<p>.attempts`/`.last` ledger is untouched; only the cap and backoff values change.

**Why.** The drain's retry semantics were global env knobs. Some projects need a tighter cap or a shorter backoff without changing the fleet default; a per-project row in the coordination DB lets operators tune one project without touching global env.

**What it touches.** `bin/fly-pool-tick.sh`, `tests/fly-onboard-policy.bh-1058-test.sh`, `docs/verification-map/fly-onboard.md`, `docs/verification-map/entries/BH-1058.md`, and the generated `docs/verification-map/README.md`.

**How to set a row.** On the hub:

```bash
/root/harness/bin/jobs-client.sh retry-policy-set fly-onboard/<project>/hub <max-attempts> <backoff-seconds>
```

The contract flag `machines_rows_on` must be on (env `FLY_MACHINES_ROWS=on`, or the `fly_machines_rows` setting row set to `on`) for the lookup to run; otherwise the drain keeps today's env-knob behavior.

**A raised cap does not re-arm a project that gave up.** The give-up flag is checked ahead of the policy lookup, so a new `max_attempts` row applies only after `rm flags/alerted-fly-onboard-gaveup-<p>` and `state/fly-onboard/<p>.attempts` on the hub.

**Fail-open guarantees preserved.** Worker down, missing row, malformed row, contract off, or a box with no `jobs-client.sh` all fall back to the env defaults and the tick still exits 0.
