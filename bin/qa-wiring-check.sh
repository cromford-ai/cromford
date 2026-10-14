#!/bin/bash
# bin/qa-wiring-check.sh <project> — is browser QA wired for this project?
# Prints one line per check, in this order, each `ok: ...`, `OWED: <fix>` or
# `UNKNOWN: ...` (the probe could not run here):
#   1. a vercel.conf row (preview QA)
#   2. a real prod URL in fleet.conf (not `-`)
#   3. QA_TEST_USER_ID + QA_CLERK_SECRET_KEY in env/<project>.env, and a role
#      for the project in state/qa-accounts.json
#   4. deploy.<project>.kind is not `none`
#   5. Clerk accepts the prod origin: GET https://<fapi>/v1/environment with
#      `Origin: <prod>` answers 200. The FAPI host is decoded from the
#      publishable key on the prod sign-in page. A development instance
#      (401 dev_browser_unauthenticated) has no origin allow-list: ok.
#
# WHY. project-6-os enrolled on 2026-10-09 and merged 47+ PRs with no vercel.conf
# row, prod `-`, no env file on the hub and deploy kind `none`. No browser QA ran
# on any of them and nothing said so. Its prod host was also a *.vercel.app
# domain that the Clerk prod instance refuses (origin_invalid), so a QA account
# alone would not have fixed it. bin/load-project.sh prints this check as its
# `== browser QA ==` block, and the daily hub lane bin/qa-wiring-sweep.sh alerts
# on every project with an OWED line. One implementation for both.
#
# NO SECRET IS PRINTED. The env file is only grepped with -q, never sourced and
# never echoed. The publishable key is never printed, only the host it decodes to.
#
# Exemption: a settings row qa_wiring.<project>.exempt=<reason> (a project with
# no web UI) prints the single line `exempt: <reason>` and rc 0. No row, or a
# worker that does not answer, means "check it".
#
# rc 0 every line ok (or exempt) | 1 at least one OWED | 3 no OWED, at least one
#    UNKNOWN | 2 usage (no project, or the project is not in fleet.conf)
#
# Tests only: HARNESS, VERCEL_CONF, HARNESS_ENV_DIR, QA_ACCOUNTS, FLEET_CONF,
# QA_WIRING_CURL (a curl stand-in). tests/qa-wiring-check.bh-6254-test.sh.
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$SELF/lib/env-path.sh" || exit 2
# shellcheck source=bin/lib/deploy-kind.sh
. "$SELF/lib/deploy-kind.sh" || exit 2
CURL="${QA_WIRING_CURL:-curl}"

P="${1:-}"
[ -n "$P" ] || { echo "usage: qa-wiring-check.sh <project>" >&2; exit 2; }
"$SELF/fleet-conf.sh" --projects 2>/dev/null | grep -qxF -- "$P" \
  || { echo "qa-wiring-check: $P is not in fleet.conf" >&2; exit 2; }
PL=$(printf '%s' "$P" | tr '[:upper:]' '[:lower:]')

# The settings client in a SUBSHELL, the deploy-kind.sh way: bin/jobs-client.sh
# exits the shell that sources it when a module is missing.
setting() { # setting <key> -> value, rc as setting_get (0 found, 2 no row, 1 outage)
  (
    [ -r "$H/bin/jobs-client.sh" ] || exit 1
    # shellcheck source=/dev/null
    . "$H/bin/jobs-client.sh" >/dev/null 2>&1 || exit 1
    declare -F setting_get >/dev/null 2>&1 || exit 1
    setting_get "$1" 2>/dev/null
  )
}

EX=$(setting "qa_wiring.$PL.exempt") && [ -n "$EX" ] && { echo "exempt: $EX"; exit 0; }

OWED=0 UNKNOWN=0
line() { # line <ok|OWED|UNKNOWN> <text>
  case "$1" in OWED) OWED=$((OWED+1)) ;; UNKNOWN) UNKNOWN=$((UNKNOWN+1)) ;; esac
  printf '%s: %s\n' "$1" "$2"
}

# 1. vercel.conf — column 1 is the project, exactly as bin/e2e-smoke.sh reads it.
VC="${VERCEL_CONF:-$H/vercel.conf}"
[ -r "$VC" ] || [ -n "${VERCEL_CONF:-}" ] || VC="$SELF/../vercel.conf"
if [ ! -r "$VC" ]; then
  line UNKNOWN "vercel.conf row — no readable vercel.conf at $VC"
elif awk -v p="$P" '$1 !~ /^#/ && $1 == p {f=1} END {exit !f}' "$VC"; then
  line ok "vercel.conf row (preview QA)"
else
  line OWED "vercel.conf — add '$P <teamId> <projectId> <prod-domain>' to vercel.conf, or preview QA never runs"
fi

# 2. prod URL.
PROD=$("$SELF/prod-url.sh" "$P" 2>/dev/null)
case "$PROD" in ''|-) PROD=""; line OWED "prod URL — fleet.conf prod is '-', so post-merge prod QA never runs" ;;
  *) line ok "prod URL $PROD" ;;
esac

# 3. QA account. A missing env FILE is owed (the project-6-os case); an env DIR
# this shell cannot read (a laptop running load-project.sh) is unknown.
ENVD=$(harness_env_dir "$H")
ENVF="$ENVD/$P.env"
has_key() { grep -Eq "^(export )?$1=.+" "$ENVF" 2>/dev/null && echo set || echo UNSET; }
if [ ! -d "$ENVD" ] || [ ! -r "$ENVD" ] || [ ! -x "$ENVD" ]; then
  line UNKNOWN "QA account — env dir $ENVD not readable here; run on the hub"
elif [ -e "$ENVF" ] && [ ! -r "$ENVF" ]; then
  line UNKNOWN "QA account — $ENVF not readable by $(id -un 2>/dev/null || echo this user); run on the hub as root"
else
  U=$(has_key QA_TEST_USER_ID); K=$(has_key QA_CLERK_SECRET_KEY)
  ACC="${QA_ACCOUNTS:-$H/state/qa-accounts.json}"
  ROLE=none
  jq -e --arg p "$P" '(.[$p] // {}) | length > 0' "$ACC" >/dev/null 2>&1 && ROLE=yes
  if [ "$U" = set ] && [ "$K" = set ] && [ "$ROLE" = yes ]; then
    line ok "QA account (QA_TEST_USER_ID set, QA_CLERK_SECRET_KEY set, role in qa-accounts.json)"
  else
    line OWED "QA account — QA_TEST_USER_ID=$U QA_CLERK_SECRET_KEY=$K qa-accounts.json role=$ROLE"
  fi
fi

# 4. deploy kind. No row is the deployments poll, which the deploy lanes run.
if [ ! -r "$H/bin/jobs-client.sh" ]; then
  line UNKNOWN "deploy kind — no settings client at $H/bin/jobs-client.sh; run on the hub"
# deploy_kind answers rc 2 for "no row" and for a client that does not load, so
# a broken client would read as the default. Load it here first (lr-6271).
elif ! ( . "$H/bin/jobs-client.sh" && declare -F setting_get ) >/dev/null 2>&1; then
  line UNKNOWN "deploy kind — $H/bin/jobs-client.sh does not load"
else
  DK=$(HARNESS="$H" deploy_kind "$P" 2>/dev/null); DRC=$?
  case "$DRC:$DK" in
    0:none) line OWED "deploy kind none — set settings row deploy.$PL.kind to github-deployment or smoke-only, or prod smoke is off" ;;
    0:*)    line ok "deploy kind $DK" ;;
    2:*)    line ok "deploy kind github-deployment (no row, default)" ;;
    *)      line UNKNOWN "deploy kind — settings unreadable" ;;
  esac
fi

# 5. Clerk origin.
if [ -z "$PROD" ]; then
  line OWED "Clerk origin probe — no prod URL to probe"
else
  TMP=$(mktemp -d) || exit 2
  trap 'rm -rf "$TMP"' EXIT
  PROD="${PROD%/}"
  ORIGIN=$(printf '%s' "$PROD" | sed -E 's#^(https?://[^/]+).*#\1#')
  PK="" REACHED=0
  for u in "$PROD/sign-in" "$PROD/"; do
    if "$CURL" -sS -L --max-time 15 -o "$TMP/page" "$u" 2>/dev/null; then
      REACHED=1
      PK=$(grep -oE 'pk_(live|test)_[A-Za-z0-9+/=_-]+' "$TMP/page" 2>/dev/null | head -1)
      [ -n "$PK" ] && break
    fi
  done
  if [ "$REACHED" = 0 ]; then
    line UNKNOWN "Clerk origin probe — $PROD unreachable"
  elif [ -z "$PK" ]; then
    line OWED "Clerk origin probe — no Clerk publishable key on $PROD/sign-in"
  else
    B="${PK#pk_live_}"; B="${B#pk_test_}"
    while [ $(( ${#B} % 4 )) -ne 0 ]; do B="$B="; done
    FAPI=$(printf '%s' "$B" | base64 -d 2>/dev/null | tr -d '\0')
    FAPI="${FAPI%\$}"
    if ! [[ "$FAPI" =~ ^[A-Za-z0-9.-]+$ ]]; then
      line OWED "Clerk origin probe — publishable key does not decode to a host"
    else
      CODE=$("$CURL" -sS -o "$TMP/fapi" -w '%{http_code}' --max-time 15 -H "Origin: $ORIGIN" "https://$FAPI/v1/environment" 2>/dev/null)
      CRC=$?
      if [ "$CRC" -ne 0 ] || [ "$CODE" = 000 ] || [ -z "$CODE" ]; then
        line UNKNOWN "Clerk origin probe — $FAPI unreachable"
      elif [ "$CODE" = 200 ]; then
        line ok "Clerk accepts origin $ORIGIN (FAPI $FAPI)"
      elif [ "$CODE" = 401 ] && grep -q dev_browser_unauthenticated "$TMP/fapi" 2>/dev/null; then
        # A Clerk development instance (*.clerk.accounts.dev) refuses a
        # browserless call that sends Origin, with this code, and serves the
        # same call with no Origin. It has no origin allow-list to fail.
        line ok "Clerk development instance $FAPI (dev-browser auth, no origin allow-list)"
      elif grep -q origin_invalid "$TMP/fapi" 2>/dev/null; then
        line OWED "Clerk prod rejects origin $ORIGIN (origin_invalid at $FAPI) — serve prod on a domain the Clerk instance allows"
      else
        line OWED "Clerk origin probe — $FAPI answered $CODE"
      fi
    fi
  fi
fi

[ "$OWED" -gt 0 ] && exit 1
[ "$UNKNOWN" -gt 0 ] && exit 3
exit 0
