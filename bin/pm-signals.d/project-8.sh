# shellcheck shell=bash
# pm-signals adapter: project-8 usage and funnel, support threads and churn (BH-7259).
# Read path: $HARNESS/state/pm-data/project-8.json, through _pmsa_project_rows in
# bin/lib/pm-signals-adapter.sh. No file or no key = that row is not-configured.
# Funnel step: usage.active_users (prompts/project-8.md names no product step; a generic key).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pm-signals-adapter.sh" || return 1
pms_intelligent_advisor() {
  _pmsa_project_rows "$1" \
    usage.signups:30d usage.first_run:30d usage.feature_use:30d usage.active_users:30d \
    support.open_threads:now support.new_threads:30d \
    churn.cancels:30d churn.downgrades:30d
}
