# bin/lib/ironlaw-carry.sh — CARRY AN IRON-LAW ACCEPTANCE ACROSS HEADS (BH-4474).
# Sourced, never executed; nothing runs at source time.
# shellcheck shell=bash
#
# WHY IT EXISTS. An adjudicated ACCEPT is the empty file
# <rec>/iron-law-accepted-<head>, bound to one sha. A push that never touches
# the flagged line (a merge of main, a fixture fix, a renumber) still moves the
# head, and the PR re-parks on the identical false positive and buys another
# adjudication (#4044, #4142 on 2026-10-04).
#
# WHAT IT STORES. At ACCEPT, bin/blocked-resolver.sh records the FINGERPRINT of
# every hit the adjudicated diff carried, one row per distinct fingerprint, in
# the jobs DB's generic `ledgers` table:
#   kind   ironlaw-accept
#   key    <owner/repo lowercased>#<pr>|<sha1(rule TAB path TAB contenthash)>
#   detail {"sha":<judged head>,"rule":..,"path":..,"n":<copies in that set>}
# A fingerprint is (rule id, file, sha1 of the flagged line with its leading
# `+` and surrounding whitespace removed). The line NUMBER is not in it, so a
# moved or re-indented line is the same hit; a changed character is not.
#
# WHAT IT ANSWERS. bin/merge-conductor.sh and bin/merge-sweep.sh, on a head
# with hits and no per-head marker, ask ilc_covered. It carries only when
# every current fingerprint has a row for THIS PR with n at least the current
# count. Anything it cannot prove (an outage, an unparseable row, a crashed
# check, a hit over the cap) is rc 2, which both callers read as "park as
# before". Absent is never covered.

# ilc_root — the harness root, per D43: the caller's, never a literal default.
ilc_root() { printf '%s' "${HARNESS:-${H:-}}"; }

# ilc_pr_key <pr-url> -> "<owner/repo lowercased>#<n>"; rc 1 when it does not parse.
ilc_pr_key() {
  local k
  k=$(printf '%s' "${1:-}" | sed -nE 's#^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)([/?#].*)?$#\1/\2 \3#p')
  [ -n "$k" ] || return 1
  printf '%s#%s' "$(printf '%s' "${k% *}" | tr '[:upper:]' '[:lower:]')" "${k##* }"
}

# ilc_sha1 <text> -> 40 hex. rc 1 when there is no sha1sum.
ilc_sha1() {
  command -v sha1sum >/dev/null 2>&1 || return 1
  printf '%s' "$1" | sha1sum | cut -c1-40
}

# ilc_added <diff-file> -> one "path TAB newline TAB g TAB text" per added,
# non-comment line of every real file. The line number and the normalization
# are bin/checks-run.sh's (so a CHECK-HIT location resolves to its text); g is
# 1 when the line is also in bin/merge-sweep.sh's grep scope (its skip set),
# which is the wider of the two scans' scopes, so the fingerprinted set is
# never smaller than either caller's count.
ilc_added() {
  awk '
    /^\+\+\+ /{
      raw=$2; p=raw; sub(/^b\//,"",p)
      dead = (raw=="/dev/null")
      g = !(raw ~ /\.(test|spec)\.|__tests__\/|__mocks__\/|\/tests?\/|scripts\/migrations\/|\.harness\/specs\//)
      next
    }
    /^@@ /{ n=$3; sub(/^[+]/,"",n); sub(/,.*$/,"",n); cur=n+0; next }
    /^\+/{
      t=substr($0,2)
      if (!dead && t !~ /^[[:space:]]*(\/\/|\*|\/\*|#|--|<!--)/) printf "%s\t%d\t%d\t%s\n", p, cur, g, t
      cur++; next
    }
    /^-/{ next }
    /^ /{ cur++ }
  ' "$1"
}

# ilc_redflag_re — the scan's own inline pattern, built in pieces the way
# brf_redflag_re builds it, so this file's own lines never trip the scan.
ilc_redflag_re() {
  printf '%s' 'window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)|VERCEL'"_URL"
}

# ilc_hits <diff-file> -> one "rule TAB path TAB contenthash" per hit, sorted,
# duplicates kept (a second copy of a line is a second hit).
#   rule = redflag:<the matched token> | check:<slug>
#   rc 0 ok (no output = no hits) | rc 2 the hit set is unknown, and the reason
#   is on stderr: no sha1sum, no harness root, checks-run rc 2 or a crashed
#   check, a CHECK-HIT at no added line, more than ILC_MAX_HITS (default 50).
ilc_hits() {
  local df="${1:-}" max="${ILC_MAX_HITS:-50}" root cr tab=$'\t' added raw out rc
  local loc path line text rule n=0 hash
  case "$max" in ''|*[!0-9]*) max=50 ;; esac
  [ -r "$df" ] || { echo "no readable diff" >&2; return 2; }
  command -v sha1sum >/dev/null 2>&1 || { echo "no sha1sum" >&2; return 2; }
  root=$(ilc_root)
  cr="${ILC_CHECKS_RUN:-}"
  if [ -z "$cr" ]; then
    [ -n "$root" ] || { echo "no harness root" >&2; return 2; }
    cr="$root/bin/checks-run.sh"
  fi
  added=$(ilc_added "$df")
  # rule TAB path TAB text, before hashing
  raw=$(printf '%s\n' "$added" | RE="$(ilc_redflag_re)" awk -F'\t' '
    $3 == 1 {
      t=$0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t)
      if (match(t, ENVIRON["RE"])) printf "redflag:%s\t%s\t%s\n", substr(t, RSTART, RLENGTH), $1, t
    }')
  if [ -x "$cr" ] && [ -s "$df" ]; then
    out=$("$cr" "$df" 2>/dev/null); rc=$?
    if [ "$rc" = 2 ] || grep -q '^CHECK-ERROR ' <<<"$out"; then
      echo "checks-run could not run (rc $rc)" >&2; return 2
    fi
    if [ "$rc" = 1 ]; then
      while read -r _ rule loc _; do
        [ -n "$loc" ] || continue
        path="${loc%:*}"; line="${loc##*:}"
        text=$(printf '%s\n' "$added" | awk -F'\t' -v p="$path" -v l="$line" '
          $1 == p && $2 == l { t=$0; sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, "", t); print t; exit }')
        [ -n "$text" ] || { echo "CHECK-HIT $rule $loc is not an added line" >&2; return 2; }
        raw="${raw:+$raw$'\n'}check:$rule$tab$path$tab$text"
      done < <(printf '%s\n' "$out" | grep '^CHECK-HIT ')
    fi
  fi
  [ -n "$raw" ] || return 0
  n=$(printf '%s\n' "$raw" | grep -c .)
  [ "$n" -le "$max" ] || { echo "$n hits, over the cap of $max" >&2; return 2; }
  out=""
  while IFS="$tab" read -r rule path text; do
    text="${text#"${text%%[![:space:]]*}"}"; text="${text%"${text##*[![:space:]]}"}"
    hash=$(ilc_sha1 "$text") || { echo "no sha1sum" >&2; return 2; }
    out="$out$rule$tab$path$tab$hash"$'\n'
  done <<<"$raw"
  printf '%s' "$out" | LC_ALL=C sort
}

# ilc_record <pr-url> <sha> <hits-file> — one ledger row per distinct
# fingerprint of an ADJUDICATED ACCEPT. Prints the number of rows written.
#   rc 0 every row written | rc 1 a row failed, or the url does not parse.
#   A later ACCEPT overwrites n with its own count: never a wider allowance
#   than the newest ruling on that fingerprint gave.
ilc_record() {
  local url="${1:-}" sha="${2:-}" hf="${3:-}" pk n rule path hash fk detail wrote=0 rc=0
  pk=$(ilc_pr_key "$url") || return 1
  [ -n "$sha" ] && [ -r "$hf" ] || return 1
  command -v job_ledger_put >/dev/null 2>&1 || return 1
  while IFS=$'\t' read -r n rule path hash; do
    [ -n "$hash" ] || continue
    fk=$(ilc_sha1 "$rule"$'\t'"$path"$'\t'"$hash") || return 1
    detail=$(jq -nc --arg s "$sha" --arg r "$rule" --arg p "$path" --argjson n "$n" \
      '{sha:$s,rule:$r,path:$p,n:$n}') || { rc=1; continue; }
    if job_ledger_put ironlaw-accept "$pk|$fk" accepted "$detail"; then wrote=$((wrote+1)); else rc=1; fi
  done < <(LC_ALL=C sort "$hf" | uniq -c | awk '{c=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]/, ""); print c "\t" $0}')
  printf '%s' "$wrote"
  return "$rc"
}

# ilc_covered <pr-url> <scan-count> <diff-file>
#   rc 0 carried: prints the distinct accepted shas the covering rows name.
#   rc 1 not carried: prints one line per uncovered fingerprint,
#        "<rule> <path> (new or changed)" or "<rule> <path> (more copies than accepted)".
#   rc 2 cannot decide: prints the reason. An outage, an unparseable row, an
#        unknown hit set, or a fingerprinted set smaller than the scan's count.
ilc_covered() {
  local url="${1:-}" scan="${2:-}" df="${3:-}" pk hits err total n rule path hash fk row rrc an asha
  local shas="" unc=""
  pk=$(ilc_pr_key "$url") || { echo "unparseable PR url"; return 2; }
  case "$scan" in ''|*[!0-9]*) echo "no scan count"; return 2 ;; esac
  command -v job_ledger_row >/dev/null 2>&1 || { echo "no jobs client"; return 2; }
  err=$(mktemp) || { echo "mktemp failed"; return 2; }
  hits=$(ilc_hits "$df" 2>"$err") || { printf 'hit set unknown: %s\n' "$(head -1 "$err")"; rm -f "$err"; return 2; }
  rm -f "$err"
  total=$(printf '%s' "$hits" | grep -c .)
  [ "$total" -ge "$scan" ] && [ "$total" -gt 0 ] \
    || { echo "fingerprinted $total hit(s), the scan counted $scan"; return 2; }
  while IFS=$'\t' read -r n rule path hash; do
    fk=$(ilc_sha1 "$rule"$'\t'"$path"$'\t'"$hash") || { echo "no sha1sum"; return 2; }
    row=$(job_ledger_row ironlaw-accept "$pk|$fk"); rrc=$?
    case "$rrc" in
      2) unc="${unc}$rule $path (new or changed)"$'\n'; continue ;;
      0) ;;
      *) echo "jobs ledger unreachable"; return 2 ;;
    esac
    [ "$(printf '%s' "$row" | jq -r '.status' 2>/dev/null)" = accepted ] \
      || { echo "ledger row for $rule $path is not an acceptance"; return 2; }
    an=$(printf '%s' "$row" | jq -r '.detail | fromjson | .n // empty' 2>/dev/null)
    asha=$(printf '%s' "$row" | jq -r '.detail | fromjson | .sha // empty' 2>/dev/null)
    case "$an" in ''|*[!0-9]*) echo "ledger row for $rule $path is unparseable"; return 2 ;; esac
    if [ "$an" -lt "$n" ]; then unc="${unc}$rule $path (more copies than accepted)"$'\n'; continue; fi
    [ -n "$asha" ] && shas="${shas}$asha"$'\n'
  done < <(printf '%s\n' "$hits" | uniq -c | awk '{c=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]/, ""); print c "\t" $0}')
  if [ -n "$unc" ]; then printf '%s' "$unc"; return 1; fi
  printf '%s' "$shas" | awk 'NF && !seen[$0]++'
  return 0
}
