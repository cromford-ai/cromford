#!/bin/bash
# bin/selfhost-install.sh — BH-4081: the one command that plans a self-hosted
# harness in the operator's OWN accounts (Cloudflare workers + D1 + console, a
# hub and build pool on Fly or a VM, GitHub App or PAT, model auth, optional
# Telegram/Slack). This build ships the dry-run only: it reads the settings,
# validates them, and prints the plan. It makes no network call and writes
# nothing. --apply is refused (rc 2); it is not built yet.
#
# Usage:
#   bin/selfhost-install.sh --config <file> [--dry-run] [--state <dir>]
#     --config   the install settings (copy env-templates/selfhost.conf.example)
#     --dry-run  print the plan (the default, and the only mode built)
#     --state    the install's state dir; a resource already in its ledger.tsv
#                (provider<TAB>kind<TAB>name<TAB>id<TAB>created_at) is planned
#                as `recorded` instead of `create`. Read, never written.
#     --apply    refused with rc 2
#
# The resource list is catalog/selfhost/resources.tsv (SELFHOST_CATALOG
# overrides the path). The settings file is read as data, never sourced: an
# unknown key, a duplicate key, or a secret-shaped key (…TOKEN, …SECRET,
# …API_KEY, …PASSWORD, …PRIVATE_KEY) is refused. Every missing or invalid
# setting is named in one refusal. Caps must be positive dollar amounts unless
# SELFHOST_CAPS_OFF=1. SELFHOST_RUNNER_LOCK is blank or `claude`. This script
# does not source bin/lib/deployment.sh: its defaults are another deployment's
# values, and a blank setting must refuse.
#
# Output, in catalog order, no timestamps:
#   RESOURCE <provider> <kind> <name> <create|recorded|skip(<term>)> from=<setting|fixed>
#   ENV <KEY>=<value>          each env/global.env line apply would write
#   CAP ...                    the dollar caps it would seed, or `CAP off (...)`
#   SETTING <key>=<value>      a per-project settings row (claude_auth.<p>,
#                              runner_lock.<p>, cost_ceiling.<p>), or
#   SETTING <key> skip(<why>)  printed only when SELFHOST_MODEL_AUTH=api-key or
#                              SELFHOST_RUNNER_LOCK=claude
#   SECRET <NAME> needed-by=<id>[,<id>] [where=fly-secret]
#                              api-key adds ANTHROPIC_API_KEY_<PROJECT> per
#                              project, a Fly secret, never a conf value
#   SUMMARY resources=<n> create=<n> recorded=<n> skipped=<n> live_calls=0 writes=0
# Exit: 0 plan printed, 1 settings refused, 2 usage or --apply, 3 catalog malformed.
set -uo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # a `&` in a value stays a `&`

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="${SELFHOST_CATALOG:-$ROOT/catalog/selfhost/resources.tsv}"
CONFIG=""; STATE=""

usage() { sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; }
die_usage() { echo "selfhost-install: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --config)  [ $# -ge 2 ] || die_usage "--config needs a file"; CONFIG="$2"; shift 2 ;;
    --state)   [ $# -ge 2 ] || die_usage "--state needs a dir"; STATE="$2"; shift 2 ;;
    --dry-run) shift ;;
    --apply)   echo "selfhost-install: --apply is not built yet (BH-4081 slice C0 ships the dry-run); nothing was created" >&2; exit 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown arg $1" ;;
  esac
done
[ -n "$CONFIG" ] || die_usage "--config <file> is required (see --help)"

# ── the catalog ──────────────────────────────────────────────────────────────
KNOWN=(SELFHOST_CF_ACCOUNT_ID HARNESS_WORKERS_SUBDOMAIN CONSOLE_PAGES_PROJECT BACKUP_S3_BUCKET
  HARNESS_REPO HARNESS_GH_OWNER HARNESS_OPERATOR_LOGIN HARNESS_GIT_NAME HARNESS_GIT_EMAIL SELFHOST_GH_AUTH
  HARNESS_BOX_PREFIX HARNESS_HUB_BOX SELFHOST_HUB SELFHOST_HUB_HOST FLY_ORG SELFHOST_POOL SELFHOST_PROJECTS
  SELFHOST_MODEL_AUTH SELFHOST_RUNNER_LOCK SELFHOST_CHAT SELFHOST_CAP_USD_PER_CALL SELFHOST_CAP_USD_DAY SELFHOST_CAPS_OFF)
is_known() { local k; for k in ${KNOWN[@]+"${KNOWN[@]}"}; do [ "$k" = "$1" ] && return 0; done; return 1; }
WHEN_TERMS=" always hub=fly hub=vm pool=fly pool=local gh=app gh=pat model=oauth model=api-key chat=telegram chat=slack per-project "

R_ID=(); R_PROV=(); R_KIND=(); R_NAME=(); R_FROM=(); R_WHEN=(); R_SECRETS=()
[ -r "$CATALOG" ] || { echo "selfhost-install: catalog $CATALOG:0 malformed (cannot read it)" >&2; exit 3; }
malformed() { echo "selfhost-install: catalog $CATALOG:$n malformed ($1)" >&2; exit 3; }
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1))
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r -a f <<< "$line"
  [ "${#f[@]}" = 8 ] || malformed "${#f[@]} fields, want 8"
  case "${f[1]}" in cloudflare|fly|vm|github|model|chat) ;; *) malformed "provider ${f[1]}" ;; esac
  IFS=, read -r -a terms <<< "${f[5]}"
  [ "${#terms[@]}" -ge 1 ] || malformed "empty when"
  for t in ${terms[@]+"${terms[@]}"}; do case "$WHEN_TERMS" in *" $t "*) ;; *) malformed "when term $t" ;; esac; done
  for i in "${R_ID[@]+"${R_ID[@]}"}"; do [ "$i" = "${f[0]}" ] && malformed "duplicate id ${f[0]}"; done
  [ -n "${f[3]}" ] || malformed "empty name"
  rest="${f[3]}"
  while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    v="${BASH_REMATCH[1]}"
    if [ "$v" = project ]; then
      [[ ",${f[5]}," == *",per-project,"* ]] || malformed "\${project} in a row that is not per-project"
    else
      is_known "$v" || malformed "name names unknown setting $v"
    fi
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  R_ID+=("${f[0]}"); R_PROV+=("${f[1]}"); R_KIND+=("${f[2]}"); R_NAME+=("${f[3]}")
  R_FROM+=("${f[4]}"); R_WHEN+=("${f[5]}"); R_SECRETS+=("${f[6]}")
done < "$CATALOG"
[ "${#R_ID[@]}" -ge 1 ] || { echo "selfhost-install: catalog $CATALOG:$n malformed (no rows)" >&2; exit 3; }

# ── the settings, read as data ───────────────────────────────────────────────
[ -f "$CONFIG" ] && [ -r "$CONFIG" ] || { echo "selfhost-install: cannot read $CONFIG" >&2; exit 1; }
# The settings: parallel arrays S_K/S_V, not an associative array, because
# macOS ships bash 3.2. s_idx sets SI with no subshell.
S_K=(); S_V=()
s_idx() {  # s_idx KEY — set SI to the index of KEY in S_K; rc 1 when not set
  SI=0
  while [ "$SI" -lt "${#S_K[@]}" ]; do [ "${S_K[$SI]}" = "$1" ] && return 0; SI=$((SI+1)); done
  return 1
}
PROBLEMS=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n+1))
  line="${line%$'\r'}"
  [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
  if ! [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
    PROBLEMS+=("line $n is not KEY=value"); continue
  fi
  k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
  if [[ "$k" =~ (TOKEN|SECRET|API_KEY|PASSWORD|PRIVATE_KEY)$ ]]; then
    PROBLEMS+=("$k looks like a secret; secrets never go in this file (apply asks for them)"); continue
  fi
  is_known "$k" || { PROBLEMS+=("$k is not a known setting (line $n)"); continue; }
  s_idx "$k" && { PROBLEMS+=("$k is set twice (line $n)"); continue; }
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  if [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
  S_K+=("$k"); S_V+=("$v")
done < "$CONFIG"
get() { if s_idx "$1"; then printf '%s' "${S_V[$SI]}"; fi; }

need() { [ -n "$(get "$1")" ] || PROBLEMS+=("$1 is blank"); }
enum() {  # enum KEY allowed...
  local k="$1" v; shift; v="$(get "$k")"
  [ -n "$v" ] || { PROBLEMS+=("$k is blank (one of: $*)"); return; }
  case " $* " in *" $v "*) ;; *) PROBLEMS+=("$k=$v is not one of: $*") ;; esac
}
for k in HARNESS_WORKERS_SUBDOMAIN CONSOLE_PAGES_PROJECT BACKUP_S3_BUCKET HARNESS_OPERATOR_LOGIN \
         HARNESS_GIT_NAME HARNESS_GIT_EMAIL HARNESS_BOX_PREFIX HARNESS_HUB_BOX; do
  need "$k"
done
acct="$(get SELFHOST_CF_ACCOUNT_ID)"
if [ -z "$acct" ]; then PROBLEMS+=("SELFHOST_CF_ACCOUNT_ID is blank")
elif ! [[ "$acct" =~ ^[0-9a-f]{32}$ ]]; then PROBLEMS+=("SELFHOST_CF_ACCOUNT_ID is not 32 hex characters"); fi
repo="$(get HARNESS_REPO)"
if [ -z "$repo" ]; then PROBLEMS+=("HARNESS_REPO is blank")
elif ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then PROBLEMS+=("HARNESS_REPO=$repo is not owner/repo"); fi
if [ -z "$(get HARNESS_GH_OWNER)" ]; then
  if [ -n "$repo" ]; then
    if s_idx HARNESS_GH_OWNER; then S_V[$SI]="${repo%%/*}"; else S_K+=(HARNESS_GH_OWNER); S_V+=("${repo%%/*}"); fi
  else PROBLEMS+=("HARNESS_GH_OWNER is blank and HARNESS_REPO is blank, so it cannot be derived"); fi
fi
enum SELFHOST_HUB fly vm
enum SELFHOST_POOL fly local
enum SELFHOST_GH_AUTH app pat
enum SELFHOST_MODEL_AUTH oauth api-key
enum SELFHOST_CHAT none telegram slack
lock="$(get SELFHOST_RUNNER_LOCK)"
case "$lock" in ''|claude) ;; *) PROBLEMS+=("SELFHOST_RUNNER_LOCK=$lock: blank or claude only") ;; esac
[ "$(get SELFHOST_HUB)" = vm ] && [ -z "$(get SELFHOST_HUB_HOST)" ] && PROBLEMS+=("SELFHOST_HUB_HOST is blank and SELFHOST_HUB=vm needs it")
if { [ "$(get SELFHOST_HUB)" = fly ] || [ "$(get SELFHOST_POOL)" = fly ]; } && [ -z "$(get FLY_ORG)" ]; then
  PROBLEMS+=("FLY_ORG is blank and the hub or the pool is on Fly")
fi
PROJECTS=()
read -r -a ents <<< "$(get SELFHOST_PROJECTS)"
[ "${#ents[@]}" -ge 1 ] || PROBLEMS+=("SELFHOST_PROJECTS is blank (want name=owner/repo ...)")
for e in "${ents[@]+"${ents[@]}"}"; do
  if ! [[ "$e" =~ ^([a-z0-9-]+)=[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    PROBLEMS+=("SELFHOST_PROJECTS entry $e is not name=owner/repo with name [a-z0-9-]"); continue
  fi
  p="${BASH_REMATCH[1]}"
  case " ${PROJECTS[*]+"${PROJECTS[*]}"} " in *" $p "*) PROBLEMS+=("SELFHOST_PROJECTS names project $p twice"); continue ;; esac
  PROJECTS+=("$p")
done
caps_off="$(get SELFHOST_CAPS_OFF)"
case "$caps_off" in ''|0|1) ;; *) PROBLEMS+=("SELFHOST_CAPS_OFF=$caps_off: blank, 0 or 1 only") ;; esac
if [ "$caps_off" != 1 ]; then
  for k in SELFHOST_CAP_USD_PER_CALL SELFHOST_CAP_USD_DAY; do
    v="$(get "$k")"
    if ! [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! [[ "$v" =~ [1-9] ]]; then
      PROBLEMS+=("$k='$v' is not a positive dollar amount (caps stay on; SELFHOST_CAPS_OFF=1 is the only way off)")
    fi
  done
fi
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  echo "selfhost-install: refused $CONFIG, nothing planned:" >&2
  printf '  %s\n' ${PROBLEMS[@]+"${PROBLEMS[@]}"} >&2
  exit 1
fi

# ── the plan ─────────────────────────────────────────────────────────────────
# The ledger keys, one provider<TAB>kind<TAB>name per line between newlines.
LEDGER=$'\n'
if [ -n "$STATE" ] && [ -r "$STATE/ledger.tsv" ]; then
  while IFS=$'\t' read -r lp lk ln _; do
    [ -n "$lp" ] && LEDGER+="$lp"$'\t'"$lk"$'\t'"$ln"$'\n'
  done < "$STATE/ledger.tsv"
fi

# The first `when` term that is false for these settings, or empty.
false_term() {
  local t
  IFS=, read -r -a ts <<< "$1"
  for t in ${ts[@]+"${ts[@]}"}; do
    case "$t" in
      always|per-project) ;;
      hub=*)   [ "$(get SELFHOST_HUB)" = "${t#*=}" ] || { echo "$t"; return; } ;;
      pool=*)  [ "$(get SELFHOST_POOL)" = "${t#*=}" ] || { echo "$t"; return; } ;;
      gh=*)    [ "$(get SELFHOST_GH_AUTH)" = "${t#*=}" ] || { echo "$t"; return; } ;;
      model=*) [ "$(get SELFHOST_MODEL_AUTH)" = "${t#*=}" ] || { echo "$t"; return; } ;;
      chat=*)  [ "$(get SELFHOST_CHAT)" = "${t#*=}" ] || { echo "$t"; return; } ;;
    esac
  done
}
expand() {  # expand <template> <project>: each ${X} once, left to right
  local rest="$1" out="" v
  while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    out+="${rest%%"${BASH_REMATCH[0]}"*}"
    if [ "${BASH_REMATCH[1]}" = project ]; then v="$2"; else v="$(get "${BASH_REMATCH[1]}")"; fi
    out+="$v"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done
  out+="$rest"
  [ -n "$out" ] || out="-"
  printf '%s' "$out"
}

N_RES=0; N_CREATE=0; N_REC=0; N_SKIP=0
SEC_ORDER=(); SEC_IDS=()   # SEC_IDS[j] is the id list of SEC_ORDER[j]
for i in "${!R_ID[@]}"; do
  ft="$(false_term "${R_WHEN[$i]}")"
  if [[ ",${R_WHEN[$i]}," == *",per-project,"* ]]; then targets=(${PROJECTS[@]+"${PROJECTS[@]}"}); else targets=(""); fi
  for p in ${targets[@]+"${targets[@]}"}; do
    name="$(expand "${R_NAME[$i]}" "$p")"
    if [ -n "$ft" ]; then act="skip($ft)"; N_SKIP=$((N_SKIP+1))
    elif case "$LEDGER" in *$'\n'"${R_PROV[$i]}"$'\t'"${R_KIND[$i]}"$'\t'"$name"$'\n'*) true ;; *) false ;; esac; then act=recorded; N_REC=$((N_REC+1))
    else act=create; N_CREATE=$((N_CREATE+1)); fi
    N_RES=$((N_RES+1))
    echo "RESOURCE ${R_PROV[$i]} ${R_KIND[$i]} $name $act from=${R_FROM[$i]}"
  done
  [ -z "$ft" ] || continue
  [ "${R_SECRETS[$i]}" = - ] && continue
  IFS=, read -r -a secs <<< "${R_SECRETS[$i]}"
  for s in ${secs[@]+"${secs[@]}"}; do
    j=0
    while [ "$j" -lt "${#SEC_ORDER[@]}" ] && [ "${SEC_ORDER[$j]}" != "$s" ]; do j=$((j+1)); done
    if [ "$j" = "${#SEC_ORDER[@]}" ]; then SEC_ORDER+=("$s"); SEC_IDS+=("${R_ID[$i]}")
    else SEC_IDS[$j]="${SEC_IDS[$j]},${R_ID[$i]}"; fi
  done
done

# env/global.env lines (the BH-4080 deployment knobs and the resource names).
# The merge and bot identities follow the operator's, so no default of another
# deployment survives on the box.
for k in HARNESS_REPO HARNESS_GH_OWNER HARNESS_OPERATOR_LOGIN HARNESS_GIT_NAME HARNESS_GIT_EMAIL; do
  echo "ENV $k=$(get "$k")"
done
echo "ENV HARNESS_MERGE_GIT_NAME=$(get HARNESS_GIT_NAME)"
echo "ENV HARNESS_BOT_GIT_NAME=$(get HARNESS_GIT_NAME)"
echo "ENV HARNESS_BOT_GIT_EMAIL=$(get HARNESS_GIT_EMAIL)"
for k in HARNESS_WORKERS_SUBDOMAIN HARNESS_BOX_PREFIX HARNESS_HUB_BOX CONSOLE_PAGES_PROJECT BACKUP_S3_BUCKET; do
  echo "ENV $k=$(get "$k")"
done

if [ "$caps_off" = 1 ]; then
  echo "CAP off (SELFHOST_CAPS_OFF=1)"
else
  echo "CAP AGENT_CALL_BUDGET_USD=$(get SELFHOST_CAP_USD_PER_CALL)"
  echo "CAP LLM_USD_CAP_DAY=$(get SELFHOST_CAP_USD_DAY)"
fi
echo "CAP calls/tokens: no enforcing knob in this harness yet; dollars are the cap"

# The per-project settings rows. With oauth and no lock nothing prints, so that
# plan stays as it was before these rows existed.
mode="$(get SELFHOST_MODEL_AUTH)"
if [ "$mode" = api-key ] || [ "$lock" = claude ]; then
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
    echo "SETTING claude_auth.$p=$mode"
    [ "$lock" != claude ] || echo "SETTING runner_lock.$p=claude"
    if [ "$caps_off" = 1 ]; then echo "SETTING cost_ceiling.$p skip(caps off)"
    else echo "SETTING cost_ceiling.$p=$(get SELFHOST_CAP_USD_DAY)"; fi
  done
fi

j=0
while [ "$j" -lt "${#SEC_ORDER[@]}" ]; do
  echo "SECRET ${SEC_ORDER[$j]} needed-by=${SEC_IDS[$j]}"
  j=$((j+1))
done
# api-key: one key per project, a Fly secret on that project's app. The name
# only; the value is never read from or written to the conf file.
if [ "$mode" = api-key ]; then
  for p in ${PROJECTS[@]+"${PROJECTS[@]}"}; do
    echo "SECRET ANTHROPIC_API_KEY_$(printf '%s' "$p" | tr 'a-z-' 'A-Z_') needed-by=claude_auth.$p where=fly-secret"
  done
fi
echo "SUMMARY resources=$N_RES create=$N_CREATE recorded=$N_REC skipped=$N_SKIP live_calls=0 writes=0"
