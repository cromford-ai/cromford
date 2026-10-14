#!/bin/bash
# bin/lib/restore-drill-steps.sh — what the weekly restore drill runs on the
# borrowed Orgo computer (#400). Sourced by bin/restore-drill.sh (and, for
# drill_pulled_stamp only, by bin/restore-lab.sh), never run.
#
# drill_on_box <computer_id> <hub_box_id>
#   Inputs (env): H, BACKUP_S3_ENDPOINT, BACKUP_S3_ACCESS_KEY_ID,
#     BACKUP_S3_SECRET_ACCESS_KEY, RESTORE_DRILL_IDENTITY_FILE (may be empty),
#     RESTORE_DRILL_HEALTH_PROJECT. Commands reach the box only through
#     `remote` (bin/lib/restore-drill-orgo.sh).
#   Outputs (globals): DRILL_VERDICT (OK|FAIL), DRILL_DETAIL (one line),
#     DRILL_RPO_S (seconds between the restored backup and now, or empty).
#   Returns 0 iff DRILL_VERDICT=OK.
#   It NEVER creates, gets or deletes the computer: the lane owns its lifecycle.
#
# The steps, in order, each one `remote` call; the first failure stops the run
# with DRILL_DETAIL naming it:
#   fence           crontab, tailnet state and running builds removed, before
#                   anything touches /root/harness (best-effort per command)
#   bootstrap       shallow clone of main with the hub's --read token; bin/,
#                   prompts/, fleet.conf copied in; flags/remediation-disabled
#   identity        only when RESTORE_DRILL_IDENTITY_FILE is readable here
#   restore         state-restore.sh <hub_box_id> latest --apply, R2 keys inline
#                   only; its `pulled <box>/<ts>` line sets DRILL_RPO_S. No such
#                   line is FAIL "RPO unknown"; no identity is FAIL "env not
#                   decrypted"
#   outbound-fence  CONSOLE_URL, TELEGRAM_* and SLACK_* removed from the
#                   restored global.env, so no smoke speaks as the hub
#   healthcheck, fleet-conf, jobs-ledger, gh-auth   the four smokes
# Secrets ride only inside the command body, %q-quoted; DRILL_DETAIL never
# carries command output except state-restore's own status line on failure.

# drill_pulled_stamp <output> <box> — the YYYYMMDDTHHMMSSZ of the first
# `pulled <box>/<stamp>.tar.zst` line bin/state-restore.sh printed; returns 1
# when there is none. The ONE parse of that line: drill_on_box derives its RPO
# from it and bin/restore-lab.sh (BH-1944) its snapshot_ts.
# BH-4080: HARNESS_REPO, the repo the drill box clones and authenticates for.
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$(dirname "${BASH_SOURCE[0]}")/deployment.sh}" || return 1

drill_pulled_stamp() {
  local re="(^|"$'\n'")pulled ${2}/([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.tar\.zst"
  [[ "$1" =~ $re ]] || return 1
  printf '%s\n' "${BASH_REMATCH[2]}${BASH_REMATCH[3]}${BASH_REMATCH[4]}T${BASH_REMATCH[5]}${BASH_REMATCH[6]}${BASH_REMATCH[7]}Z"
}

_drill_fail() {
  DRILL_VERDICT=FAIL
  DRILL_DETAIL=$1
  return 1
}

drill_on_box() {
  local id=$1 hub=$2 tok idarg="" ts stamp="" rc
  local outpat='^[[:space:]]*(export[[:space:]]+)?(CONSOLE_URL|TELEGRAM_[A-Za-z0-9_]*|SLACK_[A-Za-z0-9_]*)='
  DRILL_VERDICT=FAIL DRILL_DETAIL="" DRILL_RPO_S=""

  remote "$id" fence "crontab -r; rm -f /var/lib/tailscale/tailscaled.state; systemctl stop tailscaled; pkill -f 'bin/run-(build|triage).sh'; true" \
    || _drill_fail "fence: remote rc=$?" || return 1

  tok=$("$H/bin/gh-token.sh" --read "$HARNESS_REPO") && [ -n "$tok" ] \
    || _drill_fail "bootstrap: no read token" || return 1
  remote "$id" bootstrap "rm -rf /root/drill-src && git clone -q --depth 1 --branch main $(printf %q "https://x-access-token:$tok@github.com/$HARNESS_REPO.git") /root/drill-src && mkdir -p /root/harness/flags && cp -a /root/drill-src/bin /root/drill-src/prompts /root/drill-src/fleet.conf /root/harness/ && touch /root/harness/flags/remediation-disabled && rm -rf /root/drill-src" \
    || _drill_fail "bootstrap rc=$?" || return 1

  if [ -n "$RESTORE_DRILL_IDENTITY_FILE" ] && [ -r "$RESTORE_DRILL_IDENTITY_FILE" ]; then
    remote "$id" identity "umask 077 && mkdir -p /root/.drill && printf '%s\n' $(printf %q "$(cat "$RESTORE_DRILL_IDENTITY_FILE")") > /root/.drill/identity && chmod 600 /root/.drill/identity" \
      || _drill_fail "identity rc=$?" || return 1
    idarg=" --identity /root/.drill/identity"
  fi

  remote "$id" restore "BACKUP_S3_ENDPOINT=$(printf %q "$BACKUP_S3_ENDPOINT") BACKUP_S3_ACCESS_KEY_ID=$(printf %q "$BACKUP_S3_ACCESS_KEY_ID") BACKUP_S3_SECRET_ACCESS_KEY=$(printf %q "$BACKUP_S3_SECRET_ACCESS_KEY") /root/harness/bin/state-restore.sh $(printf %q "$hub") latest --apply$idarg"
  rc=$?
  # The pull is a fact even when a later part of the restore failed.
  if stamp=$(drill_pulled_stamp "$REMOTE_OUT" "$hub"); then
    ts=$(date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z" +%s 2>/dev/null) \
      && DRILL_RPO_S=$(( $(date -u +%s) - ts ))
    [ -n "$DRILL_RPO_S" ] && [ "$DRILL_RPO_S" -lt 0 ] && DRILL_RPO_S=""
  else
    stamp=""
  fi
  if [ "$rc" != 0 ]; then
    _drill_fail "restore rc=$rc$(grep -m1 -E 'not configured|REFUSED' <<<"$REMOTE_OUT" | cut -c1-200 | sed 's/^/: /')"
    return 1
  fi
  [ -n "$DRILL_RPO_S" ] || _drill_fail "restore: RPO unknown" || return 1
  [ -n "$idarg" ] || _drill_fail "restore: env not decrypted" || return 1

  remote "$id" outbound-fence ". /root/harness/bin/lib/env-path.sh && f=\"\$(harness_env_dir /root/harness)/global.env\" && [ -f \"\$f\" ] && sed -i -E '/$outpat/d' \"\$f\" && ! grep -qE '$outpat' \"\$f\"" \
    || _drill_fail "outbound-fence rc=$?" || return 1

  remote "$id" healthcheck "cd /root/harness && bin/healthcheck.sh $(printf %q "$RESTORE_DRILL_HEALTH_PROJECT")" \
    || _drill_fail "healthcheck rc=$?" || return 1
  remote "$id" fleet-conf "cd /root/harness && bin/fleet-conf.sh --projects" \
    || _drill_fail "fleet-conf rc=$?" || return 1
  [ -n "$REMOTE_OUT" ] || _drill_fail "fleet-conf: empty output" || return 1
  remote "$id" jobs-ledger "cd /root/harness && bin/jobs-client.sh ledger-list build 1" \
    || _drill_fail "jobs-ledger rc=$?" || return 1
  [ -n "$REMOTE_OUT" ] || _drill_fail "jobs-ledger: empty output" || return 1
  remote "$id" gh-auth "cd /root/harness && t=\$(bin/gh-token.sh $(printf %q "$HARNESS_REPO")) && [ -n \"\$t\" ] && GH_TOKEN=\$t gh auth status" \
    || _drill_fail "gh-auth rc=$?" || return 1

  DRILL_VERDICT=OK
  DRILL_DETAIL="restored $stamp, rpo ${DRILL_RPO_S}s, 4 smokes ok"
  return 0
}
