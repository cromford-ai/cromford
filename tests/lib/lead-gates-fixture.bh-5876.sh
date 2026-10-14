#!/bin/bash
# tests/lib/lead-gates-fixture.bh-5876.sh — the layer the BH-5876 gate suites
# (self check, body lint, rebase, traced, caps, retry and reclaim, doorbell)
# add on top of tests/lib/lead-worklist-fixture.bh-4956.sh and
# tests/lib/lead-gates-fixture.bh-5875.sh. Sourced after both, never run.
# lg6_setup (after lgf_setup) puts in front of the stubs:
#   curl (logged to $T/log/worker like the fixture's own requests):
#     POST /api/lead-reviews/reclaim-stale    reclaim.json | reclaim.fail = 500 |
#                                             else {"reclaimed":[]}
#     GET  /api/lead-reviews?status=failed*   failed.json (an array of rows) |
#                                             failed.fail = 500 | else no rows
#     POST /api/lead-reviews/<id>/reset       reset.<id> holds the code (200 =
#                                             the row back as requested; 409; 500)
#     POST /api/wakes/lane                    wakes.fail = 500 (else the fixture's 200)
#   gh (argv logged to $T/log/gh):
#     GET  pulls/<n>   head.sha head.<n> ($SHA), base.ref base.<n> (main),
#                      base.repo.default_branch main, head.ref ref.<n>
#                      (ticket/demo), head.repo.full_name hrepo.<n> (the repo),
#                      title title.<n> (t), body body.<n> ($LG6_BODY),
#                      mergeable_state ms.<n> (clean), user.login author.<n>
#                      (cromford[bot]); ghfail.<n> = 500
#     GET  issues/<n>  {body: issue.<n>} (empty body when absent)
#     POST issues/<n>/comments   the comment text appended to $T/log/comments.<n>
#                      with a `----` line after it; commentfail = 500
#     POST actions/workflows/<wf>/dispatches   204 | dispfail = 500
#     GET  actions/runs   runs.json | {"workflow_runs":[]}
#     GET  commits/<sha>/check-runs   checksfail.<sha> = 500 (else the fixture's)
# lg6_reset [risk mode] = lgf_reset (default: no risk_tier row, the tier off),
#   a lead token at $FX/lead-token, no self-check catalog, no conductor state.
# Helpers: lg6_catalog (install catalog/pr-self-check.tsv), lg6_head <pr>
#   <path> <content> [base] (a real commit, published as refs/pull/<pr>/head
#   and fetched into the cromford clone; prints its sha), lg6_main <path>
#   <content> (main moves, in the origin and the clone; prints the new tip),
#   lg6_main_back (main back where lg6_setup found it), lg6_meta <pr> <key>
#   (the newest lr-<pr>- job's meta value), lg6_skips <class>, lg6_rings,
#   lg6_reclaims, lg6_resets, lg6_dispatches, lg6_comments <pr>.

LG6_BODY=$'## Why\nThe gates move from the enqueue to the worklist.\n\n## Acceptance tests\nEvery case drives the tick whole and reads the log.\n'

lg6_setup() {
  LG6_MAIN0=$(git -C "$O" rev-parse main)
  mv "$T/fakebin/curl" "$T/fakebin/curl.5875"
  cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary|-d|--data) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
case "\$body" in @*) body=\$(cat "\${body#@}") ;; esac
p="\${url#https://jobs.test}"
lg() { ( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"; }
case "\$m \$p" in
  "POST /api/lead-reviews/reclaim-stale")
    lg
    if [ -e "$FX/reclaim.fail" ]; then printf '{"error":"fixture outage"}\n500'
    elif [ -r "$FX/reclaim.json" ]; then printf '%s\n200' "\$(cat "$FX/reclaim.json")"
    else printf '{"reclaimed":[]}\n200'; fi
    exit 0 ;;
  "GET /api/lead-reviews?status=failed"*)
    lg
    if [ -e "$FX/failed.fail" ]; then printf '{"error":"fixture outage"}\n500'
    else printf '%s\n200' "\$(jq -c '{requests:., truncated:false}' "$FX/failed.json" 2>/dev/null || echo '{"requests":[],"truncated":false}')"; fi
    exit 0 ;;
  "POST /api/lead-reviews/"*/reset)
    lg
    id="\${p#/api/lead-reviews/}"; id="\${id%/reset}"
    c=\$(cat "$FX/reset.\$id" 2>/dev/null || echo 200)
    case "\$c" in
      200) printf '%s\n200' "\$(jq -nc --arg i "\$id" '{request:{id:\$i, status:"requested"}}')" ;;
      409) printf '{"error":"a review is in flight"}\n409' ;;
      *) printf '{"error":"fixture outage"}\n%s' "\$c" ;;
    esac
    exit 0 ;;
  "POST /api/wakes/lane")
    if [ -e "$FX/wakes.fail" ]; then lg; printf '{"error":"fixture outage"}\n500'; exit 0; fi ;;
esac
exec "$T/fakebin/curl.5875" "\$@"
EOF
  mv "$T/fakebin/gh" "$T/fakebin/gh.5875"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ -X\ POST\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments ]]; then
  n="\${BASH_REMATCH[1]}"
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/commentfail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  f=\$(printf '%s' "\$a" | sed -n 's/.*body=@\([^ ]*\).*/\1/p')
  { cat "\$f" 2>/dev/null; echo ----; } >> "$T/log/comments.\$n"
  printf 'HTTP/2 201\r\n\r\n{}'; exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/issues/([0-9]+)(\ |\$) ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg b "\$(cat "$FX/issue.\${BASH_REMATCH[1]}" 2>/dev/null)" '{body:\$b}'
  exit 0
fi
if [[ "\$a" =~ -X\ POST\ repos/[^/]+/[^/]+/actions/workflows/[^/]+/dispatches ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/dispfail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 204\r\n\r\n'; exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/commits/([0-9a-f]+)/check-runs ]] && [ -e "$FX/checksfail.\${BASH_REMATCH[1]}" ]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/actions/runs ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  printf 'HTTP/2 200\r\n\r\n'
  cat "$FX/runs.json" 2>/dev/null || echo '{"workflow_runs":[]}'
  exit 0
fi
if [[ "\$a" =~ GET\ repos/([^/]+/[^/]+)/pulls/([0-9]+)(\ |\$) ]]; then
  r="\${BASH_REMATCH[1]}"; n="\${BASH_REMATCH[2]}"
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/ghfail.\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  b="\$(cat "$FX/body.\$n" 2>/dev/null || printf '%s' "\$LG6_BODY_DEFAULT")"
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "\$(cat "$FX/head.\$n" 2>/dev/null || echo "$SHA")" --arg br "\$(cat "$FX/base.\$n" 2>/dev/null || echo main)" \
    --arg ref "\$(cat "$FX/ref.\$n" 2>/dev/null || echo ticket/demo)" --arg hr "\$(cat "$FX/hrepo.\$n" 2>/dev/null || echo "\$r")" \
    --arg t "\$(cat "$FX/title.\$n" 2>/dev/null || echo t)" --arg b "\$b" --arg ms "\$(cat "$FX/ms.\$n" 2>/dev/null || echo clean)" \
    --arg u "\$(cat "$FX/author.\$n" 2>/dev/null || echo "cromford[bot]")" \
    '{state:"open", head:{sha:\$s, ref:\$ref, repo:{full_name:\$hr}},
      base:{ref:\$br, repo:{default_branch:"main"}}, user:{login:\$u}, labels:[], title:\$t, body:\$b,
      mergeable:true, mergeable_state:\$ms}'
  exit 0
fi
exec "$T/fakebin/gh.5875" "\$@"
EOF
  chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
  export LG6_BODY_DEFAULT="$LG6_BODY"
}

lg6_reset() {
  lgf_reset "${1:-none}"
  rm -f "$T/log"/comments.* "$H/catalog/pr-self-check.tsv"
  scratch_rm "$H/state/merge-conductor"; scratch_rm "$H/flags"
  printf 'tok-fixture-lead\n' > "$FX/lead-token"; chmod 600 "$FX/lead-token"
}

lg6_catalog() { cp "$LWF_SRC/catalog/pr-self-check.tsv" "$H/catalog/"; }

# lg6_head <pr> <path> <content> [base] — one commit on <base> (default the
# main lg6_setup found) writing <path>; published and fetched; prints its sha.
lg6_head() {
  local gc=(git -C "$W" -c user.email=t@example.invalid -c user.name=t) s
  "${gc[@]}" checkout -q --detach "${4:-$LG6_MAIN0}" || return 1
  mkdir -p "$W/$(dirname "$2")"; printf '%s\n' "$3" > "$W/$2"
  "${gc[@]}" add -A; "${gc[@]}" commit -qm "pr $1: $2" || return 1
  s=$("${gc[@]}" rev-parse HEAD)
  git -C "$W" push -qf "$O" "$s:refs/pull/$1/head" || return 1
  git -C "$T/repos/cromford" fetch -q origin "refs/pull/$1/head" || return 1
  printf '%s\n' "$s"
}

# lg6_main <path> <content> — main moves by one commit, in the origin and the clone.
lg6_main() {
  local gc=(git -C "$W" -c user.email=t@example.invalid -c user.name=t) s
  "${gc[@]}" checkout -q --detach "$LG6_MAIN0" || return 1
  mkdir -p "$W/$(dirname "$1")"; printf '%s\n' "$2" > "$W/$1"
  "${gc[@]}" add -A; "${gc[@]}" commit -qm "main: $1" || return 1
  s=$("${gc[@]}" rev-parse HEAD)
  git -C "$W" push -qf "$O" "$s:refs/heads/main" || return 1
  git -C "$T/repos/cromford" fetch -qf origin main:refs/remotes/origin/main || return 1
  printf '%s\n' "$s"
}
lg6_main_back() {
  git -C "$W" push -qf "$O" "$LG6_MAIN0:refs/heads/main"
  git -C "$T/repos/cromford" fetch -qf origin main:refs/remotes/origin/main
}

lg6_meta() {
  grep "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker" 2>/dev/null | tail -1 | sed 's#^POST /api/jobs ##' \
    | jq -r --arg k "$2" '(.meta // "{}") | fromjson | .[$k] // empty' 2>/dev/null
}
lg6_skips() { lwf_cnt "\\[skip $1\\] " "$L"; }
lg6_rings() { lwf_cnt '^POST /api/wakes/lane .*"kind":"lead-review"' "$T/log/worker"; }
lg6_reclaims() { lwf_cnt '^POST /api/lead-reviews/reclaim-stale ' "$T/log/worker"; }
lg6_resets() { lwf_cnt '^POST /api/lead-reviews/.*/reset ' "$T/log/worker"; }
lg6_dispatches() { lwf_cnt 'actions/workflows/.*/dispatches' "$T/log/gh"; }
lg6_comments() { lwf_cnt '^----$' "$T/log/comments.$1"; }
