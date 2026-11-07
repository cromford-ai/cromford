#!/bin/bash
# tests/docker-base-digest.bh-9209-test.sh — every committed Dockerfile pins
# its public base image by digest (BH-9209, Aikido 57216460).
#
# A tag can point at a new image at any time, so a rebuild can pull an image
# nobody reviewed. check_df reads one Dockerfile and prints one finding per
# FROM that names a public image without `@sha256:<64 hex>`:
#   from:unpinned <image>     no digest
#   from:bad-digest <image>   an `@sha256:` that is not 64 lowercase hex
#   from:unknown-arg <NAME>   FROM ${NAME} with no ARG NAME in the file
# A FROM passes when it names `scratch`, an earlier stage (`AS <name>`), an ARG
# with no default (the build passes the value; the file has nothing to pin),
# or a repo-built image (`ghcr.io/example-org/`, `registry.fly.io/`). An ARG
# with a default is checked as the image it names.
#
#   P  9 PASS fixtures give no finding
#   F  12 FAIL fixtures give their exact finding
#   R  every committed Dockerfile (>= 7) gives 0 findings
#   K  the 5 pinned lines keep their tag
#
# Run from anywhere: bash tests/docker-base-digest.bh-9209-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

check_df() {
  python3 - "$1" <<'PY'
import re, sys
args, stages = {}, set()
for raw in open(sys.argv[1]):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r"(?i)ARG\s+([A-Za-z_][A-Za-z0-9_]*)(?:=(\S*))?", line)
    if m:
        args[m.group(1)] = m.group(2)
        continue
    if not re.match(r"(?i)FROM\s", line):
        continue
    toks = [t for t in line.split()[1:] if not t.startswith("--")]
    if not toks:
        print("from:unpinned <none>")
        continue
    img = toks[0]
    if len(toks) >= 3 and toks[1].lower() == "as":
        stage = toks[2].lower()
    else:
        stage = None
    def check(image):
        if image.lower() == "scratch" or image.lower() in stages:
            return
        if image.startswith(("ghcr.io/example-org/", "registry.fly.io/")):
            return
        if "@" not in image:
            print(f"from:unpinned {image}")
        elif not re.search(r"@sha256:[0-9a-f]{64}$", image):
            print(f"from:bad-digest {image}")
    a = re.fullmatch(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", img)
    if a:
        name = a.group(1)
        if name not in args:
            print(f"from:unknown-arg {name}")
        elif args[name]:
            check(args[name])
    else:
        check(img)
    if stage:
        stages.add(stage)
PY
}

H="sha256:$(printf '%064d' 0 | tr 0 a)"   # a well-formed 64-hex digest

# expect <case> <want-findings> <dockerfile body>
expect() {
  local name=$1 want=$2 f="$T/$1.Dockerfile" got
  printf '%b\n' "$3" > "$f"
  got=$(check_df "$f"); local rc=$?
  [ "$rc" -eq 0 ] || { bad "$name: check_df rc=$rc"; return; }
  [ "$got" = "$want" ] && ok || bad "$name: want [$want] got [$got]"
}

# ── P: PASS fixtures ────────────────────────────────────────────────────────
expect P1 "" "FROM debian:trixie-slim@$H\nRUN true"
expect P2 "" "FROM --platform=linux/amd64 ubuntu:24.04@$H AS base\nRUN true\nFROM base AS final"
expect P3 "" "FROM scratch"
expect P4 "" "ARG CI_BASE=ghcr.io/example-org/ci-base:ad930bd49a76\nFROM \${CI_BASE}"
expect P5 "" "ARG HUB_BASE_IMAGE\nFROM \${HUB_BASE_IMAGE}"
expect P6 "" "ARG B=debian:trixie-slim@$H\nFROM \$B"
expect P7 "" "from ubuntu:24.04@$H"
expect P8 "" "FROM registry.fly.io/harness-builder:x"
expect P9 "" "# FROM ubuntu:24.04\nFROM ubuntu:24.04@$H"

# ── F: FAIL fixtures ────────────────────────────────────────────────────────
expect F1  "from:unpinned debian:trixie-slim" "FROM debian:trixie-slim"
expect F2  "from:unpinned ubuntu:24.04" "FROM ubuntu:24.04 AS base\nFROM base AS final"
expect F3  "from:unpinned ubuntu:24.04" "FROM --platform=linux/amd64 ubuntu:24.04"
expect F4  "from:bad-digest debian:trixie-slim@sha256:abc" "FROM debian:trixie-slim@sha256:abc"
expect F5  "from:unpinned debian:trixie-slim" "ARG X=debian:trixie-slim\nFROM \${X}"
expect F6  "from:unknown-arg NOPE" "FROM \${NOPE}"
expect F7  "from:unpinned base" "FROM base"
expect F8  "from:unpinned ubuntu:24.04" "from ubuntu:24.04"
expect F9  "from:unpinned ghcr.io/example-org-evil/x:1" "FROM ghcr.io/example-org-evil/x:1"
expect F10 "from:unpinned ghcr.io/other/img:1" "FROM ghcr.io/other/img:1"
expect F11 "from:unpinned docker.io/library/ubuntu:24.04" "FROM docker.io/library/ubuntu:24.04"
expect F12 "from:unpinned debian:trixie-slim" "FROM ubuntu:24.04@$H AS a\nRUN true\nFROM debian:trixie-slim AS b"

# ── R: every committed Dockerfile ───────────────────────────────────────────
mapfile -t DFS < <(git -C "$DIR" ls-files | grep -E '(^|/)(Dockerfile|[^/]*\.Dockerfile|Dockerfile\.[^/]*)$')
[ "${#DFS[@]}" -ge 7 ] && ok || bad "R: want >= 7 committed Dockerfiles, found ${#DFS[@]}"
for f in "${DFS[@]}"; do
  out=$(check_df "$DIR/$f"); rc=$?
  if [ "$rc" -ne 0 ]; then bad "R: $f: check_df rc=$rc"
  elif [ -n "$out" ]; then while IFS= read -r l; do bad "R: $f: $l"; done <<<"$out"
  else ok; fi
done

# ── K: the pinned lines keep their tag ──────────────────────────────────────
for pair in "ci-images/base/Dockerfile debian:trixie-slim" "ci-images/cromford/Dockerfile debian:trixie-slim" \
            "fly/testhost/Dockerfile debian:trixie-slim" "fly/Dockerfile ubuntu:24.04" "fly/lane-run.Dockerfile ubuntu:24.04"; do
  set -- $pair
  grep -qE "^FROM ${2//./\\.}@sha256:[0-9a-f]{64}( AS base)?\$" "$DIR/$1" && ok || bad "K: $1 must FROM $2@sha256:<64 hex>"
done

echo "docker-base-digest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
