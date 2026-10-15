#!/bin/bash
# tests/lead-verdict-bash32.bh-3565-test.sh — BH-3565: on the lead's Mac
# (/bin/bash 3.2.57) every `bin/lead-verdict.sh post` died in bin/lib/gh-rest.sh
# with `extra[@]: unbound variable`: bash < 4.4 calls "${arr[@]}" of an EMPTY
# array unbound under set -u, and lv_head_check's GH_ETAG=0 read always has an
# empty `extra`. No bash 3.2 exists on a box (bash 5.x does not reproduce it at
# any BASH_COMPAT level), so the 3.2 rule is pinned statically over the files a
# Mac post sources, and the rest is driven through the real entry point:
#   C  the lead-post source closure (derived, not listed) has no unguarded
#      ${name[@]} / ${name[*]} and no bash >= 4 feature; the lint is proven live
#      by mutating copies; gh_rest runs with an empty `extra` under set -u.
#   R  bin/lead-verdict.sh re-execs under a newer bash from LV_BASH_CANDIDATES
#      when the running one is older than LV_BASH_MIN, warns once and carries on
#      when none is found, never loops (LV_BASH_REEXEC), and is a no-op on a
#      modern bash (no probe at all).
#   H  a lead|human post sends `x-lead-verdict-client: <LV_CLIENT_LEVEL>` in
#      its header file; a box post does not.
# The worker half (426 below lead_verdict_min_client) is
# worker/jobs/test/verdicts-client-level.bh-3565.test.js, run at the end.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-verdict-bash32.bh-3565-test.sh
# TEST-CHANGE BH-4140: globs come from the DB, not the TSV
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ============================================================================
# The lint. lv_closure <root> prints the repo-relative files a Mac post can
# source: the entry points, the JC_MODULES literal off bin/jobs-client.sh, and
# every `. "…/<x>.sh"` target named on a non-comment line of a file already in
# the set, walked transitively. A target under `/bin/` resolves from the root
# (`$(_lr_home)/bin/jobs-client.sh`), any other from the sourcing file's dir
# (`${BASH_SOURCE[0]%/*}/gh-rest.sh`, `$SELF_DIR/lib/verdict-status.sh`).
# ============================================================================
lv_closure() {
  local root="$1" f d t next mods m queue seen=" "
  mods=$(sed -n 's/^JC_MODULES="\([^"]*\)".*/\1/p' "$root/bin/jobs-client.sh")
  queue="bin/lead-verdict.sh bin/jobs-client.sh bin/lib/verdict-status.sh bin/lib/lead-reviews.sh"
  for m in $mods; do queue="$queue bin/lib/jobs/$m.sh"; done
  while [ -n "${queue// /}" ]; do
    # shellcheck disable=SC2086
    set -- $queue; f=$1; shift; queue="$*"
    case "$seen" in *" $f "*) continue ;; esac
    seen="$seen$f "
    [ -f "$root/$f" ] || { echo "MISSING:$f"; continue; }
    echo "$f"
    d=${f%/*}
    for t in $(grep -E '(^|[;&|{(]|then|else|do)[[:space:]]*\.[[:space:]]+"' "$root/$f" | grep -vE '^[[:space:]]*#' \
                | grep -oE '/[A-Za-z0-9_./-]+\.sh"' | tr -d '"'); do
      case "$t" in /bin/*) next=${t#/} ;; *) next="$d$t" ;; esac
      queue="$queue $next"
    done
  done
}

# lv_lint <file> <label> prints `<label>:<line>: <why>` per offender. Comment
# lines are skipped; quoted text is not (a hazard inside quotes still runs).
# The guard form ${x[@]+"${x[@]}"} is removed before the array check.
lv_lint() {
  awk -v P="$2" '
    /^[[:space:]]*#/ { next }
    { s = $0
      gsub(/\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\+"\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]\}"\}/, "", s)
      if (s ~ /\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]/) print P ":" NR ": unguarded array expansion"
      if (s ~ /(declare|local|typeset)[[:space:]]+-[A-Za-z]*[Ang]/ \
          || s ~ /(^|[^A-Za-z0-9_])(mapfile|readarray|coproc)([^A-Za-z0-9_]|$)/ \
          || s ~ /\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?|@[QEPAaUuLK])\}/ || s ~ /\[\[[[:space:]]+-v[[:space:]]/ \
          || s ~ /wait[[:space:]]+-n/ || s ~ /%\([^)]*\)T/ || s ~ /EPOCH(SECONDS|REALTIME)/ \
          || s ~ /(^|[^$A-Za-z0-9_])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]/ || s ~ /;;&/ || s ~ /&>>/ || s ~ /\|&/) print P ":" NR ": bash>=4 feature"
    }' "$1"
}

# ============================================================================
# C. the closure and the lint
# ============================================================================
CL=$(lv_closure "$DIR")
grep -q '^MISSING:' <<<"$CL" && bad "C1 a sourced file is missing on disk: $(grep '^MISSING:' <<<"$CL" | tr '\n' ' ')" || ok
MODS=$(sed -n 's/^JC_MODULES="\([^"]*\)".*/\1/p' "$DIR/bin/jobs-client.sh")
[ "$(wc -w <<<"$MODS")" -ge 14 ] && ok || bad "C1 JC_MODULES must be read off bin/jobs-client.sh (got '$MODS')"
for f in bin/lead-verdict.sh bin/jobs-client.sh bin/lib/verdict-status.sh bin/lib/gh-rest.sh bin/lib/gh-rest-etag.sh \
         bin/lib/gh-rest-ledger.sh bin/lib/gh-app-auth.sh bin/lib/env-path.sh $(for m in $MODS; do echo "bin/lib/jobs/$m.sh"; done); do
  grep -qx "$f" <<<"$CL" && ok || bad "C1 the closure must contain $f"
done

OFF=""
while IFS= read -r f; do
  case "$f" in MISSING:*|"") continue ;; esac
  OFF="$OFF$(lv_lint "$DIR/$f" "$f")"$'\n'
done <<<"$CL"
OFF=$(grep . <<<"$OFF")
grep -q 'unguarded array' <<<"$OFF" && bad "C2 unguarded array expansion in the lead-post closure (bash 3.2 dies on an empty one under set -u):"$'\n'"$(grep 'unguarded array' <<<"$OFF")" || ok
grep -q 'bash>=4' <<<"$OFF" && bad "C3 bash >= 4 feature in the lead-post closure:"$'\n'"$(grep 'bash>=4' <<<"$OFF")" || ok

# C4: the lint is live. The pre-fix line 124 and a declare -A are both caught.
L124=$(grep -n 'gh api -i -X "\$m" "\$p" "\$@"' "$DIR/bin/lib/gh-rest.sh" | cut -d: -f1)
[ -n "$L124" ] && ok || bad "C4 the gh api call line in gh-rest.sh must exist"
sed 's/\${extra\[@\]+"\${extra\[@\]}"}/"${extra[@]}"/' "$DIR/bin/lib/gh-rest.sh" > "$T/gh-rest.sh"
R=$(lv_lint "$T/gh-rest.sh" gh-rest.sh)
[ "$R" = "gh-rest.sh:${L124:-x}: unguarded array expansion" ] && ok || bad "C4 the unguarded extra[@] must be reported as gh-rest.sh:$L124, got: $R"
{ cat "$DIR/bin/lib/jobs/req.sh"; echo '  declare -A x'; } > "$T/req.sh"
R=$(lv_lint "$T/req.sh" req.sh)
[ "$R" = "req.sh:$(wc -l < "$T/req.sh" | tr -d ' '): bash>=4 feature" ] && ok || bad "C4 a declare -A must be reported, got: $R"
for hz in 'mapfile -t a < f' 'x=${y,,}' '[[ -v foo ]]' 'local -n r=x' 'printf "%(%s)T" -1' 'exec {fd}>f' 'a |& b' 'echo "${a[*]}"' 'f "${a[@]:1}"'; do
  printf '%s\n' "$hz" > "$T/hz.sh"
  [ -n "$(lv_lint "$T/hz.sh" hz)" ] && ok || bad "C4 the lint must catch: $hz"
done
printf '%s\n' '# "${a[@]}" in a comment' 'n=${#a[@]}' 'for x in ${a[@]+"${a[@]}"}; do :; done' 'local -a a' > "$T/clean.sh"
[ -z "$(lv_lint "$T/clean.sh" clean)" ] && ok || bad "C4 comments, lengths, guarded forms and local -a are clean, got: $(lv_lint "$T/clean.sh" clean)"

# C5: gh_rest with an empty `extra`, under set -u, through _gh_rest_field.
HEAD1=aaaaaaaa11111111111111111111111111111111
mkdir -p "$T/c5bin" "$T/c5h/state" "$T/tmp"
cp "$DIR/tests/lib/rest-emit.sh" "$T/c5bin/restpr"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c5.calls"\nrestpr OPEN %s\n' "$T" "$HEAD1" > "$T/c5bin/gh"
chmod +x "$T/c5bin/restpr" "$T/c5bin/gh"
OUT=$(PATH="$T/c5bin:$PATH" HARNESS="$T/c5h" TMPDIR="$T/tmp" GH_APP_TOKENS=0 bash -uc \
  '. "$1/bin/lib/gh-rest.sh" && GH_ETAG=0 _gh_rest_field repos/o/r/pulls/1 .head.sha' _ "$DIR" 2>"$T/c5.err"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "$HEAD1" ] && ok || bad "C5 GH_ETAG=0 _gh_rest_field under set -u must answer the head (rc $RC, out '$OUT', err $(cat "$T/c5.err"))"
grep -q 'If-None-Match' "$T/c5.calls" 2>/dev/null && bad "C5 GH_ETAG=0 must send no If-None-Match: $(cat "$T/c5.calls")" || ok

# ============================================================================
# A scratch harness: the CLI and everything it sources, a stub gh and a stub
# jobs worker (curl) that records argv and every `-H @file` header file.
# ============================================================================
SLUG=example-org/demo-os
G="$T/gh"; W="$T/worker"; mkdir -p "$G" "$W" "$T/fakebin" "$T/tok"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"
# BH-4140: the lead_protected_paths rows, read by bin/lib/lead-authority.sh
# through the jobs worker. demo-os has none (not governed), as it had no TSV line.
LPPF="$T/lpp.json"; DOWNF="$T/lpp-down"
lpp_install "$T/fakebin" "$LPPF" "$DOWNF"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "$HEAD1" ticket/x main ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
printf '%s\n' "\$*" >> "$W/argv"
while [ \$# -gt 0 ]; do case "\$1" in
  -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;;
  -H) case "\$2" in @*) cat "\${2#@}" >> "$W/hdr" ;; *) printf '%s\n' "\$2" >> "$W/hdr" ;; esac; shift 2 ;;
  *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts)
    printf '%s\n' "\$D" >> "$W/posted"
    printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-09-29T10:00:00Z"})}' <<<"\$D")" ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/"*
printf 'lead-test-token\n' > "$T/tok/lead"; chmod 600 "$T/tok/lead"
H="$T/h"; mkdir -p "$H/logs" "$H/state"
while IFS= read -r f; do
  case "$f" in MISSING:*|"") continue ;; esac
  mkdir -p "$H/${f%/*}"; cp "$DIR/$f" "$H/$f"
done <<<"$CL"
# TEST-CHANGE (BH-3683, BH-4140): the closure carries bin/lib/lead-authority.sh,
# which reads the lead_protected_paths rows from the worker (the stub above), not
# a TSV; when they are unreadable every lead MERGE is withheld (exit 5).

export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
  JOBS_BOX=mac-lead TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" GH_APP_TOKENS=0
unset LEAD_VERDICT_CONTEXT GH_TOKEN LV_BASH_REEXEC LV_BASH_MIN LV_BASH_CANDIDATES

# The stub candidate bash: `-c` is the version probe (answers $T/<name>.ver,
# logged to .probes); anything else is the re-exec (logged to .calls, then run
# under this bash with the environment it was handed).
mkcand() { # mkcand <name> <version-answer>
  printf '%s\n' "$2" > "$T/$1.ver"
  cat > "$T/$1" <<EOF
#!/bin/bash
if [ "\${1:-}" = -c ]; then echo probe >> "$T/$1.probes"; cat "$T/$1.ver"; exit 0; fi
printf '%s\n' "\$*" >> "$T/$1.calls"
printf '%s\n' "\${LV_BASH_REEXEC:-unset}" >> "$T/$1.reexec"
# A re-exec that loops (no LV_BASH_REEXEC guard) is a red test, not a hang.
[ "\$(grep -c . "$T/$1.calls")" -le 2 ] || { echo "re-exec loop" >&2; exit 97; }
exec bash "\$@"
EOF
  chmod +x "$T/$1"; rm -f "$T/$1.calls" "$T/$1.probes" "$T/$1.reexec"
}
cnt() { [ -f "$1" ] && grep -c . "$1" || echo 0; }

# ============================================================================
# R. the re-exec
# ============================================================================
mkcand nb '99 1'
LV_BASH_MIN=99.0 LV_BASH_CANDIDATES="$T/nb" bash "$H/bin/lead-verdict.sh" >/dev/null 2>"$T/r1.err"; RC=$?
[ "$RC" = 2 ] && grep -q 'usage:' "$T/r1.err" && ok || bad "R1 the re-exec'd script prints usage, rc 2 (rc $RC, err $(cat "$T/r1.err"))"
grep -qx "$H/bin/lead-verdict.sh" "$T/nb.calls" 2>/dev/null && ok || bad "R1 the newer candidate must be exec'd with the script path: $(cat "$T/nb.calls" 2>/dev/null)"
grep -qx 1 "$T/nb.reexec" 2>/dev/null && ok || bad "R1 the re-exec must carry LV_BASH_REEXEC=1: $(cat "$T/nb.reexec" 2>/dev/null)"
grep -q 'running under bash' "$T/r1.err" && bad "R1 no warning when a newer bash was found: $(cat "$T/r1.err")" || ok

mkcand nb '99 1'
LV_BASH_MIN=99.0 LV_BASH_CANDIDATES="$T/nb" bash "$H/bin/lead-verdict.sh" post "$SLUG" 41 >/dev/null 2>"$T/r1b.err"; RC=$?
[ "$RC" = 2 ] && grep -qx "$H/bin/lead-verdict.sh post $SLUG 41" "$T/nb.calls" 2>/dev/null && ok \
  || bad "R1 the arguments ride the re-exec unchanged (rc $RC, calls $(cat "$T/nb.calls" 2>/dev/null))"

mkcand old '3 2'; mkcand junk 'GNU bash'
LV_BASH_MIN=99.0 LV_BASH_CANDIDATES="$T/missing $T/old $T/junk" bash "$H/bin/lead-verdict.sh" >/dev/null 2>"$T/r2.err"; RC=$?
[ "$RC" = 2 ] && grep -q 'usage:' "$T/r2.err" && ok || bad "R2 with no newer bash the script still runs: usage, rc 2 (rc $RC, err $(cat "$T/r2.err"))"
[ "$(grep -c 'running under bash' "$T/r2.err")" = 1 ] && ok || bad "R2 exactly one warning line: $(cat "$T/r2.err")"
W2=$(grep 'running under bash' "$T/r2.err")
grep -q "$T/missing" <<<"$W2" && grep -q "$T/old" <<<"$W2" && grep -q "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} " <<<"$W2" && ok \
  || bad "R2 the warning names the running version and the candidates: $W2"
[ "$(cnt "$T/old.calls")" = 0 ] && [ "$(cnt "$T/junk.calls")" = 0 ] && [ "$(cnt "$T/old.probes")" = 1 ] && ok \
  || bad "R2 an old or junk candidate is probed, never exec'd (old calls $(cnt "$T/old.calls"), junk calls $(cnt "$T/junk.calls"))"

mkcand nb '99 1'
LV_BASH_REEXEC=1 LV_BASH_MIN=99.0 LV_BASH_CANDIDATES="$T/nb" bash "$H/bin/lead-verdict.sh" >/dev/null 2>"$T/r3.err"; RC=$?
[ "$RC" = 2 ] && [ "$(cnt "$T/nb.calls")" = 0 ] && [ "$(cnt "$T/nb.probes")" = 0 ] && ok \
  || bad "R3 LV_BASH_REEXEC set skips the block: no probe, no exec (rc $RC, calls $(cnt "$T/nb.calls"), probes $(cnt "$T/nb.probes"))"
grep -q 'running under bash' "$T/r3.err" && bad "R3 no warning on the second pass: $(cat "$T/r3.err")" || ok

mkcand nb '99 1'
LV_BASH_CANDIDATES="$T/nb" bash "$H/bin/lead-verdict.sh" >/dev/null 2>"$T/r4.err"; RC=$?
[ "$RC" = 2 ] && [ "$(cnt "$T/nb.calls")" = 0 ] && [ "$(cnt "$T/nb.probes")" = 0 ] && ok \
  || bad "R4 bash ${BASH_VERSION} >= the default 4.4: no probe, no exec (rc $RC, calls $(cnt "$T/nb.calls"), probes $(cnt "$T/nb.probes"))"
grep -q 'running under bash' "$T/r4.err" && bad "R4 no warning on a modern bash: $(cat "$T/r4.err")" || ok

# ============================================================================
# H. the client level header
# ============================================================================
LVL=$(sed -n 's/^LV_CLIENT_LEVEL=\([0-9]*\).*/\1/p' "$DIR/bin/lead-verdict.sh")
[ -n "$LVL" ] && [ "$LVL" -ge 2 ] && ok || bad "H1 bin/lead-verdict.sh must declare LV_CLIENT_LEVEL >= 2 (got '$LVL')"
rm -f "$W"/*
bash "$H/bin/lead-verdict.sh" post "$SLUG" 41 "$HEAD1" MERGE --source lead >/dev/null 2>"$T/h1.err"; RC=$?
[ "$RC" = 0 ] && [ "$(cnt "$W/posted")" = 1 ] && ok || bad "H1 a lead post goes through (rc $RC, err $(cat "$T/h1.err"))"
grep -qx "x-lead-verdict-client: ${LVL:-x}" "$W/hdr" 2>/dev/null && ok || bad "H1 the lead post's header file carries x-lead-verdict-client: $LVL: $(grep -v -i 'authorization\|token' "$W/hdr" 2>/dev/null)"
grep -q 'x-lead-verdict-client' "$W/argv" 2>/dev/null && bad "H1 the level rides the header file, not argv" || ok
rm -f "$W"/*
bash "$H/bin/lead-verdict.sh" post "$SLUG" 41 "$HEAD1" MERGE --source box >/dev/null 2>"$T/h2.err"; RC=$?
[ "$RC" = 0 ] && [ "$(cnt "$W/posted")" = 1 ] && ok || bad "H2 a box post goes through (rc $RC, err $(cat "$T/h2.err"))"
grep -q 'x-lead-verdict-client' <<<"$(cat "$W/argv" "$W/hdr" 2>/dev/null)" && bad "H2 a box post sends no client level" || ok

echo "lead-verdict-bash32 (BH-3565): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
