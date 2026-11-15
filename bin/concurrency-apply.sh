#!/bin/bash
# bin/concurrency-apply.sh --dry-run|--apply [project] [--json]
#   — the recommended concurrency_rules repo/<p>/build for every pool project,
#     and (with --apply) the writes that get there.
#
# THE PROPOSAL, IN ONE LINE: a project may build as many at once as the smaller
# of the machines it can have and the ACCOUNT that pays for them.
#
#   proposed = min( bin/pool-cap.sh <p> , bin/account-capacity.sh <vendor> )
#
# WHY THE ACCOUNT HALF IS THE POINT. Every cap in the build path today counts
# machines, and machines were never the bottleneck: docs/LESSONS.md #6 — "MODEL
# CAPACITY IS THE THROUGHPUT CEILING, NOT HARDWARE. 2-core boxes build fine;
# every stall was account weather (session caps, org spend caps, 429s). Parallel
# lanes multiply burn against one account (~3-4 heavy sessions max)."
# bin/fly-envbundle.sh builds the bundle with ONE CLAUDE_CODE_OAUTH_TOKEN — the
# owning box's — and until 2026-09-14 every machine in a project's pool got that
# same one, so a pool cap of 20 bought 20 heavy sessions on ONE account, not 20
# accounts' worth of headroom; the extra machines queued inside the vendor, where
# nothing in this fleet can see them. bin/lib/pool-account.sh now leases a
# per-machine account at launch where env/tokens.d has shippable tokens, so on
# THAT box the ceiling is (shippable accounts x sessions-per-account) and
# bin/account-capacity.sh counts it that way. Everywhere else the old sentence
# still holds exactly, which is why this half of the min() stays.
# Raising the pool cap and the rule in lockstep, as was done by hand on
# 2026-09-11 and again on 2026-09-12, keeps those two agreeing with each other
# and neither of them agreeing with the account.
#
# DB-DRIVEN, CODE FALLBACK. The account number comes from polled quota data,
# then the env/accounts.d registry, then the implicit single account — and the
# per-account session count from fly/account-capacity.conf, a reviewed line,
# with the documented LESSONS.md figure only as a last resort. Every path says
# which one it took.
#
# ONLY POOL PROJECTS ARE PROPOSED. On the local route the repo rule is not what
# binds — flags/build-slots and concurrency_rules box/*/build are — so raising a
# repo rule there would promise parallelism the box cannot deliver, and lowering
# it would change nothing visible. The plan says "no change" and why.
#
# NEVER RAW SQL. The rule is a row behind an API with a specificity ladder the
# worker owns; writing it any other way is how a cap comes to bind somewhere
# nobody meant. Every write goes through `bin/jobs-client.sh rule-set`.
#
# IDEMPOTENT. A project already at its proposed value is not written at all, so
# this is safe on a cron or in a loop and an unchanged run is silent.
set -uo pipefail
H="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || HERE="$H/bin"

MODE=""; ONLY=""; JSON=0
for a in "$@"; do
  case "$a" in
    --dry-run) MODE=dry ;;
    --apply)   MODE=apply ;;
    --json)    JSON=1 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    --*) echo "concurrency-apply.sh: unknown option $a" >&2; exit 2 ;;
    *) ONLY="$a" ;;
  esac
done
# NO DEFAULT MODE. A script that writes fleet-wide caps when run bare is a trap:
# the one thing an operator does first is run it to see what it says.
if [ -z "$MODE" ]; then
  echo "usage: concurrency-apply.sh --dry-run|--apply [project] [--json]" >&2
  exit 2
fi

PLAN="$HERE/concurrency-plan.sh"; [ -x "$PLAN" ] || PLAN="$H/bin/concurrency-plan.sh"
ACAP="$HERE/account-capacity.sh"; [ -x "$ACAP" ] || ACAP="$H/bin/account-capacity.sh"

# The fly1 route's wip, from the one file that states it — so this script's
# explanation of that route cannot drift from the dispatcher's behaviour.
# shellcheck source=bin/lib/build-caps.sh
if   [ -r "$HERE/lib/build-caps.sh" ]; then . "$HERE/lib/build-caps.sh" 2>/dev/null
elif [ -r "$H/bin/lib/build-caps.sh" ]; then . "$H/bin/lib/build-caps.sh" 2>/dev/null; fi
FLY_DISPATCH_WIP_R="${FLY_DISPATCH_WIP:-1}"

# The lane that pays for a build. bin/run-build.sh opens its claim on lane
# plan/<project>/${RUNNER_PLAN:-claude}, so claude is the build runner unless a
# box says otherwise — and it is the vendor whose sessions are countable.
VENDOR="${RUNNER_PLAN:-claude}"

J=$( { [ -x "$PLAN" ] && "$PLAN" ${ONLY:+"$ONLY"} --json; } 2>/dev/null ) || J=""
[ -n "$J" ] || J='[]'

ACAP_OUT=$( { [ -x "$ACAP" ] && "$ACAP" "$VENDOR"; } 2>/dev/null ) || ACAP_OUT=""
ACAP_N=$(printf '%s' "$ACAP_OUT" | awk '{print $1}')
ACAP_WHY=$(printf '%s' "$ACAP_OUT" | sed -n 's/^[^ ]* (\(.*\))$/\1/p')
case "$ACAP_N" in ''|*[!0-9]*) ACAP_N="unlimited" ;; esac

jstr() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

OUT=""; WROTE=0
while IFS=$'\t' read -r P ROUTE CUR POOL; do
  [ -n "$P" ] || continue
  if [ "$ROUTE" != pool ]; then
    # Name the cap that ACTUALLY binds on this route, not a generic sentence.
    # "the repo rule is not what binds here" is only useful if it also says what
    # does, or the reader is back to opening five files.
    case "$ROUTE" in
      fly1) RWHY="no change — bin/fly-dispatch.sh holds one <p>-active.json, so this route is wip $FLY_DISPATCH_WIP_R whatever the repo rule says; move the project to the pool (flags/fly-pool-<p>) before raising it" ;;
      *)    RWHY="no change — local builds are bound by flags/build-slots and concurrency_rules box/*/build on the project's own box, not by the repo rule" ;;
    esac
    OUT="$OUT$P	$ROUTE	$CUR	null	$RWHY
"
    continue
  fi
  # BH-9719: a project that pays for claude with its own API key has no session
  # meter, so account-capacity answers `unlimited` for it and its row is the
  # pool cap alone. Any other answer keeps the shared fleet count.
  RACAP_N="$ACAP_N"; RACAP_WHY="$ACAP_WHY"; RSKIP=0
  if [ -x "$ACAP" ]; then
    RACAP_OUT=$("$ACAP" "$VENDOR" "$P" 2>/dev/null) || RACAP_OUT=""
    if [ "$(printf '%s' "$RACAP_OUT" | awk '{print $1}')" = unlimited ]; then
      RACAP_N=unlimited; RSKIP=1
      RACAP_WHY=$(printf '%s' "$RACAP_OUT" | sed -n 's/^[^ ]* (\(.*\))$/\1/p')
    fi
  fi
  # min(pool cap, account ceiling), with the reason attached to whichever bound.
  PROP="$POOL"; WHY="the Fly pool cap of $POOL machine(s)"
  if [ "$POOL" = unlimited ]; then
    # 2026-09-14 autoscale: with no ceiling configured the pool is not a cap at
    # all — it follows queue depth — so min() is the account half alone, which
    # is the half this script was written for anyway.
    PROP="$RACAP_N"
    WHY="the pool is unlimited (autoscale), so account capacity $RACAP_N is what binds — $RACAP_WHY"
  elif [ "$RACAP_N" != unlimited ] && [ "$POOL" != "?" ] && [ "$RACAP_N" -lt "$POOL" ] 2>/dev/null; then
    PROP="$RACAP_N"
    WHY="account capacity $RACAP_N below the pool cap of $POOL — $RACAP_WHY"
  elif [ "$RACAP_N" != unlimited ] && [ "$RACAP_N" = "$POOL" ]; then
    WHY="the pool cap and the account ceiling agree at $POOL — $RACAP_WHY"
  fi
  [ "$RSKIP" = 1 ] && [ "$POOL" != unlimited ] && WHY="$WHY; no account ceiling — $RACAP_WHY"
  case "$PROP" in ''|*[!0-9]*)
    # Two different sentences, because they ask for two different things: an
    # unreadable cap is a box problem, and "both halves unlimited" is a
    # deliberate state this script must not invent a number for.
    if [ "$PROP" = unlimited ] && [ "$RSKIP" = 1 ]; then
      PWHY="no proposal — the pool is unlimited (autoscale) and $P has no account ceiling ($RACAP_WHY); repo/$P/build is the only brake and it is not this script's to guess"
    elif [ "$PROP" = unlimited ]; then
      PWHY="no proposal — the pool is unlimited (autoscale) and the account ceiling is unknown; repo/$P/build is the only brake and it is not this script's to guess"
    else
      PWHY="no proposal — the pool cap could not be read from this machine"
    fi
    OUT="$OUT$P	$ROUTE	$CUR	null	$PWHY
"; continue ;; esac

  if [ "$CUR" = "$PROP" ]; then
    OUT="$OUT$P	$ROUTE	$CUR	$PROP	already at the proposed value — nothing to write
"
    continue
  fi
  OUT="$OUT$P	$ROUTE	$CUR	$PROP	$WHY
"
  if [ "$MODE" = apply ]; then
    # shellcheck source=/dev/null
    [ -r "$H/bin/jobs-client.sh" ] && . "$H/bin/jobs-client.sh" 2>/dev/null
    if command -v job_rule_set >/dev/null 2>&1; then
      job_rule_set repo "$P" build "$PROP" \
        "bin/concurrency-apply.sh $(date -u '+%Y-%m-%d'): min(pool cap $POOL, account capacity $RACAP_N) — $WHY" \
        >/dev/null 2>&1 && WROTE=$((WROTE+1))
    fi
  fi
done <<EOF
$(printf '%s' "$J" | jq -r '.[] | [.project, .route, .db_rule, .pool_cap] | @tsv' 2>/dev/null)
EOF

if [ "$JSON" = 1 ]; then
  printf '[\n'; first=1
  printf '%s' "$OUT" | while IFS=$'\t' read -r p route cur prop why; do
    [ -n "$p" ] || continue
    [ "$first" = 1 ] || printf ',\n'; first=0
    printf '  {"project":"%s","route":"%s","current":"%s","proposed":%s,"why":"%s","mode":"%s"}' \
      "$(jstr "$p")" "$route" "$cur" \
      "$( [ "$prop" = null ] && printf 'null' || printf '%s' "$prop" )" \
      "$(jstr "$why")" "$MODE"
  done
  printf '\n]\n'
  exit 0
fi

if [ "$MODE" = dry ]; then
  printf 'DRY RUN — nothing is written. Account ceiling for the %s build lane: %s (%s)\n\n' \
    "$VENDOR" "$ACAP_N" "${ACAP_WHY:-unread}"
else
  printf 'APPLY — %s rule(s) written via bin/jobs-client.sh rule-set. Account ceiling for the %s build lane: %s (%s)\n\n' \
    "$WROTE" "$VENDOR" "$ACAP_N" "${ACAP_WHY:-unread}"
fi
printf 'PROJECT              ROUTE  CURRENT  PROPOSED  WHY\n'
printf '%s' "$OUT" | while IFS=$'\t' read -r p route cur prop why; do
  [ -n "$p" ] || continue
  printf '%-20.20s %-6.6s %8.8s %9.9s  %s\n' "$p" "$route" "$cur" \
    "$( [ "$prop" = null ] && printf -- '-' || printf '%s' "$prop" )" "$why"
done
printf '\nrepo/<project>/build only. The ticket rule (1) and the box rule are not proposed:\n'
printf 'one ticket is one claim by design, and the box rule is a property of a machine.\n'
exit 0
