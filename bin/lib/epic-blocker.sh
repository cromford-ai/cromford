# shellcheck shell=bash
# bin/lib/epic-blocker.sh — BH-9289: a `Blocked-by: #N` on a hand-written epic
# resolves with a question and a default. Sourced, never run.
#
# bin/decompose-parent-close.sh closes only the masters bin/run-decompose.sh
# filed: it reads the ai-build list and finds children by `Part of #N`. A
# hand-written epic (no ai-build label, children linked by "epic #N" or only by
# the sub-issues API) is invisible to it, so a ticket that says
# `Blocked-by: #<epic>` waits forever after every child closed (project-6 #1008,
# TK-1055, TK-1057). This lib is the second pass for those epics.
#
#   eb_pass <repo> <issues.json> <tmpdir> <project> <dry 0|1>
#       The epic pass. <issues.json> is the ai-build list the caller already
#       read (number, state, title, body). It never closes the epic and never
#       launches a build. Per candidate it decides one verdict:
#         DECOMPOSE    a filer sentence is on the thread: the close path owns it
#         NO_CHILDREN  no confirmed child
#         OPEN_CHILD   a child is still open
#         ASK          every child closed, no question yet: post the question,
#                      then one alert (bin/alert-line.sh --id)
#         WAIT         question asked, window not over, no human reply
#         ANSWERED     a human replied after the question: the default stops
#         MET          question older than the window, no reply: write
#                      state/epic-blocker/<project>/<N>.met
#       Only MET writes the marker; every other definitive verdict removes it.
#       A read that fails leaves the marker as it was. Each candidate number is
#       appended to <tmpdir>/keys (the wake keys), and a failed question POST
#       appends `retry`. A dry run logs `EPIC_DRY #N <verdict>` and writes
#       nothing else. Prints nothing on stdout.
#   eb_met_list <harness> <project>
#       The epic numbers with a .met marker, one per line. Nothing when the
#       kill switch is off. bin/unblocked-children.sh reads it.
#   eb_knob <ENV>
#       EPIC_BLOCKER (0|1, fallback 1), EPIC_BLOCKER_DEFAULT_H (hours >= 1,
#       fallback 24), EPIC_BLOCKER_MAX (candidates per pass >= 1, fallback 5),
#       EPIC_BLOCKER_COMMENTS_MAX (comments read per epic >= 1, fallback 200;
#       a thread longer than it is a short read and gives no verdict).
#       The rows are declared in catalog/lanes.d/_lib.epic-blocker.json and
#       resolved through lib_env_apply epic-blocker; an invalid value reads as
#       the fallback.
#
# The question and its time live on the epic's thread (the marker comment and
# its created_at). The .met file is a box-local cache of the MET verdict and is
# recomputed every pass. docs/notes/2026-11-09-BH-9289-epic-blocker.md.
#
# The root is ${HARNESS:-${H:-}} and nothing else. No `set -e`, no `exit`.
if [ -n "${EPIC_BLOCKER_LIB:-}" ]; then return 0 2>/dev/null; fi
EPIC_BLOCKER_LIB=1
EB_MARKER='<!-- harness: epic-close-question -->'

# The knobs, resolved once and only when a function needs them (this lib is
# sourced on every tick by bin/unblocked-children.sh). lib_env_apply runs in a
# SUBSHELL, the bin/lib/wake-backstop.sh way, so a fail-closed exit there never
# stops the lane that sourced this file.
_eb_knobs_load() {
  [ -n "${_EB_KNOBS_DONE:-}" ] && return 0
  _EB_KNOBS_DONE=1
  local kv k v
  kv=$(
    exec 3>&1
    _EB_R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd) || exit 0
    command -v lib_env_apply >/dev/null 2>&1 || . "$_EB_R/bin/lib/lane-gate.sh" >/dev/null 2>&1 || exit 0
    if [ -z "${LANE_REGISTRY:-}" ] && [ ! -r "$(_lg_registry)" ] && . "$_EB_R/bin/lib/lanes-registry.sh" >/dev/null 2>&1; then
      LANE_REGISTRY=$(lanes_json_path "$_EB_R" 2>/dev/null) && export LANE_REGISTRY
    fi
    trap 'for _EB_K in EPIC_BLOCKER EPIC_BLOCKER_DEFAULT_H EPIC_BLOCKER_MAX EPIC_BLOCKER_COMMENTS_MAX; do printf "%s\t%s\n" "$_EB_K" "${!_EB_K:-}" >&3; done' EXIT
    lib_env_apply epic-blocker >/dev/null 2>&1)
  while IFS=$'\t' read -r k v; do
    case "$k" in EPIC_BLOCKER|EPIC_BLOCKER_DEFAULT_H|EPIC_BLOCKER_MAX|EPIC_BLOCKER_COMMENTS_MAX) ;; *) continue ;; esac
    if [ -n "$v" ]; then printf -v "$k" '%s' "$v"; fi
  done <<<"$kv"
  return 0
}

_eb_pos() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$((10#$1))" -ge 1 ] || return 1; printf '%s' "$((10#$1))"; }

eb_knob() {
  _eb_knobs_load
  case "${1:-}" in
    # Settings row lib.epic-blocker EPIC_BLOCKER; 1 (on) is the fallback.
    EPIC_BLOCKER) [ "${EPIC_BLOCKER:-1}" = 0 ] && printf 0 || printf 1 ;;
    # Settings row lib.epic-blocker EPIC_BLOCKER_DEFAULT_H; 24 h is the fallback.
    EPIC_BLOCKER_DEFAULT_H) _eb_pos "${EPIC_BLOCKER_DEFAULT_H:-}" || printf 24 ;;
    # Settings row lib.epic-blocker EPIC_BLOCKER_MAX; 5 candidates is the fallback.
    EPIC_BLOCKER_MAX) _eb_pos "${EPIC_BLOCKER_MAX:-}" || printf 5 ;;
    # Settings row lib.epic-blocker EPIC_BLOCKER_COMMENTS_MAX; 200 comments is the fallback.
    EPIC_BLOCKER_COMMENTS_MAX) _eb_pos "${EPIC_BLOCKER_COMMENTS_MAX:-}" || printf 200 ;;
    *) return 1 ;;
  esac
  return 0
}

_eb_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && _eb_pos "${EPIC_BLOCKER_NOW:-}" >/dev/null; then
    printf '%s' "$((10#$EPIC_BLOCKER_NOW))"
  else date +%s; fi
}

eb_met_list() { # eb_met_list <harness> <project>
  local d="${1:-}/state/epic-blocker/${2:-}" f n
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  ls "$d"/*.met >/dev/null 2>&1 || return 0
  [ "$(eb_knob EPIC_BLOCKER)" = 1 ] || return 0
  for f in "$d"/*.met; do
    n=$(basename "$f" .met)
    case "$n" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$n"
  done
  return 0
}

_eb_log() { # _eb_log <harness> <project> <line>
  mkdir -p "$1/logs" 2>/dev/null || true
  printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$2" "$3" >> "$1/logs/$2.log" 2>/dev/null || true
}

# _eb_fetch <repo> <n> <dir> -> rc 0 when every read for <n> answered, the
# answers in <dir>: issue.json comments.json part.json epic.json sub.json.
_eb_fetch() {
  local repo="$1" n="$2" d="$3" rc kind q
  mkdir -p "$d" || return 1
  rc=0; gh_rest GET "repos/$repo/issues/$n" > "$d/issue.json" || rc=$?
  [ "$rc" = 0 ] || return 1
  rc=0; gh_rest_issue_comments "$repo" "$n" "$(eb_knob EPIC_BLOCKER_COMMENTS_MAX)" > "$d/comments.json" || rc=$?
  [ "$rc" = 0 ] || return 1
  for kind in part epic; do
    if [ "$kind" = part ]; then q="repo:$repo is:issue \"Part of #$n\""; else q="repo:$repo is:issue \"epic #$n\""; fi
    rc=0; gh_rest GET search/issues -f "q=$q" -F per_page=100 > "$d/$kind.json" || rc=$?
    [ "$rc" = 0 ] || return 1
  done
  # 404 = the repo has no sub-issues for it, which is an answer: no children.
  rc=0; gh_rest GET "repos/$repo/issues/$n/sub_issues" -F per_page=100 > "$d/sub.json" || rc=$?
  case "$rc" in 0) ;; 44) echo '[]' > "$d/sub.json" ;; *) return 1 ;; esac
  return 0
}

eb_pass() { # eb_pass <repo> <issues.json> <tmpdir> <project> <dry>
  local repo="${1:-}" il="${2:-}" tmp="${3:-}" project="${4:-}" dry="${5:-0}"
  local h="${HARNESS:-${H:-}}" sd now win max cur n deps d out verdict info f
  # The alert writer beside this lib (bin/alert-line.sh); it writes under $HARNESS.
  local alert
  alert="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/alert-line.sh"
  [ -n "$h" ] && [ -n "$repo" ] && [ -r "$il" ] && [ -d "$tmp" ] && [ -n "$project" ] || return 1
  [ "$(eb_knob EPIC_BLOCKER)" = 1 ] || return 0
  command -v gh_rest >/dev/null 2>&1 && command -v gh_rest_issue_comments >/dev/null 2>&1 || return 1
  sd="$h/state/epic-blocker/$project"
  now=$(_eb_now); win=$(eb_knob EPIC_BLOCKER_DEFAULT_H); max=$(eb_knob EPIC_BLOCKER_MAX)
  cur=$(tr -dc '0-9' < "$sd/cursor" 2>/dev/null)

  # Step A, no network: the dependents per target, and the candidates.
  EB_CUR="$cur" EB_MAX="$max" python3 - "$il" "$tmp/eb-cands.tsv" "$tmp/eb-targets" <<'PYEOF' 2>/dev/null || return 0
import json, os, re, sys
issues = json.load(open(sys.argv[1]))
if not isinstance(issues, list):
    sys.exit(1)
line_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re = re.compile(r"#(\d+)")
part_re = re.compile(r"^[\s>*_\-#]*part[- ]of\b[^#\n]*#(\d+)", re.IGNORECASE | re.MULTILINE)
listed, parents, deps = set(), set(), {}
for i in issues:
    if not isinstance(i, dict) or "number" not in i:
        continue
    n = int(i["number"]); listed.add(n)
    body = i.get("body") or ""
    parents.update(int(m) for m in part_re.findall(body))
    if str(i.get("state", "")).upper() != "OPEN":
        continue
    for m in line_re.finditer(body):
        for b in num_re.findall(m.group(1)):
            if int(b) != n:
                deps.setdefault(int(b), set()).add(n)
cands = sorted(b for b in deps if b not in listed and b not in parents)
try:
    cur = int(os.environ.get("EB_CUR") or 0)
except Exception:
    cur = 0
try:
    mx = int(os.environ.get("EB_MAX") or 5)
except Exception:
    mx = 5
rot = [b for b in cands if b > cur] + [b for b in cands if b <= cur]
with open(sys.argv[2], "w") as f:
    for b in rot[:mx]:
        f.write("%d\t%s\n" % (b, ",".join(str(x) for x in sorted(deps[b]))))
with open(sys.argv[3], "w") as f:
    f.write("".join("%d\n" % b for b in sorted(deps)))
PYEOF

  local last=""
  while IFS=$'\t' read -r n deps; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    last="$n"
    printf '%s\n' "$n" >> "$tmp/keys" 2>/dev/null
    d="$tmp/eb-$n"
    # </dev/null: gh reads nothing, and this loop reads its list on stdin.
    _eb_fetch "$repo" "$n" "$d" </dev/null || continue
    out=$(EB_N="$n" EB_REPO="$repo" EB_DEPS="$deps" EB_NOW="$now" EB_WIN_H="$win" EB_MARKER="$EB_MARKER" \
          python3 - "$d" <<'PYEOF' 2>/dev/null
import json, os, re, sys, datetime
d = sys.argv[1]
n = int(os.environ["EB_N"]); now = int(os.environ["EB_NOW"]); win = int(os.environ["EB_WIN_H"])
marker = os.environ["EB_MARKER"]
deps = [int(x) for x in os.environ.get("EB_DEPS", "").split(",") if x.isdigit()]
def load(name):
    with open(os.path.join(d, name)) as f:
        return json.load(f)
iss = load("issue.json")
if not isinstance(iss, dict) or int(iss.get("number", 0) or 0) != n:
    print("SKIP\tunreadable"); sys.exit(0)
if iss.get("pull_request") is not None:
    print("GONE\tpull request"); sys.exit(0)
if str(iss.get("state", "")).lower() != "open":
    print("GONE\tclosed"); sys.exit(0)
labels = iss.get("labels")
if not isinstance(labels, list):
    print("SKIP\tno labels field"); sys.exit(0)
if any(isinstance(l, dict) and str(l.get("name", "")).strip().lower() == "ai-build" for l in labels):
    print("GONE\tcarries ai-build"); sys.exit(0)
comments = load("comments.json")
if not isinstance(comments, list):
    print("SKIP\tcomments unreadable"); sys.exit(0)
# A short read (the comment cap dropped the newest comments) is no list to
# judge from: the question or a reply may be in the part not read.
try:
    want = int(iss.get("comments", 0) or 0)
except Exception:
    want = 0
if len(comments) < want:
    print("SKIP\tcomments short read %d of %d" % (len(comments), want)); sys.exit(0)
filer = ("stays open as the master", "stays open until they ship",
         "so no builder picks the whole thing up again")
if any(s in str(c.get("body") or "") for c in comments if isinstance(c, dict) for s in filer):
    print("DECOMPOSE\tfiler sentence on the thread"); sys.exit(0)

part_re = re.compile(r"^[\s>*_\-#]*part[- ]of\b[^#\n]*#%d(?!\d)" % n, re.IGNORECASE | re.MULTILINE)
epic_re = re.compile(r"\bepic\s*:?\s*#%d(?!\d)" % n, re.IGNORECASE)
blk_re = re.compile(r"^[\s>*_\-#]*blocked[- ]by\b(.*)$", re.IGNORECASE | re.MULTILINE)
num_re = re.compile(r"#(\d+)")
kids = {}
for kind, rx in (("part.json", part_re), ("epic.json", epic_re)):
    s = load(kind)
    if not isinstance(s, dict) or not isinstance(s.get("items"), list):
        print("SKIP\tsearch unreadable"); sys.exit(0)
    # One page only: a list that does not fit it is not a list to judge from.
    if s.get("incomplete_results") or int(s.get("total_count", 0) or 0) > len(s["items"]) \
            or int(s.get("total_count", 0) or 0) > 100:
        print("SKIP\tsearch incomplete"); sys.exit(0)
    for it in s["items"]:
        if not isinstance(it, dict) or it.get("pull_request") is not None:
            continue
        k = int(it.get("number", 0) or 0)
        body = str(it.get("body") or "")
        if k <= 0 or k == n or not rx.search(body):
            continue
        # A ticket that waits on N in its Blocked-by line is a dependent.
        if any(int(x) == n for m in blk_re.finditer(body) for x in num_re.findall(m.group(1))):
            continue
        kids[k] = str(it.get("state", "")).lower()
sub = load("sub.json")
if not isinstance(sub, list):
    print("SKIP\tsub-issues unreadable"); sys.exit(0)
for it in sub:
    if isinstance(it, dict) and it.get("pull_request") is None:
        k = int(it.get("number", 0) or 0)
        if k > 0 and k != n:
            kids[k] = str(it.get("state", "")).lower()
if not kids:
    print("NO_CHILDREN\t"); sys.exit(0)
if any(s != "closed" for s in kids.values()):
    print("OPEN_CHILD\t#%d" % min(k for k, s in kids.items() if s != "closed")); sys.exit(0)
names = ", ".join("#%d" % k for k in sorted(kids))
def ts(c):
    try:
        return int(datetime.datetime.strptime(str(c.get("created_at")), "%Y-%m-%dT%H:%M:%SZ")
                   .replace(tzinfo=datetime.timezone.utc).timestamp())
    except Exception:
        return None
qs = [c for c in comments if isinstance(c, dict) and str(c.get("body") or "").lstrip().startswith(marker)]
if not qs:
    depn = ", ".join("#%d" % x for x in deps)
    body = ("%s\nEvery child of this epic is closed: %s. I recommend that we close it.\n\n"
            "These tickets wait on it in a Blocked-by line: %s.\n\n"
            "If nobody answers here in %d h, they will treat Blocked-by #%d as met and start to build. "
            "To keep them waiting, reply here. To release them now, close this issue.\n"
            % (marker, names, depn, win, n))
    with open(os.path.join(d, "question.md"), "w") as f:
        f.write(body)
    print("ASK\t%s" % names); sys.exit(0)
qt = min((ts(c) for c in qs if ts(c) is not None), default=None)
if qt is None:
    print("SKIP\tquestion time unreadable"); sys.exit(0)
for c in comments:
    if not isinstance(c, dict) or c in qs:
        continue
    b = str(c.get("body") or "")
    user = c.get("user") if isinstance(c.get("user"), dict) else {}
    t = ts(c)
    if t is None or t <= qt or "<!-- harness" in b or str(user.get("type", "")) == "Bot":
        continue
    print("ANSWERED\t%s" % (user.get("login") or "someone")); sys.exit(0)
if now - qt < win * 3600:
    print("WAIT\t%d" % qt); sys.exit(0)
print("MET\t%s" % names)
PYEOF
)
    verdict="${out%%$'\t'*}"; info="${out#*$'\t'}"
    case "$verdict" in ''|SKIP) continue ;; esac
    if [ "$dry" = 1 ]; then _eb_log "$h" "$project" "EPIC_DRY #$n $verdict"; continue; fi
    case "$verdict" in
      ASK)
        if gh_rest_comment "$repo" "$n" "$d/question.md" </dev/null; then
          _eb_log "$h" "$project" "EPIC_QUESTION_POSTED #$n — every child is closed ($info); dependents #${deps//,/, #}"
          [ -x "$alert" ] && "$alert" --id "epic-blocker-$project-$n" --project "$project" \
            "epic-blocker: $project epic #$n has every child closed ($info). I asked on the thread whether to close it. #${deps//,/, #} wait on it in Blocked-by and treat it as met in $win h if nobody answers. https://github.com/$repo/issues/$n" </dev/null >/dev/null 2>&1
        else
          printf 'retry\n' >> "$tmp/keys" 2>/dev/null
        fi
        rm -f "$sd/$n.met" 2>/dev/null ;;
      MET)
        if [ ! -e "$sd/$n.met" ]; then
          mkdir -p "$sd" 2>/dev/null
          : > "$sd/$n.met" 2>/dev/null && _eb_log "$h" "$project" "EPIC_DEFAULT_MET #$n — nobody answered the close question in $win h, so #${deps//,/, #} treat Blocked-by #$n as met"
        fi ;;
      ANSWERED)
        rm -f "$sd/$n.met" 2>/dev/null
        if [ ! -e "$sd/$n.stopped" ]; then
          mkdir -p "$sd" 2>/dev/null
          : > "$sd/$n.stopped" 2>/dev/null
          _eb_log "$h" "$project" "EPIC_DEFAULT_STOPPED #$n — $info replied to the close question, so the dependents keep waiting"
        fi ;;
      *) rm -f "$sd/$n.met" 2>/dev/null ;;
    esac
  done < "$tmp/eb-cands.tsv"
  [ "$dry" = 1 ] && return 0

  if [ -n "$last" ]; then
    mkdir -p "$sd" 2>/dev/null
    printf '%s\n' "$last" > "$sd/cursor" 2>/dev/null
  fi
  # Retention: a marker whose epic no open ticket waits on any more has no reader.
  for f in "$sd"/*.met "$sd"/*.stopped; do
    [ -e "$f" ] || continue
    n=$(basename "$f"); n="${n%.*}"
    grep -qx "$n" "$tmp/eb-targets" 2>/dev/null || rm -f "$f" 2>/dev/null
  done
  return 0
}
