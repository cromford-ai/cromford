#!/bin/bash
# bin/lib/security-audit.sh — pure helpers of bin/security-audit.sh (BH-7910).
# Sourced, never executed. No root default (D43): every path comes in as an
# argument, and HARNESS is read only to find bin/transcript-cost.sh.
#
#   sa_conf_get <conf> <key>          the value of key=value; rc 1 when absent
#   sa_num_ok <v>                     rc 0 when v is a positive decimal number
#   sa_caps <flag-usd> <flag-min> <conf>
#                                     "<usd> <minutes> <usd-src> <min-src>";
#                                     flag > settings row > conf. rc 2 on a value
#                                     that is not a positive number, or no value.
#   sa_counts <findings.json>         one JSON object {confirmed, needs_validation,
#                                     rejected, note}; null counts when the file
#                                     is missing or not a findings list (D11)
#   sa_cost_usd <ledger> <project> <host> <start-epoch> <transcript-dirs>
#                                     "<usd|null> <ledger|live|none>"; the dirs
#                                     are newline-separated
#   sa_project_slug <cwd>             Claude Code's projects/ directory name for
#                                     a cwd (every non-alphanumeric is "-")
#   sa_transcript_dirs <cwd> <env-dir>
#                                     every projects/<slug> dir a session in cwd
#                                     can write to, one per line
#   sa_dedup_hit <out> <project> <sha> <skill-sha>
#                                     prints the summary.json of a completed run
#                                     with the same target and skill sha; rc 1 none
#   sa_next_run <out> <project>       the lowest unused run number
#   sa_summary_write <path> <json>    validates the JSON, then tmp + mv

sa_conf_get() { # sa_conf_get <conf> <key>
  local conf="${1:-}" key="${2:-}" line
  [ -r "$conf" ] && [ -n "$key" ] || return 1
  line=$(grep -E "^${key}=" "$conf" | tail -1) || return 1
  [ -n "${line#*=}" ] || return 1
  printf '%s' "${line#*=}"
}

sa_num_ok() { # sa_num_ok <value> — a positive decimal, never 0, never empty
  [[ "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v v="$1" 'BEGIN{exit !(v > 0)}'
}

# _sa_cap_one <flag> <settings-key> <conf> <conf-key> — "<value> <source>".
_sa_cap_one() {
  local flag="$1" skey="$2" conf="$3" ckey="$4" v src rc
  if [ -n "$flag" ]; then
    v="$flag"; src=flag
  else
    v=""; rc=1
    if command -v setting_get >/dev/null 2>&1; then
      v=$(setting_get "$skey" 2>/dev/null); rc=$?
    fi
    if [ "$rc" -eq 0 ] && [ -n "$v" ]; then
      src="setting:$skey"
    else
      v=$(sa_conf_get "$conf" "$ckey") || { echo "security-audit: no $ckey (flag, settings row $skey or $conf)" >&2; return 2; }
      src="conf"
    fi
  fi
  sa_num_ok "$v" || { echo "security-audit: $ckey '$v' from $src is not a positive number" >&2; return 2; }
  printf '%s %s' "$v" "$src"
}

sa_caps() { # sa_caps <flag-usd> <flag-min> <conf>
  local u m
  u=$(_sa_cap_one "${1:-}" security_audit.cap_usd "${3:-}" cap_usd) || return 2
  m=$(_sa_cap_one "${2:-}" security_audit.cap_minutes "${3:-}" cap_minutes) || return 2
  printf '%s %s %s %s\n' "${u%% *}" "${m%% *}" "${u#* }" "${m#* }"
}

sa_counts() { # sa_counts <findings.json>
  local f="${1:-}"
  if [ ! -f "$f" ]; then
    jq -nc '{confirmed:null, needs_validation:null, rejected:null, note:"findings.json is missing"}'
    return 0
  fi
  # A top-level array, or an object that carries the list as .findings.
  jq -c '
    (if type == "array" then . elif type == "object" and (.findings | type) == "array" then .findings else null end) as $l
    | if $l == null then
        {confirmed:null, needs_validation:null, rejected:null, note:"findings.json is not a findings list (\(type))"}
      else
        ([$l[] | (.verdict // "(none)") | tostring]) as $v
        | ([$v[] | select(. != "confirmed" and . != "needs_validation" and . != "rejected")] | group_by(.) | map("\(.[0]) x\(length)")) as $u
        | {confirmed: ([$v[] | select(. == "confirmed")] | length),
           needs_validation: ([$v[] | select(. == "needs_validation")] | length),
           rejected: ([$v[] | select(. == "rejected")] | length),
           note: (if ($u | length) > 0 then "not counted, unknown verdict: \($u | join(", "))" else null end)}
      end' "$f" 2>/dev/null \
    || jq -nc '{confirmed:null, needs_validation:null, rejected:null, note:"findings.json is not valid JSON"}'
}

# _sa_ledger_usd <ledger> <project> <host> <start-iso> — the sum of cost_usd of
# the audit rows of this project and host at or after the start; empty when no
# row matched or the ledger is unreadable. Columns are read by header name, and
# a field is split as CSV: a quoted field may hold a comma or a "" quote.
_sa_ledger_usd() {
  local ledger="$1"
  [ -r "$ledger" ] || return 0
  awk -v p="$2" -v h="$3" -v s="$4" '
    function csv(line, f,   n, i, ch, q, cur) {
      n = 0; cur = ""; q = 0
      for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (ch == "\"") {
          if (q && substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ } else q = !q
        } else if (ch == "," && !q) { f[++n] = cur; cur = "" }
        else cur = cur ch
      }
      f[++n] = cur
      return n
    }
    { split("", f); nf = csv($0, f) }
    NR == 1 { for (i = 1; i <= nf; i++) c[f[i]] = i; next }
    !("ts" in c) || !("cost_usd" in c) { next }
    f[c["stage"]] == "audit" && f[c["project"]] == p && f[c["host"]] == h && f[c["ts"]] >= s && f[c["cost_usd"]] != "" {
      t += f[c["cost_usd"]]; n++ }
    END { if (n) printf "%.6f", t }' "$ledger"
}

# sa_project_slug <cwd> — the CLI's own rule (claude.exe: `e.replace(/[^a-zA-Z0-9]/g,"-")`,
# then a slug over 200 characters is cut to 200 plus "-<hash>"). So a
# `.scratch-<pid>` cwd gives `--scratch-<pid>`, never `-.scratch-<pid>`. A cut
# slug prints as its 200-character prefix plus "-*", a glob for the hash.
sa_project_slug() {
  local s="${1:-}"
  s="${s//[^a-zA-Z0-9]/-}"
  if [ "${#s}" -le 200 ]; then printf '%s' "$s"; else printf '%s-*' "${s:0:200}"; fi
}

# sa_transcript_dirs <cwd> <env-dir> — the session's config root is not always
# the caller's: agent-call.sh can run the child under an account's own
# CLAUDE_CONFIG_DIR (account-pick.sh exports it from env/accounts.d/*.env). So
# the candidates are the caller's root plus every CLAUDE_CONFIG_DIR an account
# file declares, each joined with the cwd's slug. The slug holds the run's own
# .scratch-<pid>, so a dir found under any root belongs to this session.
sa_transcript_dirs() {
  local cwd="${1:-}" envd="${2:-}" slug f r d
  [ -n "$cwd" ] || return 0
  slug=$(sa_project_slug "$cwd")
  {
    printf '%s\n' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
    for f in "${ACCOUNTS_DIR:-$envd/accounts.d}"/*.env; do
      [ -r "$f" ] || continue
      ( unset CLAUDE_CONFIG_DIR; set +u; . "$f" >/dev/null 2>&1; [ -n "${CLAUDE_CONFIG_DIR:-}" ] && printf '%s\n' "$CLAUDE_CONFIG_DIR" )
    done
  } | awk 'NF && !seen[$0]++' | while IFS= read -r r; do
    # shellcheck disable=SC2086 # the slug may end in a "-*" glob
    for d in "$r"/projects/$slug; do printf '%s\n' "$d"; done
  done
}

# _sa_live_usd <transcript-dirs> <start-epoch> — the cost of the newest session
# transcript in those directories (newline-separated) written after the start;
# empty when none.
_sa_live_usd() {
  local dirs="$1" start="$2" f line tc d
  local -a ex=()
  while IFS= read -r d; do [ -n "$d" ] && [ -d "$d" ] && ex+=("$d"); done <<<"$dirs"
  [ "${#ex[@]}" -gt 0 ] || return 0
  f=$(find "${ex[@]}" -maxdepth 1 -name '*.jsonl' -newermt "@$start" -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR==1{sub(/^[^ ]* /, ""); print}')
  [ -n "$f" ] || return 0
  tc="${HARNESS:-}/bin/transcript-cost.sh"
  [ -x "$tc" ] || tc="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/transcript-cost.sh"
  [ -x "$tc" ] || return 0
  line=$("$tc" "$f" --since "$start" 2>/dev/null) || return 0
  line=$(cut -d'|' -f5 <<<"$line")
  [[ "$line" =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$line"
}

sa_cost_usd() { # sa_cost_usd <ledger> <project> <host> <start-epoch> <transcript-dirs>
  local start="${4:-0}" iso l v
  iso=$(date -u -d "@$start" +%FT%TZ) || { echo "null none"; return 0; }
  l=$(_sa_ledger_usd "${1:-}" "${2:-}" "${3:-}" "$iso")
  v=$(_sa_live_usd "${5:-}" "$start")
  if [ -z "$l" ] && [ -z "$v" ]; then echo "null none"; return 0; fi
  awk -v l="$l" -v v="$v" 'BEGIN{
    if (l == "") { printf "%.6f live\n", v; exit }
    if (v == "" || l + 0 >= v + 0) { printf "%.6f ledger\n", l; exit }
    printf "%.6f live\n", v }'
}

sa_dedup_hit() { # sa_dedup_hit <out> <project> <sha> <skill-sha>
  local d="${1:-}/${2:-}" s
  [ -n "${3:-}" ] && [ -n "${4:-}" ] || return 1
  for s in "$d"/run-*/summary.json; do
    [ -f "$s" ] || continue
    if ! jq -e . "$s" >/dev/null 2>&1; then
      echo "security-audit: $s is not valid JSON; not a dedup hit" >&2; continue
    fi
    if jq -e --arg a "$3" --arg k "$4" '.sha == $a and .skill_sha == $k and .stopped == "completed"' "$s" >/dev/null 2>&1; then
      printf '%s\n' "$s"; return 0
    fi
  done
  return 1
}

sa_next_run() { # sa_next_run <out> <project>
  local d="${1:-}/${2:-}" n=1
  while [ -e "$d/run-$n" ]; do n=$((n + 1)); done
  printf '%s\n' "$n"
}

sa_summary_write() { # sa_summary_write <path> <json>
  local path="${1:-}" json="${2:-}" tmp
  [ -n "$path" ] || return 1
  printf '%s' "$json" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "security-audit: summary is not a JSON object" >&2; return 1; }
  tmp="$path.tmp.$$"
  printf '%s' "$json" | jq . > "$tmp" && mv -f "$tmp" "$path"
}
