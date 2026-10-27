#!/bin/bash
# tests/lib/project-21-fake.bh-8079.sh — start and drive the fake project-21 API
# (tests/lib/fake-project-21-api.bh-8079.py) for the BH-8079 suites. Sourced after
# tests/lib/scratch.sh, with $T set and the repo root as the first argument.
#
#   tf_start            start the fake on 127.0.0.1 and export project-21_BASE_URL
#   tf_mode <mode>      the answer of the next requests (see the .py header)
#   tf_reset            empty the request log
#   tf_posts            the count of POST requests the fake saw
#   tf_fields           the multipart field names of the last request
# The EXIT trap stops the fake and then runs the scratch cleanup.
TF_SRC="${1:-}"
TF_DIR="$T/project-21-fake"
TF_PID=""
mkdir -p "$TF_DIR"

tf_start() {
  local i
  rm -f "$TF_DIR/port"
  python3 -I "$TF_SRC/tests/lib/fake-project-21-api.bh-8079.py" "$TF_DIR" >/dev/null 2>&1 &
  TF_PID=$!
  for i in $(seq 1 100); do [ -s "$TF_DIR/port" ] && break; sleep 0.05; done
  [ -s "$TF_DIR/port" ] || { echo "FAIL: the fake project-21 API did not start"; return 1; }
  export project-21_BASE_URL="http://127.0.0.1:$(cat "$TF_DIR/port")"
}
tf_mode()   { printf '%s\n' "$1" > "$TF_DIR/mode"; }
tf_reset()  { : > "$TF_DIR/req.log"; }
tf_posts()  { grep -c '^POST ' "$TF_DIR/req.log" 2>/dev/null || true; }
tf_fields() { tail -1 "$TF_DIR/req.log" 2>/dev/null | awk '{print $3}'; }

__tf_exit() {
  [ -n "$TF_PID" ] && kill "$TF_PID" 2>/dev/null
  __scratch_exit_trap
}
trap __tf_exit EXIT
