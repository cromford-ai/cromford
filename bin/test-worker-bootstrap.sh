#!/bin/bash
# Recompose ignored inputs for every Node worker consumer, including OTP tests
# that import the jobs worker. Always rebuild so edits cannot use stale catalogs.
set -euo pipefail
task_repo=$(cd "$(dirname "$0")/.." && pwd)
bash "$task_repo/bin/lanes-build.sh" --write
bash "$task_repo/bin/llm-sites-build.sh" --compose
bash "$task_repo/bin/context-budgets-build.sh" --compose --repo "$task_repo"
