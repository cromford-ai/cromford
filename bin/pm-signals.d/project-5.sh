# shellcheck shell=bash
# pm-signals adapter: project-5 usage and funnel, support threads and churn (BH-7259).
# Read path: $HARNESS/state/pm-data/project-5.json, through _pmsa_project_rows in
# bin/lib/pm-signals-adapter.sh. No file or no key = that row is not-configured.
# Funnel step: usage.searches (the BH-7259 plan's example; prompts/project-5.md names no step).
. "$(dirname "${BASH_SOURCE[0]}")/../lib/pm-signals-adapter.sh" || return 1
pms_project-5() {
  _pmsa_project_rows "$1" \
    usage.signups:30d usage.first_run:30d usage.feature_use:30d usage.searches:30d \
    support.open_threads:now support.new_threads:30d \
    churn.cancels:30d churn.downgrades:30d
}
