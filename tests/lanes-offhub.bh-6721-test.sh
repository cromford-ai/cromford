#!/bin/bash
# tests/lanes-offhub.bh-6721-test.sh — BH-6721 (BH-6047.8, C8): the seven lanes
# #5938 names for the move off the hub. A lane moves only when it is on
# pl_dispatch and has a run-inputs manifest pair; a lane that stays has no
# placement fragment and one reason line in the note
# docs/notes/*-BH-6721-lanes-offhub.md.
#
#   O1/O2  every C8 lane a worker/jobs/schema.d/*.sql fragment places `fly`
#          calls pl_dispatch (bin/<lane>.sh or a lib in its closure) and has
#          catalog/lane-run-inputs.d/<lane>.ro and .rw. Real tree: 0 moved.
#   O3     every C8 lane that is not moved: no fragment names
#          lane_placement.<lane>, and the note has exactly one
#          "- `<lane>`: stays on the hub: <reason>" line with a reason.
#          A dispatch-ready lane (pl_dispatch and both manifests, BH-6894)
#          may carry a lane_placement.<lane> row whose value is `hub`.
#   T      the note's table has one row per C8 lane, and its moved/stays cell
#          agrees with the fragments.
#   M-a    scratch: a fly fragment for dequeue-watch turns O1/O2 and O3 red
#   M-b    scratch: the note without its metrics-collect line turns O3 red
#   M-c    scratch: a lane_placement.archie-fm.hub_only row is not a move
#   M-d    scratch: fly fragment + pl_dispatch call + both manifests: O1/O2 green
#   M-e    scratch: a hub row for a dispatch-ready dequeue-watch: O3 green;
#          a second row for it with another value: O3 red
#   M-f    scratch: a lane_placement.review-autopilot.hub_only row on a lane
#          that is not dispatch-ready: O3 green; a lane_placement.review-autopilot
#          row (value hub) or a '.hub_onlyx' key on it: O3 red
#
# Run from anywhere: tests/lanes-offhub.bh-6721-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

C8_LANES="dequeue-watch pr-url-reconcile archie-fm review-autopilot fleet-status-push metrics-collect stale-owed-tickets"

# re_lane <lane> — the lane name as an ERE literal.
re_lane() { printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'; }

# moved_lanes <root> — the C8 lanes a schema fragment sets to fly. The key must
# be exactly 'lane_placement.<lane>': a '.hub_only' key is not a placement.
moved_lanes() {
  local r="$1" l
  for l in $C8_LANES; do
    cat "$r"/worker/jobs/schema.d/*.sql 2>/dev/null \
      | grep -qE "'lane_placement\.$(re_lane "$l")'[[:space:]]*,[[:space:]]*'fly'" && echo "$l"
  done
}

# calls_pl_dispatch <root> <lane> — a non-comment pl_dispatch call in
# bin/<lane>.sh or any file of its source closure, read from <root>.
calls_pl_dispatch() {
  local r="$1" l="$2" f
  for f in $(cd "$DIR" && scratch_closure_list "bin/$l.sh" 2>/dev/null); do
    [ -f "$r/$f" ] || continue
    grep -vE '^[[:space:]]*#' "$r/$f" | grep -vE '^[[:space:]]*pl_dispatch\(\)' \
      | grep -qE '(^|[^[:alnum:]_])pl_dispatch([^[:alnum:]_]|$)' && return 0
  done
  return 1
}

# check_o12 <root> — rc 0 when every moved lane has pl_dispatch and both
# manifests; prints one line per failing lane.
check_o12() {
  local r="$1" l rc=0
  for l in $(moved_lanes "$r"); do
    calls_pl_dispatch "$r" "$l" || { echo "    $l: placed fly, not on pl_dispatch"; rc=1; }
    [ -f "$r/catalog/lane-run-inputs.d/$l.ro" ] || { echo "    $l: placed fly, no lane-run-inputs.d/$l.ro"; rc=1; }
    [ -f "$r/catalog/lane-run-inputs.d/$l.rw" ] || { echo "    $l: placed fly, no lane-run-inputs.d/$l.rw"; rc=1; }
  done
  return "$rc"
}

# dispatch_ready <root> <lane> — rc 0 when the lane calls pl_dispatch and has
# both manifests (BH-6894).
dispatch_ready() {
  calls_pl_dispatch "$1" "$2" && [ -f "$1/catalog/lane-run-inputs.d/$2.ro" ] \
    && [ -f "$1/catalog/lane-run-inputs.d/$2.rw" ]
}

# the_note <root> — the one BH-6721 note, or rc 1.
the_note() {
  local -a n=("$1"/docs/notes/*-BH-6721-lanes-offhub.md)
  [ "${#n[@]}" = 1 ] && [ -f "${n[0]}" ] && printf '%s\n' "${n[0]}"
}

# check_o3 <root> — rc 0 when every lane that is not moved has no placement
# fragment and exactly one non-empty stays line in the note.
check_o3() {
  local r="$1" l n c moved rc=0
  moved=" $(moved_lanes "$r" | tr '\n' ' ') "
  n=$(the_note "$r") || { echo "    no docs/notes/*-BH-6721-lanes-offhub.md"; return 1; }
  for l in $C8_LANES; do
    [[ $moved == *" $l "* ]] && continue
    if dispatch_ready "$r" "$l"; then
      # BH-6894: a lane on pl_dispatch with both manifests may seed its
      # placement, and the value must be hub.
      if cat "$r"/worker/jobs/schema.d/*.sql 2>/dev/null \
          | grep -E "'lane_placement\.$(re_lane "$l")'[[:space:]]*," \
          | grep -vqE "'lane_placement\.$(re_lane "$l")'[[:space:]]*,[[:space:]]*'hub'"; then
        echo "    $l: stays, but a schema fragment sets lane_placement.$l to a value other than hub"; rc=1
      fi
    elif cat "$r"/worker/jobs/schema.d/*.sql 2>/dev/null \
        | sed -E "s/'lane_placement\.$(re_lane "$l")\.hub_only'//g" \
        | grep -qE "lane_placement\.$(re_lane "$l")([^[:alnum:]_-]|$)"; then
      # BH-7427: the exact quoted '.hub_only' key is a reason row, not a
      # placement (M-c), so it is removed before the grep.
      echo "    $l: stays, but a schema fragment names lane_placement.$l"; rc=1
    fi
    c=$(grep -cE "^- \`$(re_lane "$l")\`: stays on the hub: .*[^[:space:]]" "$n")
    [ "$c" = 1 ] || { echo "    $l: $c stays lines with a reason in $n (want 1)"; rc=1; }
  done
  return "$rc"
}

# check_t <root> — rc 0 when the note's table has one 4-cell row per lane and
# the moved/stays cell matches the fragments.
check_t() {
  local r="$1" l n rows want moved rc=0
  moved=" $(moved_lanes "$r" | tr '\n' ' ') "
  n=$(the_note "$r") || { echo "    no note"; return 1; }
  for l in $C8_LANES; do
    rows=$(grep -E "^\|[[:space:]]*\`$(re_lane "$l")\`[[:space:]]*\|" "$n")
    [ "$(grep -c . <<<"$rows")" = 1 ] || { echo "    $l: want 1 table row, got $(grep -c . <<<"$rows")"; rc=1; continue; }
    [ "$(awk -F'|' '{print NF}' <<<"$rows")" = 6 ] || { echo "    $l: table row does not have 4 cells"; rc=1; continue; }
    want=stays; [[ $moved == *" $l "* ]] && want=moved
    awk -F'|' '{print $4}' <<<"$rows" | grep -qw "$want" || { echo "    $l: table cell 3 does not say $want"; rc=1; }
  done
  return "$rc"
}

echo "real tree"
M=$(moved_lanes "$DIR")
[ -z "$M" ] && echo "    O1/O2: 0 moved lanes"
check_o12 "$DIR" && ok "O1/O2: every moved lane is on pl_dispatch with a manifest pair (moved: ${M:-none})" || bad "O1/O2 on the real tree"
check_o3 "$DIR" && ok "O3: each staying lane has no placement fragment and one reason line" || bad "O3 on the real tree"
check_t "$DIR" && ok "T: the note's table has one row per C8 lane" || bad "T on the real tree"

# mk <name> — sets S to a scratch root with the fragments, the note, the
# catalog and the dequeue-watch closure. The pr-url-reconcile closure and the
# committed manifests ride too: the real fragments seed its placement hub,
# which O3 allows only for a dispatch-ready lane (BH-6894).
mk() {
  local f; S="$T/$1"; local s="$S"
  mkdir -p "$s/worker/jobs" "$s/docs/notes" "$s/catalog"
  cp -r "$DIR/worker/jobs/schema.d" "$s/worker/jobs/"
  for f in "$DIR"/docs/notes/*-BH-6721-lanes-offhub.md; do [ -f "$f" ] && cp "$f" "$s/docs/notes/"; done
  ( cd "$DIR" && scratch_install_closure bin/dequeue-watch.sh "$s" ) >/dev/null || bad "setup: closure of bin/dequeue-watch.sh"
  ( cd "$DIR" && scratch_install_closure bin/pr-url-reconcile.sh "$s" ) >/dev/null || bad "setup: closure of bin/pr-url-reconcile.sh"
  [ -d "$DIR/catalog/lane-run-inputs.d" ] && cp -r "$DIR/catalog/lane-run-inputs.d" "$s/catalog/"
}
fly_row() { printf "INSERT OR IGNORE INTO settings (key, value, description, actor, updated_at) VALUES\n  ('%s','%s','fixture BH-6721','seed','2099-01-01T00:00:00Z');\n" "$2" "$3" \
  > "$1/worker/jobs/schema.d/209901010000-bh-6721-fixture.sql"; }

echo "M-a: fly fragment for dequeue-watch, no pl_dispatch, no manifest"
mk ma; fly_row "$S" lane_placement.dequeue-watch fly
# BH-5944 put dequeue-watch on pl_dispatch through bin/lib/project-lanes.sh.
# Empty the scratch copy of the lib so the fixture lane is NOT on pl_dispatch.
: > "$S/bin/lib/project-lanes.sh"
[ "$(moved_lanes "$S")" = dequeue-watch ] && ok "M-a: moved_lanes = dequeue-watch" || bad "M-a: moved_lanes = '$(moved_lanes "$S")'"
check_o12 "$S" && bad "M-a: O1/O2 stayed green" || ok "M-a: O1/O2 red"
O=$(check_o12 "$S"); grep -q 'not on pl_dispatch' <<<"$O" && grep -q 'no lane-run-inputs.d/dequeue-watch.ro' <<<"$O" \
  && ok "M-a: O1/O2 names the missing pl_dispatch and manifest" || bad "M-a: O1/O2 output: $O"
# O3 with the lane counted as staying: drop the fly value so it is not moved but still named.
fly_row "$S" lane_placement.dequeue-watch hub
O=$(check_o3 "$S") && bad "M-a: O3 green with a lane_placement.dequeue-watch fragment" \
  || { grep -q 'dequeue-watch: stays, but a schema fragment names' <<<"$O" \
       && ok "M-a: O3 red on a placement fragment for a staying lane" || bad "M-a: O3 red for another reason: $O"; }

echo "M-b: the note without its metrics-collect line"
mk mb; N=$(the_note "$S") && sed -i '/^- `metrics-collect`: stays on the hub:/d' "$N"
O=$(check_o3 "$S") && bad "M-b: O3 stayed green" \
  || { [ "$O" = "    metrics-collect: 0 stays lines with a reason in $N (want 1)" ] \
       && ok "M-b: O3 red on metrics-collect only" || bad "M-b: O3 output: $O"; }

echo "M-c: a hub_only row is not a move"
mk mc; fly_row "$S" lane_placement.archie-fm.hub_only fly
[ -z "$(moved_lanes "$S")" ] && ok "M-c: moved_lanes stays empty" || bad "M-c: moved_lanes = '$(moved_lanes "$S")'"

echo "M-d: fly fragment + pl_dispatch + both manifests"
mk md; fly_row "$S" lane_placement.dequeue-watch fly
printf 'pl_dispatch dequeue-watch "$@"\n' >> "$S/bin/dequeue-watch.sh"
mkdir -p "$S/catalog/lane-run-inputs.d"
printf 'state/$p.fixture\n' > "$S/catalog/lane-run-inputs.d/dequeue-watch.ro"
printf 'state/$p.fixture\n' > "$S/catalog/lane-run-inputs.d/dequeue-watch.rw"
check_o12 "$S" && ok "M-d: O1/O2 green for a moved lane on pl_dispatch with manifests" || bad "M-d: O1/O2 red: $(check_o12 "$S")"
rm "$S/catalog/lane-run-inputs.d/dequeue-watch.rw"
check_o12 "$S" && bad "M-d: O1/O2 green without the .rw manifest" || ok "M-d: O1/O2 red without the .rw manifest"

echo "M-e: a hub row for a dispatch-ready lane"
mk me; fly_row "$S" lane_placement.dequeue-watch hub
printf 'pl_dispatch dequeue-watch "$@"\n' >> "$S/bin/dequeue-watch.sh"
mkdir -p "$S/catalog/lane-run-inputs.d"
printf 'state/$p.fixture\n' > "$S/catalog/lane-run-inputs.d/dequeue-watch.ro"
printf 'state/$p.fixture\n' > "$S/catalog/lane-run-inputs.d/dequeue-watch.rw"
O=$(check_o3 "$S") && ok "M-e: O3 green for a hub row on a dispatch-ready lane" || bad "M-e: O3 red: $O"
printf "INSERT OR IGNORE INTO settings (key, value, description, actor, updated_at) VALUES\n  ('lane_placement.dequeue-watch','off','fixture BH-6894','seed','2099-01-01T00:00:00Z');\n" \
  > "$S/worker/jobs/schema.d/209901010001-bh-6894-fixture.sql"
O=$(check_o3 "$S") && bad "M-e: O3 green with a non-hub row" \
  || { grep -q 'dequeue-watch: stays, but a schema fragment sets lane_placement.dequeue-watch to a value other than hub' <<<"$O" \
       && ok "M-e: O3 red on a non-hub row" || bad "M-e: O3 red for another reason: $O"; }

echo "M-f: a hub_only reason row for a lane that is not dispatch-ready"
mk mf; fly_row "$S" lane_placement.review-autopilot.hub_only 'fixture reason'
O=$(check_o3 "$S") && ok "M-f: O3 green for a review-autopilot .hub_only row" || bad "M-f: O3 red: $O"
for K in lane_placement.review-autopilot lane_placement.review-autopilot.hub_onlyx; do
  fly_row "$S" "$K" hub
  O=$(check_o3 "$S") && bad "M-f: O3 green with a $K row" \
    || { grep -q 'review-autopilot: stays, but a schema fragment names lane_placement.review-autopilot' <<<"$O" \
         && ok "M-f: O3 red on a $K row" || bad "M-f: O3 red for another reason: $O"; }
done

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
