#!/bin/bash
# tests/lib/trk-linear-stub.bh-8450.sh — PATH stubs for the bin/trk suites
# (BH-8450). Sourced; defines one function, writes nothing at source time.
#
#   trk_stub_install <stubdir>   writes <stubdir>/curl and <stubdir>/gh
#
# curl plays two hosts, with no network:
#   https://jobs.example/*        the jobs worker. GET .../settings/<key> answers
#                                 $TL_STATE/setting-<key> (line 1 = HTTP code,
#                                 the rest = body), else 404 (no row).
#   anything else                 Linear GraphQL, routed on the operation name,
#                                 from the fixtures in $TL_FIX (read only; a
#                                 test points TL_FIX at its own copy to change
#                                 one). Every request is counted in
#                                 $TL_STATE/reqs as `<seq> <op>`, each mutation
#                                 also in $TL_STATE/mutations. An unknown
#                                 operation answers 400.
# $TL_STATE/arm picks a failure: ratelimit (400 RATELIMITED), comment_fail
# (commentCreate success:false). The stub never writes its argv: the API key
# rides there. A key that is not $TL_KEY_EXPECT is logged in $TL_STATE/authbad.
#
# gh logs `gh <args>` to $TL_STATE/gh.log and exits 1.
# shellcheck shell=bash

trk_stub_install() {
  local d="${1:-}"
  [ -n "$d" ] || return 1
  mkdir -p "$d" || return 1
  cat > "$d/curl" <<'SH'
#!/bin/bash
S="$TL_STATE"; F="$TL_FIX"; url=""; data=""; out=""; fmt=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-binary|-d) data="${2#@}"; shift ;;
    -o) out="$2"; shift ;;
    -w) fmt="$2"; shift ;;
    -X|-m|--max-time|--connect-timeout) shift ;;
    -H) case "$2" in Authorization:*) auth="${2#Authorization: }" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
reply() { # reply <code> <body>
  if [ -n "$out" ]; then printf '%s' "$2" > "$out"; else printf '%s' "$2"; fi
  printf '%s' "$fmt" | sed "s/%{http_code}/$1/g"
  exit 0
}
case "$url" in
  https://jobs.example/*)
    printf '%s\n' "$url" >> "$S/jobs.log"
    f="$S/setting-${url##*/}"
    [ -r "$f" ] && reply "$(head -1 "$f")" "$(sed -n '2,$p' "$f")"
    reply 404 '{"error":"no route"}' ;;
esac
seq=$(( $(cat "$S/seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" > "$S/seq"
[ "$auth" = "$TL_KEY_EXPECT" ] || echo "badauth $seq" >> "$S/authbad"
op=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) ([A-Za-z]+).*/\2/p')
kind=$(jq -r '.query // ""' "$data" 2>/dev/null | sed -nE '1s/^(query|mutation) .*/\1/p')
printf '%s %s\n' "$seq" "$op" >> "$S/reqs"
[ "$kind" = mutation ] && printf '%s %s\n' "$seq" "$op" >> "$S/mutations"
v() { jq -r --arg k "$1" '.variables[$k] // empty' "$data"; }
arm=$(cat "$S/arm" 2>/dev/null)
[ "$arm" = ratelimit ] && reply 400 "$(cat "$F/ratelimited.json")"
ident_of() { # a UUID or an identifier -> the identifier, or empty
  local f; for f in "$F"/issue-*.json; do
    jq -e --arg i "$1" '.data.issue | .id == $i or .identifier == $i' "$f" >/dev/null && { jq -r .data.issue.identifier "$f"; return; }
  done
}
issue() { # issue <identifier> — the fixture plus the labels the stub added
  local dyn="$S/labels-$1.json"; [ -s "$dyn" ] || echo '[]' > "$dyn"
  jq -c --slurpfile d "$dyn" '.data.issue.labels.nodes += $d[0]' "$F/issue-$1.json"
}
label_name() { jq -r --arg i "$1" '.data.issueLabels.nodes[] | select(.id == $i) | .name' "$F/labels.json"; }
case "$op" in
  TrkIssues)
    case "$(v after)" in "") reply 200 "$(cat "$F/issues-page1.json")" ;; cursor-p1) reply 200 "$(cat "$F/issues-page2.json")" ;; esac
    reply 200 '{"data":{"issues":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}' ;;
  TrkIssue|TrkIssueMeta)
    i=$(ident_of "$(v id)"); [ -n "$i" ] && reply 200 "$(issue "$i")"
    reply 200 "$(cat "$F/not-found.json")" ;;
  TrkLabels)
    reply 200 "$(jq -c --arg n "$(v name)" '.data.issueLabels.nodes |= map(select((.name | ascii_downcase) == ($n | ascii_downcase)))' "$F/labels.json")" ;;
  TrkComment)
    jq -j '.variables.body' "$data" > "$S/body-$seq"
    [ "$arm" = comment_fail ] && reply 200 '{"data":{"commentCreate":{"success":false,"comment":null}}}'
    reply 200 '{"data":{"commentCreate":{"success":true,"comment":{"id":"00000000-0000-0000-0000-c00000000001"}}}}' ;;
  TrkUpdate)
    reply 200 "$(jq -nc --arg s "$(v stateId)" '{data:{issueUpdate:{success:true, issue:{state:{id:$s}}}}}')" ;;
  TrkAddLabel|TrkRemoveLabel)
    i=$(ident_of "$(v id)"); l=$(label_name "$(v labelId)"); dyn="$S/labels-$i.json"
    [ -s "$dyn" ] || echo '[]' > "$dyn"
    if [ "$op" = TrkAddLabel ]; then
      jq -c --arg i "$(v labelId)" --arg n "$l" '. + [{id:$i, name:$n}]' "$dyn" > "$dyn.new"
      mv "$dyn.new" "$dyn"; reply 200 '{"data":{"issueAddLabel":{"success":true}}}'
    fi
    jq -c --arg i "$(v labelId)" 'map(select(.id != $i))' "$dyn" > "$dyn.new"
    mv "$dyn.new" "$dyn"; reply 200 '{"data":{"issueRemoveLabel":{"success":true}}}' ;;
  TrkAttach)
    printf '%s' "$(v url)" > "$S/body-$seq"
    reply 200 '{"data":{"attachmentLinkURL":{"success":true,"attachment":{"id":"00000000-0000-0000-0000-a00000000001"}}}}' ;;
esac
reply 400 '{"errors":[{"message":"unknown operation","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}'
SH
  cat > "$d/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$TL_STATE/gh.log"
exit 1
SH
  chmod +x "$d/curl" "$d/gh"
}
