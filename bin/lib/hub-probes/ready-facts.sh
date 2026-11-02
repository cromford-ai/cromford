#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/ready-facts.sh — the ready-facts screen probe (BH-7997
# seam, filled by BH-8744). Sourced by common.sh's hp_run; the Ready screen's
# route (worker/jobs/src/routes/onboarding-ready.js) files the row.
# owner BH-7935.3
#
# hp_probe_ready_facts <project>   (hp_validate has checked the name)
#   PASS (rc 0): one line, booleans only:
#     {"vercel":<b>,"qa_account":<b>,"migration_token":<b>}
#   vercel           <root>/vercel.conf has a non-comment line whose first
#                    field is the project (the e2e-smoke.sh test)
#   qa_account       <env dir>/<project>.env sets QA_CLERK_SECRET_KEY and
#                    QA_TEST_USER_ID to a real value
#   migration_token  the same file sets MIGRATION_TOKEN to a real value
#   A real value is not empty and does not start with `<` (the template's
#   placeholder). The first `KEY=` or `export KEY=` line decides. An absent
#   file is a fact: its keys are false.
#   FAIL (rc 1): `unreadable` when there is no harness root, or a file is
#   there but is not a readable file.
# The env file is READ by awk and never sourced, and no value leaves awk: the
# only thing printed is true or false.
. "${BASH_SOURCE[0]%/*}/../env-path.sh" || return 1

# rc 0 when the first line of file $1 that sets key $2 holds a real value.
_hp_rf_has() {
  awk -v k="$2" '
    BEGIN { re = "^(export )?" k "=" }
    $0 ~ re {
      v = $0; sub(/^(export )?[^=]*=/, "", v); sub(/\r$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
      found = (v != "" && substr(v, 1, 1) != "<"); exit
    }
    END { exit !found }' "$1" 2>/dev/null
}

# A file that is there but cannot be read as one.
_hp_rf_unreadable() { [ -e "$1" ] && { [ ! -f "$1" ] || [ ! -r "$1" ]; }; }

hp_probe_ready_facts() {
  local p="$1" root conf envf v=false q=false m=false
  root="${HARNESS:-${H:-}}"
  if [ -z "$root" ]; then echo "unreadable"; return 1; fi
  conf="$root/vercel.conf"
  envf="$(harness_env_dir "$root")/$p.env"
  if _hp_rf_unreadable "$conf" || _hp_rf_unreadable "$envf"; then echo "unreadable"; return 1; fi
  if [ -f "$conf" ] && awk -v p="$p" '$1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$conf"; then v=true; fi
  if [ -f "$envf" ]; then
    _hp_rf_has "$envf" QA_CLERK_SECRET_KEY && _hp_rf_has "$envf" QA_TEST_USER_ID && q=true
    _hp_rf_has "$envf" MIGRATION_TOKEN && m=true
  fi
  printf '{"vercel":%s,"qa_account":%s,"migration_token":%s}\n' "$v" "$q" "$m"
}
