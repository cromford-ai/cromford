#!/bin/bash
# tests/lead-review-split-layout.bh-6293-test.sh — BH-6293: bin/lead-review.sh
# keeps the entry point and loads four function groups from bin/lib/lead-review/
# through the module map (bin/lib/module-map.sh, docs/MODULE-MAP.md).
#
#   L1  module-map-build --check is green on bin/lib/lead-review; load.sh is the
#       bootstrap (no "# module:" line, calls mm_load, loops over nothing
#       itself); module-map.sh is a symlink to ../module-map.sh.
#   L2  each module has a "# module: <basename>" header, parses, and sources
#       clean in a clean bash.
#   L3  load.sh in a clean bash defines all 19 moved names; no name is defined
#       by two modules.
#   L4  bin/lead-review.sh defines none of the 19 names, and still defines the
#       text-pinned functions and the BH-6984 lock pair (lr_rerun, lr_unlock),
#       and holds the `# >>> lead ci green` block and the split-host marker.
#   L5  byte for byte. The synthetic self-test always runs. With
#       LR_SPLIT_BASE=<rev> the 19 bodies in <rev>:bin/lead-review.sh equal the
#       bodies in the modules. Env-gated: a later intended body edit must not
#       go red here.
#   L6  the production entry point (D2): scratch_closure_list names the module
#       dir, and a real `bin/lead-review.sh tick` in a scratch harness sources
#       the scratch copy of worker.sh (a canary).
#   L7  the same tick with bin/lib/lead-review/ removed: rc 0, one log line,
#       one LEAD REVIEW MODULE MISSING alert line, and no request reaches the
#       jobs worker.
#   L8  with no DB rows, bin/lib/lead-authority.sh protects the module files
#       through the seed floor.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-split-layout.bh-6293-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST="$DIR/bin/lead-review.sh"
LRD="$DIR/bin/lib/lead-review"
LOAD="$DIR/bin/lib/lead-review/load.sh"
MODS=("$DIR/bin/lib/lead-review/attempts.sh" "$DIR/bin/lib/lead-review/result.sh"
      "$DIR/bin/lib/lead-review/rules-pack-inputs.sh" "$DIR/bin/lib/lead-review/worker.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

# The 19 moved names, by the module that owns each.
declare -A WANT=(
  [lr_rp_inputs]=rules-pack-inputs [lr_rp_touched]=rules-pack-inputs
  [lr_detail]=result [post_result]=result [fail_terminal]=result [claim_req]=result
  [finish_done]=result [supersede_dead]=result
  [lr_count_fail]=attempts [lr_left_running]=attempts [lr_fail_counted]=attempts
  [lr_rate_limited]=attempts [lr_release_rl]=attempts
  [cleanup]=worker [rpool_on_result]=worker [lr_worker]=worker [lr_ring_land]=worker
  [lr_worker_exit]=worker [lr_slot_free]=worker
)
MOVED=$(printf '%s\n' "${!WANT[@]}" | LC_ALL=C sort)
[ "$(grep -c . <<<"$MOVED")" = 19 ] || { echo "FAIL: the fixture name list is not 19 names"; exit 1; }
static_defs() { sed -n -E 's/^([A-Za-z_][A-Za-z0-9_]*)[(][)].*/\1/p' "$1"; }

# ── L1. the map check and the bootstrap ─────────────────────────────────────
"$DIR/bin/module-map-build.sh" --root "$DIR" --check bin/lib/lead-review > "$T/mmb.out" 2>"$T/mmb.err" && ok \
  || bad "L1: module-map-build.sh --check bin/lib/lead-review failed: $(cat "$T/mmb.err")"
grep -q 'bin/lib/lead-review' "$T/mmb.out" && ok || bad "L1: the --check summary does not name bin/lib/lead-review: $(cat "$T/mmb.out")"
if [ -r "$LOAD" ]; then
  ! grep -q '^# module:' "$LOAD" && ok || bad "L1: load.sh carries a '# module:' line (it is the bootstrap)"
  grep -qE '^mm_load "\$\{BASH_SOURCE\[0\]%/\*\}"$' "$LOAD" && ok || bad "L1: load.sh does not call mm_load on its own dir"
  ! grep -qE '^[[:space:]]*for[[:space:]]' "$LOAD" && ok || bad "L1: load.sh has its own loop (a second loader)"
else
  bad "L1: bin/lib/lead-review/load.sh is missing"
fi
[ -L "$LRD/module-map.sh" ] && [ "$(readlink "$LRD/module-map.sh")" = ../module-map.sh ] && ok \
  || bad "L1: bin/lib/lead-review/module-map.sh is not a symlink to ../module-map.sh"

# ── L2. headers, parse, sources clean ───────────────────────────────────────
for f in "${MODS[@]}"; do
  rel=${f#"$DIR"/}; base=$(basename "$f" .sh)
  [ -r "$f" ] || { bad "L2: $rel is missing"; continue; }
  head -30 "$f" | grep -qx "# module: $base" && ok || bad "L2: $rel has no '# module: $base' header"
  bash -n "$f" && ok || bad "L2: $rel does not parse"
  err=$(env -i PATH="$PATH" bash -c '. "$1"' _ "$f" 2>&1) && [ -z "$err" ] && ok || bad "L2: $rel does not source clean: $err"
done

# ── L3. load.sh defines every moved name; no name twice ─────────────────────
LOADED=$(env -i PATH="$PATH" bash -c '. "$1" || exit 3; declare -F | cut -d" " -f3' _ "$LOAD" 2>/dev/null | LC_ALL=C sort)
missing=$(comm -23 <(printf '%s\n' "$MOVED") <(printf '%s\n' "$LOADED") | tr '\n' ' ')
[ -n "$LOADED" ] && [ -z "$missing" ] && ok || bad "L3: load.sh does not define: ${missing:-everything}"
: > "$T/owners"
for f in "${MODS[@]}"; do
  [ -r "$f" ] || continue
  env -i PATH="$PATH" bash -c '. "$1" >/dev/null 2>&1 || exit 3; declare -F | cut -d" " -f3' _ "$f" \
    | sed "s/\$/	$(basename "$f" .sh)/" >> "$T/owners"
done
dups=$(cut -f1 "$T/owners" | LC_ALL=C sort | uniq -d | tr '\n' ' ')
[ -s "$T/owners" ] && [ -z "$dups" ] && ok || bad "L3: defined by two modules (or none): ${dups:-no owners}"
for fn in $MOVED; do
  grep -qxF "$fn	${WANT[$fn]}" "$T/owners" && ok || bad "L3: $fn is not defined by bin/lib/lead-review/${WANT[$fn]}.sh"
done

# ── L4. the host keeps the entry point and the text-pinned functions ────────
DEFS=$(static_defs "$HOST" | LC_ALL=C sort -u)
if [ -n "$DEFS" ]; then
  inline=$(comm -12 <(printf '%s\n' "$MOVED") <(printf '%s\n' "$DEFS") | tr '\n' ' ')
  [ -z "$inline" ] && ok || bad "L4: bin/lead-review.sh still defines moved name(s): $inline"
  for fn in lr_verify_cmd lr_verdict lr_has_findings lr_pick_review lr_ci_cfg_inputs lr_ci_cfg_touched lr_file_predates review_one lr_rerun lr_unlock; do
    grep -qxF "$fn" <<<"$DEFS" && ok || bad "L4: the text-pinned $fn is not in bin/lead-review.sh"
  done
else
  bad "L4: bin/lead-review.sh is empty or defines no function"
fi
grep -q '^# >>> lead ci green' "$HOST" && grep -q '^# <<< lead ci green' "$HOST" && ok \
  || bad "L4: the '# >>> lead ci green' block is not in bin/lead-review.sh"
grep -qxE '# split-host: bin/lib/lead-review/ max-growth=40' "$HOST" && ok \
  || bad "L4: bin/lead-review.sh has no '# split-host: bin/lib/lead-review/ max-growth=40' marker"

# ── L5. byte for byte ───────────────────────────────────────────────────────
# One line per column-0 function body: <name><TAB><sha256>. A function moved
# byte for byte gives the same line. Same reader as ms-split-layout's M5.
bodies() {
  local f name body
  for f in "$@"; do [ -r "$f" ] || return 1; done
  awk '
    function esc(s) { gsub(/\\/, "\\\\", s); return s }
    function flush() { printf "%s\t%s\n", name, body; f = 0 }
    FNR == 1 { f = 0 }
    !f && /^[A-Za-z_][A-Za-z0-9_]*[(][)] [{]/ {
      name = $0; sub(/[(].*/, "", name); body = esc($0); f = 1
      if ($0 ~ /[}][[:space:]]*$/) flush()
      next
    }
    f { body = body "\\n" esc($0); if ($0 ~ /^[}]$/) flush() }
  ' "$@" | while IFS=$'\t' read -r name body; do
    printf '%s\t%s\n' "$name" "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
  done | LC_ALL=C sort -u
}
moved_bodies() { bodies "$@" | awk -F'\t' 'NR == FNR { want[$1] = 1; next } want[$1]' <(printf '%s\n' "$MOVED") -; }
S="$T/l5"; mkdir -p "$S/before" "$S/after"
cat > "$S/before/host.sh" <<'EOF'
keep_fn() {
  echo keep
}
move_fn() { # moves
  echo "a\\b	tab"
}
one_fn() { echo one; }
EOF
printf 'keep_fn() {\n  echo keep\n}\n' > "$S/after/host.sh"
sed -n '/^move_fn/,/^}/p; /^one_fn/p' "$S/before/host.sh" > "$S/after/mod.sh"
: > "$S/before/mod.sh"
BEFORE=$(bodies "$S/before/host.sh" "$S/before/mod.sh")
[ "$(grep -c . <<<"$BEFORE")" = 3 ] && ok || bad "L5: the fixture should give 3 bodies, got: $BEFORE"
[ "$BEFORE" = "$(bodies "$S/after/host.sh" "$S/after/mod.sh")" ] && ok || bad "L5: a pure move gave a different body set"
cp "$S/after/mod.sh" "$S/mut.sh"; sed -i 's/a\\\\b/a\\\\c/' "$S/mut.sh"
[ "$BEFORE" != "$(bodies "$S/after/host.sh" "$S/mut.sh")" ] && ok || bad "L5: one changed byte gave the same body set"
if [ -n "${LR_SPLIT_BASE:-}" ]; then
  if git -C "$DIR" show "$LR_SPLIT_BASE:bin/lead-review.sh" > "$S/base.sh" 2>/dev/null; then
    moved_bodies "$S/base.sh" > "$T/base.set"
    moved_bodies "$HOST" "${MODS[@]}" > "$T/head.set"
    if [ "$(wc -l < "$T/base.set")" = 19 ] && cmp -s "$T/base.set" "$T/head.set"; then
      ok; echo "bodies: identical (19 bodies, $LR_SPLIT_BASE vs working tree)"
    else
      bad "L5: the moved body set differs from $LR_SPLIT_BASE"; diff "$T/base.set" "$T/head.set" | head -20
    fi
  else
    bad "L5: LR_SPLIT_BASE=$LR_SPLIT_BASE has no bin/lead-review.sh"
  fi
fi

# ── L6. the production entry point loads the modules ────────────────────────
CL=$(cd "$DIR" && scratch_closure_list bin/lead-review.sh 2>"$T/cl.err"); rc=$?
[ "$rc" = 0 ] && ok || bad "L6: scratch_closure_list bin/lead-review.sh rc=$rc: $(cat "$T/cl.err")"
for f in load.sh module-map.sh attempts.sh result.sh rules-pack-inputs.sh worker.sh; do
  grep -qxF "bin/lib/lead-review/$f" <<<"$CL" && ok || bad "L6: scratch_closure_list bin/lead-review.sh does not list bin/lib/lead-review/$f"
done

H="$T/h"; mkdir -p "$H/prompts" "$H/catalog/lanes.d" "$H/state" "$T/fakebin" "$T/log" "$T/tmp"
for s in bin/lead-review.sh bin/jobs-client.sh bin/box-for.sh bin/fleet-conf.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "L6: closure install of $s"
done
cp "$DIR/catalog/lanes.d/_lib.json" "$H/catalog/lanes.d/"
cp "$DIR/prompts/lead-review.md" "$DIR/prompts/lead-review-checklist.md" "$H/prompts/"
echo box-demo > "$H/state/box-name"
echo 'demo-os example-org/demo-os https://demo.test /api/board 1 box-demo' > "$H/fleet.conf"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
url=""; for a in "\$@"; do case "\$a" in http*) url="\$a" ;; esac; done
printf '%s\n' "\${url#https://jobs.test}" >> "$T/log/worker"
case "\$url" in
  *"/api/lead-reviews"*) printf '%s\n200' '{"requests":[],"truncated":false}' ;;
  *) printf '%s\n200' '{}' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
echo "echo lr-canary >> '$T/canary'" >> "$H/bin/lib/lead-review/worker.sh"
tick() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=s-fixture JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
           TMPDIR="$T/tmp" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 GH_ETAG=0 _VP_WINDOW=40
    unset BOX_NAME JOBS_BOX HARNESS_PARTICIPANT_TOKEN_FILE
    cd "$T" && bash "$H/bin/lead-review.sh" tick ) > "$T/out" 2>&1
}
rm -f "$T/canary" "$T/log/worker"
tick; rc=$?
[ "$rc" = 0 ] && ok || bad "L6: a tick with its modules exited $rc ($(tail -3 "$T/out"))"
grep -qx lr-canary "$T/canary" 2>/dev/null && ok || bad "L6: the tick did not source the scratch bin/lib/lead-review/worker.sh"
grep -q 'lead-review/ did not load' "$H/logs/lead-review.log" 2>/dev/null && bad "L6: a tick with its modules logged a load failure" || ok
grep -q '/api/lead-reviews' "$T/log/worker" 2>/dev/null && ok || bad "L6: the tick never read the lead-review list ($(tail -3 "$H/logs/lead-review.log" 2>/dev/null))"
alerts() { local c; c=$(grep -c 'LEAD REVIEW MODULE MISSING' "$H/logs/ALERTS.log" 2>/dev/null); echo "${c:-0}"; }
[ "$(alerts)" = 0 ] && ok || bad "L6: a tick that loaded its modules raised LEAD REVIEW MODULE MISSING"

# ── L7. the module dir is gone: one log line, rc 0, no request ──────────────
scratch_rm "$H/bin/lib/lead-review" || exit 1
rm -f "$T/canary" "$T/log/worker" "$H/logs/lead-review.log"
tick; rc=$?
[ "$rc" = 0 ] && ok || bad "L7: a tick with no bin/lib/lead-review/ exited $rc, want 0"
grep -qF 'bin/lib/lead-review/ did not load; lead-review tick skipped' "$H/logs/lead-review.log" 2>/dev/null && ok \
  || bad "L7: the tick did not log the load failure ($(tail -2 "$H/logs/lead-review.log" 2>/dev/null))"
[ "$(alerts)" = 1 ] && ok || bad "L7: want exactly one LEAD REVIEW MODULE MISSING alert line, got $(alerts)"
grep -q 'LEAD REVIEW MODULE MISSING: bin/lib/lead-review/ is missing or unusable on ' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "L7: the alert line does not name bin/lib/lead-review/ ($(tail -1 "$H/logs/ALERTS.log" 2>/dev/null))"
[ ! -s "$T/log/worker" ] && ok || bad "L7: a skipped tick sent a request: $(head -3 "$T/log/worker")"
[ ! -e "$T/canary" ] && ok || bad "L7: a skipped tick still sourced a module"

# ── L8. the module files keep the lead protection ───────────────────────────
G=$(env -i PATH="$PATH" bash -c '
  _jobs_req() { printf "%s" "{\"rows\":[]}"; }
  . "$1" || exit 3
  la_globs example-org/cromford || exit 4
' _ "$DIR/bin/lib/lead-authority.sh"); rc=$?
[ "$rc" = 0 ] && grep -qxF 'bin/lead-review.sh' <<<"$G" && ok || bad "L8: la_globs with no DB rows did not answer the seed floor (rc=$rc)"
hit=$(env -i PATH="$PATH" G="$G" bash -c '
  . "$1" || exit 3
  while IFS= read -r g; do [ -n "$g" ] && _la_match bin/lib/lead-review/result.sh "$g" && { echo "$g"; exit 0; }; done <<<"$G"
  exit 1' _ "$DIR/bin/lib/lead-authority.sh")
[ -n "$hit" ] && ok || bad "L8: no seed glob protects bin/lib/lead-review/result.sh"

echo "lead-review-split-layout.bh-6293: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
