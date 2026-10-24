#!/bin/bash
# tests/gh-app-ratchet-test.sh — freeze the raw-`gh` surface in bin/ while the
# App-token rollout (#425) eats through it.
#
# THE POINT. One PAT is one 5000/h REST bucket for every lane on every box, and
# one credential whose leak is fleet-wide. bin/lib/gh-app-auth.sh mints a
# short-lived, repo-scoped App token instead; #438 armed the three merge-path
# consumers (lib/merge-conductor-lib.sh, blocked-resolver.sh, merge-queue.sh)
# and children 2-5 of #425 convert the rest. This test is the ratchet in
# between: a script that calls gh directly either arms a token, or SAYS IN ITS
# OWN HEADER that it does not and why.
#
# EVERY SCRIPT DECLARES ITS OWN IDENTITY (BH-1177). The ratchet used to hold the
# line with two shared files and a pinned count — one allow-list whose length
# was asserted to be exactly six, and four baseline part files. Every PR that
# converted, allow-listed or added a raw reader had to re-pin that number and
# edit a list nobody else could edit at the same time: the suite and its
# allow-list were touched by 13 of the last 200 merges and were in six of one
# day's conflicts. None of those conflicts were about the feature being built.
#
# So the declaration moved INTO the file it is about. One line in the header:
#
#   # gh-identity: app-token                    arms an App token before its
#                                               first gh call
#   # gh-identity: raw-pat (BH-440) — <why>     still on the fleet PAT; the
#                                               ticket names the slice that
#                                               will convert it
#   # gh-identity: raw-by-design — <why>        converting it would be WRONG,
#                                               and the sentence says why
#
# one line under the shebang. The registry that keeps the raw set from growing
# is one FILE per entry,
# tests/gh-app-ratchet-baseline/<path under bin/>.txt, holding the slice note.
# A directory of one-file entries and not a list, because two PRs deleting
# ADJACENT LINES of one sorted list still conflict (measured, not assumed) —
# while two PRs deleting two different files never can. Converting a script is
# now: flip that script's own marker to app-token, delete that script's own
# registry file. Two conversions in flight touch four disjoint paths.
#
# WHAT THE RATCHET ASSERTS:
#   1. every file that calls gh RAW carries a raw-pat or raw-by-design marker
#      in its header — an unmarked raw call is the finding;
#   2. every raw-pat marker has a registry file, and every registry file has a
#      raw-pat marker (so the raw set only ever shrinks: a NEW raw lane costs a
#      reviewed registry entry, exactly as the old count did);
#   3. a file that declares app-token really arms one — the scanner, not the
#      marker, decides that, so a marker cannot claim a conversion nobody made;
#   4. a raw marker on a file that no longer calls gh raw is STALE and fails —
#      an exception must not outlive its reason;
#   5. a raw-by-design file has an entry in the BY-DESIGN registry and none in
#      the conversion one: a script is either queued or exempt, never both, and
#      never exempt on its own say-so;
#   6. a raw-pat marker cites a ticket that is still OPEN. It needs the network,
#      so a read that fails is a SKIP; CI hands it a token on pull requests
#      (block 3d, BH-1984).
#
# A TRAP WORTH KNOWING. The armed test is textual (below), so a marker whose
# REASON names one of the token helpers makes the file read as converted. Rule 4
# catches it — the file drops out of the raw set and its own marker goes stale —
# but the fix is to reword the sentence, not to delete the marker.
#
# WHAT COUNTS AS A RAW CALL. After `#` comments are stripped (quote-aware), a
# line offends when `gh <pr|issue|api|repo|run|workflow>` sits at COMMAND
# POSITION: line start, or after `$(`, `<(`, `|`, `||`, `&&`, `;`, `{`, or one
# of if/elif/while/until/then/do/else/!, optionally behind a `timeout N`,
# `env [-u NAME]`, or `NAME=value` prefix. Prose, string literals, `gh auth
# token`, `gh_ci_api`, a function named `gh_pr_list` and `ghq api` are all left
# alone — the fixture in block 1 pins every one of those cases.
#
# WHAT COUNTS AS ARMED. The file names one of the token helpers —
# gh-app-auth.sh, gh-token.sh, gh-token-live.sh, gh-ci-read.sh — or calls one of
# the App-token wrappers: mc_use_token, br_use_token, gh_auth_for,
# gh_auth_for_url. The wrapper names are in the rule because bin/merge-queue.sh
# arms through the lib and never names a helper file; `gh_repo_use_token` is
# deliberately NOT. Since BH-765 that probe's own ladder does try an App token
# first, so a caller may well get one — but only for repos the probe is asked
# about, only when the box is armed, and without the caller ever deciding it.
# Counting such a file as converted would report a conversion nobody made.
#
# WHERE A MARKER COUNTS. In the file's HEADER BLOCK only — the shebang, blank
# lines and comments before the first line of code. An identity you cannot see
# with `head` is not a declaration, and a marker further down is reported as
# misplaced rather than silently ignored.
#
# A SOURCED MODULE IS ARMED BY THE SCRIPT THAT SOURCES IT (BH-682). BH-477 is
# carving bin/lib/merge-conductor-lib.sh into bin/lib/mc/<name>.sh: the lib's own
# source loop pulls the modules in ahead of its first line of logic, so a `gh`
# call that moves from the lib into a module is the same call, in the same lane,
# on the same identity — only the file holding it changed. Scoring each module
# on its own text would report a conversion regression that never happened, and
# blocks 5 and 7 below already RUN the lib WITH its modules and read the token
# its gh calls actually go out on. The relation is read out of the lib's own
# loop, never hardcoded as a list of names, and every way that read can fail
# leaves the module standing alone — this rule can only ever go red by accident,
# never green. A module the loop stops naming is a raw file again.
#
# WHAT IT DOES NOT CATCH, said plainly so nobody reads a green run as proof:
#   * A call built at runtime — `$GHBIN pr merge`, `eval "gh $verb"`, a call
#     assembled across two lines, or one inside a `bash -c` string.
#   * A raw call in a file that is armed for some OTHER repo: arming is per
#     file, not per call site. The armed test is TEXTUAL, so a file that only
#     MENTIONS a helper in a comment reads as armed too. That is why the three
#     merge-path files are not trusted to the scanner at all: blocks 5, 6 and 7
#     RUN them and read the token their gh calls actually go out on.
#   * Anything outside bin/**/*.sh (worker/, cron/, checks/, console-ui/).
# KNOWN RESIDUALS, both fail-CLOSED, which is the right way round:
#   * A heredoc prose line that starts with `gh pr ...` at column 0 is
#     indistinguishable from a call here and counts as one. Reword the line, or
#     declare the file raw-by-design with that as the reason.
#   * A `# gh-identity:` line inside a HEREDOC of a file whose own header has no
#     marker reads as `misplaced` and fails — a generator that emits headers for
#     other scripts will trip this. Give the generator its own header marker and
#     the heredoc is ignored.
#
# `app-token` IS OPTIONAL TODAY, and no file in bin/ carries it yet. The rule is
# "every file that calls gh RAW declares"; a file that arms one may declare and
# be checked (rule 3), but is not required to — marking all ~68 armed callers in
# one change would have touched half the repo for a comment line. Conversions
# add the marker as they land, which is what rule 3 is waiting for.
#
#   bash tests/gh-app-ratchet-test.sh            exit 0 = pass
#   GH_APP_RATCHET_STRICT=1 bash tests/…         ignore the registry and the
#                                                raw-pat markers: red on every
#                                                file still to convert
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# The registry: one file per script that is still raw, named for the script's
# path under bin/ with .txt appended, holding the sentence that says which slice
# converts it. One file per entry is the whole conflict story — see the header.
REG="$DIR/tests/gh-app-ratchet-baseline"
# The twin registry: the scripts that are raw ON PURPOSE. A permanent exception
# is a reviewed decision, not a sentence a script writes about itself — see the
# header, and tests/gh-app-ratchet-by-design/README.
BYD="$DIR/tests/gh-app-ratchet-by-design"
STRICT="${GH_APP_RATCHET_STRICT:-0}"

# ── the scanner ──────────────────────────────────────────────────────────────
# Written out as a standalone script so the SAME code scans the repo and the
# synthetic fixtures below. A guard nobody has watched fail is a guard nobody
# knows is wired up. It prints one TSV row per interesting file:
#
#   <path relative to bin/>  <status>  <first offending line>  <marker>  <ticket>
#
# status is raw (calls gh, arms nothing), armed (calls gh with a token armed) or
# nocall; marker is app-token / raw-pat / raw-by-design, or none, misplaced, dup
# or bad-<what> when the header does not parse; ticket is the key a raw-pat
# marker cites, empty otherwise. Paths, line numbers, ticket keys and those
# fixed words only — never a line's contents, because a raw call's arguments can
# carry a token and a marker's reason is free text.
cat > "$T/scan.py" <<'PY'
import re, sys, os

bindir = sys.argv[1]
VERBS = "pr|issue|api|repo|run|workflow"
CALL = re.compile(r"^gh\s+(?:%s)(?![A-Za-z0-9_-])" % VERBS)
# Prefixes that still leave the next word at command position.
ASSIGN  = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|[^\s;|&]*)\s+")
TIMEOUT = re.compile(r"^timeout\s+(?:-k\s+\S+\s+)?\S+\s+")
ENVP    = re.compile(r"^env\s+(?:-[iu]\s+\S+\s+|-[iu]\s+)*")
# BH-8150: `prr_write <repo> <n> <kind> <extra> gh ...` (bin/lib/pr-record-write.sh)
# runs the gh call it wraps. Its four arguments can hold `$(...)`, which SPLIT
# would cut, so the whole prefix comes off the line before the split.
PRRW    = re.compile(r"(?<![A-Za-z0-9_])prr_write\s.*?\s(?:labels|comment|pull|none)\s+.*?(?=(?<![A-Za-z0-9_-])gh\s)")
# Command separators, exactly the ones #438 names. Bare "(" is NOT one of them:
# prose like "(gh pr view for PR claims)" inside a heredoc is not a call.
SPLIT = re.compile(r"\$\(|<\(|\|\||&&|[|;{]"
                   r"|(?<![A-Za-z0-9_-])(?:if|elif|while|until|then|do|else)(?![A-Za-z0-9_-])|!")
ARMED = re.compile(r"gh-app-auth\.sh|gh-token\.sh|gh-token-live\.sh|gh-ci-read\.sh"
                   r"|(?<![A-Za-z0-9_])(?:mc_use_token|br_use_token|gh_auth_for|gh_auth_for_url)"
                   r"(?![A-Za-z0-9_])")


MARKER = re.compile(r"^[ \t]*#[ \t]*gh-identity:[ \t]*(.*)$")
KINDS = ("app-token", "raw-pat", "raw-by-design")
TICKET = re.compile(r"\((BH-[0-9]+|#[0-9]+)\)[ \t]*(.*)$")


def header_lines(path):
    """The file's header block: shebang, blanks and comments before the first
    line of code. A declaration you cannot see with `head` is not one."""
    head, rest = [], []
    done = False
    with open(path, errors="ignore") as fh:
        for line in fh:
            if done:
                rest.append(line)
                continue
            t = line.strip()
            if t == "" or t.startswith("#"):
                head.append(line)
            else:
                done = True
                rest.append(line)
    return head, rest


def marker(path):
    """(kind, ticket) for the file's gh-identity declaration.

    kind is one of the three real markers, or: none (no declaration anywhere),
    misplaced (one below the header block), dup (two in the header), bad-kind,
    bad-ticket, bad-reason. ticket is the key a raw-pat marker cites and is
    empty for everything else. The REASON is never returned — it is the author's
    sentence, and this scanner prints no file contents.
    """
    head, rest = header_lines(path)
    hits = [m.group(1).strip() for m in
            (MARKER.match(l) for l in head) if m]
    if not hits:
        for l in rest:
            if MARKER.match(l):
                return "misplaced", ""
        return "none", ""
    if len(hits) > 1:
        return "dup", ""
    body = hits[0]
    kind = body.split()[0] if body.split() else ""
    tail = body[len(kind):].strip()
    ticket = ""
    if kind not in KINDS:
        return "bad-kind", ""
    if kind == "app-token":
        return kind, ""
    if kind == "raw-pat":
        m = TICKET.match(tail)
        if not m:
            return "bad-ticket", ""
        ticket, tail = m.group(1), m.group(2)
    # Both raw kinds carry a sentence. The point of an exception is the
    # sentence, not the silence, so a dash with nothing after it is a finding.
    if not tail.lstrip("\u2014-:\u2013 \t"):
        return "bad-reason", ""
    return kind, (ticket if kind == "raw-pat" else "")


def strip_comment(line):
    """Drop a `#` comment, honouring quotes so a "#" inside a string survives."""
    out, sq, dq, prev = [], False, False, ""
    for ch in line:
        if ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "#" and not sq and not dq and (prev == "" or prev.isspace() or prev in ";&|("):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def raw_lines(path):
    hits = []
    with open(path, errors="ignore") as fh:
        for n, line in enumerate(fh, 1):
            code = strip_comment(line.rstrip("\n")).strip()
            if not code:
                continue
            code = PRRW.sub("", code)
            for chunk in SPLIT.split(code):
                c = chunk.lstrip()
                while True:
                    for rx in (ASSIGN, TIMEOUT, ENVP):
                        m = rx.match(c)
                        if m:
                            c = c[m.end():].lstrip()
                            break
                    else:
                        break
                if CALL.match(c):
                    hits.append(n)
                    break
    return hits


def armed(path):
    with open(path, errors="ignore") as fh:
        return bool(ARMED.search(fh.read()))


# The shim's source loop, e.g. `for _mc_m in log locks classify queue rebase
# settle; do . "$MC_LIB_DIR/$_mc_m.sh"`: the loop variable ties the name list to
# a real source statement, so an unrelated for-loop cannot match.
LOOP = re.compile(r"for\s+(\w+)\s+in\s+([^;\n]+);\s*do\b"
                  r"(?:[^\n]*\n){0,3}?[^\n]*\$\{?(\w+)\}?/\$\{?\1\}?\.sh")
# BH-5240: the shim's ONE source of the mc bootstrap, `. "$MC_LIB_DIR/load.sh"`,
# which loads the names <dir>/MODULES lists. `^` keeps a commented line out.
BOOT = re.compile(r'^\. "\$\{?(\w+)\}?/load\.sh"', re.M)


def sourced_modules(bindir):
    """Map module path -> the script that sources it, read from that script.

    Every failure to read the relation returns {} and leaves the modules
    standing on their own, which is the strict answer: this cannot turn a raw
    file green by accident, only a converted one red.
    """
    shim = os.path.join(bindir, "lib", "merge-conductor-lib.sh")
    try:
        with open(shim, errors="ignore") as fh:
            text = fh.read()
    except OSError:
        return {}
    m = LOOP.search(text)
    b = None if m else BOOT.search(text)
    if not m and not b:
        return {}
    # Where the loop sources from: the literal tail of `MC_LIB_DIR="$(cd …)/mc"`.
    var = m.group(3) if m else b.group(1)
    d = re.search(r"%s=\"[^\n]*?\)/([\w./-]+)\"" % re.escape(var), text)
    if not d:
        return {}
    base = os.path.join(bindir, "lib", *d.group(1).split("/"))
    if m:
        names = m.group(2).split()
    else:
        # The bootstrap's list is the generated <base>/MODULES.
        try:
            with open(os.path.join(base, "MODULES"), errors="ignore") as fh:
                names = [l.strip() for l in fh
                         if l.strip() and not l.lstrip().startswith("#")]
        except OSError:
            return {}
    return dict((os.path.join(base, n + ".sh"), shim) for n in names)


def rb_stage_modules(bindir):
    """Map bin/lib/rb/<name>.sh -> bin/run-build.sh, read from the driver.

    BH-478 carves the build pipeline into stage modules the driver SOURCES, the
    same relation bin/lib/mc/ has to the conductor lib: the bodies are the
    driver's own lines, moved, running in the driver's process on the driver's
    identity. So the rule the mc/ modules get applies here too — and for the
    same reason, a carving slice must not be able to quiet this guard by writing
    one of them into the baseline instead.

    Read, never assumed, on the same discipline as sourced_modules above: the
    literal RB_MODULES list, a loop over it, and a real source statement that
    ties the loop variable to a directory. Any failure to read the relation
    returns {} and leaves the modules standing on their own, which is the strict
    answer — this can only arm a module the driver really sources.
    """
    driver = os.path.join(bindir, "run-build.sh")
    try:
        with open(driver, errors="ignore") as fh:
            text = fh.read()
    except OSError:
        return {}
    names = re.search(r'^RB_MODULES="([A-Za-z0-9_ -]+)"[ \t]*$', text, re.M)
    if not names:
        return {}
    loop = re.search(r"for\s+(\w+)\s+in\s+\$\{?RB_MODULES\}?[^;\n]*;\s*do\b", text)
    if not loop:
        return {}
    src = re.search(r'^[ \t]*\.[ \t]+"\$\{?\w+\}?/((?:[\w.-]+/)+)\$\{?%s\}?\.sh"'
                    % re.escape(loop.group(1)), text, re.M)
    if not src:
        return {}
    parts = [q for q in src.group(1).strip("/").split("/") if q]
    if parts and parts[0] == "bin":
        parts = parts[1:]
    if not parts:
        return {}
    base = os.path.join(bindir, *parts)
    return dict((os.path.join(base, n + ".sh"), driver) for n in names.group(1).split())


def rb_flatten(driver, modules):
    """The driver's text with each bare `rb_<name>` call line replaced by that
    entry's body — the same text tests/lib/rb-all.sh builds. Since the BH-572
    cut the driver arms its token inside a stage body (rb_gate_claim_and_workspace),
    so the driver's OWN lines no longer name the helper: the pipeline that runs
    is the flatten, and that is what arms the modules it sources. Only entry
    BODIES are read, never a module's header, so a comment there cannot arm."""
    bodies = {}
    for mp in modules:
        try:
            with open(mp, errors="ignore") as fh:
                lines = fh.read().split("\n")
        except OSError:
            continue
        name = None
        for l in lines:
            m = re.match(r"^(rb_[a-z_]+)\(\) \{$", l)
            if name is None and m:
                name, buf = m.group(1), []
            elif name is not None and l == "} # end " + name:
                bodies[name] = "\n".join(buf)
                name = None
            elif name is not None:
                buf.append(l)
    try:
        with open(driver, errors="ignore") as fh:
            text = fh.read()
    except OSError:
        return ""
    return "\n".join(bodies.get(l, l) if re.match(r"^rb_[a-z_]+$", l) else l
                     for l in text.split("\n"))


MODULES = sourced_modules(bindir)
RB_MODS = rb_stage_modules(bindir)
MODULES.update(RB_MODS)
ARMED_SHIM = {}
if RB_MODS:
    drv = next(iter(RB_MODS.values()))
    ARMED_SHIM[drv] = bool(ARMED.search(rb_flatten(drv, sorted(RB_MODS))))

rows = []
for root, dirs, names in os.walk(bindir):
    dirs.sort()
    for name in sorted(names):
        if not name.endswith(".sh"):
            continue
        p = os.path.join(root, name)
        hits = raw_lines(p)
        mk, tk = marker(p)
        if hits:
            shim = MODULES.get(p)
            covered = armed(p) or (shim is not None and ARMED_SHIM.get(shim, armed(shim)))
            status, n = ("armed" if covered else "raw"), hits[0]
        else:
            status, n = "nocall", 0
        # A file with neither a call nor a declaration has nothing to say.
        if status == "nocall" and mk == "none":
            continue
        rows.append((os.path.relpath(p, bindir), status, n, mk, tk))
for rel, status, n, mk, tk in sorted(rows):
    print("%s\t%s\t%d\t%s\t%s" % (rel, status, n, mk, tk))
PY

# The fixtures below ask the same question the ratchet has always asked — which
# files are RAW — so the helper filters the status column and hands back the
# same space-separated list those cases were written against.
scan() { python3 "$T/scan.py" "$1" | awk -F'\t' '$2=="raw"{print $1}' | tr '\n' ' '; }
mark() { python3 "$T/scan.py" "$1" | awk -F'\t' -v f="$2" '$1==f{print $4}'; }

# ══ 1. the fixture: the scanner flags calls and only calls ══════════════════
F="$T/fixture/bin"
mkdir -p "$F/lib"
cat > "$F/raw.sh" <<'EOF2'
#!/bin/bash
gh pr view foo/bar/1
EOF2
cat > "$F/sub.sh" <<'EOF2'
#!/bin/bash
X=$(gh api repos/x/y)
echo "$X"
EOF2
cat > "$F/chained.sh" <<'EOF2'
#!/bin/bash
[ -n "$x" ] && gh issue comment 1 -R x/y -b hi
gh_nope || gh api repos/x/y
EOF2
cat > "$F/timeout.sh" <<'EOF2'
#!/bin/bash
timeout 30 gh run list -R x/y
EOF2
cat > "$F/envprefix.sh" <<'EOF2'
#!/bin/bash
GH_TOKEN="$t" gh api repos/x/y
env -u GH_TOKEN gh api repos/x/z
EOF2
cat > "$F/lib/inner.sh" <<'EOF2'
#!/bin/bash
gh repo view x/y
EOF2
cat > "$F/prose.sh" <<'EOF2'
#!/bin/bash
# When a lane is stuck, run `gh pr list -R x/y` by hand and read the state.
#   gh api repos/x/y   <- the raw form, in a doc header
MSG="gh pr merge is what the conductor runs"
gh auth token >/dev/null 2>&1        # not one of the six verbs
gh_ci_api "repos/x/y"                # helper function, not a gh call
gh_pr_list() { echo "$MSG"; }        # a function whose name starts with gh_
ghq api foo                          # a different binary entirely
EOF2
cat > "$F/armed.sh" <<'EOF2'
#!/bin/bash
. "$H/bin/lib/gh-app-auth.sh"
gh_auth_for x/y || true
gh pr view x/y/1
EOF2
cat > "$F/ciread.sh" <<'EOF2'
#!/bin/bash
. "$H/bin/lib/gh-ci-read.sh"
gh api repos/x/y
EOF2
GOT=$(scan "$F")
[ "$GOT" = "chained.sh envprefix.sh lib/inner.sh raw.sh sub.sh timeout.sh " ] && ok \
  || bad "fixture: expected exactly the six call files (chained, envprefix, lib/inner, raw, sub, timeout), got '$GOT'"
# Each shape on its own, so a set mismatch above says WHICH shape moved.
for ONE in raw.sh sub.sh chained.sh timeout.sh envprefix.sh lib/inner.sh; do
  case " $GOT " in *" $ONE "*) ok ;; *) bad "fixture: $ONE makes a raw gh call and was not flagged" ;; esac
done
for ONE in prose.sh armed.sh ciread.sh; do
  case " $GOT " in *" $ONE "*) bad "fixture: $ONE makes no raw gh call and must not be flagged" ;; *) ok ;; esac
done

# ── 1a. a gh call behind the PR-record wrapper is still a call (BH-8150) ────
FP="$T/fixture-prr/bin"
mkdir -p "$FP"
cat > "$FP/wrapped.sh" <<'EOF2'
#!/bin/bash
prr_write "$(mc_slug_of_url "$url")" "$(mc_num_of_url "$url")" labels - gh api -X DELETE "repos/x/y/issues/1/labels/z" >/dev/null 2>&1 || true
EOF2
cat > "$FP/wrapsub.sh" <<'EOF2'
#!/bin/bash
err=$(prr_write "$slug" "$num" comment "$(prr_mergify_extra "$body")" gh api -X POST "repos/$slug/issues/$num/comments" 2>&1 >/dev/null)
EOF2
cat > "$FP/nowrap.sh" <<'EOF2'
#!/bin/bash
prr_note_push "$slug" "$num" "$at" "$wt" HEAD "$head"
prr_write "$slug" "$num" none - true
EOF2
GOT=$(scan "$FP")
[ "$GOT" = "wrapped.sh wrapsub.sh " ] && ok \
  || bad "1a: a gh call behind prr_write must be flagged and a prr_ line with no gh call must not: expected 'wrapped.sh wrapsub.sh ', got '$GOT'"

# ── 1b. the armed rule tells an App token from the PAT probe ────────────────
# The rollout this ratchet drives is PAT -> App token, so a script pinned to the
# PAT must still count as raw; a script arming through the lib must not.
F2="$T/fixture2/bin"; mkdir -p "$F2"
cat > "$F2/patonly.sh" <<'EOF2'
#!/bin/bash
gh_repo_use_token x/y
gh pr list -R x/y
EOF2
cat > "$F2/queuearm.sh" <<'EOF2'
#!/bin/bash
mc_use_token "$SLUG" || true
gh pr merge "$NUM" -R "$SLUG" --squash
mc_reset_token
EOF2
GOT2=$(scan "$F2")
[ "$GOT2" = "patonly.sh " ] && ok \
  || bad "armed rule: a gh_repo_use_token-only script must stay raw and an mc_use_token one must not, got '$GOT2'"

# ── 1c. a module the lib SOURCES is armed by the lib ────────────────────────
# BH-477 moves the conductor's gh calls out of bin/lib/merge-conductor-lib.sh
# and into bin/lib/mc/<name>.sh without changing one of them. The loop is what
# makes a module part of the lib, so the fixture puts a fourth file in the same
# directory that the loop does NOT name: it stands on its own and stays raw.
F3="$T/fixture3/bin"; mkdir -p "$F3/lib/mc"
cat > "$F3/lib/merge-conductor-lib.sh" <<'EOF2'
#!/bin/bash
MC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mc"
for _mc_m in log queue; do
  # shellcheck source=/dev/null
  . "$MC_LIB_DIR/$_mc_m.sh" || exit 1
done
mc_use_token() { command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"; return 0; }
EOF2
cat > "$F3/lib/mc/log.sh" <<'EOF2'
#!/bin/bash
mc_log() { echo "$*"; }
EOF2
cat > "$F3/lib/mc/queue.sh" <<'EOF2'
#!/bin/bash
mc_merge() { gh pr merge "$1" -R "$2" --squash; }
EOF2
cat > "$F3/lib/mc/orphan.sh" <<'EOF2'
#!/bin/bash
gh pr list -R x/y
EOF2
GOT3=$(scan "$F3")
[ "$GOT3" = "lib/mc/orphan.sh " ] && ok \
  || bad "shim rule: a module the lib's loop names carries the lib's arming, one it does not name must stay raw, got '$GOT3'"

# ── 1d. …and only while the lib itself is armed ─────────────────────────────
# The inheritance is the lib's arming, not the lib's existence. Same module,
# same loop, a lib that names no helper: the module is raw again.
F4="$T/fixture4/bin"; mkdir -p "$F4/lib/mc"
cat > "$F4/lib/merge-conductor-lib.sh" <<'EOF2'
#!/bin/bash
MC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mc"
for _mc_m in queue; do
  # shellcheck source=/dev/null
  . "$MC_LIB_DIR/$_mc_m.sh" || exit 1
done
EOF2
cp "$F3/lib/mc/queue.sh" "$F4/lib/mc/queue.sh"
GOT4=$(scan "$F4")
[ "$GOT4" = "lib/mc/queue.sh " ] && ok \
  || bad "shim rule: a module whose lib arms nothing must stay raw, got '$GOT4'"

# ── 1e. a stage module the DRIVER sources is armed by the driver ───────────
# The BH-478 half of the same rule. A fifth file in bin/lib/rb/ that RB_MODULES
# does not name is not a stage module: it stands on its own and stays raw.
F5="$T/fixture5/bin"; mkdir -p "$F5/lib/rb"
cat > "$F5/run-build.sh" <<'EOF2'
#!/bin/bash
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
RB_MODULES="gates review"
for _m in $RB_MODULES; do
  # shellcheck source=/dev/null
  . "$HARNESS/bin/lib/rb/$_m.sh"
done
EOF2
cat > "$F5/lib/rb/gates.sh" <<'EOF2'
#!/bin/bash
rb_gates() { echo gate; }
EOF2
cat > "$F5/lib/rb/review.sh" <<'EOF2'
#!/bin/bash
rb_review() { gh pr comment "$1" --body hi; }
EOF2
cat > "$F5/lib/rb/orphan.sh" <<'EOF2'
#!/bin/bash
gh pr list -R x/y
EOF2
GOT5=$(scan "$F5")
[ "$GOT5" = "lib/rb/orphan.sh " ] && ok \
  || bad "stage rule: a module RB_MODULES names carries the driver's arming, one it does not name must stay raw, got '$GOT5'"

# ── 1f. …and only while the DRIVER itself is armed ─────────────────────────
# Same module, same list, a driver that arms nothing: raw again. This is what
# keeps the cut honest — if the slice that moves the driver's own arming line
# into a module ever leaves the driver unarmed, every stage module goes red here
# instead of inheriting an identity nobody sets any more.
F6="$T/fixture6/bin"; mkdir -p "$F6/lib/rb"
grep -v 'gh-app-auth' "$F5/run-build.sh" > "$F6/run-build.sh"
cp "$F5/lib/rb/review.sh" "$F6/lib/rb/review.sh"
GOT6=$(scan "$F6")
[ "$GOT6" = "lib/rb/review.sh " ] && ok \
  || bad "stage rule: a module whose driver arms nothing must stay raw, got '$GOT6'"

# ── 1g. the marker reader: every shape that parses, and every shape that must not ─
# The declaration IS the mechanism now, so it gets a fixture of its own rather
# than being trusted to read correctly on the repo. Each file below is one
# shape, so a failure names which shape moved.
F7="$T/fixture7/bin"; mkdir -p "$F7"
cat > "$F7/converted.sh" <<'EOF2'
#!/bin/bash
# gh-identity: app-token
. "$H/bin/lib/gh-app-auth.sh"
gh pr view x/y/1
EOF2
cat > "$F7/queued.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-pat (BH-440) — the issue-lane slice converts it
gh issue view 1 -R x/y
EOF2
cat > "$F7/bydesign.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-by-design — it runs before any token exists on the box
gh api repos/x/y
EOF2
cat > "$F7/naked.sh" <<'EOF2'
#!/bin/bash
gh pr list -R x/y
EOF2
cat > "$F7/late.sh" <<'EOF2'
#!/bin/bash
X=1
# gh-identity: raw-by-design — declared below the header, where nobody looks
gh pr list -R x/y
EOF2
cat > "$F7/twice.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-by-design — one reason
# gh-identity: app-token
gh pr list -R x/y
EOF2
cat > "$F7/nokind.sh" <<'EOF2'
#!/bin/bash
# gh-identity: pat
gh pr list -R x/y
EOF2
cat > "$F7/noticket.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-pat — no ticket, so nobody owns the conversion
gh pr list -R x/y
EOF2
cat > "$F7/noreason.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-by-design —
gh pr list -R x/y
EOF2
cat > "$F7/quiet.sh" <<'EOF2'
#!/bin/bash
# gh-identity: raw-pat (BH-440) — a declaration on a file that calls nothing
echo hi
EOF2
for CASE in "converted.sh app-token" "queued.sh raw-pat" "bydesign.sh raw-by-design" \
            "naked.sh none" "late.sh misplaced" "twice.sh dup" "nokind.sh bad-kind" \
            "noticket.sh bad-ticket" "noreason.sh bad-reason" "quiet.sh raw-pat"; do
  set -- $CASE
  GOTM=$(mark "$F7" "$1")
  [ "$GOTM" = "$2" ] && ok || bad "marker reader: $1 must read as '$2', got '$GOTM'"
done
# …and the status column tells the three of them apart: the converted one arms,
# the queued one does not, the one that calls nothing is neither.
STAT=$(python3 "$T/scan.py" "$F7" | awk -F'\t' '$1=="converted.sh"||$1=="queued.sh"||$1=="quiet.sh"{printf "%s=%s ", $1, $2}')
[ "$STAT" = "converted.sh=armed queued.sh=raw quiet.sh=nocall " ] && ok \
  || bad "marker reader: the status column must read armed/raw/nocall for the three shapes, got '$STAT'"

# ── the repo scan, once ─────────────────────────────────────────────────────
python3 "$T/scan.py" "$DIR/bin" > "$T/rows.tsv"
awk -F'\t' '$2=="raw"{print $1}' "$T/rows.tsv" > "$T/raw.txt"
[ -s "$T/raw.txt" ] && ok || bad "the scan found nothing at all in bin/ — the scanner is not reaching the repo"

# ══ 2. both registries are well formed, and every entry names a real file ══
# A missing directory, or one with no entries, is not a pass: it is strict mode
# for the conversion registry, so an accidentally deleted one goes red on every
# unconverted script instead of quietly reporting zero — and a hard failure for
# the by-design one, because an empty exception registry with six exempt files
# in the tree is the guard being off, not a clean tree.
# NEVER CAPTURED, ALWAYS A GLOBAL. This helper calls bad(), and bad() has to
# run in THIS shell: `N=$(load_registry …)` would increment FAIL inside a
# command substitution's subshell, throw that increment away when the subshell
# exits, and staple the FAIL text into N — which is exactly what the first cut
# of this refactor did. A ghost entry then printed its finding INSIDE the
# summary line and the suite exited 0. So the count comes back in a global, and
# the two call sites read it immediately.
REGISTRY_COUNT=0
load_registry() { # load_registry <dir> <out file> <label> <dir name for messages>
  local dir="$1" out="$2" label="$3" short="$4" n=0 e rf
  REGISTRY_COUNT=0
  : > "$out"
  [ -d "$dir" ] || { REGISTRY_COUNT=-1; return 0; }
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    rf=${e#"$dir/"}; rf=${rf%.txt}
    echo "$rf" >> "$out"
    n=$((n+1))
    [ -f "$DIR/bin/$rf" ] \
      || bad "$label entry '$rf' names a file that is not in bin/ — delete tests/$short/$rf.txt. (An entry for a script that does not exist YET is how a self-bless would land in two steps.)"
    grep -qvE '^[[:space:]]*(#.*)?$' "$e" \
      || bad "$label entry '$rf' carries no note — an entry with nothing in it is a pinned count in disguise"
  done < <(find "$dir" -type f -name '*.txt' | sort)
  REGISTRY_COUNT=$n
}

load_registry "$REG" "$T/reg.txt" "registry" gh-app-ratchet-baseline
REG_COUNT=$REGISTRY_COUNT
if [ "$REG_COUNT" -eq -1 ]; then
  bad "tests/gh-app-ratchet-baseline/ is missing — treating the run as strict"
  STRICT=1; REG_COUNT=0
elif [ "$REG_COUNT" -eq 0 ]; then
  bad "the registry has no entries — treating the run as strict"
  STRICT=1
else
  ok
fi

load_registry "$BYD" "$T/byd.txt" "by-design registry" gh-app-ratchet-by-design
BYD_COUNT=$REGISTRY_COUNT
if [ "$BYD_COUNT" -eq -1 ]; then
  bad "tests/gh-app-ratchet-by-design/ is missing — the exception registry is the reviewed half of this ratchet, and without it every raw-by-design marker blesses itself"
  BYD_COUNT=0
elif [ "$BYD_COUNT" -eq 0 ]; then
  bad "the by-design registry has no entries — a raw-by-design marker with nothing behind it is a script allow-listing itself"
else
  ok
fi

# ══ 3. every file that calls gh says what it calls it on ══════════════════
# One pass over the scan. The marker and the scanner have to agree: a marker
# that claims more than the scanner can see is a conversion nobody made, and a
# marker the scanner has outgrown is an exception outliving its reason.
NEW=0
while IFS=$'\t' read -r RF ST RL MK TK; do
  [ -n "$RF" ] || continue
  INREG=0; grep -qxF "$RF" "$T/reg.txt" && INREG=1
  INBD=0;  grep -qxF "$RF" "$T/byd.txt" && INBD=1
  case "$MK" in
    dup)
      bad "bin/$RF declares gh-identity twice in its header — one file, one identity"; continue ;;
    misplaced)
      bad "bin/$RF has a gh-identity marker below its header block — an identity you cannot see with \`head\` is not a declaration; move it up with the other header comments"; continue ;;
    bad-kind)
      bad "bin/$RF has a gh-identity marker that names no known kind — it is one of: app-token, raw-pat (BH-<n>) — <why>, raw-by-design — <why>"; continue ;;
    bad-ticket)
      bad "bin/$RF is marked raw-pat with no ticket — write 'raw-pat (BH-<n>) — <why>' so the slice that converts it has an owner"; continue ;;
    bad-reason)
      bad "bin/$RF has a raw marker with no reason — the point of an exception is the sentence, not the silence"; continue ;;
  esac
  case "$ST:$MK" in
    raw:none)
      NEW=$((NEW+1)); echo "  bin/$RF:$RL raw gh call, no App token armed and no gh-identity marker" ;;
    raw:app-token)
      bad "bin/$RF:$RL declares 'gh-identity: app-token' but arms nothing before its gh call — the marker claims a conversion the scanner cannot see. Arm it, or put the marker back to raw-pat with the ticket that will." ;;
    raw:raw-pat)
      if [ "$STRICT" = 1 ]; then
        NEW=$((NEW+1)); echo "  bin/$RF:$RL still on the fleet PAT"
      elif [ "$INREG" = 0 ]; then
        bad "bin/$RF is marked raw-pat with no registry entry — a NEW raw lane costs a reviewed decision, exactly as the old pinned count did: add tests/gh-app-ratchet-baseline/$RF.txt with the sentence that says which slice converts it"
      fi ;;
    raw:raw-by-design)
      if [ "$INBD" = 0 ]; then
        bad "bin/$RF declares raw-by-design with no entry in tests/gh-app-ratchet-by-design/ — a PERMANENT exception is a reviewed decision, not a sentence a script writes about itself. This is the artifact the old pinned allow-list count stood for: add tests/gh-app-ratchet-by-design/$RF.txt naming who decided it and why it will never be converted."
      fi
      [ "$INREG" = 0 ] \
        || bad "bin/$RF is in BOTH registries — a script is either queued for conversion or exempt from it, never both; delete tests/gh-app-ratchet-baseline/$RF.txt" ;;
    armed:raw-pat|armed:raw-by-design|nocall:raw-pat|nocall:raw-by-design)
      bad "bin/$RF is marked $MK but the scanner sees no raw gh call in it any more — an exception must not outlive its reason. Converted? flip the marker to 'app-token' and delete its entry under tests/gh-app-ratchet-baseline/ or tests/gh-app-ratchet-by-design/. Just wrote the marker? a REASON that names a token helper (gh-app-auth.sh, gh-token.sh, mc_use_token, gh_auth_for, …) makes the whole file read as armed — reword the sentence." ;;
  esac
done < "$T/rows.tsv"
if [ "$NEW" = 0 ]; then ok; else
  if [ "$STRICT" = 1 ]; then
    bad "GH_APP_RATCHET_STRICT=1: $NEW script(s) in bin/ still call gh on the fleet PAT (the registry and the raw-pat markers are ignored in strict mode)."
  else
    bad "$NEW script(s) make raw gh calls and declare no identity.
     Fix: source bin/lib/gh-app-auth.sh, arm before the first gh call and reset at
     the end — 'gh_auth_for \"\$SLUG\" || true' ... 'gh_auth_reset' (or the
     mc_use_token/mc_reset_token pair from bin/lib/merge-conductor-lib.sh) — and
     put '# gh-identity: app-token' in the header, one line under the shebang.
     If it is genuinely still raw,
     write '# gh-identity: raw-pat (BH-<n>) — <which slice converts it>' in the
     header AND add tests/gh-app-ratchet-baseline/<path>.txt. If converting it
     would be WRONG, write '# gh-identity: raw-by-design — <why>' and add no
     registry entry."
  fi
fi

# ══ 3b. …and neither registry holds an entry nobody owns ═════════════════
# The other direction, once per registry: an entry whose file converted (or
# never declared) leaves that registry counting a lane that is not there, which
# is how a list quietly stops being the line it is holding.
reverse_check() { # reverse_check <entry list> <required marker> <label> <dir>
  local list="$1" want="$2" label="$3" dir="$4" rf mk
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    [ -f "$DIR/bin/$rf" ] || continue   # already reported above; one mistake, one line
    mk=$(awk -F'\t' -v f="$rf" '$1==f{print $4}' "$T/rows.tsv")
    [ "$mk" = "$want" ] \
      || bad "$label entry '$rf' has no $want marker in bin/$rf (it reads '${mk:-none}') — a file that stopped being $want keeps no entry, and an entry with no declaration is a line nobody owns; delete tests/$dir/$rf.txt"
  done < "$list"
}
reverse_check "$T/reg.txt" raw-pat       "registry"           gh-app-ratchet-baseline
reverse_check "$T/byd.txt" raw-by-design "by-design registry" gh-app-ratchet-by-design
ok

# ══ 3d. a raw-pat marker names a LIVE owner ═══════════════════════════════
# The only part of this suite that touches the network. The marker
# format exists so the slice that converts a file has an owner; a CLOSED ticket
# is not one — somebody greps for the marker, opens the ticket, finds it shipped
# and the file stays raw for ever. That is exactly what four of these markers
# did when BH-1177 first wrote them (they cited BH-439/BH-440, both closed).
#
# One REST read per DISTINCT ticket, never per marker (five markers, one ticket
# today). EVERY way the read can fail is a printed SKIP rather than a red: no
# gh on the box, no origin remote (an export is not a checkout), a timeout, an
# empty answer. A ratchet that goes red because api.github.com blinked is a
# ratchet somebody turns off, so this block can only ever ADD a finding — it
# never calls ok(), and a green run of this suite is not a claim about liveness.
#
# CI RUNS IT ON PULL REQUESTS (BH-1984). The shard step used to export no token,
# so every read came back empty and printed a SKIP, and BH-425 sat closed under
# three markers with nothing going red. The tests/ step now passes the workflow's
# own github.token, the Actions App's installation token and not the fleet PAT,
# as GH_APP_RATCHET_OWNER_TOKEN on pull_request runs only. A push to main gets
# no token and still skips, so a ticket closing on GitHub cannot turn main red
# and freeze merges with no commit to blame. A failed read is still a SKIP.
TICKETS=$(awk -F'\t' '$4=="raw-pat" && $5!=""{print $5}' "$T/rows.tsv" | sort -u)
SLUG=$(git -C "$DIR" config --get remote.origin.url 2>/dev/null \
       | sed -n 's|.*[:/]\([^/]\{1,\}/[^/]\{1,\}\)$|\1|p' | sed 's/\.git$//')
# GH_APP_RATCHET_OWNER_TOKEN (BH-1984) is the token CI hands this block on a
# pull request. It is set as GH_TOKEN on this one read and nowhere else, so no
# other block, and no other suite in the shard, runs with it. Unset, the read
# carries no credential: tests/lib/scratch.sh strips the caller's GH_TOKEN and
# points GH_CONFIG_DIR at the scratch dir (BH-6672), so it fails and SKIPs.
gh_state() { # gh_state <owner/repo> <issue number> -> prints open|closed|""
  local tok=()
  [ -n "${GH_APP_RATCHET_OWNER_TOKEN:-}" ] && tok=(env GH_TOKEN="$GH_APP_RATCHET_OWNER_TOKEN")
  if command -v timeout >/dev/null 2>&1; then
    "${tok[@]}" timeout 20 gh api "repos/$1/issues/$2" --jq .state 2>/dev/null
  else
    "${tok[@]}" gh api "repos/$1/issues/$2" --jq .state 2>/dev/null
  fi
}
if [ -z "$TICKETS" ]; then
  :
elif ! command -v gh >/dev/null 2>&1; then
  echo "block 3d: no gh on this box — the raw-pat owner check is advisory and was skipped"
elif [ -z "$SLUG" ]; then
  echo "block 3d: no origin remote here (an export is not a checkout) — the raw-pat owner check was skipped"
else
  for TK in $TICKETS; do
    NUM=${TK##*[-#]}   # BH-425 and #425 are both accepted by the parser
    case "$(gh_state "$SLUG" "$NUM")" in
      open)   : ;;
      closed) bad "a raw-pat marker names $TK as the slice that converts it, and #$NUM is CLOSED — a shipped ticket is not an owner. Re-point the marker at an open ticket: the rollout parent, or a child filed for that file." ;;
      *)      echo "block 3d: could not read the state of #$NUM — the raw-pat owner check is advisory, skipping" ;;
    esac
  done
fi

# ══ 3c. the files that arm through something else are never declared raw ═══
# The three files #438 arms are converted, not written down. A raw marker on one
# of them would make the ratchet report a lane the rollout never lost. BH-682:
# the lib's modules are the lib — same calls, same lane, same identity — so the
# rule covers them too, and a later carving slice cannot quiet this guard by
# declaring one of them raw instead of keeping it inside the lib's arming.
# BH-478's stage modules are the driver for exactly the same reason.
ARMED_FILES="lib/merge-conductor-lib.sh blocked-resolver.sh merge-queue.sh run-build.sh"
for MOD in "$DIR"/bin/lib/mc/*.sh; do
  [ -f "$MOD" ] && ARMED_FILES="$ARMED_FILES lib/mc/$(basename "$MOD")"
done
for MOD in "$DIR"/bin/lib/rb/*.sh; do
  [ -f "$MOD" ] && ARMED_FILES="$ARMED_FILES lib/rb/$(basename "$MOD")"
done
for MP in $ARMED_FILES; do
  MK=$(awk -F'\t' -v f="$MP" '$1==f{print $4}' "$T/rows.tsv")
  case "$MK" in
    raw-pat|raw-by-design)
      bad "$MP arms its gh calls (#438; the mc/ and rb/ modules through the script that sources them) and must not declare itself $MK" ;;
  esac
  grep -qxF "$MP" "$T/reg.txt" \
    && bad "$MP arms its gh calls and must not have a conversion-registry entry"
  grep -qxF "$MP" "$T/byd.txt" \
    && bad "$MP arms its gh calls and must not have a by-design-registry entry"
done
ok

# ══ 5. the LIB really arms: source it and read GH_TOKEN ════════════════════
# Not a grep for mc_use_token's body. The lib is sourced into a scratch $HARNESS
# that has an App env file and a gh-token.sh printing a stub token, and what is
# asserted is the value GH_TOKEN actually holds afterwards.
L="$T/lib5"
mkdir -p "$L/bin/lib" "$L/env" "$L/logs"
cp "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$L/bin/lib/"
mkdir -p "$L/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$L/bin/lib/mc/"
printf '#!/bin/bash\nprintf ghs_stub\n' > "$L/bin/gh-token.sh"; chmod +x "$L/bin/gh-token.sh"
: > "$L/env/github-app.env"

lib_drive() { # lib_drive <code> — source the lib under $L with GH_TOKEN=pattok
  ( export HARNESS="$L" GH_TOKEN=pattok
    # shellcheck source=/dev/null
    . "$L/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
    eval "$1" ) 2>/dev/null
}
OUT=$(lib_drive 'mc_use_token Acme/x; printf "rc=%s tok=%s" "$?" "${GH_TOKEN:-unset}"')
[ "$OUT" = "rc=0 tok=ghs_stub" ] && ok \
  || bad "block 5: mc_use_token must export the App token for the slug, got '$OUT'"
OUT=$(lib_drive 'mc_use_token Acme/x; mc_reset_token; printf "rc=%s tok=%s" "$?" "${GH_TOKEN:-unset}"')
[ "$OUT" = "rc=0 tok=pattok" ] && ok \
  || bad "block 5: mc_reset_token must put back the token the process started with, got '$OUT'"
mv "$L/env/github-app.env" "$L/env/github-app.env.off"
OUT=$(lib_drive 'mc_use_token Acme/x; printf "rc=%s tok=%s" "$?" "${GH_TOKEN:-unset}"')
[ "$OUT" = "rc=0 tok=pattok" ] && ok \
  || bad "block 5: on an unarmed box mc_use_token must rc 0 and leave GH_TOKEN alone, got '$OUT'"
mv "$L/env/github-app.env.off" "$L/env/github-app.env"
# The helper missing entirely (a box whose harness sync has not landed it).
OUT=$( env -u GH_TOKEN bash -c \
       'HARNESS="$2"; . "$1/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1
        mc_use_token Acme/x; printf "rc=%s tok=%s" "$?" "${GH_TOKEN:-unset}"' _ "$DIR" "$T/no-harness" 2>/dev/null )
[ "$OUT" = "rc=0 tok=unset" ] && ok \
  || bad "block 5: with no helper on the box mc_use_token must rc 0 and touch nothing, got '$OUT'"

# ══ 6. the RESOLVER's own wrappers, extracted verbatim ═════════════════════
# The `# >>> br-token` / `# <<< br-token` markers in bin/blocked-resolver.sh are
# the contract: this block evaluates the production text, not a copy of it, and
# stubs the four helpers to record the ORDER they are called in.
BRBLK=$(awk '/^# >>> br-token/{f=1;next} /^# <<< br-token/{exit} f' "$DIR/bin/blocked-resolver.sh")
if [ "$(grep -c 'br_use_token' <<<"$BRBLK")" -ge 1 ] && [ "$(grep -c 'br_reset_token' <<<"$BRBLK")" -ge 1 ]; then
  ok
else
  bad "block 6: the # >>> br-token block in bin/blocked-resolver.sh is missing or empty — nothing was extracted to drive"
fi
# The extracted block logs through the resolver's say(), which the extract does
# not carry. Unstubbed, a bare `say` is /usr/bin/say on macOS and reads the log
# line aloud; a recorder sits first on PATH so a missing stub fails, silently.
mkdir -p "$T/say-bin"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$T/os-say.log" > "$T/say-bin/say"
chmod +x "$T/say-bin/say"
: > "$T/os-say.log"
br_drive() { # br_drive <gh_auth_for-rc|none> <call...>
  local APPRC="$1"; shift
  ( : > "$T/br.log"; PATH="$T/say-bin:$PATH"
    if [ "$APPRC" != none ]; then
      eval "gh_auth_for() { echo \"gh_auth_for \$1\" >> \"\$T/br.log\"; return $APPRC; }"
      gh_auth_reset() { echo gh_auth_reset >> "$T/br.log"; return 0; }
    fi
    gh_repo_use_token()   { echo "gh_repo_use_token $1" >> "$T/br.log"; return 0; }
    gh_repo_token_reset() { echo gh_repo_token_reset >> "$T/br.log"; return 0; }
    say() { :; }
    eval "$BRBLK"
    "$@" >/dev/null 2>&1; echo "rc=$?" >> "$T/br.log"
    tr '\n' ' ' < "$T/br.log" )
}
OUT=$(br_drive 0 br_use_token Acme/x)
[ "$OUT" = "gh_auth_for Acme/x rc=0 " ] && ok \
  || bad "block 6: with the App token available br_use_token must arm it and stop there, got '$OUT'"
OUT=$(br_drive 1 br_use_token Acme/x)
[ "$OUT" = "gh_auth_for Acme/x gh_repo_use_token Acme/x rc=0 " ] && ok \
  || bad "block 6: when the App token is not available br_use_token must fall to today's PAT probe, got '$OUT'"
OUT=$(br_drive none br_use_token Acme/x)
[ "$OUT" = "gh_repo_use_token Acme/x rc=0 " ] && ok \
  || bad "block 6: with no gh-app-auth.sh on the box br_use_token must behave exactly as it did before, got '$OUT'"
OUT=$(br_drive 0 br_reset_token)
[ "$OUT" = "gh_auth_reset gh_repo_token_reset rc=0 " ] && ok \
  || bad "block 6: br_reset_token must undo BOTH tokens, App first, got '$OUT'"

[ ! -s "$T/os-say.log" ] && ok \
  || bad "block 6: the extracted br-token block reached the system say command (macOS speaks it aloud): $(tr '\n' '|' < "$T/os-say.log") — stub say() in br_drive"

# ══ 7. the QUEUE really arms: run the script and read the token gh saw ═════
# bin/merge-queue.sh names no helper file — it arms through the lib — so the
# only honest proof is the identity its gh calls actually go out on. The fake gh
# logs "$GH_TOKEN $*" per call; the fixture is tests/merge-queue-db-test.sh's
# section 1 (one queued row, a CLOSED PR) with an App env added.
QH="$T/q/h"; QB="$T/q/fakebin"
mkdir -p "$QH/bin/lib" "$QH/logs" "$QH/flags" "$QH/locks" "$QH/builds" "$QH/env" \
         "$QH/state/merge-queue/project-3" "$QB"
cp "$DIR/bin/jobs-client.sh" "$DIR/bin/fleet-conf.sh" "$QH/bin/"
mkdir -p "$QH/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$QH/bin/lib/jobs/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-app-auth.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$QH/bin/lib/"
mkdir -p "$QH/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$QH/bin/lib/mc/"
: > "$QH/env/global.env"
: > "$QH/env/github-app.env"
printf '#!/bin/bash\nprintf ghs_stub\n' > "$QH/bin/gh-token.sh"; chmod +x "$QH/bin/gh-token.sh"
printf 'project-3 example-org/project-3 - - 2 box-project-3-1\n' > "$QH/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$QB/flock"; chmod +x "$QB/flock"
printf '#!/bin/bash\necho 1893456000\n' > "$QB/stat"; chmod +x "$QB/stat"
printf '#!/bin/bash\nexit 0\n' > "$QH/bin/beat.sh"; chmod +x "$QH/bin/beat.sh"
printf '#!/bin/bash\nexit 0\n' > "$QH/bin/deploy-request.sh"; chmod +x "$QH/bin/deploy-request.sh"
cat > "$QB/gh" <<'EOF2'
#!/bin/bash
printf '%s %s\n' "${GH_TOKEN:-unset}" "$*" >> "$GH_CALL_LOG"
case "$*" in
  *"--json state,mergeable,headRefName"*) echo "CLOSED MERGEABLE ticket/x" ;;
  *"--json state"*)                       echo "CLOSED" ;;
  *)                                      echo "" ;;
esac
exit 0
EOF2
chmod +x "$QB/gh"
cat > "$QB/curl" <<'EOF2'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/merge-queue\?*) printf '{"merge_queue":[{"project":"project-3","pr":41,"status":"queued","repo":"example-org/project-3","enqueued_by":"hub","enqueued_at":"2026-09-10T01:00:00Z","reason":"tier-1 APPROVE from pool build TK-9"}]}\n200\n' ;;
  */api/flags/*)        printf '{"error":"not found"}\n404\n' ;;
  *)                    printf '{"ok":true}\n200\n' ;;
esac
EOF2
chmod +x "$QB/curl"
queue_run() { # queue_run — drive the real script, GH_TOKEN=pattok going in
  rm -f "$QH/state/merge-queue/project-3/41" "$QH/logs/merge-queue.log"
  : > "$T/q/gh-calls.txt"
  ( export PATH="$QB:$PATH" HARNESS="$QH" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=box-project-3-1 JOBS_RETRIES=0 \
           GH_TOKEN=pattok GH_CALL_LOG="$T/q/gh-calls.txt"
    bash "$DIR/bin/merge-queue.sh" project-3 >/dev/null 2>&1 )
}
tok_lines() { # tok_lines <token> — how many logged calls went out on it
  local n; n=$(grep -c "^$1 " "$T/q/gh-calls.txt" 2>/dev/null) || n=0; printf '%s' "$n"
}
call_lines() { local n; n=$(grep -c . "$T/q/gh-calls.txt" 2>/dev/null) || n=0; printf '%s' "$n"; }
if command -v jq >/dev/null 2>&1; then
  queue_run
  NCALL=$(call_lines)
  [ "$NCALL" -ge 1 ] && ok \
    || bad "block 7: the queue fixture made no gh call at all — nothing was proved about its identity"
  [ "$NCALL" -ge 1 ] && [ "$(tok_lines ghs_stub)" = "$NCALL" ] && ok \
    || bad "block 7: every gh call the armed queue makes must go out on the App token; $(tok_lines ghs_stub)/$NCALL did"
  grep -rqs ghs_stub "$QH/logs" && bad "block 7: a token value reached $QH/logs — the ratchet's own rule is that no log carries one" || ok
  # Unarmed: same script, no App env file, and every call is the PAT again.
  mv "$QH/env/github-app.env" "$QH/env/github-app.env.off"
  queue_run
  NCALL2=$(call_lines)
  [ "$NCALL2" -ge 1 ] && [ "$(tok_lines pattok)" = "$NCALL2" ] && ok \
    || bad "block 7: on an unarmed box the queue must still run, on the PAT; $(tok_lines pattok)/$NCALL2 did"
  mv "$QH/env/github-app.env.off" "$QH/env/github-app.env"
  # The reset before the final `exit 0` cannot be OBSERVED from outside the run:
  # the exported token dies with the process either way. It is pinned by source
  # text for that reason alone, and the pin names what it did find so an absent
  # marker fails loudly instead of matching nothing and passing.
  QTAIL=$(grep -vE '^[[:space:]]*(#|$)' "$DIR/bin/merge-queue.sh" | tail -2 | tr '\n' ' ')
  case "$QTAIL" in
    *mc_reset_token*exit\ 0*) ok ;;
    *) bad "block 7: the queue must reset the token on its last line before exit 0; its last two code lines are '$QTAIL'" ;;
  esac
else
  echo "block 7: jq missing — the queue fixture needs it, as tests/merge-queue-db-test.sh does"
fi

# ── strict mode says so out loud ────────────────────────────────────────────
if [ "$STRICT" = 1 ]; then
  echo "GH_APP_RATCHET_STRICT=1: the $REG_COUNT registered raw files are:"
  sed 's/^/  /' "$T/reg.txt"
fi

echo "gh-app-ratchet-test: $PASS pass, $FAIL fail ($REG_COUNT raw files still in the registry, $BYD_COUNT raw-by-design)"
[ "$FAIL" -eq 0 ]
