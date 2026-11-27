// worker/jobs/src/lib/deployment-defaults.js — BH-4080: the jobs worker's
// deployment defaults, in one place. Each is the documented fallback for an
// env binding the operator sets on the worker; bin/deployment-lint.sh keeps
// these literals out of every other file.

// The meter is per ACCOUNT and extra_usage_snapshots keys it by the BOX that
// polled (see bin/extra-usage-track.sh): "project-6-account" is the box label
// for the account cost_rows calls "claude:operator@second.example". The mapping is a
// business parameter, so it is configurable (COST_ANCHOR_ACCOUNT_MAP on the
// worker) and this constant is the documented fallback, not the source.
export const ANCHOR_DEFAULT_ACCOUNT_MAP =
  "project-6-account=claude:operator@second.example,hub=claude:operator_home@example.com";
