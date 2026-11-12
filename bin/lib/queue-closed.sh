#!/bin/bash
# bin/lib/queue-closed.sh — BH-9286: stop the triage queue re-offering lines
# that can never become work.
#
# project-6-os, 2026-11-08: READY-QUEUE.log held lines for issues #38, #421, #854,
# #1371 and #3384, all closed. The unchanged-shard gate (bin/lib/rt/shards.sh)
# re-offered each one every <= 240 min, the call-guard refused each shard with
# rc 74 (`call-guard repeat`), and nothing dropped a line or paged. Two fixes:
#
#   qc_drop_closed <harness> <project> <slug> <units-file> [<queue-lines>]
#     The dispatcher, before any shard is offered, on a GitHub-issue board
#     only. ONE issue-state read per distinct queue key per tick. `closed`:
#     bin/queue-line-drop.sh drops the file line and the D1 `ready` row, and
#     ONLY when that returns rc 0 are the key's `queue` rows taken out of the
#     units file. A key's board and result rows stay. With <queue-lines> (the
#     READY-QUEUE text, QLINES) only the rows that came from it are candidates,
#     so a queued build dir (QDIRS) is never dropped from scope. Anything but
#     `open` or `closed` (rc 75, rc 44, empty, budget low) keeps the line.
#     Prints the dropped canonical keys (" 38 3384"), always rc 0.
#
#   qc_refusal_note <harness> <project> <KEY> <repeat|other> <queue-text>
#     bin/triage-shard.sh, after the call. Counts `call-guard repeat` refusals
#     IN A ROW per key in state/queue-refused/<p>/<KEY>.n ("<n> <sha>"), keyed
#     by a sha of the shard's queue text (TSH_QUEUE), so changed text restarts
#     at 1. Any other outcome deletes the counter. At the threshold: drop the
#     line(s), then ONE warn lane-alert that says
#     "dropped" only when the drop returned rc 0 (bin/alert-line.sh if that
#     fails), then delete the counter.
#     Empty queue text (a hand-run shard, a board-only shard) is a no-op.
#     Always rc 0.
#
# KNOBS (catalog/lanes.d/_lib.queue-closed.json, through lib_env_apply; the
# numbers below are the documented fallback only):
#   QUEUE_CLOSED_DROP (1, 0 = off)   QUEUE_REFUSED_DROP_AFTER (3, 0 = off)
#   QUEUE_REFUSED_KEEP_S (604800)
# shellcheck shell=bash
if [ -n "${QUEUE_CLOSED_LIB:-}" ]; then return 0 2>/dev/null; fi
QUEUE_CLOSED_LIB=1
_QC_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_QC_APPLIED=0

# _qc_knobs <project> — sets _QC_DROP/_QC_AFTER/_QC_KEEP in THIS shell; the
# settings contract is applied once per process (triage-park.sh's idiom).
_qc_knobs() {
  if [ "$_QC_APPLIED" = 0 ]; then
    _QC_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_QC_LIBDIR/lane-gate.sh" ] && . "$_QC_LIBDIR/lane-gate.sh" 2>/dev/null
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply queue-closed "${1:-}"
  fi
  # Fallbacks name their rows in catalog/lanes.d/_lib.queue-closed.json.
  _QC_DROP="${QUEUE_CLOSED_DROP:-1}"
  _QC_AFTER="${QUEUE_REFUSED_DROP_AFTER:-3}"
  _QC_KEEP="${QUEUE_REFUSED_KEEP_S:-604800}"
  case "$_QC_DROP" in 0|1) ;; *) _QC_DROP=1 ;; esac
  case "$_QC_AFTER" in ''|*[!0-9]*) _QC_AFTER=3 ;; esac
  case "$_QC_KEEP" in ''|*[!0-9]*) _QC_KEEP=604800 ;; esac
  # Clamp to the min/max of catalog/lanes.d/_lib.queue-closed.json. lib_env_apply
  # clamps only operator settings rows, so an env-file value lands here raw: a
  # KEEP of 0 would prune every counter before the next refusal reads it and the
  # drop would never happen. 10# reads "08" as 8, not as octal.
  _QC_AFTER=$((10#$_QC_AFTER)); _QC_KEEP=$((10#$_QC_KEEP))
  [ "$_QC_AFTER" -gt 50 ] && _QC_AFTER=50
  [ "$_QC_KEEP" -lt 3600 ] && _QC_KEEP=3600
  [ "$_QC_KEEP" -gt 2592000 ] && _QC_KEEP=2592000
  return 0
}

_qc_stamp() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
_qc_log() { # _qc_log <harness> <project> <text>
  printf '%s [%s] %s\n' "$(_qc_stamp)" "$2" "$3" >> "$1/logs/$2.log" 2>/dev/null || true
}
# _qc_rawkeys — stdin queue lines -> the distinct raw line keys (BH-38), the
# same key-first rule triage_shard_key uses for a queue line.
_qc_rawkeys() {
  sed -nE 's/^(\[HOTFIX\] )?([A-Za-z]+-[0-9]+)([^0-9].*)?$/\2/p' | awk '!s[$0]++'
}

qc_drop_closed() {
  local h="${1:-}" p="${2:-}" slug="${3:-}" u="${4:-}" ql="${5-}" cand keys k rc st raw res
  local dropped="" kept="" failed="" armed=0
  [ -n "$h" ] && [ -n "$p" ] && [ -s "$u" ] || return 0
  _qc_knobs "$p"
  [ "$_QC_DROP" = 1 ] || return 0
  [ -n "$slug" ] || return 0
  cand=$(mktemp "${TMPDIR:-/tmp}/qc-cand.XXXXXX") || return 0
  # The candidate rows: class queue, and, when the READY-QUEUE text was given,
  # a line that is in it (the HOTFIX mark is stripped exactly as shard_collect
  # strips it).
  if [ -n "${5+x}" ]; then
    printf '%s\n' "$ql" | sed 's/^\[HOTFIX\] //' \
      | awk -F'\t' 'NR==FNR { if ($0 != "") q[$0]=1; next } $2=="queue" && ($3 in q)' - "$u" > "$cand" 2>/dev/null
  else
    awk -F'\t' '$2=="queue"' "$u" > "$cand" 2>/dev/null
  fi
  # Issue numbers only: a GitHub board's canonical queue key is the number.
  keys=$(cut -f1 "$cand" | grep -E '^[0-9]+$' | awk '!s[$0]++')
  [ -n "$keys" ] || { rm -f "$cand"; return 0; }
  # shellcheck source=bin/lib/gh-rest.sh
  command -v gh_rest_issue_state_var >/dev/null 2>&1 \
    || { [ -r "$h/bin/lib/gh-rest.sh" ] && . "$h/bin/lib/gh-rest.sh"; }
  command -v gh_rest_issue_state_var >/dev/null 2>&1 || { rm -f "$cand"; return 0; }
  # A closed check is a non-essential read: skipping it keeps the line, which
  # is today's behaviour. rc 0 = low; rc 2 (unknown) proceeds as healthy.
  if command -v _tsh_gh_budget_low >/dev/null 2>&1 && _tsh_gh_budget_low "$h" triage-queue-closed; then
    _qc_log "$h" "$p" "queue-closed: GitHub budget low — no issue-state read this tick, every queue line kept"
    rm -f "$cand"; return 0
  fi
  # shellcheck source=bin/lib/gh-app-auth.sh
  command -v gh_auth_for >/dev/null 2>&1 \
    || { [ -r "$h/bin/lib/gh-app-auth.sh" ] && . "$h/bin/lib/gh-app-auth.sh"; }
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "$slug" && armed=1
  # One read per distinct key: the key list IS the per-tick cache.
  for k in $keys; do
    rc=0; st=""
    # The _var form keeps GH_REST_STATUS in this shell (gh-rest-no-subshell-lint).
    gh_rest_issue_state_var st "$slug" "$k" || rc=$?
    if [ "$rc" = 0 ] && [ "$st" = open ]; then
      continue
    elif [ "$rc" = 0 ] && [ "$st" = closed ]; then
      raw=$(awk -F'\t' -v k="$k" '$1==k {print $3}' "$cand" | _qc_rawkeys)
      # shellcheck disable=SC2086 # raw is a list of validated ticket keys
      if [ -n "$raw" ] && res=$(HARNESS="$h" "$h/bin/queue-line-drop.sh" $raw 2>&1); then
        dropped="$dropped $k"
      else
        failed="$failed $k (${res:-no line key}; $(printf '%s' "$raw" | tr '\n' ' '))"
      fi
    else
      kept="$kept $k (rc $rc, HTTP ${GH_REST_STATUS:-000}${st:+, state $st})"
    fi
  done
  [ "$armed" = 1 ] && command -v gh_auth_reset >/dev/null 2>&1 && gh_auth_reset
  if [ -n "$dropped" ]; then
    local tmp="$u.qc.$$"
    if awk -F'\t' -v ks="$dropped" -v qf="$cand" '
        BEGIN { n = split(ks, a, " "); for (i = 1; i <= n; i++) d[a[i]] = 1
                while ((getline l < qf) > 0) c[l] = 1 }
        !($1 in d && ($0 in c))' "$u" > "$tmp" 2>/dev/null && mv -f "$tmp" "$u"; then
      _qc_log "$h" "$p" "queue-closed: dropped closed issue(s):$dropped — queue line(s) and ready row(s) removed, no shard offered for them"
    else
      rm -f "$tmp"
      _qc_log "$h" "$p" "queue-closed: dropped the line(s) of closed issue(s):$dropped but could not rewrite the units file — they stay in scope this tick only"
    fi
  fi
  [ -n "$failed" ] && _qc_log "$h" "$p" "queue-closed: drop failed for$failed — line kept, offered as before"
  [ -n "$kept" ] && _qc_log "$h" "$p" "queue-closed: kept$kept — issue state unknown, line kept"
  rm -f "$cand"
  printf '%s' "$dropped"
  return 0
}

qc_refusal_note() {
  local h="${1:-}" p="${2:-}" k="${3:-}" kind="${4:-other}" text="${5-}" d f n s sha raw res what msg
  [ -n "$h" ] && [ -n "$p" ] || return 0
  case "$k" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  _qc_knobs "$p"
  d="$h/state/queue-refused/$p"; f="$d/$k.n"
  # Retention: a counter older than the keep window is a run that ended.
  [ -d "$d" ] && find "$d" -maxdepth 1 -type f -name '*.n' -mmin +"$(( (_QC_KEEP + 59) / 60 ))" -delete 2>/dev/null
  [ -n "$text" ] || return 0
  [ "$_QC_AFTER" -gt 0 ] || return 0
  if [ "$kind" != repeat ]; then
    rm -f "$f" 2>/dev/null
    return 0
  fi
  sha=$(printf '%s' "$text" | sha256sum 2>/dev/null | cut -c1-64)
  [ -n "$sha" ] || return 0
  n=0; s=""
  [ -r "$f" ] && read -r n s < "$f" 2>/dev/null
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$s" = "$sha" ]; then n=$((n + 1)); else n=1; fi
  # A counter that cannot be written counts nothing and drops nothing.
  mkdir -p "$d" 2>/dev/null && printf '%s %s\n' "$n" "$sha" > "$f.tmp.$$" 2>/dev/null \
    && mv -f "$f.tmp.$$" "$f" 2>/dev/null || { rm -f "$f.tmp.$$" 2>/dev/null; return 0; }
  [ "$n" -ge "$_QC_AFTER" ] || return 0
  raw=$(printf '%s\n' "$text" | _qc_rawkeys | tr '\n' ' ')
  raw=${raw% }
  # shellcheck disable=SC2086 # raw is a list of validated ticket keys
  if [ -n "$raw" ] && res=$(HARNESS="$h" "$h/bin/queue-line-drop.sh" $raw 2>&1); then
    what="dropped queue line(s) $raw ($res)"
  else
    what="queue line(s) ${raw:-(no line key)} NOT removed: drop failed (${res:-no line key})"
  fi
  msg="[queue-refused] $p $k: call-guard refused $n times in a row on unchanged queue text — $what. Nothing was called; check the issue and re-queue it if it still needs work."
  "$h/bin/lane-alert.sh" --severity warn --id "queue-refused-$p-$k" triage-queue "$msg" >/dev/null 2>&1 \
    || HARNESS="$h" "$h/bin/alert-line.sh" --severity warn --id "queue-refused-$p-$k" --project "$p" \
         "$msg (bin/lane-alert.sh did not run)" >/dev/null 2>&1 || true
  _qc_log "$h" "$p" "queue-refused: $k refused $n times in a row — $what"
  rm -f "$f" 2>/dev/null
  return 0
}
