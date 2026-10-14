#!/bin/bash
# bin/lib/sentry-report.sh — BH-5617 (BH-5611.1): one bash call that reports a
# lane's silent failure to Sentry. Sourced, never executed; defining functions
# is its only effect at source time.
#
# WHY. Three lanes failed with nothing but a log line nobody read: the
# autoenqueue ledger skip (about 150 skips on 2026-10-08), the review pool
# capped below 3 by /tmp, and the merge conductor's WORKER_DEADLINE kill.
#
# sentry_report <level> <lane> <reason> <message> [extra-json] [tags-json]
#   tags-json (BH-6346) is a JSON object of extra tags, for example
#   {"step":"ci-read"}. An object at extra-json's `.tags` (BH-6351) is read the
#   same way and then deleted from extra; tags-json wins over it on a clash.
#   Only a key matching ^[a-z][a-z0-9_]{0,31}$ with a string value is kept, each
#   value cut to 200 chars, at most 8 entries, and the five standard tags win on
#   a clash. Anything else is ignored. The fingerprint does not change.
#   Posts ONE event to the envelope endpoint of HARNESS_SENTRY_DSN, with
#   `curl --max-time 5`. ALWAYS rc 0, and it prints NOTHING on stdout or stderr:
#   bin/lib/fanin.sh reads mc_fanin_outcome's stdout as the outcome word, and
#   that function calls this. The body runs in a subshell with errexit, nounset
#   and pipefail off, so it can never exit its caller or change a caller global.
#
# THE CHECKS, cheapest first. Each one that stops the send returns 0.
#   1. No HARNESS_SENTRY_DSN (or no root): nothing at all. The DSN is a SECRET
#      in env/global.env, never a registry knob, never logged, never on argv.
#   2. A DSN that does not parse: one `dsn-malformed` log line.
#   3. The kill switch: flags/lane-off-sentry-report or its pause_flags row,
#      through lane_paused (all-off stops it too). A caller without
#      bin/lib/lane-gate.sh gets it sourced inside the body's subshell; a
#      lane-gate that does not source means no send.
#   4. The cap: SENTRY_MAX_PER_FP_HOUR through lib_env_apply sentry-report (row >
#      cached row > env > registry default; no literal here). Unresolved: one
#      `cap-unresolved` line and no send. 0 = off.
#   5. DEDUP BEFORE SPEND. The fingerprint is [lane, project, reason]; never a PR
#      or a sha. state/sentry-report/<key>.sends holds one epoch per attempt in
#      the last hour, under flock. An attempt is recorded BEFORE curl runs, so a
#      failed send still counts and a 500 storm cannot become a retry loop. At
#      the cap: one `capped` line per fingerprint per hour, and no send.
#      The capped-first verdict writes "<epoch> <cap>" to <key>.capped. Later
#      calls read it lock-free BEFORE checks 3 and 4: a marker under an hour old
#      and a window still holding that many sends stop the call with no
#      lane-gate or knob read. A raised cap so takes effect when the window
#      drops below the old cap, at most one hour later.
#   6. The send. Any answer but HTTP 200 is one log line with the code, the curl
#      rc and the first 300 bytes of Sentry's body.
#
# Log: $HARNESS/logs/sentry-report.log,
#   <ISO> [sentry-report] <lane> <reason> <word>: <detail>
# Test seams: SENTRY_REPORT_NOW (epoch), HARNESS_SENTRY_CURL (the curl binary).

sentry_report() {
  ( _sr_body "$@" ) >/dev/null 2>&1
  return 0
}

_sr_log() { # _sr_log <root> <lane> <reason> <word> <detail>
  mkdir -p "$1/logs" 2>/dev/null
  printf '%s [sentry-report] %s %s %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$2" "$3" "$4" "$5" >> "$1/logs/sentry-report.log" 2>/dev/null
  return 0
}

# _sr_sha <root> — the harness sha this box runs: the checkout's .git HEAD (read
# from the files by lane-gate's _lg_git_head), else a pool box's HARNESS_COMMIT
# stamp, else `unknown`. Not _lg_harness_commit: that one is rate-limited.
_sr_sha() {
  local co="${HARNESS_CHECKOUT:-$1/../harness-checkout}" sha=""
  if [ -e "$co/.git" ] && command -v _lg_git_head >/dev/null 2>&1; then
    sha=$(_lg_git_head "$co")
  fi
  if [ -z "$sha" ] && [ -r "$co/HARNESS_COMMIT" ]; then
    IFS= read -r sha < "$co/HARNESS_COMMIT"; sha=${sha%$'\r'}
  fi
  if [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then printf '%s' "$sha"; else printf unknown; fi
}

# _sr_ledger <dir> <key> <now> <cap> — prints send, capped-first or capped.
# rc 1 when the lock or the ledger could not be written.
_sr_ledger() {
  local dir="$1" key="$2" now="$3" cap="$4"
  (
    exec 9>>"$dir/$key.lock" || exit 1
    flock -w 2 9 || exit 1
    f="$dir/$key.sends"; t="$f.tmp"
    if [ -f "$f" ]; then
      awk -v c="$((now - 3600))" '$1 ~ /^[0-9]+$/ && $1 > c' "$f" > "$t" || exit 1
    else
      : > "$t" || exit 1
    fi
    n=$(wc -l < "$t")
    if [ "$n" -ge "$cap" ]; then
      mv -f "$t" "$f" || exit 1
      last=$(cut -d' ' -f1 "$dir/$key.capped" 2>/dev/null)
      if [[ "$last" =~ ^[0-9]+$ ]] && [ "$((now - last))" -lt 3600 ] && [ "$((now - last))" -ge 0 ]; then
        echo capped
      else
        printf '%s %s\n' "$now" "$cap" > "$dir/$key.capped"; echo capped-first
      fi
      exit 0
    fi
    printf '%s\n' "$now" >> "$t" && mv -f "$t" "$f" || exit 1
    echo send
  )
}

# _sr_capped_fast <dir> <key> <now> — rc 0 when the fingerprint is surely
# capped: the marker is under an hour old and the ledger still holds at least
# the cap the marker recorded. Anything unreadable is rc 1 (the full path runs).
_sr_capped_fast() {
  local m="$1/$2.capped" f="$1/$2.sends" t c n
  [ -r "$m" ] && [ -r "$f" ] || return 1
  read -r t c < "$m" 2>/dev/null || return 1
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -gt 0 ] || return 1
  [ "$(($3 - t))" -ge 0 ] && [ "$(($3 - t))" -lt 3600 ] || return 1
  n=$(awk -v c="$(($3 - 3600))" '$1 ~ /^[0-9]+$/ && $1 > c' "$f" 2>/dev/null | wc -l)
  [ "$n" -ge "$c" ]
}

_sr_body() {
  set +e +u; set +o pipefail
  local level="$1" lane="$2" reason="$3" msg="$4" extra="$5"
  local h="${HARNESS:-${H:-}}" dsn="${HARNESS_SENTRY_DSN:-}"
  local scheme key host path proj url cap now fp dir verdict id box sha
  local tmpd envf resp code crc ev body xt='{}' at='{}'
  [ -n "$dsn" ] && [ -n "$h" ] || return 0
  [ -n "$lane" ] || lane=unknown
  [ -n "$reason" ] || reason=unknown

  local re='^(https?)://([^@/:]+)(:[^@/]*)?@([^/]+)(/.*)?/([0-9]+)$'
  if [[ ! "$dsn" =~ $re ]] || [[ "$dsn" == *[\"\\[:space:]]* ]]; then
    _sr_log "$h" "$lane" "$reason" dsn-malformed "HARNESS_SENTRY_DSN does not parse as https://<key>@<host>/<project-id>; nothing sent"
    return 0
  fi
  scheme=${BASH_REMATCH[1]}; key=${BASH_REMATCH[2]}; host=${BASH_REMATCH[4]}
  path=${BASH_REMATCH[5]}; url="$scheme://$host$path/api/${BASH_REMATCH[6]}/envelope/"

  [ -n "$extra" ] || extra='{}'
  if ! jq -e 'type == "object"' <<<"$extra" >/dev/null 2>&1; then
    extra=$(jq -nc --arg r "${extra:0:1000}" '{extra_raw: $r}')
  fi
  # Extra tags: extra-json's own .tags object (BH-6351), then the 6th argument,
  # which wins on a clash. .tags leaves extra either way.
  if [ -n "${6:-}" ] && jq -e 'type == "object"' <<<"$6" >/dev/null 2>&1; then at=$6; fi
  xt=$(jq -c --argjson a "$at" '
    def clean: if type == "object" then to_entries
      | map(select((.key | test("^[a-z][a-z0-9_]{0,31}$")) and (.value | type == "string")) | .value |= .[0:200])
      | .[0:8] | from_entries else {} end;
    ((.tags | clean) + ($a | clean)) | to_entries | .[0:8] | from_entries' <<<"$extra" 2>/dev/null)
  [ -n "$xt" ] || xt='{}'
  extra=$(jq -c 'del(.tags)' <<<"$extra" 2>/dev/null) || extra='{}'
  proj=$(jq -r '.project // empty | strings' <<<"$extra" 2>/dev/null)
  [ -n "$proj" ] || proj="${PROJECT:-}"
  [ -n "$proj" ] || proj=-
  now="${SENTRY_REPORT_NOW:-$(date -u +%s)}"
  [[ "$now" =~ ^[0-9]+$ ]] || now=$(date -u +%s)

  dir="$h/state/sentry-report"
  fp=$(printf '%s|%s|%s' "$lane" "$proj" "$reason" | sha1sum | cut -c1-16)

  # A capped fingerprint stops here, before the lane-gate and knob reads below.
  # Lock-free and read-only: the .capped marker holds "<epoch> <cap>" from the
  # last capped-first verdict. A fresh marker and a window still holding that
  # many sends is the verdict the locked ledger would give at that cap.
  if _sr_capped_fast "$dir" "$fp" "$now"; then return 0; fi

  # No lane-gate in the caller: load it here. The body is a subshell, so the
  # caller never sees its functions or globals.
  if ! command -v lane_paused >/dev/null 2>&1; then
    # shellcheck source=lane-gate.sh
    . "$(dirname "${BASH_SOURCE[0]}")/lane-gate.sh" 2>/dev/null || return 0
  fi
  lane_paused sentry-report && return 0

  if command -v lib_env_apply >/dev/null 2>&1; then
    cap=$(lib_env_apply sentry-report >/dev/null 2>&1; printf '%s' "${SENTRY_MAX_PER_FP_HOUR:-}")
  else
    cap="${SENTRY_MAX_PER_FP_HOUR:-}"
  fi
  if ! [[ "$cap" =~ ^[0-9]+$ ]]; then
    _sr_log "$h" "$lane" "$reason" cap-unresolved "SENTRY_MAX_PER_FP_HOUR has no row, env value or registry default ('$cap'); nothing sent"
    return 0
  fi
  [ "$cap" -gt 0 ] || return 0

  mkdir -p "$dir" && verdict=$(_sr_ledger "$dir" "$fp" "$now" "$cap") || verdict=""
  case "$verdict" in
    send) ;;
    capped-first)
      _sr_log "$h" "$lane" "$reason" capped "project $proj reached SENTRY_MAX_PER_FP_HOUR=$cap sends this hour; no more sends for this fingerprint until it rolls"
      return 0 ;;
    capped) return 0 ;;
    *) _sr_log "$h" "$lane" "$reason" ledger-unwritable "no lock or no write on $dir/$fp.sends; nothing sent"
       return 0 ;;
  esac

  case "$level" in fatal|error|warning|info|debug) ;; *) level=error ;; esac
  id=$(tr -d '-' < /proc/sys/kernel/random/uuid 2>/dev/null)
  [[ "$id" =~ ^[0-9a-f]{32}$ ]] || id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  box="${JOBS_BOX:-$(hostname -s 2>/dev/null || printf unknown)}"
  sha=$(_sr_sha "$h")

  tmpd="$h/tmp"; mkdir -p "$tmpd" 2>/dev/null && [ -w "$tmpd" ] || tmpd="${TMPDIR:-/tmp}"
  envf=$(mktemp "$tmpd/sentry-envelope.XXXXXX") || return 0
  resp=$(mktemp "$tmpd/sentry-resp.XXXXXX") || { rm -f "$envf"; return 0; }
  # Removed by hand on every return below. An EXIT trap cannot do it: it fires
  # when the subshell exits, after this function returned and its locals died.
  ev=$(jq -nc --arg id "$id" --argjson ts "$now" --arg lv "$level" --arg lane "$lane" \
    --arg box "$box" --arg sha "$sha" --arg msg "${msg:0:1000}" --arg proj "$proj" \
    --arg reason "$reason" --argjson extra "$extra" --argjson xt "$xt" '
    {event_id: $id, timestamp: $ts, level: $lv, platform: "other", logger: $lane,
     server_name: $box, message: {formatted: $msg},
     fingerprint: [$lane, $proj, $reason],
     tags: ($xt + {lane: $lane, project: $proj, box: $box, harness_sha: $sha, reason: $reason}),
     extra: $extra}
    + (if $sha == "unknown" then {} else {release: $sha} end)') || { rm -f "$envf" "$resp"; return 0; }
  {
    jq -nc --arg id "$id" --arg at "$(date -u -d "@$now" '+%Y-%m-%dT%H:%M:%SZ')" '{event_id: $id, sent_at: $at}'
    jq -nc '{type: "event", content_type: "application/json"}'
    printf '%s\n' "$ev"
  } > "$envf" || { rm -f "$envf" "$resp"; return 0; }

  # The key rides the config on stdin, never argv: a `ps` reader cannot see it.
  code=$(printf 'url = "%s"\nheader = "X-Sentry-Auth: Sentry sentry_version=7, sentry_key=%s, sentry_client=cromford-bash/1.0"\nheader = "Content-Type: application/x-sentry-envelope"\n' \
           "$url" "$key" \
         | "${HARNESS_SENTRY_CURL:-curl}" -sS -K - --max-time 5 --connect-timeout 3 \
             -o "$resp" -w '%{http_code}' --data-binary @"$envf")
  crc=$?
  body=$(head -c 300 "$resp" 2>/dev/null | tr '\n\r\t' '   ')
  rm -f "$envf" "$resp"
  [ "$crc" = 0 ] && [ "$code" = 200 ] && return 0
  _sr_log "$h" "$lane" "$reason" send-failed "project $proj http=${code:-none} curl_rc=$crc body=${body:-<empty>}"
  return 0
}
