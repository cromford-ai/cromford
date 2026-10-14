#!/bin/bash
# tests/jobs-client-usage.bh-5235-test.sh — the jobs-client usage line is
# generated from the `#:` comment above each dispatch arm (BH-5264, BH-5235.4).
#
# The usage used to be one ~6 KB literal on the `*)` arm. Every PR that added a
# verb edited that one line, so any two of them conflicted on a hunk neither was
# about. Now each arm carries its own `    #: <verb> <args>` line and `_jc_usage`
# joins them, so a new verb is an arm plus its `#:` line and nothing else.
#
#   U1. no verb, and an unknown verb: rc 2, stderr is ONE line `usage: jobs-client.sh {...}`.
#   U2. the arm set equals the `#:` set, both ways; transcript-get has two entries.
#   U3. mutation on a scratch copy: an arm with no `#:` line, and a `#:` line with
#       no arm, each go red naming the verb; the unmodified copy is green.
#   U4. the generated usage carries triage-state-get, lane-proc-beat (with its
#       own `|`s) and the new rule-unset entry verbatim.
#   U5. against the old literal (645b72ecb blob, when history has it): every old
#       entry is still a `#:` line, rule-unset is added, and the old arms are an
#       in-order subsequence of the arms now. No count or hash of TODAY's list is
#       pinned: U5b adds a documented verb to a scratch copy and stays green, and
#       U5c proves an edited entry and a moved arm go red.
#   U6. no literal usage line is left: one `usage: jobs-client.sh {` in the
#       source, no line over 400 bytes.
# JC_SRC=<file> runs the suite against another copy of the client (the old one
# from origin/main goes red on U2, U5 and U6).
# Run from anywhere: tests/jobs-client-usage.bh-5235-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
info() { echo "info: $1"; }

SRC="${JC_SRC:-$DIR/bin/jobs-client.sh}"
# sha256 of the 645b72ecb literal's entries, split by the ticket's naive rule and
# sorted under LC_ALL=C. It pins the OLD blob's extraction only, never the list now.
# Four quoted 16-hex pieces: the share leak check reads a bare 32- or 64-hex run as an id.
OLD_SHA="50a82d4f3296aeb9""52698ea44b351092""219fee3d944a41b9""264ae50b589d43b7"
RULE_UNSET='rule-unset <scope> [selector] [kind]'

# The outer dispatch arms, in file order: 4-space indent inside `case "$CMD" in`
# up to the default arm. Nested case arms sit deeper and never match.
arm_list() {
  awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit}
       f&&match($0,/^    [a-z][a-z0-9-]*\)/){print substr($0,5,RLENGTH-5)}' "$1"
}
arm_set() { arm_list "$1" | sort -u; }
# The first word of every `    #: ` line in the same block.
doc_set() {
  awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit}
       f&&sub(/^    #: /,""){print $1}' "$1" | sort -u
}
# check_sync <file>: prints `arm without #: <verb>` / `#: without arm <verb>`,
# rc 1 when either list is non-empty.
check_sync() {
  local a d out
  a=$(arm_set "$1"); d=$(doc_set "$1")
  out=$( comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$d") | sed '/^$/d; s/^/arm without #: /'
         comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$d") | sed '/^$/d; s/^/#: without arm /' )
  [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }
}
# split_entries <naive|depth> <arms...>: one usage body on stdin, one entry per
# line out. A `|` splits only when the next token is an arm name; `depth` also
# requires it to sit outside every <...> and [...].
split_entries() {
  local mode="$1"; shift
  awk -v arms="$*" -v mode="$mode" '
    BEGIN { n = split(arms, a, " "); for (i = 1; i <= n; i++) A[a[i]] = 1 }
    { s = $0; cur = ""; d = 0; L = length(s)
      for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (c == "<" || c == "[") d++; else if (c == ">" || c == "]") d--
        if (c == "|" && (mode == "naive" || d == 0)) {
          rest = substr(s, i + 1); tok = match(rest, /^[^ |]+/) ? substr(rest, 1, RLENGTH) : ""
          if (tok in A) { print cur; cur = ""; continue }
        }
        cur = cur c
      }
      print cur }'
}

[ -r "$SRC" ] || { echo "jobs-client-usage.bh-5235-test: cannot read $SRC"; exit 1; }

# A scratch harness running the client as delivered, with $SRC as its client.
H="$T/h"
mkdir -p "$H/env" "$H/logs"
: > "$H/env/global.env"
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
cp "$SRC" "$H/bin/jobs-client.sh"
run_jc() {
  env -u HARNESS_SECRET -u JOBS_URL HARNESS="$H" HARNESS_ENV_DIR="$H/env" \
    bash "$H/bin/jobs-client.sh" "$@"
}

# ══ U1. the usage is one line on stderr, rc 2 ═══════════════════════════════
USAGE=""
for verb in "" bogus-verb; do
  if [ -z "$verb" ]; then run_jc >"$T/out" 2>"$T/err"; rc=$?
  else run_jc "$verb" >"$T/out" 2>"$T/err"; rc=$?; fi
  [ "$rc" = 2 ] && ok || bad "U1 '${verb:-<none>}': rc $rc, want 2"
  [ ! -s "$T/out" ] && ok || bad "U1 '${verb:-<none>}': stdout is not empty"
  lines=$(wc -l < "$T/err")
  [ "$lines" = 1 ] && ok || bad "U1 '${verb:-<none>}': stderr has $lines lines, want 1"
  line=$(cat "$T/err")
  case "$line" in
    'usage: jobs-client.sh {'*'}') ok ;;
    *) bad "U1 '${verb:-<none>}': stderr is not 'usage: jobs-client.sh {...}': $(printf '%s' "$line" | head -c 120)" ;;
  esac
  [ -z "$verb" ] && USAGE="$line"
  [ -n "$verb" ] && { [ "$line" = "$USAGE" ] && ok || bad "U1: bogus-verb usage differs from the no-verb usage"; }
done
BODY=${USAGE#usage: jobs-client.sh \{}; BODY=${BODY%\}}

# ══ U2. every arm has its #: line, every #: line has its arm ════════════════
if out=$(check_sync "$SRC"); then ok; else bad "U2: arm/#: mismatch: $(head -5 <<<"$out" | tr '\n' ';')"; fi
[ "$(arm_set "$SRC" | wc -l)" -gt 100 ] && ok || bad "U2: fewer than 100 arms found in $SRC: the block scoping is wrong"
n=$(awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit} f&&/^    #: transcript-get /{n++} END{print n+0}' "$SRC")
[ "$n" = 2 ] && ok || bad "U2: transcript-get has $n #: lines, want 2"

# ══ U3. the check is not always green, and not always red ═══════════════════
awk '/^    \*\)/&&!d{print "    zz-u3a-undocumented) true; RC=0 ;;"; d=1} {print}' "$SRC" > "$T/a.sh"
out=$(check_sync "$T/a.sh"); rc=$?
[ "$rc" = 1 ] && grep -qx 'arm without #: zz-u3a-undocumented' <<<"$out" && ok \
  || bad "U3a: an arm with no #: line was not named (rc $rc): $out"
awk '/^    \*\)/&&!d{print "    #: zz-u3b-armless <x>"; d=1} {print}' "$SRC" > "$T/b.sh"
out=$(check_sync "$T/b.sh"); rc=$?
[ "$rc" = 1 ] && grep -qx '#: without arm zz-u3b-armless' <<<"$out" && ok \
  || bad "U3b: a #: line with no arm was not named (rc $rc): $out"
cp "$SRC" "$T/c.sh"
if check_sync "$T/c.sh" >/dev/null; then ok; else bad "U3c: the unmodified copy does not pass check_sync"; fi

# ══ U4. entries survive verbatim ════════════════════════════════════════════
for e in 'triage-state-get <project> <key>' \
         'lane-proc-beat <lane> start|beat|done [pid] [interval_s] [expect_s] [note]' \
         "$RULE_UNSET"; do
  grep -qF -- "$e" <<<"$USAGE" && ok || bad "U4: usage lacks '$e'"
done

# ══ U5. every old entry survives, plus rule-unset; no arm moved ═════════════
# Nothing here pins today's verb list: the checks are that the 645b72ecb entries
# are a SUBSET of the `#:` entries and its arms an in-order SUBSEQUENCE of the
# arms now, so a PR that adds an arm and its `#:` line touches no line of this
# file (U5b proves it on a scratch copy).
OLDOK=0
if git -C "$DIR" cat-file -e 645b72ecb:bin/jobs-client.sh 2>/dev/null; then
  git -C "$DIR" show 645b72ecb:bin/jobs-client.sh > "$T/old.sh"
  oldbody=$(sed -n 's/^    \*) echo "usage: jobs-client.sh {\(.*\)}" >&2; exit 2 ;;$/\1/p' "$T/old.sh")
  read -r -a OARMS <<< "$(arm_list "$T/old.sh" | tr '\n' ' ')"
  osha=$(printf '%s\n' "$oldbody" | split_entries naive "${OARMS[@]}" | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
  [ -n "$oldbody" ] && [ "$osha" = "$OLD_SHA" ] && ok \
    || bad "U5: the 645b72ecb literal hashes to $osha, want $OLD_SHA (the extraction is wrong)"
  printf '%s\n' "$oldbody" | split_entries depth "${OARMS[@]}" | LC_ALL=C sort -u > "$T/old.entries"
  arm_list "$T/old.sh" > "$T/old.arms"
  OLDOK=1
else
  info "U5: 645b72ecb is not in this clone's history; the old-literal comparison did not run"
fi
# The `#:` entries of a client, in file order.
doc_entries() {
  awk '/^  case "\$CMD" in/{f=1;next} f&&/^    \*\)/{exit} f&&sub(/^    #: /,""){print}' "$1"
}
# entry_check <file> <usage-body>: prints one line per failed check (empty = pass).
entry_check() {
  local f="$1" body="$2" arms naive depth miss n
  read -r -a arms <<< "$(arm_list "$f" | tr '\n' ' ')"
  [ "$body" = "$(doc_entries "$f" | paste -sd'|')" ] || echo "the usage is not the #: lines joined in order"
  naive=$(printf '%s\n' "$body" | split_entries naive "${arms[@]}")
  depth=$(printf '%s\n' "$body" | split_entries depth "${arms[@]}")
  n=$(printf '%s\n' "$naive" | wc -l); [ "$n" -ge 148 ] || echo "naive split gives $n pieces, want >= 148"
  n=$(printf '%s\n' "$depth" | wc -l); [ "$n" -ge 147 ] || echo "bracket-aware split gives $n entries, want >= 147"
  # grep reads all of a here-string, so -q cannot SIGPIPE a writer under pipefail.
  grep -qx 'mt-put <project> <branch> <creating|open|landed|abandoned> \[k=v...\]' <<< "$depth" \
    || echo "mt-put is not one whole entry"
  grep -qxF -- "$RULE_UNSET" <<< "$(doc_entries "$f")" || echo "no '#: $RULE_UNSET' line"
  if [ "$OLDOK" = 1 ]; then
    miss=$(doc_entries "$f" | LC_ALL=C sort -u | LC_ALL=C comm -23 "$T/old.entries" -)
    [ -z "$miss" ] || echo "645b72ecb entries missing now: $(head -3 < <(printf '%s' "$miss") | tr '\n' ';')"
    # in-order subsequence: walk the current arms, consuming the old list.
    arm_list "$f" | awk 'NR==FNR{o[++n]=$0; next} i<n && $0==o[i+1]{i++} END{exit !(i==n)}' "$T/old.arms" - \
      || echo "the 645b72ecb arms are not an in-order subsequence of the arms now (an arm moved or went)"
  fi
  return 0
}
usage_body() {
  local line
  cp "$1" "$H/bin/jobs-client.sh"; line=$(run_jc 2>&1 >/dev/null)
  cp "$SRC" "$H/bin/jobs-client.sh"
  line=${line#usage: jobs-client.sh \{}; printf '%s' "${line%\}}"
}
out=$(entry_check "$SRC" "$BODY")
[ -z "$out" ] && ok || bad "U5: $(printf '%s' "$out" | tr '\n' ';')"

# U5b. a correctly documented new verb (arm + `#:` line, nothing else) stays
# green on U2 and U5, and shows up in the usage.
awk '/^    \*\)/&&!d{print "    #: zz-new <x>"; print "    zz-new) true; RC=0 ;;"; d=1} {print}' "$SRC" > "$T/new.sh"
if out=$(check_sync "$T/new.sh"); then ok; else bad "U5b: a documented new verb fails U2: $out"; fi
nbody=$(usage_body "$T/new.sh")
out=$(entry_check "$T/new.sh" "$nbody")
[ -z "$out" ] && ok || bad "U5b: a documented new verb fails U5: $(printf '%s' "$out" | tr '\n' ';')"
case "|$nbody|" in *'|zz-new <x>|'*) ok ;; *) bad "U5b: the new verb's entry is not in its usage" ;; esac

# U5c. the old-literal checks are not always green: an edited entry and a moved
# arm each go red.
if [ "$OLDOK" = 1 ]; then
  sed 's/^    #: triage-state-get <project> <key>$/    #: triage-state-get <key>/' "$SRC" > "$T/edit.sh"
  out=$(entry_check "$T/edit.sh" "$(usage_body "$T/edit.sh")")
  grep -q '645b72ecb entries missing now: triage-state-get <project> <key>' <<<"$out" && ok \
    || bad "U5c: an edited old entry was not caught: $out"
  # Move the first arm (with its #: lines) to just above `*)`.
  awk '/^  case "\$CMD" in/{f=1; print; next}
       f==1 && /^    #: /{hold=hold $0 "\n"; next}
       f==1 && /^    [a-z][a-z0-9-]*\)/{hold=hold $0 "\n"; f=2; next}
       f==1 {printf "%s", hold; hold=""; print; next}
       f==2 && /^    \*\)/{printf "%s", hold; f=3}
       {print}' "$SRC" > "$T/move.sh"
  if [ "$(arm_list "$T/move.sh" | sort)" = "$(arm_list "$SRC" | sort)" ] \
     && [ "$(arm_list "$T/move.sh")" != "$(arm_list "$SRC")" ]; then
    out=$(entry_check "$T/move.sh" "$(usage_body "$T/move.sh")")
    grep -q 'not an in-order subsequence' <<<"$out" && ok \
      || bad "U5c: a moved arm was not caught: $out"
  else
    bad "U5c: the move fixture did not move exactly one arm"
  fi
fi

# ══ U6. no literal usage line is left ═══════════════════════════════════════
n=$(grep -c 'usage: jobs-client.sh {' "$SRC")
[ "$n" = 1 ] && ok || bad "U6: 'usage: jobs-client.sh {' appears $n times in the source, want 1"
long=$(awk 'length>400{print FNR}' "$SRC" | tr '\n' ' ')
[ -z "$long" ] && ok || bad "U6: lines over 400 bytes: $long"

echo "jobs-client-usage.bh-5235-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
