#!/bin/bash
# tests/harness-ci-tool-download.bh-6950-test.sh — BH-6950: A CI TOOL DOWNLOAD
# IS RETRIED, CACHED, AND NAMED AS INFRA WHEN IT STILL FAILS.
#
# Merge-queue batch #6943 went red on one GitHub 504 from the raw gitleaks curl
# in the tests-shard job. A single transient error took a PR out of the queue.
#
#   W1  every non-comment curl/wget line in harness-ci.yml (continuations
#       joined) runs through `bin/ci-retry.sh `
#   W2  the gitleaks ci-retry call sets no CI_RETRY_ATTEMPTS override (the
#       semgrep install's count: ci-retry's default)
#   W3  the step that runs the gitleaks curl is named `infra: tool download:…`
#       and its ci-retry label contains `tool download`
#   W4  the install step has no curl
#   C1  an actions/cache/restore step precedes the download step, keyed
#       gitleaks-$V-$SHA with V/SHA read from the install step
#   C2  an actions/cache/save step follows the install step, runs only when
#       steps.gitleaks-dl.outputs.downloaded == '1', with C1's key
#   C3  the tarball path is the same in the download and install steps, and the
#       cache path is its directory
#   D1-D4 the download step body, EXECUTED with a stub curl and the real
#       bin/ci-retry.sh: retry to success, the warning annotation, no download
#       when cached or already installed, and a red with the infra error after
#       the last attempt
#
# curl is always a stub: this suite never touches the network. No clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
WF="$REPO/.github/workflows/harness-ci.yml"
BASH_BIN=$(command -v bash)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# step_field <step-name-prefix> <field> — for the first step whose name starts
# with the prefix: `run` prints the dedented `run: |` body, `index` its position
# among the tests-shard job's steps, `if`/`uses`/`id` the scalar, and `with.<k>`
# a `with:` value. rc 1 if there is no such step or field.
step_field() {
  python3 - "$WF" "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
want, field = sys.argv[2].lower(), sys.argv[3]
inj, n, start = False, 0, None
steps = []
for i, l in enumerate(lines):
    if l == "  tests-shard:":
        inj = True
        continue
    if inj and re.match(r"^  [A-Za-z0-9_-]+:\s*$", l):
        break
    if inj and re.match(r"^      - ", l):
        steps.append(i)
if not steps:
    sys.exit(1)
end_all = len(lines)
for k, i in enumerate(steps):
    j_end = steps[k + 1] if k + 1 < len(steps) else end_all
    block = lines[i:j_end]
    m = re.match(r"^      - name:\s*(.*)$", block[0])
    if not m or not m.group(1).strip().strip('"').lower().startswith(want):
        continue
    if field == "index":
        print(k); sys.exit(0)
    for b, s in enumerate(block):
        if field == "run" and re.match(r"^        run:\s*\|\s*$", s):
            body = []
            for t in block[b + 1:]:
                if t.strip() and len(t) - len(t.lstrip()) <= 8:
                    break
                body.append(t)
            mi = min(len(t) - len(t.lstrip()) for t in body if t.strip())
            print("\n".join(t[mi:] for t in body).rstrip("\n")); sys.exit(0)
        key = field.split(".", 1)[-1]
        ind = 10 if field.startswith("with.") else 8
        r = re.match(r"^" + " " * ind + re.escape(key) + r":\s*(.+)$", s)
        if r and field != "run":
            print(r.group(1).strip()); sys.exit(0)
    sys.exit(1)
sys.exit(1)
PY
}

DL="infra: tool download: gitleaks"
INS="install gitleaks"

# ── W1. every curl/wget runs through ci-retry ───────────────────────────────
RAW=$(awk '
  /^[[:space:]]*#/ { next }
  { line = $0; sub(/^[[:space:]]+/, "", line)
    if (held != "") { line = held " " line; held = "" }
    if (line ~ /\\$/) { sub(/[[:space:]]*\\$/, "", line); held = line; next }
    if (line ~ /(^|[^A-Za-z0-9_-])(curl|wget) /) print NR ": " line }' "$WF" \
  | grep -v '^[0-9]*: bin/ci-retry\.sh ')
[ -z "$RAW" ] && ok || bad "W1: a tool download in harness-ci.yml does not run through bin/ci-retry.sh: $RAW"

# ── W2-W4, C1-C3. the steps ─────────────────────────────────────────────────
DL_BODY=$(step_field "$DL" run) || DL_BODY=""
INS_BODY=$(step_field "$INS" run) || INS_BODY=""
if [ -z "$DL_BODY" ]; then
  bad "W3: no tests-shard step named '$DL…' with a run body"
else
  RETRY=$(sed 's/^[[:space:]]*//' <<<"$DL_BODY" | grep '^bin/ci-retry\.sh .*curl ' | head -1)
  if [ -z "$RETRY" ]; then bad "W3: the '$DL' step runs no curl through bin/ci-retry.sh"
  else
    ok
    grep -q '^bin/ci-retry\.sh "tool download[^"]*" ' <<<"$RETRY" \
      && ok || bad "W3: the ci-retry label must contain 'tool download' (got: $RETRY)"
  fi
  grep -q 'CI_RETRY_ATTEMPTS' <<<"$DL_BODY" \
    && bad "W2: the gitleaks download must use ci-retry's default attempt count, as semgrep does" || ok
fi
if [ -z "$INS_BODY" ]; then bad "W4: no tests-shard step named '$INS…'"
else
  grep -q 'curl' <<<"$INS_BODY" && bad "W4: the install step still runs curl itself" || ok
fi

V=$(sed -n 's/^V=\([0-9][0-9.]*\)$/\1/p' <<<"$INS_BODY" | head -1)
SHA=$(sed -n 's/^SHA=\([0-9a-f]\{64\}\)$/\1/p' <<<"$INS_BODY" | head -1)
WANT_KEY="gitleaks-$V-$SHA"
I_DL=$(step_field "$DL" index) || I_DL=""
I_INS=$(step_field "$INS" index) || I_INS=""
I_RES=$(step_field "restore the pinned gitleaks" index) || I_RES=""
I_SAV=$(step_field "save the pinned gitleaks" index) || I_SAV=""
if [ -z "$V" ] || [ -z "$SHA" ]; then bad "C1: could not read V/SHA from the install step"
elif [ -z "$I_RES" ] || [ -z "$I_DL" ]; then bad "C1: no restore step (got '$I_RES') or download step (got '$I_DL')"
else
  [ "$I_RES" -lt "$I_DL" ] && ok || bad "C1: the cache restore (step $I_RES) must come before the download (step $I_DL)"
  case "$(step_field "restore the pinned gitleaks" uses)" in
    actions/cache/restore@*) ok ;; *) bad "C1: the restore step must use actions/cache/restore" ;;
  esac
  [ "$(step_field "restore the pinned gitleaks" with.key)" = "$WANT_KEY" ] \
    && ok || bad "C1: the restore key must be '$WANT_KEY' (got '$(step_field "restore the pinned gitleaks" with.key)')"
fi
if [ -z "$I_SAV" ] || [ -z "$I_INS" ]; then bad "C2: no save step (got '$I_SAV') or install step (got '$I_INS')"
else
  [ "$I_SAV" -gt "$I_INS" ] && ok || bad "C2: the cache save (step $I_SAV) must come after the checksum-verified install (step $I_INS)"
  case "$(step_field "save the pinned gitleaks" uses)" in
    actions/cache/save@*) ok ;; *) bad "C2: the save step must use actions/cache/save" ;;
  esac
  [ "$(step_field "save the pinned gitleaks" if)" = "steps.gitleaks-dl.outputs.downloaded == '1'" ] \
    && ok || bad "C2: the save step must run only when this run downloaded (got if: '$(step_field "save the pinned gitleaks" if)')"
  [ "$(step_field "save the pinned gitleaks" with.key)" = "$WANT_KEY" ] \
    && ok || bad "C2: the save key must equal the restore key '$WANT_KEY'"
  [ "$(step_field "$DL" id)" = "gitleaks-dl" ] && ok || bad "C2: the download step must have id gitleaks-dl"
fi

# C3. one tarball path, written by the download, read by the install, cached by
# its directory.
TGZ_DL=$(sed -n 's/^TGZ=//p' <<<"$DL_BODY" | head -1)
D_DL=$(sed -n 's/^D=//p' <<<"$DL_BODY" | head -1)
TGZ_INS=$(sed -n 's/^TGZ=//p' <<<"$INS_BODY" | head -1)
TGZ_DL_X=${TGZ_DL//\$D/${D_DL//\"/}}
if [ -z "$TGZ_DL" ] || [ -z "$TGZ_INS" ]; then bad "C3: TGZ= missing from the download ('$TGZ_DL') or install ('$TGZ_INS') step"
elif [ "${TGZ_DL_X//\"/}" = "${TGZ_INS//\"/}" ]; then ok
else bad "C3: the download writes $TGZ_DL_X but the install reads $TGZ_INS"
fi
CPATH=$(step_field "restore the pinned gitleaks" with.path)
[ -n "$CPATH" ] && [ "${CPATH/\$\{\{ runner.temp \}\}/\$RUNNER_TEMP}" = "${D_DL//\"/}" ] \
  && ok || bad "C3: the cache path '$CPATH' must be the download dir '$D_DL'"
grep -q 'sha256sum -c' <<<"$INS_BODY" && grep -q '"\$TGZ"' <<<"$INS_BODY" \
  && ok || bad "C3: the install step must checksum and unpack \$TGZ"

# ── D1-D4. the download step, executed ──────────────────────────────────────
# run_dl <case> <curl-script> <present-rc> [seed-tarball]: writes the step body
# to a scratch repo with the real bin/ci-retry.sh, a stub ci-tool-present.sh
# and a stub curl that records each call, then runs it.
run_dl() {
  local c="$1" R="$T/$1"
  mkdir -p "$R/bin" "$R/stub" "$R/tmp"
  scratch_install_closure bin/ci-retry.sh "$R" >/dev/null || { bad "$c: cannot install bin/ci-retry.sh"; return 1; }
  printf '#!%s\nexit %s\n' "$BASH_BIN" "$3" > "$R/bin/ci-tool-present.sh"
  # The stub reads its rc for call N from line N of curl.plan (last line repeats).
  printf '%s\n' $2 > "$R/curl.plan"
  cat > "$R/stub/curl" <<EOF
#!$BASH_BIN
echo "\$*" >> "$R/curl.calls"
n=\$(wc -l < "$R/curl.calls")
rc=\$(sed -n "\${n}p" "$R/curl.plan"); [ -n "\$rc" ] || rc=\$(tail -1 "$R/curl.plan")
[ "\$rc" = 0 ] || { echo "curl: (22) The requested URL returned error: 504" >&2; exit "\$rc"; }
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { printf 'fixture-tarball\n' > "\$2"; }; shift; done
EOF
  chmod +x "$R/bin/ci-tool-present.sh" "$R/stub/curl"
  : > "$R/curl.calls"; : > "$R/gh.out"
  if [ -n "${4:-}" ]; then mkdir -p "$R/tmp/bh-gitleaks-cache"; printf 'cached\n' > "$R/tmp/bh-gitleaks-cache/gitleaks_${V}_linux_x64.tar.gz"; fi
  printf '%s\n' "$DL_BODY" > "$R/step.sh"
  ( cd "$R" && env -u CI_RETRY_ATTEMPTS PATH="$R/stub:$PATH" RUNNER_TEMP="$R/tmp" GITHUB_OUTPUT="$R/gh.out" \
      CI_RETRY_DELAY_S=0 "$BASH_BIN" step.sh ) > "$R/out" 2>&1
  echo $? > "$R/rc"
}
calls() { wc -l < "$T/$1/curl.calls" | tr -d ' '; }
TGZ_NAME="bh-gitleaks-cache/gitleaks_${V}_linux_x64.tar.gz"

if [ -z "$DL_BODY" ] || [ -z "$V" ]; then
  bad "D1-D4: no download step body or V to execute"
else
  # D1/D2. a 504, then a success.
  run_dl d1 "22 0" 1
  [ "$(cat "$T/d1/rc")" = 0 ] && ok || bad "D1: one 504 then success must be rc 0 (got $(cat "$T/d1/rc"): $(tail -3 "$T/d1/out" | tr '\n' '|'))"
  [ "$(calls d1)" = 2 ] && ok || bad "D1: expected 2 curl calls (got $(calls d1))"
  [ -s "$T/d1/tmp/$TGZ_NAME" ] && ok || bad "D1: the tarball must be at \$RUNNER_TEMP/$TGZ_NAME"
  grep -qx 'downloaded=1' "$T/d1/gh.out" && ok || bad "D1: the step must set downloaded=1 (got: $(cat "$T/d1/gh.out"))"
  grep -q '^::warning title=CI infra (tool download: gitleaks)::' "$T/d1/out" \
    && ok || bad "D2: a retried download must print '::warning title=CI infra (tool download: gitleaks)' (got: $(head -3 "$T/d1/out" | tr '\n' '|'))"

  # D3. cached tarball: nothing downloaded, nothing to save.
  run_dl d3 "0" 1 seed
  [ "$(cat "$T/d3/rc")" = 0 ] && ok || bad "D3: a cached tarball must be rc 0 (got $(cat "$T/d3/rc"))"
  [ "$(calls d3)" = 0 ] && ok || bad "D3: a cached tarball must download nothing (curl calls: $(calls d3))"
  grep -q 'downloaded=1' "$T/d3/gh.out" && bad "D3: a cache hit must not set downloaded=1" || ok
  # D3b. the pin already installed, no tarball: nothing downloaded either.
  run_dl d3b "0" 0
  [ "$(cat "$T/d3b/rc")" = 0 ] && ok || bad "D3: an installed pin must be rc 0 (got $(cat "$T/d3b/rc"))"
  [ "$(calls d3b)" = 0 ] && ok || bad "D3: an installed pin must download nothing (curl calls: $(calls d3b))"
  grep -q 'downloaded=1' "$T/d3b/gh.out" && bad "D3: an installed pin must not set downloaded=1" || ok

  # D4. three 504s: red, with the curl's rc and the infra error.
  run_dl d4 "22" 1
  [ "$(cat "$T/d4/rc")" = 22 ] && ok || bad "D4: three failed downloads must be rc 22, never a pass (got $(cat "$T/d4/rc"))"
  [ "$(calls d4)" = 3 ] && ok || bad "D4: expected 3 curl calls, ci-retry's default (got $(calls d4))"
  grep -q '^::error title=CI infra (tool download: gitleaks)::' "$T/d4/out" \
    && ok || bad "D4: the last failure must print '::error title=CI infra (tool download: gitleaks)' (got: $(tail -3 "$T/d4/out" | tr '\n' '|'))"
  grep -q 'downloaded=1' "$T/d4/gh.out" && bad "D4: a failed download must not set downloaded=1" || ok
fi

echo "harness-ci-tool-download.bh-6950-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
