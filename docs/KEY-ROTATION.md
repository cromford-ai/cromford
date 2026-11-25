# Key rotation: per-project Sentry and PostHog keys

This doc lists the app-signal keys a fleet project owns, where each key lives,
and how to rotate it. The readers are `bin/sentry-lookup.sh`,
`bin/posthog-lookup.sh` and the `sentry-triage` lane (BH-9799). The row that
names each key is `catalog/signal-sources.d/<project>.json`. The row holds env
names only, never a value.

## project-6-os

Rotate by **2027-02-15**.

| Name | Secret | What it is |
|---|---|---|
| `SENTRY_MK_API_TOKEN` | yes | Sentry token for org `project-6-llc` (read scopes plus `event:write`, no admin) |
| `POSTHOG_MK_PERSONAL_API_KEY` | yes | PostHog personal key, scoped to project `598179` (read scopes plus annotation write) |
| `SENTRY_MK_ORG` | no | `project-6-llc` (the registry row holds the same value) |
| `SENTRY_MK_PROJECT` | no | `project-6-os` (the registry row holds the same value) |
| `POSTHOG_MK_HOST` | no | `https://us.posthog.com` (the registry row holds the same value) |
| `POSTHOG_MK_PROJECT_ID` | no | `598179` (the registry row holds the same value) |

Homes. Each home has a copy of each key:

1. `box-project-6-os-1`: `env/project-6-os.env` (the first home; the keys were tested there with HTTP 200).
2. The hub: `env/project-6-os.env`. The `sentry-triage` lane runs on the hub and reads `SENTRY_MK_API_TOKEN` from the environment or from this file.

Ticket BH-9800 C2 (#9840) adds the D1 signal-key store as a third home. Until
it merges, the env files are the only homes.

The PostHog project `598179` also holds project-5 events. The registry row adds
the filter `properties.app = 'project-6'` to the canned reports.

## How to install or rotate a key

Do these steps on each home:

1. Put the new value on stdin of `bin/signal-env-install.sh`. Do not put it on the command line:

   ```
   read -rs V && printf '%s' "$V" | /root/harness/bin/signal-env-install.sh project-6-os SENTRY_MK_API_TOKEN; unset V
   ```

   The script takes `locks/harden-state.lock`, runs `bin/harden-state.sh --release` on the env file, writes the line, and runs `--rearm`. It prints `installed <NAME> for <project> (value not shown)`.
2. Do step 1 again for `POSTHOG_MK_PERSONAL_API_KEY`.
3. Probe Sentry: `/root/harness/bin/sentry-lookup.sh x project-6-os`. A line that starts with `(sentry lookup unavailable` means the key is not read.
4. Probe PostHog: `/root/harness/bin/posthog-lookup.sh project-6-os --report web-vitals`. A line that starts with `(posthog lookup failed` or `(posthog lookup unavailable` means the key is not read or not valid.
5. Revoke the old key in the vendor console.

## One Sentry project, one reader

The `discovery-daily` lane (BH-9795) can also read a project's Sentry issues,
through its settings row `DISCOVERY_SENTRY_PROJ`. For project-6-os that row is
empty, so only `sentry-triage` reads `project-6-llc/project-6-os`. Set that row
OR keep the `sentry` block of the registry row, never both: the two lanes write
different body markers, so one issue would get two tickets.
