#!/bin/bash
# tests/lib/lead-gates-fixture.bh-5875.sh — the layer the BH-5875 gate suites
# (silence, risk tier, in-build grace, order) add on top of
# tests/lib/lead-worklist-fixture.bh-4956.sh. Sourced after it, never run.
# lgf_setup (after lwf_setup) gives the scratch harness:
#   - example-org/cromford in fleet.conf (box box-demo) and in
#     LEAD_REVIEW_AUTO_REPOS, with a clone at $T/repos/cromford;
#   - the real catalog/silence-markers.tsv (the lead protected paths are the
#     lead_protected_paths rows lwf_setup already serves, BH-4148);
#   - a curl in front of the fixture's: GET /api/verdict?pr= answers $FX/jv.json,
#     else (jv.approve, which lgf_reset writes) a builder APPROVE bound to the
#     PR's head ($FX/head.<n>), else {} (no builder row); jv.fail = 500.
#     POST /api/risk-tiers answers 201.
#     Both are logged to $T/log/worker like the fixture's own requests;
#   - a gh in front of the fixture's: POST issues/<n>/labels (labelfail = 500;
#     adds the label to $FX/labels.<n>), POST issues/<n>/comments
#     (commentfail = 500), GET pulls/<n> with .user.login $FX/author.<n>
#     (default cromford[bot]) and .labels from $FX/labels.<n>;
#   - a stub bin/lead-verdict.sh: argv to $T/log/lv, exit $FX/lvrc (0);
#   - a stub bin/render-rules.sh: exit $FX/renderrc (0).
# lgf_reset re-seeds after lwf_reset: risk_tier.mode for cromford
# ($1, default enforce; `none` = no row), lead_pr_authors = lead-bot, and no
# enqueue or gate state.
# Helpers: lgf_needs <pr>:<head>... (each head CI green, so gate 10 passes a
# head with no builder row), lgf_cmp <head> <files json> [commits json],
# lgf_signed <pr>, lgf_jobs <pr>, lgf_rt_posts.

lgf_setup() {
  local src
  src="$LWF_SRC"
  BH=example-org/cromford
  printf '%s\n' 'cromford example-org/cromford https://bh.test /api/board 1 box-demo' >> "$H/fleet.conf"
  git clone -q "$O" "$T/repos/cromford"
  mkdir -p "$H/catalog"
  # TEST-CHANGE BH-4140: globs come from the DB, not the TSV. lwf_setup's
  # lpp-answer serves the cromford rows; the curl below falls through to it.
  cp "$src/catalog/silence-markers.tsv" "$H/catalog/"
  export LEAD_REVIEW_AUTO_REPOS="$BH"
  mv "$T/fakebin/curl" "$T/fakebin/curl.fx"
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
  "POST /api/risk-tiers") lg; printf '{"ok":true}\n201'; exit 0 ;;
  "GET /api/verdict?"*)
    lg
    if [ -e "$FX/jv.fail" ]; then printf '{"error":"fixture outage"}\n500'
    elif [ -r "$FX/jv.json" ]; then printf '%s\n200' "\$(cat "$FX/jv.json")"
    elif [ -e "$FX/jv.approve" ]; then
      n=\$(printf '%s' "\$p" | sed -n 's/.*pull%2F\([0-9]*\).*/\1/p')
      printf '{"verdict":"APPROVE","reviewed_sha":"%s","job_id":"job-fixture-1"}\n200' "\$(cat "$FX/head.\$n" 2>/dev/null)"
    else printf '{}\n200'; fi
    exit 0 ;;
esac
exec "$T/fakebin/curl.fx" "\$@"
EOF
  mv "$T/fakebin/gh" "$T/fakebin/gh.fx"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ -X\ POST\ repos/[^/]+/[^/]+/issues/([0-9]+)/labels ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/labelfail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  echo needs-human >> "$FX/labels.\${BASH_REMATCH[1]}"
  printf 'HTTP/2 200\r\n\r\n[]'; exit 0
fi
if [[ "\$a" =~ -X\ POST\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/commentfail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 201\r\n\r\n{}'; exit 0
fi
if [[ "\$a" =~ GET\ repos/([^/]+/[^/]+)/pulls\?.*page=([0-9]+) ]]; then
  printf '%s\n' "\$a" >> "$T/log/gh"
  printf 'HTTP/2 200\r\n\r\n'
  [ "\${BASH_REMATCH[2]}" = 1 ] || { echo '[]'; exit 0; }
  r="\${BASH_REMATCH[1]}"
  for f in "$FX"/head.*; do
    [ -e "\$f" ] || continue
    jq -nc --argjson n "\${f##*.}" --arg s "\$(cat "\$f")" --arg r "\$r" \
      '{number:\$n, html_url:("https://github.com/" + \$r + "/pull/" + (\$n|tostring)), draft:false, state:"open", title:"t",
        base:{ref:"main"}, head:{sha:\$s}, updated_at:"2026-10-10T03:00:00Z", labels:[], user:{login:"cromford[bot]", type:"Bot"}}'
  done | jq -sc .
  exit 0
fi
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/pulls/([0-9]+)(\ |\$) ]]; then
  n="\${BASH_REMATCH[1]}"
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/ghfail.\$n" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  l='[]'; [ -r "$FX/labels.\$n" ] && l=\$(jq -Rsc 'split("\n") | map(select(. != "") | {name:.})' "$FX/labels.\$n")
  printf 'HTTP/2 200\r\n\r\n'
  jq -nc --arg s "\$(cat "$FX/head.\$n" 2>/dev/null || echo "$SHA")" --arg u "\$(cat "$FX/author.\$n" 2>/dev/null || echo "cromford[bot]")" \
    --argjson l "\$l" \
    '{state:"open", head:{sha:\$s}, base:{ref:"main"}, user:{login:\$u}, labels:\$l, title:"t", body:"b"}'
  exit 0
fi
exec "$T/fakebin/gh.fx" "\$@"
EOF
  cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/log/lv"
exit "\$(cat "$FX/lvrc" 2>/dev/null || echo 0)"
EOF
  cat > "$H/bin/render-rules.sh" <<EOF
#!/bin/bash
exit "\$(cat "$FX/renderrc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$T/fakebin/curl" "$T/fakebin/gh" "$H/bin/lead-verdict.sh" "$H/bin/render-rules.sh"
}

lgf_reset() {
  lwf_reset
  scratch_rm "$H/state/lead-review-enqueue"; scratch_rm "$H/state/lead-review-gates"
  case "${1:-enforce}" in
    none) ;;
    *) printf '%s' "${1:-enforce}" > "$FX/settings/risk_tier.mode.example-org.cromford" ;;
  esac
  printf 'lead-bot' > "$FX/settings/lead_pr_authors"
  # TEST-CHANGE BH-5878: gate 60 signs off only a head a builder approved (the
  # enqueue's BH-5630 rule, now the gate's), so every head here carries a
  # builder APPROVE unless a suite writes jv.json or removes jv.approve.
  : > "$FX/jv.approve"
}

# lgf_needs <pr>:<head>... — the cromford worklist, in that order
lgf_needs() {
  local pair n s i=0 out='[]'
  for pair in "$@"; do
    n="${pair%%:*}"; s="${pair#*:}"
    echo "$s" > "$FX/head.$n"
    out=$(jq -c --argjson n "$n" --arg s "$s" --argjson i "$i" \
      '. + [{repo:"example-org/cromford", number:$n, url:("https://github.com/example-org/cromford/pull/" + ($n|tostring)),
             head:$s, hotfix:0, nudged:0, approved_at:("2026-10-10T03:00:0" + ($i|tostring) + "Z")}]' <<<"$out")
    i=$((i + 1))
  done
  printf '%s\n' "$out" > "$FX/needs.example-org_cromford.json"
  # TEST-CHANGE (main at #6037): gate 10 (the builder gate) now runs first on
  # the worklist, and the default verdict answer here is {} (no builder row),
  # which gate 10 holds unless CI is green on the head. The suites built on
  # this layer test later gates, so every worklist head is CI green
  # (lwf_ci_green); a case that wants gate 10 to hold sets its own state.
  # shellcheck disable=SC2046  # one sha per word, by design
  lwf_ci_green $(jq -r '.[].head' "$FX/needs.example-org_cromford.json")
}

# lgf_cmp <head> <files json: [[name, status, additions, deletions, patch]...]> [commits json: [[parents, msg]...]]
lgf_cmp() {
  jq -nc --argjson f "$2" --argjson c "${3:-[[1,\"feat: x\"]]}" '{total_commits:($c|length),
    commits:[$c[] | {parents:[range(0; .[0]) | {sha:"p"}], commit:{message:.[1]}}],
    files:[$f[] | {filename:.[0], status:.[1], additions:.[2], deletions:.[3]} + (if .[4] == null then {} else {patch:.[4]} end)]}' > "$FX/cmp.$1"
}

lgf_signed() { lwf_cnt "^post example-org/cromford $1 .* MERGE --source risk-tier" "$T/log/lv"; }
lgf_lv() { lwf_cnt . "$T/log/lv"; }
lgf_jobs() { lwf_cnt "^POST /api/jobs .*\"ticket_id\":\"lr-$1-" "$T/log/worker"; }
lgf_rt_posts() { lwf_cnt '^POST /api/risk-tiers ' "$T/log/worker"; }
lgf_cmp_reads() { lwf_cnt "compare/.*\\.\\.\\.$1" "$T/log/gh"; }
