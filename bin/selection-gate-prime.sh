#!/bin/bash
# bin/selection-gate-prime.sh [--dry-run] — HUB only, once per hour behind the
# hub lease (BH-9094): prime the selection gate's base-run cache for the
# current origin/main sha with the suites that were red most often.
#
# WHY. bin/selection-gate.sh step 6 (BH-8901) runs each red suite once on the
# merge base, and caches a clean answer per (base sha, suite) in
# state/selection-gate/baseline/. Every cromford gate runs on a fresh pool
# machine, so that cache was always cold, and the base run hit its 900 s bound:
# 25 of 38 GATE_REDs on 2026-11-04 had `baseline: could-not-run: timeout`.
# This lane runs the usual reds once an hour on the main tip, on the hub, and
# bin/fly-pool.sh relays the result (prime.tsv) to every live cromford
# pool machine (bin/lib/sg-prime-relay.sh). The cache key stays base sha + suite.
#
# STEPS.
#   1  The knobs below. A value outside its range: one ALERTS line, exit 1.
#   2  git fetch origin main in the repo; SHA = origin/main. A failed fetch or a
#      bad sha: one log line, exit 0, nothing written.
#   3  Sha dirs older than KEEP_DAYS days go. A sha dir that holds .primed is
#      already primed: log it, recompose prime.tsv (step 8), exit 0.
#   4  The candidates: the gate.txt files of builds/pool-<project>-*/ and
#      builds/<project>-*/ (project = the repo dir's name) newer than
#      WINDOW_DAYS days. In each file the `red:` and `baseline-red:` fields,
#      split on `,`; a name counts when it matches ^tests/[A-Za-z0-9._/-]+\.sh$
#      with no `..`, once per file. `noted:` is not counted (a noted suite never
#      reaches the base run). A suite with no file in the SHA tree is dropped.
#      Then count desc, name asc (LC_ALL=C), the first SUITES.
#   5  A candidate with a red or green file under baseline/SHA/ is not sent.
#   6  The rest run once: REMOTE_GATE_P=P timeout TIMEOUT_S <runner> <detached
#      worktree of SHA> <suites…>. Could-not-run (elapsed >= TIMEOUT_S, rc over
#      123, or a RUNNER-FAILURE line): one log line, nothing cached, no .primed,
#      prime.tsv unchanged, exit 0; the next hour tries again. Else each suite
#      is classified by `bin/selection-gate.sh --classify` (the gate's own
#      bl_class), and a red or green answer is written to baseline/SHA/<suite,
#      / as _> (tmp + mv). An unknown answer writes nothing.
#   7  baseline/SHA/.primed (tmp + mv): line 1 `primed <utc> suites=<n> red=<r>
#      green=<g> unknown=<u>`, then one `<suite> TAB <red|green>` line for each
#      suite this run wrote.
#   8  prime.tsv: the rows of the RELAY_SHAS newest sha dirs with .primed (dir
#      mtime), `<sha> TAB <suite> TAB <red|green>`, each one still equal to its
#      per-file cache value. Written tmp + mv, and only when the bytes differ,
#      so the relay's mtime check sees only a real change.
#   The worktree and the temp dir go on every exit.
# --dry-run: steps 1, 2 and 4, then the list on stdout, one suite a line. It
# runs nothing and writes nothing.
#
# A RECORDER, NOT AN ALERTER. The one ALERTS line is a bad knob. A prime that
# could not run is a log line: a cold cache is the behaviour before BH-9094.
# DEDUPE: flock -n on locks/selection-gate-prime.lock, skip if held, never wait.
#
# Off: flags/lane-off-selection-gate-prime or bin/harness-ctl.sh off selection-gate-prime.
# Knobs (settings rows lane.selection-gate-prime.*, catalog/lanes.d/selection-gate-prime.json).
# Test seams: HARNESS, SELECTION_GATE_PRIME_REPO, SELECTION_GATE_PRIME_RUNNER.
# Never set the seams in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  -h|--help) sed -n '2,52p' "$0"; exit 0 ;;
  *) echo "selection-gate-prime: unknown argument $1 (usage: bin/selection-gate-prime.sh [--dry-run])" >&2; exit 2 ;;
esac

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-selection-gate-prime
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off selection-gate-prime.
# shellcheck disable=SC1091
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit selection-gate-prime
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    selection-gate-prime

LOG="$HARNESS/logs/selection-gate-prime.log"
log() {
  if [ "$DRY" = 1 ]; then echo "selection-gate-prime: $*" >&2; return 0; fi
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') selection-gate-prime: $*" >> "$LOG"
}
SG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/selection-gate.sh"
CDIR="$HARNESS/state/selection-gate/baseline"
TSV="$HARNESS/state/selection-gate/prime.tsv"
SUITE_RE='^tests/[A-Za-z0-9._/-]+\.sh$'

# knob <NAME> <value> <min> <max>: a whole number inside the range, else one
# ALERTS line and exit 1. An out-of-range value is refused, never clamped.
knob() {
  case "$2" in
    ''|*[!0-9]*|0?*) ;;
    *) [ "${#2}" -le 7 ] && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] && return 0 ;;
  esac
  "$HARNESS/bin/alert-line.sh" --id selection-gate-prime-knob \
    "[selection-gate-prime] $1='$2' is not a whole number from $3 to $4, so the selection gate cache was not primed. Set the settings row lane.selection-gate-prime.$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') (or env/global.env) to a value in that range." \
    >/dev/null 2>&1 9>&-
  exit 1
}

if [ "$DRY" = 0 ]; then
  mkdir -p "$HARNESS/locks" "$HARNESS/logs"
  exec 9>"$HARNESS/locks/selection-gate-prime.lock"
  flock -n 9 || exit 0
fi

# lane.selection-gate-prime.selection_gate_prime_suites (catalog/lanes.d/selection-gate-prime.json)
N="${SELECTION_GATE_PRIME_SUITES:-20}";           knob SELECTION_GATE_PRIME_SUITES "$N" 1 200
# lane.selection-gate-prime.selection_gate_prime_window_days (catalog/lanes.d/selection-gate-prime.json)
WIN="${SELECTION_GATE_PRIME_WINDOW_DAYS:-7}";     knob SELECTION_GATE_PRIME_WINDOW_DAYS "$WIN" 1 30
# lane.selection-gate-prime.selection_gate_prime_timeout_s (catalog/lanes.d/selection-gate-prime.json)
TO="${SELECTION_GATE_PRIME_TIMEOUT_S:-900}";      knob SELECTION_GATE_PRIME_TIMEOUT_S "$TO" 5 3600
# lane.selection-gate-prime.selection_gate_prime_p (catalog/lanes.d/selection-gate-prime.json)
PAR="${SELECTION_GATE_PRIME_P:-4}";               knob SELECTION_GATE_PRIME_P "$PAR" 1 16
# lane.selection-gate-prime.selection_gate_prime_keep_days (catalog/lanes.d/selection-gate-prime.json)
KEEP="${SELECTION_GATE_PRIME_KEEP_DAYS:-2}";      knob SELECTION_GATE_PRIME_KEEP_DAYS "$KEEP" 1 14
# lane.selection-gate-prime.selection_gate_prime_relay_shas (catalog/lanes.d/selection-gate-prime.json)
RELAY="${SELECTION_GATE_PRIME_RELAY_SHAS:-3}";    knob SELECTION_GATE_PRIME_RELAY_SHAS "$RELAY" 1 24
# lane.selection-gate-prime.selection_gate_prime_fetch_timeout_s (catalog/lanes.d/selection-gate-prime.json)
FTO="${SELECTION_GATE_PRIME_FETCH_TIMEOUT_S:-60}"; knob SELECTION_GATE_PRIME_FETCH_TIMEOUT_S "$FTO" 5 600
# Seams, not settable from the control plane (catalog/lanes.d/selection-gate-prime.json).
REPO="${SELECTION_GATE_PRIME_REPO:-/root/repos/cromford}"
PROJ=$(basename "$REPO")

TMPW=""
cleanup() {
  [ -n "$TMPW" ] || return 0
  git -C "$REPO" worktree remove --force "$TMPW/wt" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1
  rm -rf "$TMPW"; TMPW=""
}
trap cleanup EXIT

# compose_tsv — step 8. Echoes the row count.
compose_tsv() {
  local d sha line s v rows=0 t
  mkdir -p "$(dirname "$TSV")" || { echo 0; return 0; }
  t="$TSV.tmp.$$"
  : > "$t" || { echo 0; return 0; }
  while IFS= read -r sha; do
    d="$CDIR/$sha"
    while IFS=$'\t' read -r s v; do
      [[ "$s" =~ $SUITE_RE ]] && [[ "$s" != *..* ]] || continue
      case "$v" in red|green) ;; *) continue ;; esac
      [ "$(cat "$d/${s//\//_}" 2>/dev/null)" = "$v" ] || continue
      printf '%s\t%s\t%s\n' "$sha" "$s" "$v" >> "$t"; rows=$((rows + 1))
    done < <(tail -n +2 "$d/.primed" 2>/dev/null)
  done < <(for d in "$CDIR"/*/; do
             d=${d%/}; sha=${d##*/}
             [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && [ -f "$d/.primed" ] || continue
             printf '%s\t%s\n' "$(stat -c %Y "$d" 2>/dev/null || echo 0)" "$sha"
           done | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | awk -v n="$RELAY" 'NR <= n' | cut -f2)
  if cmp -s "$t" "$TSV"; then rm -f "$t"; else mv -f "$t" "$TSV" || rm -f "$t"; fi
  echo "$rows"
}

# ── 2. the main sha ──────────────────────────────────────────────────────────
if ! timeout "$FTO" git -C "$REPO" fetch -q origin main >/dev/null 2>&1; then
  log "fetch of origin main failed in $REPO; nothing primed"; exit 0
fi
SHA=$(git -C "$REPO" rev-parse --verify -q 'refs/remotes/origin/main^{commit}' 2>/dev/null)
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { log "origin/main is not a sha in $REPO ('$SHA'); nothing primed"; exit 0; }

# ── 3. retention, and a sha that is already primed ───────────────────────────
if [ "$DRY" = 0 ]; then
  find "$CDIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP" -exec rm -rf {} + 2>/dev/null
fi
if [ -f "$CDIR/$SHA/.primed" ]; then
  if [ "$DRY" = 1 ]; then log "already primed ${SHA:0:12}"; exit 0; fi
  k=$(compose_tsv)
  log "already primed ${SHA:0:12}; tsv_rows=$k"; exit 0
fi

# ── 4. the suites that were red most often ───────────────────────────────────
mapfile -t GATES < <(find "$HARNESS/builds" -mindepth 2 -maxdepth 2 -name gate.txt -mtime "-$WIN" \
  \( -path "$HARNESS/builds/pool-$PROJ-*/gate.txt" -o -path "$HARNESS/builds/$PROJ-*/gate.txt" \) 2>/dev/null | LC_ALL=C sort)
mapfile -t TOP < <(
  for f in "${GATES[@]}"; do
    sed -nE 's/^(red|baseline-red): //p' "$f" 2>/dev/null | tr -d '\r ' | tr ',' '\n' \
      | grep -E "$SUITE_RE" | grep -vF '..' | LC_ALL=C sort -u
  done | LC_ALL=C sort | uniq -c | awk '{ print $1 "\t" $2 }' | LC_ALL=C sort -t$'\t' -k1,1nr -k2,2 | cut -f2 \
  | while IFS= read -r s; do git -C "$REPO" cat-file -e "$SHA:$s" 2>/dev/null && printf '%s\n' "$s"; done \
  | awk -v n="$N" 'NR <= n')
if [ "$DRY" = 1 ]; then
  [ "${#TOP[@]}" -gt 0 ] && printf '%s\n' "${TOP[@]}"
  log "dry run on ${SHA:0:12}: ${#TOP[@]} suite(s) from ${#GATES[@]} gate record(s)"
  exit 0
fi

# ── 5. what is already cached ────────────────────────────────────────────────
SEND=(); CACHED=0
for s in "${TOP[@]}"; do
  case "$(cat "$CDIR/$SHA/${s//\//_}" 2>/dev/null)" in red|green) CACHED=$((CACHED + 1)) ;; *) SEND+=("$s") ;; esac
done

# ── 6. the run ───────────────────────────────────────────────────────────────
RED=0; GREEN=0; UNK=0; WROTE=()
if [ "${#SEND[@]}" -gt 0 ]; then
  [ -r "$SG" ] || { log "could-not-run: no-classifier ($SG)"; exit 0; }
  TMPW=$(mktemp -d "${TMPDIR:-/tmp}/selection-gate-prime.XXXXXX") || { TMPW=""; log "could-not-run: no-tmp"; exit 0; }
  if ! git -C "$REPO" worktree add -q --detach "$TMPW/wt" "$SHA" >/dev/null 2>&1; then
    log "could-not-run: no-worktree"; exit 0
  fi
  RUNNER="${SELECTION_GATE_PRIME_RUNNER:-$TMPW/wt/bin/remote-gate.sh}"
  rc=0; t0=$SECONDS
  REMOTE_GATE_P="$PAR" timeout -k 30 "$TO" "$RUNNER" "$TMPW/wt" "${SEND[@]}" > "$TMPW/run.txt" 2>&1 || rc=$?
  el=$((SECONDS - t0))
  tok=""
  if [ "$el" -ge "$TO" ]; then tok=timeout
  elif [ "$rc" -gt 123 ]; then tok="runner-rc-$rc"
  elif grep -q '^RUNNER-FAILURE ' "$TMPW/run.txt" 2>/dev/null; then tok=runner-failure
  fi
  if [ -n "$tok" ]; then log "could-not-run: $tok on ${SHA:0:12} (${#SEND[@]} suite(s), ${el}s); nothing cached"; exit 0; fi
  mkdir -p "$CDIR/$SHA" || { log "could-not-run: cannot create $CDIR/$SHA"; exit 0; }
  for s in "${SEND[@]}"; do
    v=$(bash "$SG" --classify "$TMPW/run.txt" "$s" 2>/dev/null)
    case "$v" in
      red|green)
        k="$CDIR/$SHA/${s//\//_}"
        if printf '%s\n' "$v" > "$k.tmp.$$" 2>/dev/null && mv -f "$k.tmp.$$" "$k" 2>/dev/null; then
          WROTE+=("$s"$'\t'"$v")
          if [ "$v" = red ]; then RED=$((RED + 1)); else GREEN=$((GREEN + 1)); fi
        else rm -f "$k.tmp.$$"; UNK=$((UNK + 1)); fi ;;
      *) UNK=$((UNK + 1)) ;;
    esac
  done
fi

# ── 7. the stamp ─────────────────────────────────────────────────────────────
mkdir -p "$CDIR/$SHA" || { log "could-not-run: cannot create $CDIR/$SHA"; exit 0; }
P="$CDIR/$SHA/.primed"
{ printf 'primed %s suites=%s red=%s green=%s unknown=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${#SEND[@]}" "$RED" "$GREEN" "$UNK"
  [ "${#WROTE[@]}" -gt 0 ] && printf '%s\n' "${WROTE[@]}"
  true; } > "$P.tmp.$$" && mv -f "$P.tmp.$$" "$P" || { rm -f "$P.tmp.$$"; log "could-not-run: cannot write $P"; exit 0; }
touch "$CDIR/$SHA" 2>/dev/null

# ── 8. prime.tsv ─────────────────────────────────────────────────────────────
k=$(compose_tsv)
log "primed ${SHA:0:12} sent=${#SEND[@]} red=$RED green=$GREEN unknown=$UNK cached=$CACHED tsv_rows=$k"
exit 0
