# shellcheck shell=bash
# tests/lib/fake-jobs-attempts.bh-4156.sh — a fake jobs worker for the
# BH-4156 suites, as a `curl` on PATH, so the REAL _jobs_req and the real
# verbs in bin/lib/jobs/*.sh run against it.
#
#   fja_install <dir>   writes <dir>/bin/curl. State lives in <dir>:
#     db.tsv     the pr_attempts rows, one `repo<TAB>number<TAB>kind<TAB>sha`
#                per line, oldest first (a PUT appends)
#     req.log    one `METHOD /path?query` line per request
#     view.json  the body GET /api/pr-state answers (404 when absent)
#     verdict.json  the body GET /api/verdict answers (404 when absent)
#     route404   present: GET /api/conductor-state answers 404 (pre-deploy)
#     routebad   present: it answers a 200 with no arrays
#     drop       numbers the route leaves out as truncated (space list)
#     tabsha     present: PR 4 gets one row whose sha holds a tab
#     down       present: every request is a transport failure (curl rc 7)
#
# The batch answers the order the real route answers (number ascending, newest
# first inside one number), and the per-PR list answers newest first, the
# order GET /api/pr-attempts uses.

fja_install() {
  local d="${1:?}"
  mkdir -p "$d/bin" || return 1
  : > "$d/db.tsv"; : > "$d/req.log"
  cat > "$d/bin/curl" <<EOF
#!/bin/bash
F="$d"
EOF
  cat >> "$d/bin/curl" <<'EOF'
M=GET; URL=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary|-d) BODY="$2"; shift 2 ;;
    -m|--connect-timeout|-w|-H|-o) shift 2 ;;
    -*) shift ;;
    *) URL="$1"; shift ;;
  esac
done
P="/${URL#*://*/}"; PO="${P%%\?*}"; Q=""; [[ "$P" == *\?* ]] && Q="${P#*\?}"
printf '%s %s\n' "$M" "$P" >> "$F/req.log"
[ -e "$F/down" ] && exit 7
qv() { local x v; local -a kv; IFS='&' read -ra kv <<<"$Q"
  for x in "${kv[@]}"; do [ "${x%%=*}" = "$1" ] || continue; v="${x#*=}"; v="${v//+/ }"; printf '%b' "${v//%/\\x}"; return 0; done; return 1; }
out() { printf '%s\n%s' "$2" "$1"; exit 0; }
case "$M $PO" in
  "GET /api/conductor-state")
    [ -e "$F/route404" ] && out 404 '{"error":"not found"}'
    [ -e "$F/routebad" ] && out 200 '{"ok":true}'
    B=$(jq -Rn --arg r "$(qv repo)" --arg ns "$(qv numbers)" --arg drop "$(cat "$F/drop" 2>/dev/null)" \
      --argjson tab "$([ -e "$F/tabsha" ] && echo true || echo false)" '
      ([$ns|split(",")[]|tonumber]|unique) as $want
      | [$drop|split(" ")[]|select(. != "")|tonumber] as $dr
      | ($want - $dr) as $cov
      | [inputs|split("\t")|select(.[0] == $r)|{number:(.[1]|tonumber), kind:.[2], sha:.[3]}] as $rows
      | {repo:$r, numbers:$cov, truncated:(($dr|length) > 0),
         attempts:([$cov[] as $n | ($rows|map(select(.number == $n))|reverse)[]]
                   + (if $tab and ($cov|index(4)) != null then [{number:4, kind:"rebase", sha:"a\tb"}] else [] end))}' "$F/db.tsv")
    out 200 "$B" ;;
  "GET /api/pr-attempts")
    R=$(qv repo); N=$(qv number); K=$(qv kind); S=$(qv sha)
    if [ -n "$S" ]; then
      grep -qxF "$R"$'\t'"$N"$'\t'"$K"$'\t'"$S" "$F/db.tsv" && out 200 '{"attempt":{}}'
      out 404 '{"error":"not found"}'
    fi
    B=$(jq -Rn --arg r "$R" --arg n "$N" --arg k "$K" '[inputs|split("\t")|select(.[0] == $r and .[1] == $n and ($k == "" or .[2] == $k))|{kind:.[2], sha:.[3]}]
      | reverse | {attempts:., count:length}' "$F/db.tsv")
    out 200 "$B" ;;
  "PUT /api/pr-attempts")
    L=$(printf '%s' "$BODY" | jq -r '[.repo, (.number|tostring), .kind, .sha]|join("\t")') || out 400 '{}'
    grep -qxF "$L" "$F/db.tsv" && out 200 '{"recorded":false,"duplicate":true}'
    printf '%s\n' "$L" >> "$F/db.tsv"; out 201 '{"recorded":true,"duplicate":false}' ;;
  "DELETE /api/pr-attempts")
    L="$(qv repo)"$'\t'"$(qv number)"$'\t'"$(qv kind)"$'\t'"$(qv sha)"
    grep -qxF "$L" "$F/db.tsv" || out 404 '{"error":"not found"}'
    grep -vxF "$L" "$F/db.tsv" > "$F/db.tmp"; mv "$F/db.tmp" "$F/db.tsv"; out 200 '{"deleted":true}' ;;
  "GET /api/pr-state") [ -f "$F/view.json" ] && out 200 "$(cat "$F/view.json")"; out 404 '{"error":"not found"}' ;;
  "GET /api/verdict") [ -f "$F/verdict.json" ] && out 200 "$(cat "$F/verdict.json")"; out 404 '{"error":"not found"}' ;;
  "PUT /api/ledger") out 200 '{"ok":true}' ;;
  "GET /api/verdicts") out 200 '{"standing":null}' ;;
  *) out 404 '{"error":"not found"}' ;;
esac
EOF
  chmod +x "$d/bin/curl"
}
