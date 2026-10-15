#!/bin/bash
# tests/lib/lpp-stub.sh — a fake of the harness-jobs route the lead's protected
# paths are read from (BH-4148, BH-4140.3): GET/PUT /api/lead-protected-paths.
# Sourced, never executed: `. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1`.
#
# The rows live in ONE JSON file, {"rows":[{repo,glob,added_by,added_at,removed_at}]},
# for any number of repos (repo stored lowercased, as the worker stores it).
#
# lpp_set <rows-file> <owner/repo> [glob...]
#   replaces the repo's rows with these globs, all live (other repos kept).
# lpp_install <bin-dir> <rows-file> <down-flag>
#   writes <bin-dir>/lpp-answer METHOD URL [BODY], which prints what curl -w
#   '\n%{http_code}' would: the body, a newline, the status. It answers
#     GET  ...?repo=<r>[&all=1]  the repo's live rows (all=1 adds removed ones);
#     PUT  {repo,glob,op:add|remove,added_by}  201 new / 200 already live /
#          200 removed (removed_at set) / 404 not live;
#   <down-flag> present: every request answers its content as the status
#   (empty = 500). <rows-file>.raw present: a GET answers that file verbatim.
#   Every request is appended to <rows-file>.log as `METHOD URL`.
# lpp_curl_case [method-var] [url-var] [body-var]
#   prints a `case` arm for a suite's fake curl that hands the request to
#   lpp-answer, e.g.  *"/api/lead-protected-paths"*) lpp-answer "$m" "$url" "$body"; exit 0 ;;
#   Splice it into the curl heredoc ahead of any catch-all arm.
# lpp_jobs_req <rows-file> <down-flag> <method> <path> [body]
#   the same answer with _jobs_req's contract (rc 0 + body on 2xx, rc 2 on
#   404, rc 1 otherwise; JOBS_HTTP set), for suites that stub the jobs
#   client in-shell instead of through curl.

lpp_set() {
  local f="$1" repo g rows
  repo=$(printf '%s' "$2" | tr 'A-Z' 'a-z'); shift 2
  [ -s "$f" ] || printf '{"rows":[]}' > "$f"
  rows=$(for g in "$@"; do printf '%s\n' "$g"; done | jq -Rsc --arg r "$repo" \
    'split("\n") | map(select(length > 0)) | map({repo:$r, glob:., added_by:"test", added_at:"2026-10-04T00:00:00Z", removed_at:null})')
  jq -c --arg r "$repo" --argjson n "$rows" '.rows = ([.rows[] | select(.repo != $r)] + $n)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

lpp_install() {
  local bin="$1" rows="$2" down="$3"
  mkdir -p "$bin"
  [ -s "$rows" ] || printf '{"rows":[]}' > "$rows"
  cat > "$bin/lpp-answer" <<EOF
#!/bin/bash
ROWS="$rows"; DOWN="$down"
m="\$1"; url="\$2"; body="\${3:-}"
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
printf '%s %s\n' "\$m" "\$url" >> "\$ROWS.log"
if [ -e "\$DOWN" ]; then c=\$(cat "\$DOWN"); printf '{"error":"down"}\n%s' "\${c:-500}"; exit 0; fi
q="\${url#*\?}"; [ "\$q" != "\$url" ] || q=""
param() { printf '%s' "&\$q" | tr '&' '\n' | sed -n "s/^\$1=//p" | head -n1; }
case "\$m" in
  GET)
    [ -f "\$ROWS.raw" ] && { printf '%s\n200' "\$(cat "\$ROWS.raw")"; exit 0; }
    r=\$(param repo | tr 'A-Z' 'a-z')
    [ -n "\$r" ] || { printf '{"error":"repo must be owner/name"}\n400'; exit 0; }
    all=\$(param all)
    printf '%s\n200' "\$(jq -c --arg r "\$r" --arg a "\$all" '{rows:[.rows[] | select(.repo == \$r and (\$a == "1" or .removed_at == null))]}' "\$ROWS")" ;;
  PUT)
    r=\$(printf '%s' "\$body" | jq -r '.repo // ""' | tr 'A-Z' 'a-z')
    g=\$(printf '%s' "\$body" | jq -r '.glob // ""')
    op=\$(printf '%s' "\$body" | jq -r '.op // ""')
    by=\$(printf '%s' "\$body" | jq -r '.added_by // ""')
    [ -n "\$r" ] && [ -n "\$g" ] || { printf '{"error":"bad body"}\n400'; exit 0; }
    live=\$(jq -c --arg r "\$r" --arg g "\$g" '[.rows[] | select(.repo == \$r and .glob == \$g and .removed_at == null)] | length' "\$ROWS")
    case "\$op" in
      add)
        [ "\$live" = 0 ] || { printf '{"created":false}\n200'; exit 0; }
        jq -c --arg r "\$r" --arg g "\$g" --arg b "\$by" '.rows += [{repo:\$r, glob:\$g, added_by:\$b, added_at:"2026-10-04T00:00:00Z", removed_at:null}]' "\$ROWS" > "\$ROWS.tmp" && mv "\$ROWS.tmp" "\$ROWS"
        printf '{"created":true}\n201' ;;
      remove)
        [ "\$live" != 0 ] || { printf '{"error":"not live"}\n404'; exit 0; }
        jq -c --arg r "\$r" --arg g "\$g" '.rows |= map(if .repo == \$r and .glob == \$g and .removed_at == null then .removed_at = "2026-10-04T01:00:00Z" else . end)' "\$ROWS" > "\$ROWS.tmp" && mv "\$ROWS.tmp" "\$ROWS"
        printf '{"removed":true}\n200' ;;
      *) printf '{"error":"op must be add or remove"}\n400' ;;
    esac ;;
  *) printf '{"error":"unknown endpoint"}\n404' ;;
esac
EOF
  chmod +x "$bin/lpp-answer"
}

lpp_curl_case() {
  printf '  *"/api/lead-protected-paths"*) lpp-answer "$%s" "$%s" "$%s"; exit 0 ;;\n' "${1:-m}" "${2:-url}" "${3:-body}"
}

lpp_jobs_req() {
  local rows="$1" down="$2" m="$3" p="$4" body="${5:-}" out dir
  dir=$(dirname "$rows")
  [ -x "$dir/lpp-answer" ] || lpp_install "$dir" "$rows" "$down" >/dev/null
  out=$("$dir/lpp-answer" "$m" "http://lpp.stub$p" "$body")
  JOBS_HTTP="${out##*$'\n'}"
  case "$JOBS_HTTP" in
    2*) printf '%s' "${out%$'\n'*}"; return 0 ;;
    404) return 2 ;;
    *) return 1 ;;
  esac
}
