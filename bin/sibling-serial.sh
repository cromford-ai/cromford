#!/bin/bash
# bin/sibling-serial.sh decide <rows> <inflight> <prs> [parts]
# bin/sibling-serial.sh check <project> <KEY>
# bin/sibling-serial.sh prime <project>
# bin/sibling-serial.sh parts <project>
# bin/sibling-serial.sh replay <rows> <parts> | replay --project <p> [--last N]
#
# SIBLING PARTS OF ONE SPLIT SLICE THAT SHARE A PLANNED FILE RUN ONE AT A TIME,
# IN n ORDER. A part is one slice of a parent ticket split into slices that were
# planned against the same contract and very often edit the same files. Run side
# by side, the second to merge conflicts with the first and is closed. A key that
# is not a part is never judged here; bin/overlap-schedule.sh and
# bin/overlap-guard.sh keep their rule.
#
# WHICH KEY IS A PART (BH-6374 C1). A split child has a BOARD key (TK-184), not a
# dotted one: bin/run-decompose.sh writes `TK-145.1: ...` as the title label only.
# The children are recorded, in land order, on line 1 of the parent's build
# RESULT: `DECOMPOSED TK-183,TK-184,TK-185,TK-186` (the record
# bin/lib/split-chain.sh reads). `parts` turns those records into the parts map
#   key<TAB>parent<TAB>n      n = the 0-based index; 0 is the contract
# from builds/<p>-*/RESULT and builds/pool-<p>-*/RESULT younger than
# SIBLING_PARTS_LOOKBACK_D days. A key in two records takes the newer one. A key
# shaped <PARENT>.<n> (TK-142.2) with no record is still a part: the fallback.
#
# THE RULE (decide). For a candidate part K with parent P, the first hit wins:
#   1. a sibling S IN FLIGHT (any n): K waits when the two lists collide, or when
#      K or S has no pre-plan list (unsure means wait);
#   2. a sibling S with an OPEN PR (branch matches (^|/)<s>($|[-/]), any n; so
#      ticket/TK-184, ticket/TK-184-r2 and agent/TK-184 are TK-184's):
#      K waits when its list names a file the PR changed. The line ends
#      ` stackable base=<branch>` when STACK_ON=1 and that PR is the only
#      blocker. A K with no list does not wait on a PR;
#   3. a sibling S QUEUED with a lower n: K waits when both lists exist and
#      collide. A higher n never holds a lower one, so no wait cycle exists.
# Lists are pruned as bin/overlap-schedule.sh prunes them: the SOURCE: header,
# a bare directory the same list names a file under, OVERLAP_IGNORE globs (env
# IGNORE) and read-mostly paths (env RM). Plan against plan uses the prefix
# rule; a plan against a PR's files is exact. One shared path is enough.
#
# INPUT FILES (the ones bin/overlap-schedule.sh already writes):
#   rows      key<TAB>class<TAB>path; class inflight, or a candidate class
#             (queued child child-building ahead); an empty path = no list
#   inflight  one key per line, every key in flight, with a list or not
#   prs       number<TAB>branch<TAB>path, one line per file an open PR changed
#   parts     optional: the parts map `parts` prints. Absent = dotted keys only
# OUTPUT: one line per candidate that must wait, in row order:
#   SIBLING_SERIAL <K> waits for <S> on <file>[ stackable base=<branch>]
#   SIBLING_SERIAL <K> waits for <S> on (no pre-plan list)
# decide exits 0 always; bad input prints nothing.
#
# check gathers this box's pool state for one KEY, runs decide and prints KEY's
# line. rc 3 = wait (the line is on stdout); rc 0 = go. Every missing input,
# kill switch or error is rc 0 with nothing on stdout: the machinery fails open.
# env SIBLING_STACK_BASE: the branch the caller's row already stacks on. That
# PR is the row's base, not a blocker, so check drops it before decide.
# SIBLING_STACK=0 drops the ` stackable base=` suffix: the pool then waits
# instead of stacking (bin/fly-pool.sh gate 0c stacks on a stackable line).
#   lists     plans/<p>-<K>/planned-files.txt, then preplan_planned_files, then
#             the newest builds/<p>-<K>-* or builds/pool-<p>-<K>-* list: its
#             touch-files.txt when touch-source=declared, else planned-files.txt
#             (see files_of); a claim's own list first. Each tick writes one
#             note line `list sources: <K>=<src> <S>=<src> ...`, where src is
#             claim, a files_of source, or the cause of no list
#   in flight state/fly-pool/<p>/*.json, build_queue_active_key, and the
#             job_claims rows (fclaim_list_dir, BH-5002). When the worker does
#             not answer, claims are not judged (one note line); the
#             state/claims/ files are never read here
#   queued    state/build-queue/<p>/*.json and SIBLING_QDIR (the pool's
#             rows-only scratch dir), not *.failed.json, not older than
#             SIBLING_QUEUED_MAX_MIN by enqueued_at
#   open PRs  state/overlap-guard/<p>-prs.json while younger than
#             OVERLAP_SNAPSHOT_MAX_AGE (600 s). No GitHub call.
# THE WAIT CEILING. state/sibling-serial/<p>/<K>.sibling-since holds
# <S><TAB><epoch> from the first waiting tick. It is this box's wait clock
# (catalog/state-paths.json: box-local), not a pool row: a failed-over box
# starts the clock again, which only delays a release. At SIBLING_SERIAL_MAX_MIN the key is released: rc 0,
# stdout `SIBLING_SERIAL_RELEASED <K> after <m> min behind <S>`, and one warn
# alert per (K, S). A tick that answers go removes the file.
#
# KNOBS (lib sibling-serial, catalog/lanes.d/_lib.sibling-serial.json; env, then
# env/global.env):
#   SIBLING_SERIAL=1             0|off = no check at all
#   SIBLING_QUEUED_MAX_MIN=120   a queued sibling older than this holds nobody
#                                (0 = a queued sibling never holds)
#   SIBLING_SERIAL_MAX_MIN=360   the wait ceiling (0 = no ceiling)
#   SIBLING_STACK=1              0 = never print `stackable`: the pool waits
#   SIBLING_PARTS_LOOKBACK_D=14  days of DECOMPOSED records the parts map reads
#   lane_switch sibling-serial-off   the same kill switch, as a settings row or flag
#   SIBLING_SERIAL_NOW           the clock, for tests
#
# THE TICK CACHE (BH-7706). A pool tick runs check once per queued row, and the
# project-wide inputs are the same for every row: the parts map, the active key
# and the job_claims rows. With env SIBLING_TICK_DIR naming a writable dir,
# `prime <project>` reads them once into it:
#   parts         the parts map
#   active        the active key (one line, empty for none)
#   fc/ + fc.ok   the job_claims rows; fc.ok only when the read answered
# active and fc/ are read only when a queued key is a part. check then reads
# each of them from the dir, and files_of keeps each key's list there:
#   lists/<K>     the list; lists/<K>.src the FO_SRC it came from
# Each file is written to a temp name and moved, so a parallel check never reads
# half a file. A missing file (or no fc.ok) is the live read, as before. No
# SIBLING_TICK_DIR: prime does nothing and check reads everything live. The
# rule, the wait clock and every output line do not change.
#
# replay simulates the pool over each parent's parts and prints the order the
# rule gives, without writing anything. It skips n 0 (the contract lands first
# through its hard Blocked-by). Each tick takes the waiting parts in n order and
# runs decide for each against the parts in flight, the ones it let go this tick
# included; a part with no line joins the wave in flight. A tick that lets
# nothing go closes the wave (it merged) and the next wave starts. Output:
#   REPLAY <parent> parts=<n> waves=<w> order=<k,k> > <k> ... nolist=<n> added_cycles=<w-1>
#   REPLAY_TOTAL parents=<n> parts=<n> nolist_waits=<n> fallback_pct=<p>
#   REPLAY_CAUSE <no-plan|index-unreachable|empty-list|unknown> waits=<n> pct=<p>
#   REPLAY_SOURCES plans-dir=<n> preplan-index=<n> build-touch=<n> build-planned=<n> none=<n>
# nolist counts the parts that waited at least once on `(no pre-plan list)`.
# Each such part is counted once more under one REPLAY_CAUSE (four lines, this
# order, they sum to nolist_waits): the cause files_of gave for the part, or,
# when the part has a list, for the sibling it waits for. env CAUSES names the
# key<TAB>cause file; with none, every cause is unknown. REPLAY_SOURCES counts
# where each part's list came from and is printed in --project mode only.
# `replay <rows> <parts>` reads rows as key<TAB>queued<TAB>path (an empty path =
# no list). `--project` reads the newest N (30) DECOMPOSED records on this box
# with no age bound, and each child's list the way check does. rc 2 = usage.
set -uo pipefail
VERB="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

decide() { # decide <rows> <inflight> <prs> [parts]
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" "$3" "${4:-}" <<'PYEOF' 2>/dev/null || :
import fnmatch, os, re, sys

PART = re.compile(r"^(.+-[0-9]+)\.([0-9]+)$")
READY = ("queued", "child", "child-building", "ahead")
IGNORE = (os.environ.get("IGNORE") or "").split()
STACK_ON = (os.environ.get("STACK_ON") or "1") != "0"

def norm(p):
    p = p.strip().rstrip("/")
    if p.startswith("./"):
        p = p[2:]
    return p

READ_MOSTLY = set(norm(x) for x in (os.environ.get("RM") or "").split())

def ignored(p):
    if p in READ_MOSTLY:
        return True
    for g in IGNORE:
        if fnmatch.fnmatchcase(p, g) or fnmatch.fnmatchcase(p, "*/" + g):
            return True
    return False

def prune(files):
    fs = sorted(files)
    return [p for p in fs if not any(q.startswith(p + "/") for q in fs)]

def read_lines(path):
    try:
        with open(path) as fh:
            return [l.rstrip("\n") for l in fh]
    except Exception:
        return None

rows = read_lines(sys.argv[1])
if rows is None:
    sys.exit(0)
lists, cls, order = {}, {}, {}
for idx, line in enumerate(rows):
    parts = line.split("\t")
    if len(parts) < 3 or not parts[0]:
        continue
    k, c, p = parts[0], parts[1], norm(parts[2])
    cls.setdefault(k, c)
    order.setdefault(k, idx)
    entry = lists.setdefault(k, set())
    if p and not p.upper().startswith("SOURCE:"):
        entry.add(p)

P = {k: prune(v) for k, v in lists.items()}           # a list at all
PC = {k: [p for p in v if not ignored(p)] for k, v in P.items()}  # compared

inflight = set(k for k, c in cls.items() if c == "inflight")
for k in read_lines(sys.argv[2]) or []:
    k = k.strip()
    if k:
        inflight.add(k)

prs = {}
for line in read_lines(sys.argv[3]) or []:
    parts = line.split("\t")
    if len(parts) < 3 or not parts[0] or not parts[1] or not parts[2]:
        continue
    prs.setdefault((parts[0], parts[1]), set()).add(norm(parts[2]))
pr_lists = {pk: [p for p in prune(fs) if p and not ignored(p)] for pk, fs in prs.items()}

PARTS = {}
for line in (read_lines(sys.argv[4]) if sys.argv[4] else None) or []:
    f = line.split("\t")
    if len(f) >= 3 and f[0] and f[1] and f[2].isdigit():
        PARTS[f[0]] = (f[1], int(f[2]))

def part(k):
    if k in PARTS:
        return PARTS[k]
    m = PART.match(k)
    return (m.group(1), int(m.group(2))) if m else None

def collide(A, B, exact=False):
    for p in A:
        for q in B:
            if q == p:
                return p
            if not exact:
                if q.startswith(p + "/"):
                    return q
                if p.startswith(q + "/"):
                    return p
    return None

def pr_sibling(parent, branch):
    """The sibling key an open PR's branch belongs to, or None."""
    b = branch.lower()
    for s, (sp, sn) in sorted(PARTS.items()):
        if sp == parent and re.search(r"(^|/)" + re.escape(s.lower()) + r"($|[-/])", b):
            return (s, sn)
    m = re.search(r"(^|/)" + re.escape(parent.lower()) + r"\.([0-9]+)($|[-/])", b)
    return (parent + "." + m.group(2), int(m.group(2))) if m else None

def by_n(keys):
    return sorted(keys, key=lambda s: (part(s)[1], s))

cands = sorted([k for k, c in cls.items() if c in READY and k not in inflight and part(k)],
               key=lambda k: order.get(k, 1 << 30))
NOLIST = "(no pre-plan list)"
for k in cands:
    parent, n = part(k)
    mine = PC.get(k) if P.get(k) else None      # None = K has no list
    sibs = lambda pool: [s for s in pool if s != k and part(s) and part(s)[0] == parent]
    verdict = None
    # 1. a sibling in flight, any n
    for s in by_n(sibs(inflight)):
        theirs = PC.get(s) if P.get(s) else None
        if mine is None or theirs is None:
            verdict = (s, NOLIST, None)
            break
        f = collide(mine, theirs)
        if f:
            verdict = (s, f, None)
            break
    # 3 is computed before 2 is printed: a PR verdict is stackable only when
    # nothing else holds K.
    queued_hit = None
    if mine is not None:
        for s in by_n([s for s in sibs([c for c, x in cls.items() if x in READY])
                       if s not in inflight and part(s)[1] < n]):
            if not P.get(s):
                continue
            f = collide(mine, PC.get(s, []))
            if f:
                queued_hit = (s, f, None)
                break
    # 2. a sibling with an open PR, any n
    if verdict is None and mine is not None:
        hits = []
        for (num, br), pl in sorted(pr_lists.items(),
                                    key=lambda r: (int(r[0][0]) if r[0][0].isdigit() else 1 << 30, r[0][1])):
            sib = pr_sibling(parent, br)
            if sib is None or sib[1] == n:
                continue
            f = collide(mine, pl, exact=True)
            if f:
                hits.append((sib[0], f, br))
        if hits:
            s, f, br = hits[0]
            stackable = STACK_ON and len(hits) == 1 and queued_hit is None
            verdict = (s, f, br if stackable else None)
    # 3. a lower-n sibling queued
    if verdict is None:
        verdict = queued_hit
    if verdict:
        s, f, base = verdict
        print("SIBLING_SERIAL %s waits for %s on %s%s"
              % (k, s, f, (" stackable base=%s" % base) if base else ""))
PYEOF
  return 0
}

case "$VERB" in
  decide)
    decide "${2:-}" "${3:-}" "${4:-}" "${5:-}"
    exit 0 ;;
  check|prime|parts|replay) ;;
  *) echo "usage: sibling-serial.sh decide <rows> <inflight> <prs> [parts] | check <project> <KEY> | prime <project> | parts <project> | replay <rows> <parts> | replay --project <p> [--last N]" >&2; exit 2 ;;
esac

HARNESS="${HARNESS:-/root/harness}"
num() { case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac; }

# parts_scan <harness> <project> <lookback-days> [newest-N] — the parts map.
# Lookback 0 = no age bound; newest-N 0 = every record. One find, no GitHub.
parts_scan() {
  local h="$1" p="$2" days="${3:-0}" lim="${4:-0}" age=()
  [ -d "$h/builds" ] || return 0
  [ "$days" -gt 0 ] 2>/dev/null && age=(-newermt "@$(( $(date +%s) - days * 86400 ))")
  # The globs list builds/ once; find then looks only inside this project's dirs.
  find "$h/builds/$p-"* "$h/builds/pool-$p-"* -maxdepth 1 -name RESULT -type f \
       "${age[@]}" -printf '%T@\t%p\n' 2>/dev/null \
    | python3 -c '
import re, sys
p, lim = sys.argv[1], int(sys.argv[2])
KEY = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")
PAR = re.compile(r"^([A-Za-z][A-Za-z0-9]*-[0-9]+)")
recs = []
for line in sys.stdin:
    t, _, path = line.rstrip("\n").partition("\t")
    try:
        with open(path, errors="replace") as fh:
            first = fh.readline().rstrip("\n")
        t = float(t)
    except Exception:
        continue
    if not first.startswith("DECOMPOSED "):
        continue
    toks = first[len("DECOMPOSED "):].split()
    keys = [k for k in toks[0].split(",") if KEY.match(k)] if toks else []
    d = path.rsplit("/", 2)[-2]
    d = d[5:] if d.startswith("pool-") else d
    m = PAR.match(d[len(p) + 1:]) if d.startswith(p + "-") else None
    if m and keys:
        recs.append((t, path, m.group(1), keys))
recs.sort(key=lambda r: (r[0], r[1]))
if lim > 0:
    recs = recs[-lim:]
out = {}
for _, _, parent, keys in recs:          # oldest first: the newer record wins
    for n, k in enumerate(keys):
        out[k] = (parent, n)
for k, (parent, n) in sorted(out.items(), key=lambda x: (x[1][0], x[1][1], x[0])):
    print("%s\t%s\t%d" % (k, parent, n))
' "$p" "$lim" 2>/dev/null
  return 0
}

# replay_pure <rows> <parts> — see `replay` in the header. Writes nothing.
replay_pure() {
  local rows="$1" partsf="$2" rtmp par k r i line tick max waves order nol nl went np
  local tp=0 tparts=0 tnol=0 c
  local -a R I NR
  local -A NOL CAUSE=() CC=([no-plan]=0 [index-unreachable]=0 [empty-list]=0 [unknown]=0)
  [ -r "$rows" ] && [ -r "$partsf" ] || { echo "replay: unreadable <rows> or <parts>" >&2; return 2; }
  command -v python3 >/dev/null 2>&1 || return 0
  rtmp=$(mktemp -d "${TMPDIR:-/tmp}/sibling-replay-XXXXXX") || return 0
  mkdir -p "$rtmp/l"
  # one list file per key; a key with no row, or only an empty path, has none
  awk -F'\t' -v d="$rtmp/l" '$1 ~ /^[A-Za-z0-9._-]+$/ && $3 != "" {print $3 > (d "/" $1)}' "$rows"
  # CAUSES (optional): key<TAB>source-or-cause, what files_of found per key
  if [ -n "${CAUSES:-}" ] && [ -r "$CAUSES" ]; then
    while IFS=$'\t' read -r k c; do [ -n "$k" ] && CAUSE[$k]="$c"; done < "$CAUSES"
  fi
  : > "$rtmp/none"
  for par in $(awk -F'\t' '$3 ~ /^[0-9]+$/ && $3 > 0 && !s[$2]++ {print $2}' "$partsf"); do
    R=(); I=(); NR=(); NOL=()
    mapfile -t R < <(awk -F'\t' -v p="$par" '$2 == p && $3 ~ /^[0-9]+$/ && $3 > 0' "$partsf" | sort -t$'\t' -k3,3n | cut -f1)
    np=${#R[@]}; tp=$((tp + 1)); tparts=$((tparts + np))
    I=(); waves=0; order=""; tick=0; max=$(( 4 * ${#R[@]} ))
    while [ "${#R[@]}" -gt 0 ] && [ "$tick" -lt "$max" ]; do
      tick=$((tick + 1)); NR=(); went=0
      for k in "${R[@]}"; do
        : > "$rtmp/rows"; : > "$rtmp/inflight"
        for r in "${R[@]}"; do
          case " ${I[*]} " in *" $r "*) continue ;; esac
          if [ -s "$rtmp/l/$r" ]; then awk -v k="$r" '{print k "\tqueued\t" $0}' "$rtmp/l/$r" >> "$rtmp/rows"
          else printf '%s\tqueued\t\n' "$r" >> "$rtmp/rows"; fi
        done
        for i in "${I[@]}"; do
          printf '%s\n' "$i" >> "$rtmp/inflight"
          if [ -s "$rtmp/l/$i" ]; then awk -v k="$i" '{print k "\tinflight\t" $0}' "$rtmp/l/$i" >> "$rtmp/rows"
          else printf '%s\tinflight\t\n' "$i" >> "$rtmp/rows"; fi
        done
        line=$(STACK_ON=0 decide "$rtmp/rows" "$rtmp/inflight" "$rtmp/none" "$partsf" | awk -v k="$k" '$2 == k {print; exit}')
        if [ -z "$line" ]; then I+=("$k"); went=1
        else
          NR+=("$k")
          case "$line" in *" on (no pre-plan list)")
            if [ -z "${NOL[$k]:-}" ]; then
              # the cause of the missing list: K's own, else the sibling's it waits for
              if [ -s "$rtmp/l/$k" ]; then c="${CAUSE[$(awk '{print $5}' <<<"$line")]:-}"; else c="${CAUSE[$k]:-}"; fi
              case "$c" in no-plan|index-unreachable|empty-list) ;; *) c=unknown ;; esac
              CC[$c]=$(( ${CC[$c]} + 1 ))
            fi
            NOL[$k]=1 ;;
          esac
        fi
      done
      R=("${NR[@]}")
      if [ "$went" = 0 ] && [ "${#I[@]}" -gt 0 ]; then
        order="${order:+$order > }$(IFS=,; echo "${I[*]}")"; waves=$((waves + 1)); I=()
      fi
    done
    if [ "${#I[@]}" -gt 0 ]; then
      order="${order:+$order > }$(IFS=,; echo "${I[*]}")"; waves=$((waves + 1))
    fi
    nol=${#NOL[@]}; tnol=$((tnol + nol))
    nl="REPLAY $par parts=$np waves=$waves order=$order nolist=$nol added_cycles=$(( waves > 0 ? waves - 1 : 0 ))"
    [ "${#R[@]}" -gt 0 ] && nl="$nl stuck=$(IFS=,; echo "${R[*]}")"
    printf '%s\n' "$nl"
  done
  printf 'REPLAY_TOTAL parents=%d parts=%d nolist_waits=%d fallback_pct=%d\n' \
    "$tp" "$tparts" "$tnol" "$(( tparts > 0 ? tnol * 100 / tparts : 0 ))"
  for c in no-plan index-unreachable empty-list unknown; do
    printf 'REPLAY_CAUSE %s waits=%d pct=%d\n' "$c" "${CC[$c]}" "$(( tparts > 0 ? ${CC[$c]} * 100 / tparts : 0 ))"
  done
  case "$rtmp" in "${TMPDIR:-/tmp}"/sibling-replay-*) rm -rf "$rtmp" ;; esac
  return 0
}

PROJECT=""; KEY=""; LAST=30
case "$VERB" in
  check) PROJECT="${2:-}"; KEY="${3:-}"; [ -n "$KEY" ] || exit 0 ;;
  parts|prime) PROJECT="${2:-}" ;;
  replay)
    if [ "${2:-}" != --project ]; then
      [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: sibling-serial.sh replay <rows> <parts> | replay --project <p> [--last N]" >&2; exit 2; }
      : "${IGNORE=package.json package-lock.json *.md}"
      IGNORE="$IGNORE" RM="${RM:-}" replay_pure "$2" "$3"; exit $?
    fi
    PROJECT="${3:-}"
    if [ "${4:-}" = --last ]; then LAST="${5:-}"; fi
    case "$LAST" in ''|*[!0-9]*|0) echo "replay: --last needs a positive number" >&2; exit 2 ;; esac
    [[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "replay: bad project '$PROJECT'" >&2; exit 2; } ;;
esac
[[ "$PROJECT" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || exit 0
[[ "$KEY" =~ ^[A-Za-z0-9._-]{0,64}$ ]] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# shellcheck source=bin/lib/preplan-lib.sh
[ -r "$HERE/lib/preplan-lib.sh" ] && . "$HERE/lib/preplan-lib.sh" 2>/dev/null
if ! command -v _preplan_env >/dev/null 2>&1; then
  [ "$VERB" = check ] && exit 0
  _preplan_env() { local v=""; eval "v=\${$2:-}"; printf '%s\n' "${v:-$3}"; }
fi
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply sibling-serial "$PROJECT" >/dev/null 2>&1
LOOKBACK_D=$(num "$(_preplan_env "$HARNESS" SIBLING_PARTS_LOOKBACK_D 14)" 14)
[ "$LOOKBACK_D" -ge 1 ] || LOOKBACK_D=1

# files_of <key> <dst> — the key's list into <dst>, rc 0; rc 1 = no list.
# Sources in order (the name goes in FO_SRC): plans-dir, preplan-index, then
# each build record newest first, build-touch (touch-source=declared and a
# touch-files.txt) before build-planned (planned-files.txt). With no list
# FO_SRC is the cause: empty-list (a plan.md exists and no list came of it),
# index-unreachable (preplan_planned_files rc 2, or not defined), no-plan.
# With FO_LOG set, one `key<TAB>FO_SRC` line is appended to that file.
# The tick cache dir (BH-7706), for check and prime only.
TICKDIR=""
case "$VERB" in
  check|prime)
    [ -n "${SIBLING_TICK_DIR:-}" ] && [ -d "$SIBLING_TICK_DIR" ] && [ -w "$SIBLING_TICK_DIR" ] && TICKDIR="$SIBLING_TICK_DIR" ;;
esac
# tick_put <src-file> <name> — copy into the tick dir through a temp name.
tick_put() {
  local t
  t=$(mktemp "$TICKDIR/.put.XXXXXX" 2>/dev/null) || return 1
  if cat "$1" > "$t" 2>/dev/null && mv -f "$t" "$TICKDIR/$2" 2>/dev/null; then return 0; fi
  rm -f "$t"; return 1
}
FO_SRC=""
files_of() {
  local k="$1" dst="$2" p d l rc=2 src="" had_plan=0 c=""
  if [ -n "$TICKDIR" ] && [[ "$k" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    c="lists/$k"
    src=$(cat "$TICKDIR/$c.src" 2>/dev/null)
    case "$src" in
      plans-dir|preplan-index|build-touch|build-planned)
        if [ -s "$TICKDIR/$c" ] && cat "$TICKDIR/$c" > "$dst" 2>/dev/null; then
          FO_SRC="$src"; [ -n "${FO_LOG:-}" ] && printf '%s\t%s\n' "$k" "$src" >> "$FO_LOG"
          return 0
        fi ;;
      empty-list|index-unreachable|no-plan)
        FO_SRC="$src"; [ -n "${FO_LOG:-}" ] && printf '%s\t%s\n' "$k" "$src" >> "$FO_LOG"
        return 1 ;;
    esac
    src=""
  fi
  p="$HARNESS/plans/$PROJECT-$k"
  if [ -s "$p/planned-files.txt" ]; then cat "$p/planned-files.txt" > "$dst"; src=plans-dir; fi
  [ -s "$p/plan.md" ] && had_plan=1
  if [ -z "$src" ] && command -v preplan_planned_files >/dev/null 2>&1; then
    l=$(preplan_planned_files "$HARNESS" "$PROJECT" "$k" 2>/dev/null); rc=$?
    [ "$rc" = 0 ] && [ -n "$l" ] && { printf '%s\n' "$l" > "$dst"; src=preplan-index; }
  fi
  if [ -z "$src" ]; then
    for d in $(ls -1dt "$HARNESS/builds/$PROJECT-$k-"* "$HARNESS/builds/pool-$PROJECT-$k-"* 2>/dev/null); do
      if [ "$(cat "$d/touch-source" 2>/dev/null)" = declared ] && [ -s "$d/touch-files.txt" ]; then
        cat "$d/touch-files.txt" > "$dst"; src=build-touch; break
      fi
      [ -s "$d/planned-files.txt" ] && { cat "$d/planned-files.txt" > "$dst"; src=build-planned; break; }
      [ -s "$d/plan.md" ] && had_plan=1
    done
  fi
  if [ -z "$src" ]; then
    if [ "$had_plan" = 1 ]; then src=empty-list
    elif [ "$rc" = 2 ]; then src=index-unreachable
    else src=no-plan; fi
  fi
  FO_SRC="$src"
  [ -n "${FO_LOG:-}" ] && printf '%s\t%s\n' "$k" "$src" >> "$FO_LOG"
  # The list before its source, so a reader that finds the .src finds the list.
  if [ -n "$c" ] && mkdir -p "$TICKDIR/lists" 2>/dev/null; then
    case "$src" in
      plans-dir|preplan-index|build-touch|build-planned)
        tick_put "$dst" "$c" && printf '%s\n' "$src" | tick_put /dev/stdin "$c.src" ;;
      *) printf '%s\n' "$src" | tick_put /dev/stdin "$c.src" ;;
    esac
  fi
  case "$src" in plans-dir|preplan-index|build-touch|build-planned) return 0 ;; esac
  return 1
}
if [ "$VERB" = parts ]; then
  parts_scan "$HARNESS" "$PROJECT" "$LOOKBACK_D"
  exit 0
fi

if [ "$VERB" = replay ]; then
  RT=$(mktemp -d "${TMPDIR:-/tmp}/sibling-replay-XXXXXX") || exit 0
  trap 'rm -rf "$RT"' EXIT
  parts_scan "$HARNESS" "$PROJECT" 0 "$LAST" > "$RT/parts"
  : > "$RT/rows"; : > "$RT/sources"
  FO_LOG="$RT/sources"
  while IFS=$'\t' read -r K _ N; do
    [ "$N" -gt 0 ] 2>/dev/null || continue
    if files_of "$K" "$RT/l" && [ -s "$RT/l" ]; then
      awk -v k="$K" '{print k "\tqueued\t" $0}' "$RT/l" >> "$RT/rows"
    else
      printf '%s\tqueued\t\n' "$K" >> "$RT/rows"
    fi
  done < "$RT/parts"
  IGNORE='package.json package-lock.json *.md'
  # shellcheck source=bin/lib/scheduler-conf.sh
  [ -r "$HERE/lib/scheduler-conf.sh" ] && . "$HERE/lib/scheduler-conf.sh" 2>/dev/null
  command -v sched_conf >/dev/null 2>&1 && IGNORE=$(sched_conf OVERLAP_IGNORE 'package.json package-lock.json *.md' "$HARNESS")
  IGNORE="$IGNORE" RM="" CAUSES="$RT/sources" replay_pure "$RT/rows" "$RT/parts"
  awk -F'\t' '{n[$2 ~ /^(plans-dir|preplan-index|build-touch|build-planned)$/ ? $2 : "none"]++}
    END {printf "REPLAY_SOURCES plans-dir=%d preplan-index=%d build-touch=%d build-planned=%d none=%d\n",
         n["plans-dir"], n["preplan-index"], n["build-touch"], n["build-planned"], n["none"]}' "$RT/sources"
  exit 0
fi

# ── check ────────────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || exit 0
case "$(printf '%s' "$(_preplan_env "$HARNESS" SIBLING_SERIAL 1)" | tr '[:upper:]' '[:lower:]')" in
  0|off|false|no) exit 0 ;;
esac
command -v lane_switch >/dev/null 2>&1 && HARNESS="$HARNESS" lane_switch sibling-serial-off && exit 0
# The jobs client (active key) and the job_claims reader, for check and prime.
load_clients() {
  if [ -r "$HERE/jobs-client.sh" ]; then
    # shellcheck source=/dev/null
    command -v build_queue_active_key >/dev/null 2>&1 || . "$HERE/jobs-client.sh" 2>/dev/null || :
  fi
  # shellcheck source=bin/lib/file-claims.sh
  [ -r "$HERE/lib/file-claims.sh" ] && . "$HERE/lib/file-claims.sh" 2>/dev/null
  return 0
}
if [ "$VERB" = prime ]; then
  [ -n "$TICKDIR" ] || exit 0
  PT=$(mktemp "$TICKDIR/.parts.XXXXXX" 2>/dev/null) || exit 0
  parts_scan "$HARNESS" "$PROJECT" "$LOOKBACK_D" > "$PT"
  mv -f "$PT" "$TICKDIR/parts" 2>/dev/null || { rm -f "$PT"; exit 0; }
  # A key that is not a part never reads the active key or the claims, so a
  # queue with no part makes neither read.
  declare -A PM=()
  while IFS=$'\t' read -r K PP _; do [ -n "$K" ] && PM[$K]="$PP"; done < "$TICKDIR/parts"
  ANY=0
  for F in "$HARNESS/state/build-queue/$PROJECT"/*.json ${SIBLING_QDIR:+"$SIBLING_QDIR"/*.json}; do
    [ -f "$F" ] || continue
    case "$F" in *.failed.json) continue ;; esac
    K=$(jq -r '.key // empty' "$F" 2>/dev/null); [ -n "$K" ] || K=$(basename "$F" .json)
    if [ -n "${PM[$K]:-}" ] || [[ "$K" =~ ^[A-Za-z0-9_-]+-[0-9]+\.[0-9]+$ ]]; then ANY=1; break; fi
  done
  [ "$ANY" = 1 ] || exit 0
  load_clients
  A=""
  command -v build_queue_active_key >/dev/null 2>&1 && A=$(build_queue_active_key "$PROJECT" 2>/dev/null | cut -f1 | head -1)
  printf '%s\n' "$A" | tick_put /dev/stdin active
  mkdir -p "$TICKDIR/fc" 2>/dev/null
  if command -v fclaim_list_dir >/dev/null 2>&1 && fclaim_list_dir "$PROJECT" "$TICKDIR/fc" 2>/dev/null; then
    : > "$TICKDIR/fc.ok"
  fi
  exit 0
fi
QMAX=$(num "$(_preplan_env "$HARNESS" SIBLING_QUEUED_MAX_MIN 120)" 120)
WMAX=$(num "$(_preplan_env "$HARNESS" SIBLING_SERIAL_MAX_MIN 360)" 360)
MAX_AGE=$(num "$(_preplan_env "$HARNESS" OVERLAP_SNAPSHOT_MAX_AGE 600)" 600)
NOW=$(num "${SIBLING_SERIAL_NOW:-}" "$(date +%s)")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sibling-serial-XXXXXX") || exit 0
trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; INFLIGHT="$TMP/inflight"; PRS="$TMP/prs"; PARTS="$TMP/parts"
: > "$ROWS"; : > "$INFLIGHT"; : > "$PRS"; FO_LOG="$TMP/sources"; : > "$FO_LOG"
# A key that is not a part is never judged: rc 0 before the pool state is read.
# A part is a key in the parts map, or a dotted <PARENT>.<n> key (the fallback).
if [ -n "$TICKDIR" ] && [ -r "$TICKDIR/parts" ]; then cat "$TICKDIR/parts" > "$PARTS"
else parts_scan "$HARNESS" "$PROJECT" "$LOOKBACK_D" > "$PARTS"; fi
declare -A PMAP=()
while IFS=$'\t' read -r K PP _; do [ -n "$K" ] && PMAP[$K]="$PP"; done < "$PARTS"
PARENT=""
if [ -n "${PMAP[$KEY]:-}" ]; then PARENT="${PMAP[$KEY]}"
elif [[ "$KEY" =~ ^([A-Za-z0-9_-]+-[0-9]+)\.([0-9]+)$ ]]; then PARENT="${BASH_REMATCH[1]}"
else exit 0; fi
note() { echo "$(date -u '+%F %TZ') [sibling-serial/$PROJECT] $*" >&2; }
# sib <key> — same parent in the parts map, or the dotted rule for a key in none
sib() {
  if [ -n "${PMAP[$1]:-}" ]; then [ "${PMAP[$1]}" = "$PARENT" ]
  else [[ "$1" =~ ^${PARENT//./\\.}\.[0-9]+$ ]]; fi
}

# emit <key> <class> [list-file] — the key's rows; no list = one empty-path row
emit() {
  local k="$1" c="$2" src="${3:-}" f="$TMP/l"
  if [ -n "$src" ] && [ -s "$src" ]; then
    cp "$src" "$f" 2>/dev/null || : > "$f"; printf '%s\tclaim\n' "$k" >> "$FO_LOG"
  else files_of "$k" "$f" || : > "$f"; fi
  if [ -s "$f" ]; then awk -v k="$k" -v c="$c" '{print k "\t" c "\t" $0}' "$f" >> "$ROWS"
  else printf '%s\t%s\t\n' "$k" "$c" >> "$ROWS"; fi
}

# ── in flight ───────────────────────────────────────────────────────────────
declare -A IN=()
add_inflight() { # add_inflight <key> [claim-list-file]
  local k="$1"
  [ "$k" != "$KEY" ] && sib "$k" || return 0
  [ -n "${IN[$k]:-}" ] && return 0
  IN[$k]=1; printf '%s\n' "$k" >> "$INFLIGHT"
  emit "$k" inflight "${2:-}"
}
for F in "$HARNESS/state/fly-pool/$PROJECT"/*.json; do
  [ -f "$F" ] || continue
  add_inflight "$(jq -r '.key // empty' "$F" 2>/dev/null)"
done
# The active key and the claims come from the tick cache when prime wrote them.
FCD="$TMP/fc"; FC_OK=0
if [ -n "$TICKDIR" ] && [ -r "$TICKDIR/active" ]; then
  A=$(head -n 1 "$TICKDIR/active" 2>/dev/null)
  [ -n "$A" ] && add_inflight "$A"
  [ -e "$TICKDIR/fc.ok" ] && [ -d "$TICKDIR/fc" ] && { FCD="$TICKDIR/fc"; FC_OK=1; }
  [ "$FC_OK" = 1 ] || load_clients
else
  load_clients
  if command -v build_queue_active_key >/dev/null 2>&1; then
    A=$(build_queue_active_key "$PROJECT" 2>/dev/null | cut -f1 | head -1)
    [ -n "$A" ] && add_inflight "$A"
  fi
fi
# The job_claims rows are the record (BH-5002). No answer: claims are not
# judged this tick (fail open, as every missing input here), never a file.
if [ "$FC_OK" = 0 ]; then
  mkdir -p "$TMP/fc"
  command -v fclaim_list_dir >/dev/null 2>&1 && fclaim_list_dir "$PROJECT" "$TMP/fc" 2>/dev/null && FC_OK=1
fi
if [ "$FC_OK" = 1 ]; then
  for F in "$FCD"/*; do
    [ -f "$F" ] || continue
    add_inflight "$(basename "$F")" "$F"
  done
else
  note "$KEY claims=unread (the job_claims rows did not answer) — claimed siblings not judged this tick"
fi

# ── queued ──────────────────────────────────────────────────────────────────
emit "$KEY" queued
declare -A QS=()
for F in "$HARNESS/state/build-queue/$PROJECT"/*.json ${SIBLING_QDIR:+"$SIBLING_QDIR"/*.json}; do
  [ -f "$F" ] || continue
  case "$F" in *.failed.json) continue ;; esac
  K=$(jq -r '.key // empty' "$F" 2>/dev/null); [ -n "$K" ] || K=$(basename "$F" .json)
  [ "$K" != "$KEY" ] && sib "$K" || continue
  [ -n "${IN[$K]:-}" ] || [ -n "${QS[$K]:-}" ] && continue
  QS[$K]=1
  if [ "$QMAX" -gt 0 ]; then
    E=$(jq -r '.enqueued_at // empty' "$F" 2>/dev/null)
    ES=""
    [ -n "$E" ] && { ES=$(date -u -d "$E" +%s 2>/dev/null) || ES=""; }
    if [ -n "$ES" ] && [ $(( (NOW - ES) / 60 )) -ge "$QMAX" ]; then
      note "$KEY: queued sibling $K enqueued $(( (NOW - ES) / 60 )) min ago (SIBLING_QUEUED_MAX_MIN=$QMAX) — stuck for another reason, not a blocker"
      continue
    fi
  else
    continue
  fi
  emit "$K" queued
done

# ── open PRs, from the overlap-guard cache only ─────────────────────────────
STACK_ON=1
case "$(_preplan_env "$HARNESS" STACKED_BUILDS 1)" in 0) STACK_ON=0 ;; esac
command -v lane_switch >/dev/null 2>&1 && HARNESS="$HARNESS" lane_switch stacked-builds-off file && STACK_ON=0
# SIBLING_STACK=0: the pool waits instead of stacking, so no line says stackable.
[ "$(num "$(_preplan_env "$HARNESS" SIBLING_STACK 1)" 1)" = 0 ] && STACK_ON=0
PRC="$HARNESS/state/overlap-guard/$PROJECT-prs.json"
PAGE=""; PRS_UNREAD=0
[ -s "$PRC" ] && PAGE=$(( $(date +%s) - $(stat -c %Y "$PRC" 2>/dev/null || echo 0) ))
if [ -n "$PAGE" ] && [ "$PAGE" -ge 0 ] && [ "$PAGE" -le "$MAX_AGE" ]; then
  jq -r '.[]? | select((.isDraft // false) | not)
         | (.number|tostring) as $n | (.headRefName // "") as $b
         | (.files // [])[] | (.path // .filename // empty) | [$n, $b, .] | @tsv' "$PRC" 2>/dev/null \
    | awk -F'\t' -v sb="${SIBLING_STACK_BASE:-}" '$2 ~ /^[A-Za-z0-9._\/-]+$/ && index($2, "..") == 0 && $3 != "" && $2 != sb' > "$PRS" 2>/dev/null || : > "$PRS"
else
  PRS_UNREAD=1
fi

# ── the rule ────────────────────────────────────────────────────────────────
IGNORE='package.json package-lock.json *.md'
# shellcheck source=bin/lib/scheduler-conf.sh
[ -r "$HERE/lib/scheduler-conf.sh" ] && . "$HERE/lib/scheduler-conf.sh" 2>/dev/null
command -v sched_conf >/dev/null 2>&1 && IGNORE=$(sched_conf OVERLAP_IGNORE 'package.json package-lock.json *.md' "$HARNESS")
RM=""
# shellcheck source=bin/lib/read-mostly.sh
[ -r "$HERE/lib/read-mostly.sh" ] && . "$HERE/lib/read-mostly.sh" 2>/dev/null
command -v read_mostly_list >/dev/null 2>&1 && RM=$(read_mostly_list "$PROJECT" "$HARNESS" 2>/dev/null | tr '\n' ' ')
# Where each key's list came from, KEY first: a part that waits on
# (no pre-plan list) is explained by the next line in the pool log.
note "list sources: $(awk -F'\t' -v k="$KEY" '$1 == k && m == "" {m = $1 "=" $2; next} {o = o " " $1 "=" $2} END {print m o}' "$FO_LOG")"
LINE=$(IGNORE="$IGNORE" RM="$RM" STACK_ON="$STACK_ON" decide "$ROWS" "$INFLIGHT" "$PRS" "$PARTS" \
       | awk -v k="$KEY" '$2 == k {print; exit}')

# ── the wait clock ──────────────────────────────────────────────────────────
SF="$HARNESS/state/sibling-serial/$PROJECT/$KEY.sibling-since"
if [ -z "$LINE" ]; then
  # Said only on a go: a wait is already decided without the PRs.
  [ "$PRS_UNREAD" = 1 ] && note "$KEY prs=unread (state/overlap-guard/$PROJECT-prs.json absent or older than ${MAX_AGE}s) — open sibling PRs not judged"
  rm -f "$SF" 2>/dev/null
  exit 0
fi
S=$(printf '%s\n' "$LINE" | awk '{print $5}')
OS=""; OE=""; OR=""
[ -r "$SF" ] && IFS=$'\t' read -r OS OE OR < "$SF"
case "$OE" in ''|*[!0-9]*) OS="" ;; esac
if [ "$OS" != "$S" ]; then
  mkdir -p "$(dirname "$SF")" 2>/dev/null
  printf '%s\t%s\n' "$S" "$NOW" > "$SF" 2>/dev/null
  printf '%s\n' "$LINE"; exit 3
fi
M=$(( (NOW - OE) / 60 ))
if [ "$WMAX" -gt 0 ] && [ "$M" -ge "$WMAX" ]; then
  REL="SIBLING_SERIAL_RELEASED $KEY after $M min behind $S"
  if [ "$OR" != released ] && [ -x "$HERE/alert-line.sh" ]; then
    if HARNESS="$HARNESS" "$HERE/alert-line.sh" --severity warn --id "sibling-serial-$PROJECT-$KEY-$S" --project "$PROJECT" \
         "[pool/$PROJECT] $REL (SIBLING_SERIAL_MAX_MIN=$WMAX) — the ticket is offered again; its build re-checks the overlap. If $S is stuck, that is the thing to move." >/dev/null 2>&1; then
      printf '%s\t%s\treleased\n' "$S" "$OE" > "$SF" 2>/dev/null
    fi
  fi
  printf '%s\n' "$REL"; exit 0
fi
printf '%s\n' "$LINE"; exit 3
