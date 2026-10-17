#!/bin/bash
# tests/lib/lead-gates-fixture.bh-5878.sh — the layer the BH-5878 gate suites
# (notes, step done, tier tokens, probe hold) add on top of
# tests/lib/lead-worklist-fixture.bh-4956.sh, tests/lib/lead-gates-fixture.bh-5875.sh
# and tests/lib/lead-gates-fixture.bh-5876.sh. Sourced after all three, never run.
# lg8_setup (after lg6_setup) puts in front of the stubs:
#   curl (logged to $T/log/worker like the fixture's own requests):
#     POST /api/lead-reviews/start   the fixture's answer, with the row's
#                                    scope_notes set from the request body (the
#                                    worker stores them on create); start.fail = 500.
#                                    Each body is also appended to $T/log/start.
#     GET  /api/verdict?pr=          bv.<n> when it exists (the fixture's own
#                                    answer otherwise, as before).
#   gh (argv logged to $T/log/gh):
#     GET  issues/<n>/comments       thread.<n>.json (an array) | thread.<n>.fail = 500 |
#                                    else []
# Helpers: lg8_bv <pr> <verdict> <reviewed sha> <updated_at> (the builder verdict
#   with its verdict artifact's updated_at, the lsd_verdict_at read),
#   lg8_starts <pr> (the number of /start bodies for the PR), lg8_notes <pr>
#   (the newest /start body's scope_notes for the PR).

lg8_setup() {
  mv "$T/fakebin/curl" "$T/fakebin/curl.5876"
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
case "\$m \$p" in
  "POST /api/lead-reviews/start")
    ( flock 9; printf '%s\n' "\$body" >> "$T/log/start" ) 9>"$T/start.lock"
    if [ -e "$FX/start.fail" ]; then
      ( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
      printf '{"error":"fixture outage"}\n500'; exit 0
    fi
    out=\$("$T/fakebin/curl.5876" "\$@")
    code=\$(printf '%s' "\$out" | tail -n 1); res=\$(printf '%s' "\$out" | sed '\$d')
    n=\$(printf '%s' "\$body" | jq -r '.scope_notes // empty')
    res=\$(printf '%s' "\$res" | jq -c --arg n "\$n" 'if (.request | type) == "object" and \$n != "" and (.request.scope_notes // "") == "" then .request.scope_notes = \$n else . end')
    printf '%s\n%s' "\$res" "\$code"; exit 0 ;;
  "GET /api/verdict?"*)
    n=\$(printf '%s' "\$p" | sed -n 's/.*pull%2F\([0-9]*\).*/\1/p')
    if [ -r "$FX/bv.\$n" ]; then
      ( flock 9; printf '%s %s %s\n' "\$m" "\$p" "\$body" >> "$T/log/worker" ) 9>"$T/worker.lock"
      printf '%s\n200' "\$(cat "$FX/bv.\$n")"; exit 0
    fi ;;
esac
exec "$T/fakebin/curl.5876" "\$@"
EOF
  mv "$T/fakebin/gh" "$T/fakebin/gh.5876"
  cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
a="\$*"
if [[ "\$a" =~ GET\ repos/[^/]+/[^/]+/issues/([0-9]+)/comments ]]; then
  n="\${BASH_REMATCH[1]}"
  printf '%s\n' "\$a" >> "$T/log/gh"
  if [ -e "$FX/thread.\$n.fail" ]; then printf 'HTTP/2 500\r\n\r\n{"message":"fixture outage"}'; exit 1; fi
  printf 'HTTP/2 200\r\n\r\n'
  cat "$FX/thread.\$n.json" 2>/dev/null || echo '[]'
  exit 0
fi
exec "$T/fakebin/gh.5876" "\$@"
EOF
  chmod +x "$T/fakebin/curl" "$T/fakebin/gh"
}

# lg8_bv <pr> <verdict> <reviewed sha> <updated_at>
lg8_bv() {
  jq -nc --arg v "$2" --arg s "$3" --arg at "$4" '{verdict:$v, reviewed_sha:$s,
    artifacts:[{artifact_kind:"verdict", updated_at:$at, detail:"{}"}]}' > "$FX/bv.$1"
}
lg8_starts() { jq -c --argjson n "$1" 'select(.pr == $n)' "$T/log/start" 2>/dev/null | wc -l | tr -d ' '; }
lg8_notes() { jq -r --argjson n "$1" 'select(.pr == $n) | .scope_notes // ""' "$T/log/start" 2>/dev/null | tail -n 1; }
