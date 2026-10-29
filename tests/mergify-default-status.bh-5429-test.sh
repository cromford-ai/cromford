#!/bin/bash
# tests/mergify-default-status.bh-5429-test.sh — BH-5441 (#5429 child 4).
#
#   M1-M4  bin/mergify-template.sh's repeatable `default_status_check` key: it
#          renders `check-success=<name>` into the DEFAULT queue's
#          queue_conditions only (never the hotfix queue, never a
#          merge_conditions), it is refused like status_check (rc 2), and the
#          merge-base copy of each conf renders byte for byte as the merge-base
#          renderer does.
#   R1-R3  bin/lib/queue-status-contexts.sh: qsc_list, and both queue readers
#          (_ae_required_checks, mc_mergify_required_checks) skip every name in
#          it — lead-verdict AND prequeue-verdict. The readers are sourced from
#          the repo, so they load the lib through their own guarded source.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mergify-default-status.bh-5429-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/mergify-pause-filter.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML missing — skipping"; exit 0; }
MT="$DIR/bin/mergify-template.sh"
BH="$DIR/config/mergify/repos/cromford.conf"

# ============================================================================
# M1. The key renders in the default queue's queue_conditions, and only there.
# ============================================================================
{ cat "$BH"; echo default_status_check=prequeue-verdict; } > "$T/m1.conf"
out=$("$MT" render "$T/m1.conf" 2>"$T/m1.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "M1 render rc 0 (rc $rc: $(cat "$T/m1.err"))"
[ "$(grep -cxF '      - "check-success=prequeue-verdict"' <<<"$out")" = 1 ] && ok \
  || bad "M1 exactly one '- \"check-success=prequeue-verdict\"' line (got $(grep -c prequeue-verdict <<<"$out"))"
where=$(python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
hits = []
for q in d.get("queue_rules", []):
    for k in ("queue_conditions", "merge_conditions"):
        if "check-success=prequeue-verdict" in (q.get(k) or []):
            hits.append("%s.%s" % (q.get("name"), k))
for r in d.get("pull_request_rules", []) + d.get("priority_rules", []):
    if "check-success=prequeue-verdict" in (r.get("conditions") or []):
        hits.append("rule:" + r.get("name", "?"))
print(" ".join(hits))' <<<"$out" 2>&1)
[ "$where" = "default.queue_conditions" ] && ok || bad "M1 only in default.queue_conditions (got '$where')"
# It comes after the queue checks and the lead-verdict status_check.
ql=$(grep -n 'check-success=prequeue-verdict' <<<"$out" | cut -d: -f1)
ll=$(grep -n 'check-success=lead-verdict' <<<"$out" | tail -1 | cut -d: -f1)
[ -n "$ql" ] && [ -n "$ll" ] && [ "$ql" = $((ll + 1)) ] && ok || bad "M1 right after the default queue's last queue check (lead-verdict line ${ll:-none}, prequeue-verdict line ${ql:-none})"
# Repeatable: two keys, two lines, in conf order.
{ cat "$BH"; echo default_status_check=prequeue-verdict; echo default_status_check=other-status; } > "$T/m1b.conf"
out=$("$MT" render "$T/m1b.conf" 2>/dev/null)
[ "$(grep -A1 'check-success=prequeue-verdict' <<<"$out" | tail -1)" = '      - "check-success=other-status"' ] && ok \
  || bad "M1 a second key renders on the next line ($(grep -A1 prequeue-verdict <<<"$out"))"

# ============================================================================
# M2. No conf without the key changes: --check is green, .mergify.yml and the
#     confs are untouched, and each real conf renders byte for byte as the
#     merge-base renderer does.
# ============================================================================
"$MT" --check > "$T/check.out" 2>&1 && ok || bad "M2 --check rc 0 ($(cat "$T/check.out"))"
grep -q '^ok: cromford.conf renders and matches .mergify.yml$' "$T/check.out" && ok || bad "M2 cromford matches .mergify.yml ($(cat "$T/check.out"))"
grep -q '^ok: project-5.conf renders$' "$T/check.out" && ok || bad "M2 project-5 renders ($(cat "$T/check.out"))"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" diff --quiet HEAD -- .mergify.yml config/mergify/repos/ && ok || bad "M2 .mergify.yml and config/mergify/repos/ are unchanged against HEAD"
  BASE=$(git -C "$DIR" merge-base HEAD origin/main 2>/dev/null)
  if [ -n "$BASE" ] && git -C "$DIR" cat-file -e "$BASE:bin/mergify-template.sh" 2>/dev/null; then
    mkdir -p "$T/base/bin" "$T/base/config/mergify"
    git -C "$DIR" show "$BASE:bin/mergify-template.sh" > "$T/base/bin/mergify-template.sh" && chmod +x "$T/base/bin/mergify-template.sh"
    git -C "$DIR" show "$BASE:config/mergify/template.yml" > "$T/base/config/mergify/template.yml"
    # Both renderers read the MERGE-BASE copy of each conf. A branch may add a
    # new key to a conf on purpose (BH-5430 solo_label); the base renderer
    # refuses that key, and the conf edit is not renderer drift. The conf as
    # committed is checked by --check above (it must match .mergify.yml).
    for c in "$DIR"/config/mergify/repos/*.conf; do
      rel="config/mergify/repos/$(basename "$c")"
      git -C "$DIR" cat-file -e "$BASE:$rel" 2>/dev/null || { echo "note: M2 $(basename "$c") is new on this branch; no merge-base copy to compare"; continue; }
      git -C "$DIR" show "$BASE:$rel" > "$T/base.conf"
      "$T/base/bin/mergify-template.sh" render "$T/base.conf" > "$T/base.out" 2>&1
      "$MT" render "$T/base.conf" > "$T/head.out" 2>&1
      # TEST-CHANGE (BH-8706): drop the main-red breaker's pause lines from both
      # sides only while the base has none (tests/lib/mergify-pause-filter.sh).
      mergify_pause_filter "$T/base.out" "$T/head.out"
      cmp -s "$T/base.out" "$T/head.out" && ok || bad "M2 $(basename "$c") renders byte-identical to the merge base ($(diff "$T/base.out" "$T/head.out" | head -5))"
    done
  else
    echo "note: M2 merge-base render comparison not run (no origin/main merge base in this checkout)"
  fi
fi

# ============================================================================
# M3. Refusals: rc 2 and a message naming the problem.
# ============================================================================
refused() { # refused <case> <expected message part> <extra conf lines...>
  local name="$1" want="$2" rc; shift 2
  { cat "$BH"; printf '%s\n' "$@"; } > "$T/m3.conf"
  "$MT" render "$T/m3.conf" > "$T/m3.out" 2> "$T/m3.err"; rc=$?
  [ "$rc" = 2 ] && ok || bad "M3 $name: rc 2 (got $rc)"
  [ -s "$T/m3.out" ] && bad "M3 $name: nothing renders ($(head -2 "$T/m3.out"))" || ok
  grep -qF -- "$want" "$T/m3.err" && ok || bad "M3 $name: message holds '$want' (got '$(cat "$T/m3.err")')"
}
refused quote "default_status_check name holds a quote, backslash or control character" 'default_status_check=pre"q'
refused backslash "default_status_check name holds a quote, backslash or control character" 'default_status_check=pre\q'
refused control "default_status_check name holds a quote, backslash or control character" "$(printf 'default_status_check=pre\tq')"
refused duplicate "duplicate default_status_check prequeue-verdict" default_status_check=prequeue-verdict default_status_check=prequeue-verdict
refused "same as check=" "default_status_check 'ci-a' is also a check=, queue_check= or status_check= line" check=ci-a default_status_check=ci-a
refused "same as queue_check=" "default_status_check 'ci-q' is also a check=, queue_check= or status_check= line" check=ci-q queue_check=ci-q default_status_check=ci-q
refused "same as status_check=" "default_status_check 'lead-verdict' is also a check=, queue_check= or status_check= line" default_status_check=lead-verdict

# ============================================================================
# M4. No rendered output holds a stray token.
# ============================================================================
for c in "$DIR"/config/mergify/repos/*.conf "$T/m1.conf" "$T/m1b.conf"; do
  o=$("$MT" render "$c" 2>&1)
  grep -q '@@' <<<"$o" && bad "M4 $(basename "$c") renders a stray token ($(grep '@@' <<<"$o" | head -2))" || ok
done

# ============================================================================
# R3. qsc_list honours LEAD_VERDICT_CONTEXT and dedupes.
# ============================================================================
QSC="$DIR/bin/lib/queue-status-contexts.sh"
r=$(unset LEAD_VERDICT_CONTEXT; . "$QSC" && qsc_list | paste -sd' ')
[ "$r" = "lead-verdict prequeue-verdict" ] && ok || bad "R3 default list (got '$r')"
r=$(LEAD_VERDICT_CONTEXT=lv2; . "$QSC" && qsc_list | paste -sd' ')
[ "$r" = "lv2 prequeue-verdict" ] && ok || bad "R3 the override is first (got '$r')"
r=$(LEAD_VERDICT_CONTEXT=prequeue-verdict; . "$QSC" && qsc_list | paste -sd' ')
[ "$r" = "prequeue-verdict" ] && ok || bad "R3 one line when the override is prequeue-verdict (got '$r')"

# ============================================================================
# R1. _ae_required_checks drops both status contexts.
# ============================================================================
r=$( unset LEAD_VERDICT_CONTEXT MC_AUTOENQUEUE_CHECK
     . "$DIR/bin/lib/autoenqueue.sh" >/dev/null 2>&1
     ae_mergify_admit_checks() { printf 'A\nlead-verdict\nprequeue-verdict\n'; }
     _ae_required_checks example-org/demo-os | paste -sd' ' )
[ "$r" = "A" ] && ok || bad "R1 _ae_required_checks prints only A (got '$r')"
r=$( LEAD_VERDICT_CONTEXT=lv2; unset MC_AUTOENQUEUE_CHECK
     . "$DIR/bin/lib/autoenqueue.sh" >/dev/null 2>&1
     ae_mergify_admit_checks() { printf 'A\nlv2\nprequeue-verdict\nlead-verdict\n'; }
     _ae_required_checks example-org/demo-os | paste -sd' ' )
[ "$r" = "A lead-verdict" ] && ok || bad "R1 with LEAD_VERDICT_CONTEXT=lv2, lv2 and prequeue-verdict are dropped (got '$r')"

# ============================================================================
# R2. mc_mergify_required_checks drops both status contexts.
# ============================================================================
YML=$(printf 'queue_rules:\n  - name: default\n    queue_conditions:\n      - check-success=A\n      - "check-success=lead-verdict"\n      - "check-success=prequeue-verdict"\n    merge_conditions:\n      - check-success=A\n      - check-success=B\n' | base64 | tr -d '\n')
r=$( unset LEAD_VERDICT_CONTEXT
     export MC_H="$T/h"; mkdir -p "$T/h/logs" "$T/h/state"
     . "$DIR/bin/lib/mc/log.sh" >/dev/null 2>&1
     . "$DIR/bin/lib/mc/queue.sh" >/dev/null 2>&1
     mc_policy_get() { printf -v "$1" '{"content":"%s"}' "$YML"; }
     mc_mergify_required_checks example-org/demo-os | paste -sd' ' )
[ "$r" = "A B" ] && ok || bad "R2 mc_mergify_required_checks prints only A and B (got '$r')"

echo "mergify-default-status.bh-5429: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
