# shellcheck shell=bash
# tests/lib/unblock-gate-fake.bh-10197.sh — a file-backed fake of the two jobs
# worker routes of the unblock change gate (BH-10197), for the hub suites that
# drive bin/unblock.sh with a fake _jobs_req. Sourced from a suite's fixture
# file. Functions only.
#
# It follows the decision rule of worker/jobs/src/routes/unblock-change-marks.js
# (first, head, wake, unsettled, off, backstop, else quiet), on a fixture clock:
#   FXG_DIR    the state dir: rows.json {"<site>:<pr>": row}, wakes.json [..]
#   GATE_NOW   the fake worker clock, epoch seconds (a wake minute is now/60)
# Fail switches: $FXG_DIR/check-fail and $FXG_DIR/commit-fail hold the rc the
# route returns (75 = rate limited, 1 = an http 500 as _jobs_req reports it).
# Each call appends "check" or "commit" and the body to $FXG_DIR/calls.log.
#
#   fxg_reset                 empty rows and wakes, no fail switch, no log
#   fxg_wake <kind> <key> <epoch>   one wakes row; the id is the next sequence
#   fxg_req <method> <path> <body>  the route; rc 2 for a path it does not own

fxg_reset() {
  mkdir -p "$FXG_DIR"
  echo '{}' > "$FXG_DIR/rows.json"; echo '[]' > "$FXG_DIR/wakes.json"
  rm -f "$FXG_DIR/check-fail" "$FXG_DIR/commit-fail" "$FXG_DIR/calls.log"
}

fxg_wake() {
  jq -c --arg k "$1" --arg key "$2" --argjson at "$3" \
    '. + [{kind: $k, key: $key, id: ((map(.id) | max // 100) + 1), minute: (($at / 60) | floor)}]' \
    "$FXG_DIR/wakes.json" > "$FXG_DIR/wakes.tmp" && mv "$FXG_DIR/wakes.tmp" "$FXG_DIR/wakes.json"
}

fxg_req() {
  local m="$1" p="$2" body="${3:-}" rc out
  case "$m $p" in
    "POST /api/unblock/change-marks/check")
      printf 'check %s\n' "$body" >> "$FXG_DIR/calls.log"
      if [ -f "$FXG_DIR/check-fail" ]; then rc=$(cat "$FXG_DIR/check-fail"); return "$rc"; fi
      jq -c --slurpfile rows "$FXG_DIR/rows.json" --slurpfile w "$FXG_DIR/wakes.json" --argjson now "$GATE_NOW" '
        . as $b | (($now / 60) | floor) as $cur
        | {as_of: $now, items: [$b.items[] | . as $it
          | [$w[0][] | select((.kind == "pr" and .key == ($it.pr | tostring))
                              or (.kind == "issue" and $it.issue != null and .key == ($it.issue | tostring)))] as $ws
          | (if ($ws | length) == 0 then 0 else ([$ws[].id] | max) end) as $mark
          | (if ($ws | length) == 0 then 1 elif ([$ws[].minute] | max) < $cur then 1 else 0 end) as $settled
          | $rows[0]["\($b.site):\($it.pr)"] as $row
          | (if $row == null then [true, "first"] elif $row.head != $it.head then [true, "head"]
             elif $mark > $row.mark then [true, "wake"] elif $row.settled == 0 then [true, "unsettled"]
             elif $b.backstop_s == 0 then [true, "off"] elif ($now - $row.checked_at) >= $b.backstop_s then [true, "backstop"]
             else [false, "quiet"] end) as $d
          | {pr: $it.pr, due: $d[0], reason: $d[1], mark: $mark, settled: $settled, fields: ($row.fields // {})}]}' <<<"$body"
      ;;
    "POST /api/unblock/change-marks/commit")
      printf 'commit %s\n' "$body" >> "$FXG_DIR/calls.log"
      if [ -f "$FXG_DIR/commit-fail" ]; then rc=$(cat "$FXG_DIR/commit-fail"); return "$rc"; fi
      out=$(jq -c --slurpfile b <(printf '%s' "$body") --argjson now "$GATE_NOW" '
        . as $rows | reduce $b[0].items[] as $it ({rows: $rows, n: 0};
          "\($b[0].site):\($it.pr)" as $k
          | if .rows[$k] == null or $it.mark >= .rows[$k].mark
            then .rows[$k] = {head: $it.head, mark: $it.mark, settled: $it.settled, fields: $it.fields, checked_at: $now} | .n += 1
            else . end)' "$FXG_DIR/rows.json") || return 1
      jq -c .rows <<<"$out" > "$FXG_DIR/rows.json"
      jq -c '{ok: true, stored: .n, refused: []}' <<<"$out"
      ;;
    *) return 2 ;;
  esac
}
