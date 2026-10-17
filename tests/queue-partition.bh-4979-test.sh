#!/bin/bash
# tests/queue-partition.bh-4979-test.sh — BH-4979: impact partitioning in the
# merge queue. Every queued PR gets an impact set (the suites
# bin/test-impact.sh maps its changed files to, minus the always-suites), PRs
# whose sets don't intersect land in separate partitions, and a high-tier or
# unmappable PR goes to the serial lane. Shipped dark: the conf stays
# queue_mode=serial and the mode row defaults to shadow.
#
#   P1-P8  bin/lib/queue-partition.sh qp_impact / qp_partition on a fixture
#          map (--map), through the real bin/test-impact.sh select --why
#   U1-U5  qp_scopes_json + qp_upload: the PUT, the per-head ledger, the key
#          never on argv or in the log, no key = rc 2 and no call
#   E1-E5  the real mc_enqueue_mergify (bin/lib/mc/queue.sh) with gh and curl
#          stubs on PATH: shadow logs a PARTITION line, enforce on a parallel
#          conf fails closed (rc 3, no label), E5 deletes the block and E1 goes red
#   R1-R4  bin/mergify-template.sh queue_mode / scope_default_capacity
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/queue-partition.bh-4979-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

QP_LIB="$DIR/bin/lib/queue-partition.sh"
[ -r "$QP_LIB" ] || { echo "FAIL: $QP_LIB does not exist (BH-4979 not built)"; echo "PASS=0 FAIL=1"; exit 1; }

# ============================================================================
# The fixture tree: a scratch root with its own bin/test-impact.sh and a
# hand-written map, so the selection is exactly what the cases say it is.
# ============================================================================
R="$T/r"; mkdir -p "$R/bin" "$R/tests" "$R/docs" "$R/worker/jobs" "$R/bin/lib/mc" "$R/.github"
cp "$DIR/bin/test-impact.sh" "$R/bin/test-impact.sh"
scratch_install_closure bin/test-impact.sh "$R" >/dev/null
MAP="$T/map"
{
  printf 'tests/always-test.sh\t*\n'
  printf 'tests/always2-test.sh\t*\n'
  for s in a b c d e; do printf 'tests/%s-test.sh\tbin/%s.sh\n' "$s" "$s"; done
  printf 'tests/foo-test.sh\tbin/foo1.sh\n'
  printf 'tests/foo-test.sh\tbin/foo2.sh\n'
  # the chain: x -> s1, y -> s1 s2, z -> s2
  printf 'tests/s1-test.sh\tbin/x.sh\n'
  printf 'tests/s1-test.sh\tbin/y.sh\n'
  printf 'tests/s2-test.sh\tbin/y.sh\n'
  printf 'tests/s2-test.sh\tbin/z.sh\n'
  # the adversarial paths the serial ERE must catch even though the map CAN place them
  printf 'tests/gh-test.sh\t.github/\n'
  printf 'tests/mergify-test.sh\t.mergify.yml\n'
  printf 'tests/schema-test.sh\tworker/jobs/schema.sql\n'
  printf 'tests/mc-test.sh\tbin/lib/mc/\n'
  # an always-suite that ALSO names a file directly stays in the impact set
  printf 'tests/always-test.sh\tbin/e.sh\n'
} | LC_ALL=C sort > "$MAP"
for s in $(cut -f1 "$MAP" | sort -u); do printf '#!/bin/bash\n:\n' > "$R/$s"; done
for f in a b c d e foo1 foo2 x y z; do printf '#!/bin/bash\n:\n' > "$R/bin/$f.sh"; done
touch "$R/.mergify.yml" "$R/worker/jobs/schema.sql" "$R/bin/lib/mc/queue.sh" "$R/docs/guide.md"

# imp <out-file> <path>... — qp_impact on those changed paths, against the fixture.
imp() {
  local out="$1"; shift
  printf '%s\n' "$@" > "$T/changed"
  ( HARNESS="$R"; unset H; . "$QP_LIB"; qp_impact "$T/changed" "$MAP" ) > "$out" 2>"$T/imp.err"
}
part() { ( . "$QP_LIB"; qp_partition "$1" ) 2>"$T/part.err"; }
pid() { awk -F'\t' -v p="$2" '$1 == p { print $2 }' <<<"$1"; }

# ── P1: three disjoint PRs, three partitions ────────────────────────────────
P="$T/p1"; mkdir -p "$P"
imp "$P/101.impact" bin/a.sh; imp "$P/102.impact" bin/b.sh; imp "$P/103.impact" bin/c.sh
head -1 "$P/101.impact" | grep -qx 'lane=scoped' && ok || bad "P1 bin/a.sh is a scoped lane: $(cat "$P/101.impact") $(cat "$T/imp.err")"
grep -qx 'tests/a-test.sh' "$P/101.impact" && ok || bad "P1 101's impact set holds tests/a-test.sh: $(cat "$P/101.impact")"
OUT=$(part "$P")
A=$(pid "$OUT" 101); B=$(pid "$OUT" 102); C=$(pid "$OUT" 103)
[ -n "$A" ] && [ -n "$B" ] && [ -n "$C" ] && [ "$A" != "$B" ] && [ "$B" != "$C" ] && [ "$A" != "$C" ] \
  && [ "$(cut -f2 <<<"$OUT" | sort -u | grep -c .)" = 3 ] && ok \
  || bad "P1 three disjoint PRs must be three partitions: $OUT $(cat "$T/part.err")"
[ "$A" = p101 ] && [ "$B" = p102 ] && [ "$C" = p103 ] && ok || bad "P1 a partition id is p<lowest PR>: $OUT"
[ "$(cut -f1 <<<"$OUT" | tr '\n' ' ')" = "101 102 103 " ] && ok || bad "P1 output is sorted by PR: $OUT"

# ── P2: two PRs touching the same suite share one partition ─────────────────
P="$T/p2"; mkdir -p "$P"
imp "$P/7.impact" bin/foo1.sh; imp "$P/12.impact" bin/foo2.sh; imp "$P/30.impact" bin/a.sh
OUT=$(part "$P")
[ "$(pid "$OUT" 7)" = p7 ] && [ "$(pid "$OUT" 12)" = p7 ] && ok || bad "P2 two PRs selecting tests/foo-test.sh share partition p7: $OUT"
[ "$(pid "$OUT" 30)" = p30 ] && ok || bad "P2 the unrelated PR keeps its own partition: $OUT"

# ── P3: an unmappable file goes to the serial lane ──────────────────────────
imp "$T/p3.impact" bin/brand-new.sh
[ "$(head -1 "$T/p3.impact")" = 'lane=serial reason=full: unknown reach (bin/brand-new.sh)' ] && ok \
  || bad "P3 an unmappable file is serial with test-impact's reason verbatim: $(head -1 "$T/p3.impact")"
P="$T/p3"; mkdir -p "$P"; cp "$T/p3.impact" "$P/5.impact"; imp "$P/6.impact" bin/a.sh
OUT=$(part "$P")
[ "$(pid "$OUT" 5)" = serial ] && ok || bad "P3 qp_partition prints serial for it: $OUT"
[ "$(pid "$OUT" 6)" = p6 ] && ok || bad "P3 a serial PR never joins a scoped partition: $OUT"
# A mixed PR (one mappable file, one not) is serial too.
imp "$T/p3b.impact" bin/a.sh bin/brand-new.sh
head -1 "$T/p3b.impact" | grep -q '^lane=serial reason=full: unknown reach' && ok || bad "P3 a mixed PR is serial: $(head -1 "$T/p3b.impact")"

# ── P4: always-suites are not an intersection ───────────────────────────────
P="$T/p4"; mkdir -p "$P"
imp "$P/40.impact" bin/a.sh; imp "$P/41.impact" bin/b.sh
grep -q 'always' "$P/40.impact" && bad "P4 the always-suites are left out of the impact set: $(cat "$P/40.impact")" || ok
OUT=$(part "$P")
[ "$(pid "$OUT" 40)" != "$(pid "$OUT" 41)" ] && ok || bad "P4 two PRs sharing only always-suites are two partitions: $OUT"
# ... but an always-suite that ALSO names the changed file directly stays.
imp "$T/p4e.impact" bin/e.sh
grep -qx 'tests/always-test.sh' "$T/p4e.impact" && grep -qx 'tests/e-test.sh' "$T/p4e.impact" && ok \
  || bad "P4 a suite picked by another kind as well stays in the set: $(cat "$T/p4e.impact")"
grep -qx 'tests/always2-test.sh' "$T/p4e.impact" && bad "P4 an always-only suite never joins: $(cat "$T/p4e.impact")" || ok

# ── P5: the adversarial negatives, each serial ──────────────────────────────
serial_for() { # serial_for <case> <reason-substring> <path>...
  local c="$1" want="$2"; shift 2
  imp "$T/p5.impact" "$@"
  local h; h=$(head -1 "$T/p5.impact")
  case "$h" in "lane=serial reason="*"$want"*) ok ;; *) bad "P5 $c must be serial ($want): $h $(cat "$T/imp.err")" ;; esac
  [ "$(grep -c . "$T/p5.impact")" = 1 ] && ok || bad "P5 $c: a serial impact carries no scope lines: $(cat "$T/p5.impact")"
}
serial_for github 'serial path (.github/x.yml)' .github/x.yml
serial_for mergify 'serial path (.mergify.yml)' .mergify.yml
serial_for schema 'serial path (worker/jobs/schema.sql)' worker/jobs/schema.sql
serial_for mc 'serial path (bin/lib/mc/queue.sh)' bin/lib/mc/queue.sh
serial_for new-file 'unknown reach (bin/x2.sh)' bin/x2.sh
mapfile -t MANY < <(for i in $(seq 1 26); do echo "docs/n$i.md"; done)
serial_for 26-files 'too-many-files (26 > 25)' "${MANY[@]}"
mapfile -t MANY < <(for i in $(seq 1 25); do echo "docs/n$i.md"; done)
imp "$T/p5.impact" "${MANY[@]}"; head -1 "$T/p5.impact" | grep -qx 'lane=scoped' && ok || bad "P5 25 files is still scoped: $(head -1 "$T/p5.impact")"
# fix-main-red, a train title, a train ref
printf 'bin/a.sh\n' > "$T/changed"
H1=$( ( HARNESS="$R"; QP_LABELS="hotfix,fix-main-red"; . "$QP_LIB"; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=fix-main-red' ] && ok || bad "P5 a fix-main-red PR is serial: $H1"
H1=$( ( HARNESS="$R"; QP_TITLE="batch(cromford): land 3 approved siblings as one train"; . "$QP_LIB"; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=train' ] && ok || bad "P5 a batch train is serial: $H1"
H1=$( ( HARNESS="$R"; QP_HEAD_REF="train/x"; . "$QP_LIB"; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=train' ] && ok || bad "P5 a train/ ref is serial: $H1"
# the file list could not be read: an empty list and a missing file
: > "$T/empty"
H1=$( ( HARNESS="$R"; . "$QP_LIB"; qp_impact "$T/empty" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=files-unavailable' ] && ok || bad "P5 an empty file list is serial, never 'no impact': $H1"
H1=$( ( HARNESS="$R"; . "$QP_LIB"; qp_impact "$T/nonexistent" "$MAP" ); echo "rc=$?")
grep -q '^lane=serial reason=files-unavailable' <<<"$H1" && grep -q 'rc=0' <<<"$H1" && ok || bad "P5 an unreadable list is serial, rc 0: $H1"
# the risk-tier seam (#4973): a risk_tier answering high is serial
H1=$( ( HARNESS="$R"; . "$QP_LIB"; risk_tier() { echo high; }; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=risk-tier high' ] && ok || bad "P5 risk_tier high is serial: $H1"
H1=$( ( HARNESS="$R"; . "$QP_LIB"; risk_tier() { echo low; }; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=scoped' ] && ok || bad "P5 risk_tier low stays scoped: $H1"
# the serial ERE is a settings row first, the constant only as fallback
H1=$( ( HARNESS="$R"; . "$QP_LIB"; setting_get() { [ "$1" = queue_partition.serial_re ] && printf '^bin/a\\.sh$'; }; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=serial path (bin/a.sh)' ] && ok || bad "P5 the queue_partition.serial_re row is read: $H1"
H1=$( ( HARNESS="$R"; . "$QP_LIB"; setting_get() { printf '(unclosed'; }; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=serial_re invalid' ] && ok || bad "P5 an invalid serial_re row is serial, never a silent pass: $H1"
# no harness root at all: refuse cleanly (D43), serial
H1=$( ( unset HARNESS H; . "$QP_LIB"; qp_impact "$T/changed" "$MAP" ) | head -1)
[ "$H1" = 'lane=serial reason=no harness root' ] && ok || bad "P5 an empty root is serial: $H1"

# ── P6: docs-only is the synthetic scope _inert ─────────────────────────────
imp "$T/p6.impact" docs/guide.md
[ "$(cat "$T/p6.impact")" = $'lane=scoped\n_inert' ] && ok || bad "P6 docs-only is scoped as _inert: $(cat "$T/p6.impact")"
J=$( ( . "$QP_LIB"; qp_scopes_json "$T/p6.impact" ) )
[ "$(jq -c . <<<"$J")" = '{"scopes":["_inert"],"all_scopes":false}' ] && ok || bad "P6 the _inert payload: $J"

# ── P7: a transitive chain is one partition ─────────────────────────────────
P="$T/p7"; mkdir -p "$P"
imp "$P/70.impact" bin/x.sh; imp "$P/71.impact" bin/z.sh; imp "$P/72.impact" bin/y.sh; imp "$P/73.impact" bin/d.sh
OUT=$(part "$P")
[ "$(pid "$OUT" 70)" = p70 ] && [ "$(pid "$OUT" 71)" = p70 ] && [ "$(pid "$OUT" 72)" = p70 ] && ok \
  || bad "P7 A∩B, B∩C puts A, B and C in one partition: $OUT"
[ "$(pid "$OUT" 73)" = p73 ] && ok || bad "P7 the unrelated PR is alone: $OUT"

# ── P8: the same answer under mawk and gawk ─────────────────────────────────
for awkbin in mawk gawk; do
  command -v "$awkbin" >/dev/null || { echo "P8 $awkbin not installed — that half skipped"; continue; }
  mkdir -p "$T/awk-$awkbin"; ln -sf "$(command -v "$awkbin")" "$T/awk-$awkbin/awk"
  for d in p1 p2 p7; do
    A=$(part "$T/$d")
    B=$(PATH="$T/awk-$awkbin:$PATH" part "$T/$d")
    [ "$A" = "$B" ] && [ -n "$B" ] && ok || bad "P8 $d under $awkbin: '$B' vs '$A' $(cat "$T/part.err")"
  done
done

# ============================================================================
# U. the payload, the PUT and the ledger
# ============================================================================
SLUG=example-org/cromford
HEAD1=aaaaaaaa11111111111111111111111111111111
HEAD2=bbbbbbbb22222222222222222222222222222222
KEY='fixture-key-7f3a9c'
M="$T/mergify"; mkdir -p "$M" "$T/fakebin"
# The stub curl. A PUT to …/scopes records argv (one per line), stdin (the
# --config) and the body, and answers $M/code (default 200) on -w.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
n=\$(( \$(cat "$M/n" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$M/n"
printf '%s\n' "\$@" > "$M/argv.\$n"
cat > "$M/stdin.\$n"
D=""; prev=""; for a in "\$@"; do [ "\$prev" = --data-binary ] && D="\$a"; prev="\$a"; done
printf '%s' "\$D" > "$M/body.\$n"
printf '%s' "\$(cat "$M/code" 2>/dev/null || echo 200)"
EOF
chmod +x "$T/fakebin/curl"
calls() { cat "$M/n" 2>/dev/null || echo 0; }
mreset() { rm -f "$M"/*; }
SD="$T/state"; mkdir -p "$SD"
upl() { ( PATH="$T/fakebin:$PATH" MERGIFY_API_URL=https://mergify.test/v1 MC_STATE_DIR="$SD"; . "$QP_LIB"; qp_upload "$@" ); }

printf 'lane=scoped\ntests/a-test.sh\ntests/b x/c$-test.sh\n' > "$T/u.impact"
J=$( ( . "$QP_LIB"; qp_scopes_json "$T/u.impact" ) )
[ "$(jq -c . <<<"$J")" = '{"scopes":["tests_a-test.sh","tests_b_x_c_-test.sh"],"all_scopes":false}' ] && ok \
  || bad "U0 scope names are the suite paths sanitised to [A-Za-z0-9._-]: $J"
JS=$( ( . "$QP_LIB"; qp_scopes_json "$T/p3.impact" ) )
[ "$(jq -c . <<<"$JS")" = '{"scopes":[],"all_scopes":true}' ] && ok || bad "U0 a serial impact is the all_scopes barrier: $JS"
printf 'lane=scoped\n%s\n' "$(printf 'z%.0s' {1..150})" > "$T/long.impact"
JL=$( ( . "$QP_LIB"; qp_scopes_json "$T/long.impact" ) )
[ "$(jq -r '.scopes[0] | length' <<<"$JL")" = 100 ] && ok || bad "U0 a scope name is capped at 100 characters: $JL"

# U1: 2xx -> the ledger is written
mreset; scratch_rm "$SD/queue-partition"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$J" 41; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "U1 a 200 PUT is rc 0 after one call (rc $RC, calls $(calls))"
grep -qx -- "https://mergify.test/v1/repos/$SLUG/commits/$HEAD1/scopes" "$M/argv.1" && grep -qx PUT "$M/argv.1" && ok \
  || bad "U1 the PUT goes to …/repos/<slug>/commits/<sha>/scopes: $(cat "$M/argv.1")"
[ "$(cat "$M/body.1")" = "$J" ] && ok || bad "U1 the body is the scopes payload: $(cat "$M/body.1")"
LF="$SD/queue-partition/example-org_cromford_41"
[ -f "$LF" ] && [ "$(cut -f1 "$LF")" = "$HEAD1" ] && ok || bad "U1 the ledger names the head: $(cat "$LF" 2>/dev/null)"

# U2: a 500 is a failure and records nothing
mreset; scratch_rm "$SD/queue-partition"; echo 500 > "$M/code"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$J" 41; RC=$?
[ "$RC" = 1 ] && ok || bad "U2 a 500 is rc 1 (rc $RC)"
[ -f "$LF" ] && bad "U2 a failed PUT is never recorded in the ledger (D9)" || ok
mreset; echo 000 > "$M/code"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$J" 41; RC=$?
[ "$RC" = 1 ] && [ ! -f "$LF" ] && ok || bad "U2 a transport failure (000) is rc 1 and unrecorded (rc $RC)"

# U3: same head + payload -> no second call; a new head or payload calls again
mreset; scratch_rm "$SD/queue-partition"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$J" 41
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$J" 41; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "U3 the same head+payload is not PUT twice (rc $RC, calls $(calls))"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD1" "$JS" 41
[ "$(calls)" = 2 ] && ok || bad "U3 a changed payload on the same head is PUT again (calls $(calls))"
MERGIFY_CI_KEY="$KEY" upl "$SLUG" "$HEAD2" "$JS" 41
[ "$(calls)" = 3 ] && [ "$(cut -f1 "$LF")" = "$HEAD2" ] && ok || bad "U3 a new head is PUT again and replaces the ledger (calls $(calls))"

# U4: the key is never on argv, it rides the --config on stdin
grep -q -- "$KEY" "$M"/argv.* && bad "U4 the key must never be on curl's argv: $(cat "$M"/argv.*)" || ok
grep -q -- "Authorization: Bearer $KEY" "$M/stdin.1" && grep -qx -- '--config' "$M/argv.1" && ok \
  || bad "U4 the key rides --config - on stdin: $(cat "$M/stdin.1")"
# a key with a quote would break out of the curl config line: refused, no call
mreset
MERGIFY_CI_KEY='bad"key' upl "$SLUG" "$HEAD1" "$J" 41; RC=$?
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && ok || bad "U4 a malformed key is rc 2 with no call (rc $RC, calls $(calls))"

# U5: no key -> rc 2, zero calls
mreset
( unset MERGIFY_CI_KEY; upl "$SLUG" "$HEAD1" "$J" 41 ); RC=$?
[ "$RC" = 2 ] && [ "$(calls)" = 0 ] && ok || bad "U5 no MERGIFY_CI_KEY is rc 2 and no call (rc $RC, calls $(calls))"

# ============================================================================
# E. through the real mc_enqueue_mergify
# ============================================================================
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state/merge-conductor" "$H/config/mergify/repos" "$T/tmp"
cp "$DIR/bin/test-impact.sh" "$H/bin/test-impact.sh"
scratch_install_closure bin/test-impact.sh "$H" >/dev/null
for s in $(cut -f1 "$MAP" | sort -u); do mkdir -p "$H/$(dirname "$s")"; cp "$R/$s" "$H/$s"; done
mkdir -p "$H/bin/lib/mc" "$H/docs"; cp "$R"/bin/*.sh "$H/bin/" 2>/dev/null; cp "$DIR/bin/test-impact.sh" "$H/bin/test-impact.sh"
G="$T/gh"; mkdir -p "$G"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
# The stub gh: the PR read ($G/labels, $G/title), its files ($G/files, one per
# line; $G/files-500 forces a failed read), the status POST and the label POST.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$G/calls"
case "\$*" in
  *"-X GET repos/"*"/pulls/"*"/files"*)
    [ -f "$G/files-500" ] && { restpr --raw 500 '{"message":"boom"}'; exit 0; }
    restpr --raw 200 "\$(jq -R -s -c 'split("\n") | map(select(length > 0)) | map({filename: .})' < "$G/files")" ;;
  *"-X GET repos/"*"/pulls/"[0-9]*)
    restpr --raw 200 "\$(jq -nc --arg t "\$(cat "$G/title" 2>/dev/null || echo 'BH-1: a change')" --arg l "\$(cat "$G/labels" 2>/dev/null)" \
      '{title:\$t, head:{ref:"ticket/bh-1", sha:"x"}, labels:(if \$l == "" then [] else (\$l | split(",") | map({name:.})) end)}')" ;;
  *"-X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *"-X POST repos/"*"/labels"*) exit 0 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

CONF_SERIAL="$H/config/mergify/repos/cromford.conf"
conf() { sed "s/^queue_mode=.*/queue_mode=$1/" "$DIR/config/mergify/repos/cromford.conf" > "$CONF_SERIAL"; }
U41="https://github.com/$SLUG/pull/41"
ereset() { rm -f "$G"/* "$M"/*; scratch_rm "$H/state/merge-conductor/queue-partition"; scratch_rm "$H/state/merge-conductor/pr-files"; : > "$H/logs/merge-conductor.log"; printf 'bin/a.sh\n' > "$G/files"; }
LIBROOT="$DIR"
# enq <mode-row|-> <head> — the real conductor lib, the real mc_enqueue_mergify.
# The witness/command reads are replaced (this pins the partition block's order
# and rc, not Mergify's answers); setting_get answers the mode row.
enq() { local mode="$1" head="$2"; (
  export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" GH_APP_TOKENS=0 MERGIFY_API_URL=https://mergify.test/v1 QP_MAP="$MAP"
  . "$LIBROOT/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }
  mc_queue_state() { printf 'queued'; }
  mc_mergify_witness() { return 0; }
  if [ "$mode" != - ]; then eval "setting_get() { [ \"\$1\" = queue_partition.mode ] && { printf '%s' '$mode'; return 0; }; return 2; }"; fi
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify "$SLUG" "$U41" "$head"
) 2>"$T/enq.err"; }
labelled() { grep -q -- "-X POST repos/$SLUG/issues/41/labels" "$G/calls" 2>/dev/null; }
plog() { grep 'PARTITION' "$H/logs/merge-conductor.log"; }

# E1: shadow (no row at all) — a PARTITION line, the label still goes on, no PUT
conf serial; ereset
OUT=$(MERGIFY_CI_KEY="$KEY" enq - "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "E1 shadow leaves the rc alone (rc $RC, out $OUT, err $(cat "$T/enq.err"))"
plog | grep -q "PARTITION $SLUG#41@${HEAD1:0:12} lane=scoped scopes=1 reason=" && ok \
  || bad "E1 shadow logs the lane it would take: $(cat "$H/logs/merge-conductor.log")"
labelled && ok || bad "E1 the label POST is still made: $(cat "$G/calls")"
[ "$(calls)" = 0 ] && ok || bad "E1 shadow uploads nothing (calls $(calls))"
# shadow with a serial PR: the reason is in the line
ereset; printf 'bin/brand-new.sh\n' > "$G/files"
enq shadow "$HEAD1" >/dev/null
plog | grep -q "lane=serial scopes=0 reason=full: unknown reach (bin/brand-new.sh)" && ok \
  || bad "E1 a serial PR's PARTITION line names why: $(plog)"
# the PR's labels reach the classifier
ereset; echo fix-main-red > "$G/labels"
enq shadow "$HEAD1" >/dev/null
plog | grep -q "lane=serial scopes=0 reason=fix-main-red" && ok || bad "E1 the PR's labels are read: $(plog)"
# a failed file read is serial, never "no impact"
ereset; touch "$G/files-500"
enq shadow "$HEAD1" >/dev/null
plog | grep -q "lane=serial scopes=0 reason=files-unavailable" && ok || bad "E1 an unreadable file list is serial: $(plog)"
# an unknown mode row is off, with one log line
ereset
enq bogus "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ! grep -q 'lane=' <<<"$(plog)" && grep -q "queue_partition.mode 'bogus' is not off|shadow|enforce" "$H/logs/merge-conductor.log" && labelled && ok \
  || bad "E1 an unknown mode is off with one log line (rc $RC): $(cat "$H/logs/merge-conductor.log")"
ereset
enq off "$HEAD1" >/dev/null; RC=$?
[ "$RC" = 0 ] && ! grep -q . <<<"$(plog)" && labelled && ok || bad "E1 mode off does nothing on a serial conf (rc $RC): $(plog)"

# E2: enforce + parallel conf + PUT 500 -> rc 3, no label
conf parallel; ereset; echo 500 > "$M/code"
OUT=$(MERGIFY_CI_KEY="$KEY" enq enforce "$HEAD1"); RC=$?
[ "$RC" = 3 ] && ok || bad "E2 a failed upload on a parallel conf is rc 3 (rc $RC, out $OUT)"
grep -q "queue scopes could not be uploaded on ${HEAD1:0:12} (HTTP 500) — not labelled" <<<"$OUT" && ok || bad "E2 the rc 3 reason names the HTTP answer: $OUT"
labelled && bad "E2 no label POST after a failed upload: $(cat "$G/calls")" || ok
# no key on a parallel conf: same hold, zero calls
ereset
OUT=$( (unset MERGIFY_CI_KEY; enq enforce "$HEAD1") ); RC=$?
[ "$RC" = 3 ] && ! labelled && [ "$(calls)" = 0 ] && grep -q 'MERGIFY_CI_KEY not set' <<<"$OUT" && ok \
  || bad "E2 no key on a parallel conf holds, no call, no label (rc $RC, out $OUT)"
# shadow or off on a parallel conf: a scopeless PR never enters a parallel queue
for md in shadow off -; do
  ereset
  OUT=$(MERGIFY_CI_KEY="$KEY" enq "$md" "$HEAD1"); RC=$?
  [ "$RC" = 3 ] && ! labelled && [ "$(calls)" = 0 ] && ok || bad "E2 mode '$md' on a parallel conf holds unlabelled (rc $RC, out $OUT)"
done
# enforce on a SERIAL conf: a failed upload is a log line, the enqueue proceeds
conf serial; ereset; echo 500 > "$M/code"
OUT=$(MERGIFY_CI_KEY="$KEY" enq enforce "$HEAD1"); RC=$?
[ "$RC" = 0 ] && labelled && grep -q "scopes not uploaded on ${HEAD1:0:12} (HTTP 500)" "$H/logs/merge-conductor.log" && ok \
  || bad "E2 enforce on a serial conf: a failed upload is logged and the PR still enqueues (rc $RC): $(cat "$H/logs/merge-conductor.log")"

# E3: enforce + parallel + 2xx -> the PUT, then the label, in that order
conf parallel; ereset
# Order: the stub curl and stub gh both append to one shared trace.
sed -i "1a echo PUT >> \"$T/order\"" "$T/fakebin/curl"
sed -i "1a case \"\\\$*\" in *labels*) echo LABEL >> \"$T/order\" ;; esac" "$T/fakebin/gh"
rm -f "$T/order"
OUT=$(MERGIFY_CI_KEY="$KEY" enq enforce "$HEAD1"); RC=$?
[ "$RC" = 0 ] && ok || bad "E3 a 2xx upload enqueues (rc $RC, out $OUT, err $(cat "$T/enq.err"))"
[ "$(tr '\n' ' ' < "$T/order" 2>/dev/null)" = "PUT LABEL " ] && ok || bad "E3 the PUT comes before the label POST: $(cat "$T/order" 2>/dev/null)"
[ "$(jq -c . < "$M/body.1" 2>/dev/null)" = '{"scopes":["tests_a-test.sh"],"all_scopes":false}' ] && ok || bad "E3 the uploaded scopes: $(cat "$M/body.1" 2>/dev/null)"
grep -q -- "$KEY" "$H/logs/merge-conductor.log" "$T/enq.err" && bad "U4 the key never reaches \$MC_LOG or stderr" || ok
# a second enqueue on the same head costs no second PUT (the ledger)
rm -f "$T/order"
MERGIFY_CI_KEY="$KEY" enq enforce "$HEAD1" >/dev/null
[ "$(calls)" = 1 ] && ok || bad "E3 a re-ask on the same head does not PUT again (calls $(calls))"

# E4: a slug with no conf, and a conf that has not opted in, get nothing
conf serial; ereset
( export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" QP_MAP="$MAP"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }; mc_mergify_witness() { return 0; }; mc_queue_state() { printf queued; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify example-org/other-os "https://github.com/example-org/other-os/pull/41" "$HEAD1" ) >/dev/null 2>&1
grep -q . <<<"$(plog)" && bad "E4 a slug with no conf logs no PARTITION line: $(plog)" || ok
cp "$DIR/config/mergify/repos/project-5.conf" "$H/config/mergify/repos/project-5.conf"; ereset
( export PATH="$T/fakebin:$PATH" HARNESS="$H" TMPDIR="$T/tmp" QP_MAP="$MAP"
  . "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
  mc_mergify_command() { return 0; }; mc_mergify_witness() { return 0; }; mc_queue_state() { printf queued; }
  MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 mc_enqueue_mergify example-org/project-5 "https://github.com/example-org/project-5/pull/41" "$HEAD1" ) >/dev/null 2>&1
grep -q . <<<"$(plog)" && bad "E4 project-5's conf has no queue_mode, so it is untouched: $(plog)" || ok
grep -q -- '/pulls/41' "$G/calls" 2>/dev/null && bad "E4 an opted-out repo costs no PR read: $(cat "$G/calls")" || ok

# E5: delete the block from a copy of the lib and E1's assertion goes red —
# the PARTITION line comes from mc_enqueue_mergify's block and nowhere else.
MUT="$T/mut"; mkdir -p "$MUT/bin/lib"
cp -r "$DIR/bin/lib/." "$MUT/bin/lib/"
grep -q '^  # >>> queue partition scopes (BH-4979)' "$MUT/bin/lib/mc/queue.sh" && ok || bad "E5 the marked block is in bin/lib/mc/queue.sh"
sed -i '/# >>> queue partition scopes (BH-4979)/,/# <<< queue partition scopes (BH-4979)/d' "$MUT/bin/lib/mc/queue.sh"
conf serial; ereset
LIBROOT="$MUT" enq shadow "$HEAD1" >/dev/null
grep -q . <<<"$(plog)" && bad "E5 with the block deleted there is no PARTITION line: $(plog)" || ok
labelled && ok || bad "E5 the mutated enqueue still labels (the mutation removed only the block)"
LIBROOT="$DIR"

# ============================================================================
# R. the parallel-mode render
# ============================================================================
MT="$DIR/bin/mergify-template.sh"
# R1: project-5 renders byte-identical to main's renderer + template
if git -C "$DIR" rev-parse --verify -q origin/main >/dev/null; then
  OLD="$T/old"; mkdir -p "$OLD/bin" "$OLD/config/mergify"
  git -C "$DIR" show origin/main:bin/mergify-template.sh > "$OLD/bin/mergify-template.sh"
  git -C "$DIR" show origin/main:config/mergify/template.yml > "$OLD/config/mergify/template.yml"
  for c in project-5 cromford; do
    # solo_label= (BH-5430) is not serial-vs-parallel: it adds the solo queue
    # on purpose (tests/mergify-solo-queue.bh-5430-test.sh pins that render), so
    # the serial byte-identity is checked on the conf without it, on BOTH sides.
    # Main's renderer accepts solo_label since BH-5430 merged; rendering main's
    # side from the full conf compared a solo queue against none (main red).
    # flake_fix_label= (BH-7279) adds the flake-fix queue the same way, so it
    # is left out on both sides too.
    grep -vE '^(solo_label|flake_fix_label)=' "$DIR/config/mergify/repos/$c.conf" > "$T/new-$c.conf"
    bash "$OLD/bin/mergify-template.sh" render "$T/new-$c.conf" > "$T/old-$c.yml" 2>/dev/null
    if [ "$c" = cromford ] && ! [ -s "$T/old-$c.yml" ]; then
      # main's renderer refuses the new keys; render a copy without them
      grep -vE '^(queue_mode|scope_default_capacity|solo_label|flake_fix_label)=' "$DIR/config/mergify/repos/$c.conf" > "$T/bh-nokeys.conf"
      bash "$OLD/bin/mergify-template.sh" render "$T/bh-nokeys.conf" > "$T/old-$c.yml"
    fi
    bash "$MT" render "$T/new-$c.conf" > "$T/new-$c.yml"
    cmp -s "$T/old-$c.yml" "$T/new-$c.yml" && ok || bad "R1 $c.conf (serial) renders byte-identical to main: $(diff "$T/old-$c.yml" "$T/new-$c.yml" | head -5)"
  done
else
  echo "R1 no origin/main ref — byte-identity against main skipped"
fi
# R2: parallel renders the mode and the manual scopes block
sed 's/^queue_mode=.*/queue_mode=parallel/' "$DIR/config/mergify/repos/cromford.conf" > "$T/par.conf"
bash "$MT" render "$T/par.conf" > "$T/par.yml"; RC=$?
Y=$(python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$T/par.yml" 2>/dev/null)
[ "$RC" = 0 ] && [ "$(jq -r '.merge_queue.mode' <<<"$Y")" = parallel ] && ok || bad "R2 parallel renders merge_queue.mode: parallel (rc $RC): $(head -5 "$T/par.yml")"
[ "$(jq -c '.scopes' <<<"$Y")" = '{"source":{"manual":{}},"default_capacity":1}' ] && ok || bad "R2 the scopes block: $(jq -c .scopes <<<"$Y")"
# compare treats manual: {} and manual: (null) as one thing
sed 's/manual: {}/manual:/' "$T/par.yml" > "$T/par-null.yml"
bash "$MT" compare "$T/par.conf" "$T/par-null.yml" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "R2 compare: manual: {} equals manual: (null) (rc $RC)"
# R3: capacity 9 is refused, naming the line
sed 's/^scope_default_capacity=.*/scope_default_capacity=9/' "$T/par.conf" > "$T/r3.conf"
ERR=$(bash "$MT" render "$T/r3.conf" 2>&1 >/dev/null); RC=$?
N=$(grep -n '^scope_default_capacity=' "$T/r3.conf" | cut -d: -f1)
[ "$RC" = 2 ] && grep -q "r3.conf:$N: scope_default_capacity 9 is outside 1..8" <<<"$ERR" && ok || bad "R3 capacity 9 is rc 2 naming line $N (rc $RC): $ERR"
# R4: capacity above max_parallel_checks is refused
sed -e 's/^scope_default_capacity=.*/scope_default_capacity=5/' -e 's/^max_parallel_checks=.*/max_parallel_checks=4/' "$T/par.conf" > "$T/r4.conf"
ERR=$(bash "$MT" render "$T/r4.conf" 2>&1 >/dev/null); RC=$?
N=$(grep -n '^scope_default_capacity=' "$T/r4.conf" | cut -d: -f1)
[ "$RC" = 2 ] && grep -q "r4.conf:$N: scope_default_capacity 5 > max_parallel_checks 4" <<<"$ERR" && ok || bad "R4 capacity > max_parallel_checks is rc 2 naming line $N (rc $RC): $ERR"
sed 's/^queue_mode=.*/queue_mode=fast/' "$T/par.conf" > "$T/r5.conf"
ERR=$(bash "$MT" render "$T/r5.conf" 2>&1 >/dev/null); RC=$?
[ "$RC" = 2 ] && grep -q "queue_mode 'fast' is not serial|parallel" <<<"$ERR" && ok || bad "R4 an unknown queue_mode is refused (rc $RC): $ERR"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
