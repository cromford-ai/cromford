#!/usr/bin/env python3
"""bin/config-inventory.py — BH-1511.0: classify every `${VAR:-literal}` read
and every hardcoded endpoint literal in the harness, so #1511's later slices
know which ones convert to settings rows and which don't.

Invoked by bin/config-inventory.sh (the entry point CI and a human run). This
file does the scanning and classification; the wrapper resolves paths and
prints the summary line.

NO NETWORK, NO GIT WRITE. Reads the tree it is pointed at and writes exactly
the files under --out. Its renders are generated and git-ignored (BH-5518):
nothing under docs/config-inventory/ is committed, and every reader renders
first. `bin/config-inventory.sh --check` is how they are kept honest — two
renders of the same tree must be byte-identical — see
tests/config-inventory.bh-1511-test.sh section 6 (no writes under --root) and
section 8 (determinism).

WHAT IT SCANS. Variables: bin/, fly/, cron/ (the set #1511 measured 2,256
`${VAR:-literal}` reads over). Endpoints: bin/, fly/, worker/jobs/src,
console-ui/src (the broader set #1511's endpoint line names). Both exclude
tests/*, anything under a tests/ or test/ directory, and *-test.sh / *.test.*
files — the same file-shape tests/test-determinism-lint.sh already uses, so
this generator and that lint agree on what "a test" is.

CLASSIFICATION, IN ORDER (the ticket's four required rules, plus the registry
and secret checks the repo already enforces elsewhere):
  1. ALREADY_REGISTERED — env name is a `.knobs[].env` in some catalog/lanes.d/
     *.json file (excluding _registry.json, which is the schema note, not a
     lane). This is the source of truth section 7's own scan reads, not the
     lead's scratch snapshot — this generator recomputes it every run.
  2. SECRET — name ends in TOKEN/SECRET/PASSWORD/CREDENTIAL(S)/KEY/PAT. This is
     tests/lanes-registry-test.sh section 13's own shape, widened by the PAT
     suffix #1511's ticket body names explicitly.
  3. BOX_LAYOUT — a known box-layout name (HARNESS and its aliases, the repo
     paths every lane resolves relative to it) OR a default value that is
     itself a filesystem path rooted at /root, /tmp, ./ or $HARNESS.
  4. TEST_HOOK — assigned only inside tests/ (an `export FOO=` or `FOO=` line
     in a tests/*.sh or tests/mc/*.sh file) and never assigned by production
     code itself. This is what "set only by tests" means operationally: the
     seam a test pokes to control behaviour it does not own. Three kinds of
     KNOB EVIDENCE beat a test assignment: a production self-init, any
     non-empty production default, and (BH-1530) an in-code fallback — a read
     whose literal default is empty because the real one is the next argument
     to a knob helper, the clamp below it, or the "treating as N" message
     beside it (see fallback_shape()). A name the reading file itself assigns
     is never a test hook either, whatever a test does with it: it is rule 5.
  5. PLUMBING (self-assigned) — the SAME production file that reads
     `${NAME:-default}` also assigns NAME itself (`NAME=`, `local NAME=`,
     `for NAME in`, `read ... NAME`, `export NAME=`) — the section 7 shape:
     "assigned then read in the same function," widened to "same file" because
     a bash local can cross function boundaries in this codebase and a
     same-function AST is not worth building for a signal this cheap to get
     another way (see also the curated PLUMBING allowlist below). The
     self-init idiom itself (`NAME="${NAME:-default}"`) is NOT an assignment
     for this purpose — it is the knob declaring itself — but only as many
     times as it appears: `X=$(cmd); X="${X:-0}"` on one line is one real
     assignment plus one self-init, and X is plumbing (BH-1530).
  6. PLUMBING (known list) — ported verbatim from tests/lanes-registry-test.sh's
     own PLUMBING allowlist (BH-1132/1269), which is already a reviewed,
     merged judgement about which repo-wide names are outputs, identities or
     box layout rather than knobs.
  7. Everything else: if the name matches the repo's own hazard shape (the HAZ
     regex tests/lanes-registry-test.sh section 17 uses to gate what a
     settings row may drive into a root lane — command/host/path/identity
     suffixes) it is genuinely ambiguous from source alone, so a second pass
     (MANUAL_SUFFIX_RULES below) applies suffix-level judgement this generator
     author made by reading the surrounding code for a representative sample
     of each suffix family, tagged "manual:<reason>" so it is honest about
     being a rule, not a per-instance read of all ~900 names. A hazard-shaped
     name no suffix rule covers is UNDECIDED — the ticket's own bucket for
     "the rules cannot decide," left for a human to resolve reading the code
     directly, never silently defaulted to CONFIG.
  8. A name with no hazard shape and none of the above is CONFIG — the
     residual: a plain value (a count, a seconds, a percent, a USD figure, a
     flag) with nothing else it could be, i.e. exactly the "should be a
     settings row" case #1511 exists for.

Endpoint literals get their own, much simpler pass: every https?:// URL or
known bare vendor hostname literal (not read from a variable) in the scanned
files, tagged CONFIG (a call target) when the surrounding line looks like it
drives a network call (curl/fetch/wget/axios/requests/urllib/Request/
base_url=/os.environ.get/process.env/bash's own `api_get "…"`, any assignment
`name = <url>` regardless of the name, or — BH-1530 — a URL that is the
DEFAULT of a variable read, `X="${X:-https://…}"`, which is a call target the
variable side already carries) and DOC (documentation, a regex/pattern
literal, a log/echo string, or an interpolated github.com link to a
pull/issue/run/commit PAGE, which is a link a human clicks and not an address
this code calls) otherwise.

SLICING. The proposed conversion slices are cut so that ONE FILE BELONGS TO
ONE SLICE: vars are partitioned into file-connected components (share a read
file, share a slice) before anything else, so two independent slices can never
conflict when their PRs are built in parallel. A component too large for the
≤40-knob / ≤12-file caps cannot honour both rules, so it is cut into a serial
chain (`serial_group` / `order` / `blocked_by`) whose links are built one
after another — see build_slices().

NOT A CLASS (BH-1530, R2-N5). Two families of names look like settings and
are not, and this generator deliberately mints no class for them — they land
in CONFIG or TEST_HOOK like anything else, and a slice author drops them on
sight. CALLER-SUPPLIED CONTEXT: `COST_KEY`, `COST_JOB`, `COST_PROJECT`,
`COST_STAGE`, `COST_ACCT_NAME`, `BUILD_ATTEMPT`, `COST_RUN_ID` — values the
caller hands the script for this invocation, never an operator setting.
OUTPUT/STATUS: `JOBS_BODY`, `JOBS_TRANSCRIPT_TRUNCATED`, `JOB_REFUSED`,
`LLM_GATE_REASON`, `SRC` — values the code computes and passes back out. A
settings row for either is a row nobody can usefully set. A class of their own
would change the `by_class` schema every consumer reads, so if one is ever
wanted it is its own slice, not a side effect of this one.

NOT DETECTED (BH-1511 review M5, kept small and out of scope for this slice):
default idioms other than bash's `${VAR:-literal}` — Python's
`os.environ.get('X', 'literal')` used WITHOUT a call-shaped context on the
same line, JS's `process.env.X || 'literal'` outside the `||`/`&&`/`?`
shapes CALL_SHAPE_RE knows, bash's `${VAR:=literal}` (assign-if-unset) and
`${VAR-literal}` (unset-only, no `:`). A handful of sites (~19, spot-checked)
carry one of these; a future slice can extend extract_defaults() for them.
"""
import html
import json
import os
import re
import subprocess
import sys
from collections import defaultdict

# ── file selection ───────────────────────────────────────────────────────────

VAR_SCAN_DIRS = ["bin", "fly", "cron"]
ENDPOINT_SCAN_DIRS = ["bin", "fly", "worker/jobs/src", "console-ui/src"]

TEST_PATH_RE = re.compile(r'(^|/)tests?(/|$)')


def is_test_path(rel):
    parts = rel.split("/")
    if "tests" in parts or "test" in parts:
        return True
    base = os.path.basename(rel)
    if base.endswith("-test.sh"):
        return True
    if ".test." in base:
        return True
    return False


TEXT_EXT = {".sh", ".bash", ".js", ".mjs", ".cjs", ".py", ".cron", ""}

# This generator's own two files are excluded from being SCANNED (they are
# never excluded from running — see bin/config-inventory.sh). Their comments
# and docstrings use `${VAR:-literal}` and `${NAME:-default}` as illustrative
# syntax dozens of times, which is real `${…:-…}` text to a regex that cannot
# tell documentation from a shell read — scanning them fabricated four
# variables (A, B, NAME, VAR) out of prose before this exclusion was added.
SELF_EXCLUDE = {"bin/config-inventory.py", "bin/config-inventory.sh"}


def iter_files(root, dirs):
    out = []
    for d in dirs:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [dn for dn in sorted(dirnames) if dn != "node_modules"]
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, root)
                if is_test_path(rel):
                    continue
                if rel in SELF_EXCLUDE:
                    continue
                ext = os.path.splitext(fn)[1]
                if ext not in TEXT_EXT:
                    continue
                out.append(rel)
    return out


# ── variable extraction ──────────────────────────────────────────────────────

VAR_OPEN_RE = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-')


def strip_comment(line):
    # section 7's own shape: strip a trailing `  # …` and a comment-only line.
    if re.match(r'^\s*#', line):
        return ""
    return re.sub(r'[ \t]#[ \t].*$', '', line)


def extract_defaults(line):
    """Yield (varname, default_text) for every ${VAR:-default} on a line,
    tracking brace depth so a nested ${A:-${B:-c}} default is captured whole
    rather than truncated at the first `}`."""
    out = []
    for m in VAR_OPEN_RE.finditer(line):
        name = m.group(1)
        i = m.end()
        depth = 1
        buf = []
        while i < len(line) and depth > 0:
            c = line[i]
            if c == '{':
                depth += 1
                buf.append(c)
            elif c == '}':
                depth -= 1
                if depth == 0:
                    break
                buf.append(c)
            else:
                buf.append(c)
            i += 1
        out.append((name, "".join(buf)))
    return out


ASSIGN_RE = re.compile(
    r'(?:^|[\s;&|(])(?:export\s+|local\s+|declare\s+(?:-[A-Za-z]+\s+)?)?'
    r'([A-Za-z_][A-Za-z0-9_]*)='
)
FOR_RE = re.compile(r'(?:^|\s)for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\b')

# read's OPTIONS that take their own argument, so the token right after one is
# never a variable name (`read -t 5 X` must not register "5").
READ_OPTS_WITH_ARG = {"-p", "-d", "-n", "-N", "-t", "-u", "-i"}
READ_CMD_RE = re.compile(r'(?:^|[\s;&|(])read\b')
READ_TERM_RE = re.compile(r'<<<|<<|<|>|\||;|&&|\|\||\bdo\b|\bthen\b')


def blank_quoted(line):
    """Return `line` with the CONTENTS of every '...'/"..." string replaced by
    spaces (quotes kept, length preserved so column positions still line up).
    Used only ahead of assignment/loop/read detection (BH-1511 review B4): a
    log line like `echo "tick: NAME=$NAME"` or a QA note
    `"...(NAME=0, warn only)"` contains the exact shape `NAME=` inside a
    STRING, and a regex that doesn't know about quoting reads it as a real
    assignment. extract_defaults() never sees this version — a real
    `${NAME:-default}` read commonly lives inside a quoted string
    (`X="${X:-5}"`) and must still be found there."""
    out = []
    i = 0
    n = len(line)
    q = None
    while i < n:
        c = line[i]
        if q:
            if c == '\\' and q == '"' and i + 1 < n:
                out.append('  ')
                i += 2
                continue
            if c == q:
                out.append(c)
                q = None
            else:
                out.append(' ')
            i += 1
            continue
        if c in ('"', "'"):
            q = c
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def read_assigned_names(code):
    """Every identifier `read` (or `read -r`, `IFS=x read -r A B C`, …)
    assigns, for a multi-name read — BH-1511 review B5. The prior single
    `\\S+$`-anchored regex caught only the LAST name on the line, so
    `while IFS=$'\\t' read -r A B C; do` registered none of A, B or C as
    assigned, and each one it also happened to read with a `${X:-default}`
    fallback landed in CONFIG as a fabricated settings-row candidate."""
    names = set()
    for m in READ_CMD_RE.finditer(code):
        rest = code[m.end():]
        term = READ_TERM_RE.search(rest)
        segment = rest[:term.start()] if term else rest
        toks = segment.split()
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.startswith('-') and t != '-':
                if t in READ_OPTS_WITH_ARG:
                    i += 2
                    continue
                i += 1
                continue
            if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', t):
                names.add(t)
            i += 1
    return names


def assigned_names(line):
    """Candidate assignment targets on `line`, quote-blanked first (B4a) so a
    `NAME=` inside a log/echo string is never mistaken for a real one."""
    blanked = blank_quoted(line)
    names = set()
    for m in ASSIGN_RE.finditer(blanked):
        names.add(m.group(1))
    for m in FOR_RE.finditer(blanked):
        names.add(m.group(1))
    names |= read_assigned_names(blanked)
    return names


CLAMP_RHS_RE_TMPL = r'(?:^|[\s;&|(])(?:export\s+|local\s+)?{name}=([A-Za-z0-9_./:-]+)\s*(?:[;&|)]|$)'


def clamp_matches_default(code, name, known_defaults):
    """True when THIS assignment of `name` on `code` is a validation-clamp
    idiom (`case "$X" in ''|*[!0-9]*) X=60 ;; esac`) restating a default the
    var already carries elsewhere, not a genuinely different local value —
    BH-1511 review B4b. Only fires for a BARE literal RHS (no `$`, no command
    substitution) that equals one of the var's own known defaults; a clamp to
    a DIFFERENT literal (a real re-derivation) still counts as plumbing
    evidence, same as before."""
    if not known_defaults:
        return False
    for m in re.finditer(CLAMP_RHS_RE_TMPL.format(name=re.escape(name)), code):
        if m.group(1) in known_defaults:
            return True
    return False


def self_init_counts(code, default_names):
    """name -> HOW MANY self-init assignments (`NAME="${NAME:-default}"` /
    `local NAME=${NAME:-default}`) this line carries, for names in
    `default_names`. That idiom is the one nearly every top-level config
    default in this codebase uses to declare itself: it is NOT the "assigned
    then read" plumbing shape (an output var, a loop var, a local computed
    from something else), it is the opposite — the line IS the knob
    declaration, so it must not count as the var assigning itself.

    BH-1530 (R2-N2): this COUNTS rather than just detecting, because a line
    can hold both shapes at once — `X=$(wc -l < f); X="${X:-0}"` is one real
    assignment (X is a computed local) plus one self-init. The caller
    compares this count against the line's total assignments of the name and
    only skips the self-init ones; the prior version returned a SET and the
    caller dropped every assignment of a name in it, so the real `X=$(…)`
    vanished and 15 locals (BEFORE, VCUR, DEFER, LN0, …) were filed as
    settings-row candidates."""
    out = {}
    for name in default_names:
        pat = (
            r'(?:^|[\s;&|(])(?:export\s+|local\s+|declare\s+(?:-\S+\s+)?)?'
            + re.escape(name) + r'=\s*"?\$\{' + re.escape(name) + r':-'
        )
        n = len(re.findall(pat, code))
        if n:
            out[name] = n
    return out


# BH-1530 (R2-N4): three code shapes that say "this empty `${NAME:-}` read is
# a KNOB whose real default lives in code," not a test seam:
#   (i)   a knob helper is handed the name       `br_knob_num X "${X:-}" 12`
#                                                `num_or "${X:-}" 14`
#   (ii)  a validation clamp reads it            `case "${X:-}" in ''|*[!0-9]*) X=45 ;;`
#   (iii) a validation message restates it       `X='${X:-}' is not a number — treating as 600`
# Deliberately NARROW: an equality compare (`[ "${X:-}" = 1 ]`) is exactly how
# a genuine seam like HARNESS_TEST_SANDBOX is read too, and a helper handed a
# `$X` EXPANSION (`num_or "$X" 5`) is a value passed by a caller, not the
# name declaring its own default — neither is evidence.
FALLBACK_HELPER_TMPL = r'\b(?:br_knob_num|knob_num|num_or|[a-z][a-z_]*_num)\s+(?:["\']?\$\{{)?{name}\b'
FALLBACK_CASE_TMPL = r'\bcase\s+"?\$\{{{name}:-[^}}]*\}}"?\s+in\b'
FALLBACK_ISNOT_TMPL = r'{name}=[\'"]?\$\{{{name}:-[^}}]*\}}[\'"]?\s+is not\b'


def fallback_shape(code, name):
    """True when `code` carries one of the three in-code-fallback shapes for
    `name` — see FALLBACK_HELPER_TMPL above."""
    n = re.escape(name)
    for tmpl in (FALLBACK_HELPER_TMPL, FALLBACK_CASE_TMPL, FALLBACK_ISNOT_TMPL):
        if re.search(tmpl.format(name=n), code):
            return True
    return False


def scan_variables(root):
    """Two passes over the same file list, because the clamp filter (B4b)
    needs every var's FULL default set — gathered from files scanned later —
    before it can decide whether an earlier `NAME=<literal>` was a real
    assignment or a validation clamp restating a default the var already has.
    Returns (records, self_assigned, self_init_vars): the last is every name
    with at least one production self-init site, used by classify()'s
    TEST_HOOK rule (B3) as knob evidence that beats a test-only assignment."""
    files = iter_files(root, VAR_SCAN_DIRS)
    file_lines = {}
    records = defaultdict(list)          # varname -> [ {file, line, default, raw} ]
    self_init_vars = set()               # varname -> has a production self-init site
    raw_candidates = []                  # (varname, file, blanked_code) — filtered below

    for rel in files:
        try:
            with open(os.path.join(root, rel), "r", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        file_lines[rel] = lines
        for lineno, raw in enumerate(lines, 1):
            code = strip_comment(raw.rstrip("\n"))
            if not code:
                continue
            defaults_here = extract_defaults(code)
            default_names = {n for n, _ in defaults_here}
            self_init = self_init_counts(code, default_names)
            self_init_vars |= set(self_init)
            for name, default in defaults_here:
                records[name].append({
                    "file": rel, "line": lineno,
                    "default": default.strip(), "text": code.strip(),
                    # BH-1530 (R2-N4): per-site knob evidence for a read whose
                    # literal default is empty because the real one lives in
                    # code. Not written to the JSON — classify() consumes it
                    # and the freshness projection stays as it was.
                    "fallback_shape": fallback_shape(code, name),
                })
            blanked = blank_quoted(code)
            assign_counts = defaultdict(int)
            for m in ASSIGN_RE.finditer(blanked):
                assign_counts[m.group(1)] += 1
            loop_names = {m.group(1) for m in FOR_RE.finditer(blanked)}
            loop_names |= read_assigned_names(blanked)
            # BH-1530 (R2-N2): skip as many assignments as the line has
            # self-inits of that name, not every assignment of a name that
            # has one. A `for`/`read` name is never a self-init shape, so it
            # is always real evidence.
            for name in sorted(set(assign_counts) | loop_names):
                if name not in loop_names and assign_counts[name] <= self_init.get(name, 0):
                    continue
                raw_candidates.append((name, rel, blanked))

    var_defaults = {name: {r["default"] for r in recs} for name, recs in records.items()}
    self_assigned = defaultdict(set)     # varname -> set(files it's ALSO assigned in)
    for name, rel, blanked in raw_candidates:
        if clamp_matches_default(blanked, name, var_defaults.get(name, set())):
            continue
        self_assigned[name].add(rel)
    return records, self_assigned, self_init_vars


def scan_test_assignments(root):
    out = set()
    tdirs = [os.path.join(root, "tests")]
    for tdir in tdirs:
        if not os.path.isdir(tdir):
            continue
        for dirpath, _, filenames in os.walk(tdir):
            for fn in filenames:
                if not (fn.endswith(".sh") or fn.endswith(".bash")):
                    continue
                full = os.path.join(dirpath, fn)
                try:
                    with open(full, "r", errors="replace") as fh:
                        for raw in fh:
                            code = strip_comment(raw.rstrip("\n"))
                            if not code:
                                continue
                            out |= assigned_names(code)
                except OSError:
                    continue
    return out


# ── registered-knob resolution (recomputed, never trusted from a snapshot) ──

def load_registered(root):
    """env -> list of {lane, settable, default, read_in} from catalog/lanes.d/*.json
    and catalog/lanes.d/<owner>.knobs.d/*.json."""
    reg = defaultdict(list)
    d = os.path.join(root, "catalog", "lanes.d")
    if not os.path.isdir(d):
        return reg
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json") or fn == "_registry.json":
            continue
        try:
            with open(os.path.join(d, fn), "r") as fh:
                lane = json.load(fh)
        except (OSError, ValueError):
            continue
        lane_id = lane.get("id") or fn[:-5]
        for knob in lane.get("knobs", []) or []:
            env = knob.get("env")
            if not env:
                continue
            reg[env].append({
                "lane": lane_id,
                "settable": knob.get("settable", True),
                "default": knob.get("default"),
                "read_in": knob.get("read_in"),
            })
    # A knob added as its own file: <owner>.knobs.d/<ENV>.json, one knob object
    # (bin/lanes-build.sh composes it into the owner's knobs).
    for dn in sorted(os.listdir(d)):
        kd = os.path.join(d, dn)
        if not dn.endswith(".knobs.d") or not os.path.isdir(kd):
            continue
        owner = dn[:-len(".knobs.d")]
        for fn in sorted(os.listdir(kd)):
            if not fn.endswith(".json"):
                continue
            try:
                with open(os.path.join(kd, fn), "r") as fh:
                    knob = json.load(fh)
            except (OSError, ValueError):
                continue
            env = knob.get("env") if isinstance(knob, dict) else None
            if not env:
                continue
            reg[env].append({
                "lane": owner,
                "settable": knob.get("settable", True),
                "default": knob.get("default"),
                "read_in": knob.get("read_in"),
            })
    return reg


def load_lane_scripts(root):
    """script path (relative, e.g. bin/alert-triage.sh) -> lane id, for owner
    resolution of a var's read sites."""
    out = {}
    d = os.path.join(root, "catalog", "lanes.d")
    if not os.path.isdir(d):
        return out
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json") or fn == "_registry.json":
            continue
        try:
            with open(os.path.join(d, fn), "r") as fh:
                lane = json.load(fh)
        except (OSError, ValueError):
            continue
        script = lane.get("script")
        lane_id = lane.get("id") or fn[:-5]
        if script:
            out[script] = lane_id
    return out


# ── classification ───────────────────────────────────────────────────────────

SECRET_RE = re.compile(r'(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIALS?|KEY|PAT|DSN)$')

# BH-1511 review M2: a bare `KEY` suffix also matches a dedup/lookup
# identifier — a ticket key, a cache key, a pin — that is not a credential at
# all. Reviewed by reading each read site: none of these hold a value that
# authenticates anything, and PIN itself is a passphrase a member types in
# (not a system secret this repo holds). Kept narrow (named, not a second
# suffix regex) because the failure mode of getting this wrong the OTHER way
# — a real credential reclassified as CONFIG — is the one that matters; only
# names actually read and confirmed non-secret are listed.
SECRET_FALSE_POSITIVES = {
    "KEY", "TICKET_KEY", "LAST_KEY", "CUR_KEY", "COST_KEY",
    "ACCOUNT_PIN_KEY", "MRG_MEMO_KEY", "FC_KEY",
}

# Ported verbatim (names only) from tests/lanes-registry-test.sh's own
# PLUMBING allowlist (BH-1132/1269) — a reviewed judgement this generator
# reuses rather than re-deriving. BH-1511 review M6: LANE_GATE_CACHE_S,
# LANE_GATE_LOG_EVERY_S, CI_LOG_BYTES, BR_ADJ_NOVERDICT_MAX,
# BR_ENQUEUE_FAIL_MAX and BR_SATURATED_TICKS read as knob-shaped (numeric
# tunables) rather than pure outputs/identities — kept here because the list
# is a REUSED, already-reviewed judgement this generator did not re-derive,
# but flagged so a `.N` conversion slice re-checks them against the source
# before trusting PLUMBING at face value.
KNOWN_PLUMBING = set("""
HARNESS H HENV TMPDIR FLEET_CONF REPOS_ROOT GH_TOKEN HARNESS_SECRET
CONSOLE_URL FLY_BIN_DIR JOB_ID JOB_BEAT BASH_SOURCE POOL_APP BR_SSH MC_TICK_ID
MC_RR_PATH MC_FLAKE MC_FLAKE_RUNG MC_IDENTITY_BLOCKED MC_INQUEUE_STATES
MC_LIST_INQUEUE ACCOUNT_EXHAUST_REGEX LANE_REGISTRY LANE_GATE_NOW MRG_FLAG
MC_REPOS MC_GIT_NAME MC_GIT_EMAIL GH_REST_STATUS GH_REST_REASON ISSUE_CLOSE_ERR
LANE_GATE_CACHE_S LANE_GATE_LOG_EVERY_S LANE_GATE_DISABLE CI_LOG_BYTES
LANE_PAUSED_WHY LANE_PAUSED_FLAG LANE_PAUSED_SOURCE LANE_GATE_CHECKED
CI_LOG_RUNS BR_ENQUEUE_WHY BR_ADJ_NOVERDICT_MAX BR_ENQUEUE_FAIL_MAX
BR_SATURATED_TICKS PREPLAN_RELAY_DIR DEFER_FAMS HELD_ALERTS
""".split())

# BOX_LAYOUT: known repo-root-relative names beyond HARNESS itself.
KNOWN_BOX_LAYOUT = set("""
HARNESS H HENV DISK_CLEAN_REPOS WORKTREES HUB_BOX_NAME
""".split())

# Bash's own special/builtin variables and the CI platform's own env
# (GitHub Actions runner vars) — never a knob this repo could register, no
# matter what shape the name has. `${BASHPID:-$$}`-style reads of these show
# up because a script wants a fallback when a builtin is unset under an older
# shell, not because the harness owns the value.
SHELL_AND_CI_BUILTINS = set("""
BASHPID BASH_SOURCE BASH_VERSION PPID RANDOM SECONDS LINENO FUNCNAME IFS
PATH HOME PWD OLDPWD HOSTNAME USER SHLVL TERM EDITOR LANG LC_ALL TZ OSTYPE
UID EUID GROUPS HOSTTYPE MACHTYPE OPTARG OPTIND REPLY
CI GITHUB_ACTIONS GITHUB_WORKSPACE GITHUB_REPOSITORY GITHUB_SHA GITHUB_REF
GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_ACTOR GITHUB_TOKEN GITHUB_EVENT_NAME
GITHUB_EVENT_PATH GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY GITHUB_HEAD_REF
GITHUB_BASE_REF RUNNER_TEMP RUNNER_OS RUNNER_ARCH RUNNER_NAME RUNNER_DEBUG
FLY_APP_NAME FLY_REGION FLY_ALLOC_ID FLY_MACHINE_ID FLY_PUBLIC_IP FLY_PRIVATE_IP
FLY_VM_MEMORY_MB FLY_IMAGE_REF FLY_PROCESS_GROUP
""".split())

# BH-1511 review M3: $H/, $HENV/ and $HOME/ are the three other spellings this
# codebase uses for a box-relative path (`$H` = `$HARNESS` short alias, `$HENV`
# = the env dir under it, `$HOME` = the account's home — /root on every box).
BOX_PATH_RE = re.compile(
    r'^(\.?/(root|tmp)\b|\./|\$\{?(HARNESS|H|HENV|HOME)\b)'
)

# tests/lanes-registry-test.sh section 17's HAZ regex, verbatim — the shape a
# hazard-suffixed name has, used the same way that section uses it: to flag
# "needs a human's read of the code," not to itself decide CONFIG vs not.
HAZ_RE = re.compile(
    r'(^|_)(SSH|CMD|CALL|BIN|FETCH|GH|CLIENT|URL|BASE|HOOK|WEBHOOK|DIR|ROOT|ROOTS|'
    r'PATH|FILE|REPOS|REPO|PROC|BOX|BOXES|LIB|SOURCES|CATALOG|SNAPSHOT|BASELINE|'
    r'FIXTURES|LOG|ALERTS|CHECKOUT|HTTP|BUCKET|REGION|NOW|AT|CONF|PRICES|LOGINS|'
    r'BRANCH|AUTHOR|AUTHORS|ID|PROJECTS|WORKTREES|RUNNER|APP)$|^RUNNER_|^HUB_BOX_NAME$'
)

# Suffix-level manual judgement (see module docstring point 7). Order matters:
# first match wins. Each entry: (compiled suffix regex, class, reason).
MANUAL_SUFFIX_RULES = [
    (re.compile(r'^RUNNER_|(^|_)RUNNER$'), "CONFIG", "manual:runner-lever — names a runner out of the closed agent-call.sh list, the same shape section 17 already carves out as a business lever (HOUSEKEEPING_RUNNER, RUNNER_TRIAGE); overlaps #1510's model_routes.runner field — a conversion slice should reconcile with that ticket rather than mint a duplicate knob"),
    (re.compile(r'(^|_)(URL|BASE|HOOK|WEBHOOK)$'), "CONFIG", "manual:endpoint-like — names a call target; a conversion slice should fold this into the endpoints/service_endpoints work rather than a plain settings row"),
    (re.compile(r'(^|_)(BUCKET|REGION)$'), "CONFIG", "manual:cloud-param — a cloud resource name/region is an operator-editable setting, not box layout"),
    (re.compile(r'(^|_)(DIR|ROOT|ROOTS|REPOS|REPO|WORKTREES|CHECKOUT)$'), "BOX_LAYOUT", "manual:fs-path — a directory this box resolves under, not a value a settings row can move"),
    (re.compile(r'(^|_)(LOG|LOGINS|SNAPSHOT|BASELINE|FIXTURES|CATALOG|SOURCES|CONF|FILE)$'), "BOX_LAYOUT", "manual:file-ref — names a file this box reads/writes on disk"),
    (re.compile(r'(^|_)(SSH|CMD|CALL|BIN|FETCH|GH|CLIENT|LIB|PROC|HTTP)$'), "PLUMBING", "manual:command-or-lib — names a command, client or library the lane invokes, not a tunable value"),
    (re.compile(r'(^|_)(BOX|BOXES|APP|ID|AUTHOR|AUTHORS|PROJECTS|BRANCH)$'), "PLUMBING", "manual:identity — names an identity (a box, an app, an author, a project) this lane claims or targets, not a knob"),
    (re.compile(r'(^|_)(NOW|AT)$'), "PLUMBING", "manual:timestamp — a wall-clock or point-in-time value a lane computes, not one an operator sets"),
    (re.compile(r'(^|_)PATH$'), "BOX_LAYOUT", "manual:fs-path — a filesystem path"),
    (re.compile(r'(^|_)ALERTS$'), "CONFIG", "manual:alerts-param — an alerting threshold/target, operator-editable"),
    (re.compile(r'(^|_)PRICES$'), "CONFIG", "manual:pricing-data — a pricing figure, the exact shape #1511 wants moved out of a bash literal"),
]

# Exact-name overrides: read directly because a suffix/prefix rule could not
# resolve them (or a generic rule would give a less precise reason than the
# actual read site does). This is the "you decide them by reading the code"
# bucket the ticket calls for — named individually because there were only 7
# names left after every rule above ran, not a claim that all ~900 were read
# one by one.
MANUAL_NAME_OVERRIDES = {
    "WARM_ENV_FILE": ("TEST_HOOK", "manual:test-seam — fly/warm-bake.sh's own comment says it plainly (\"WARM_ENV_FILE overrides the path (tests)\", fly/warm-bake.sh:18); tests/warm-bake.bh-1115-test.sh sets it via `env WARM_ENV_FILE=... bash fly/warm-bake.sh`, a dynamic env-prefix this generator's static assignment scan cannot see"),
    "RUNNER_PLAN": ("CONFIG", "manual:runner-lever — selects the build runner (claude|codex|...) for a plan job (bin/run-decompose.sh:117, bin/concurrency-apply.sh:81, bin/run-build.sh:1125); overlaps #1510's model_routes.runner field — a conversion slice should reconcile with that ticket rather than mint a duplicate knob"),
    "RUNNER_PLAN_FALLBACK": ("CONFIG", "manual:runner-lever — fallback runner when RUNNER_PLAN's pick is unavailable (bin/run-decompose.sh:118); same #1510 overlap note as RUNNER_PLAN"),
}

# BH-1530 (R2-N4): names read ONLY as `[ "${X:-}" = <value> ]`, which is the
# same shape a genuine test seam is read with — no regex can separate the two,
# so the handful that are real operator levers are listed by hand rather than
# by widening fallback_shape() and dragging HARNESS_TEST_SANDBOX and its kin
# into CONFIG with them. Honest about being a hand call, one name at a time.
MANUAL_KNOB_EVIDENCE = {
    "GROK_BILLING": "manual:billing-mode lever — `GROK_BILLING=api` switches the xAI key from the SuperGrok subscription pool to metered API billing (bin/billing-mode.sh:52, bin/auth-fingerprint.sh:61); an operator setting with real money behind it, read with an equality compare rather than a default",
}


# BH-1511 review I2: the ORIGINAL check missed a model id that isn't the
# WHOLE default string (`PROMPT_EVAL_MODEL_LIGHT` defaults to
# `${TRIAGE_MODEL_LIGHT:-<model id>}`, a nested reference) — search, not
# match, and drop the anchors.
#
# BH-1530 (R2-N3): `<vendor>-[\w.]+` also matches every OTHER hyphenated word
# a vendor name can start — `claude-auth-down.txt` (a state FILE path) was
# deferred to #1510 as if it were a model id. The shape a model VERSION has
# is narrower than "vendor word, then anything": a family name or a digit.
# Measured against every default on main: claude-fable/opus/sonnet, gpt-6,
# grok-4.x, kimi-k2p* and deepseek-v* all still match; only `claude-auth`
# (MC_LANE_DOWN_FILE) and `gemini-default` drop, and the latter's owner
# (GEMINI_MODEL) is still deferred by its NAME.
MODEL_VALUE_RE = re.compile(
    r'\b(claude-(opus|sonnet|haiku|fable)|gpt-\d|grok-\d|gemini-\d|kimi-k\d|'
    r'deepseek-(v\d|r\d|chat|reasoner))', re.I)

# A `_MODEL_` segment ANYWHERE in the name, not only as a suffix
# (`REVIEW_MODEL_T0` has it in the middle).
MODEL_NAME_RE = re.compile(r'(^|_)MODEL(_|$)')

# `RUNNER`/`RUNNERS` as a whole segment, or `EFFORT` (a model-tier lever,
# `TSH_EFFORT` -> `${GROK_EFFORT:-}`) — both #1510 roles/ladder concepts, not
# generic settings.
RUNNER_NAME_RE = re.compile(r'(^|_)(RUNNERS?|EFFORT)(_|$)')

# BH-1530 (R2-N3): a CI runner is a GitHub Actions machine label, not one of
# #1510's model runners — `CI_RUNNERS`, `CI_RUNNERS_LABEL`, `BATCH_CI_RUNNERS`
# (no `CI_` PREFIX, which is why this matches a whole `CI_RUNNERS` SEGMENT
# anywhere) and `SUITE_RUNNER_LABEL` all read as routing levers under
# RUNNER_NAME_RE and were excluded from #1511's slices for no reason.
CI_RUNNER_NAME_RE = re.compile(r'(^|_)CI_RUNNERS?(_|$)|_RUNNER_LABEL$')

# A name that names BOTH a routing concept (which rung, which ladder tier,
# which fallback) AND a specific vendor is a routing lever even when neither
# word alone would be (`LADDER_TIER2_GROK`) — but a vendor-scoped ordinary
# setting (`GROK_MAX_TURNS`) has no routing word and stays in #1511's scope.
ROUTING_WORD_RE = re.compile(r'(RUNNER|LADDER|TIER\d*|FALLBACK|ROUTING|ROUTE)')
VENDOR_WORD_RE = re.compile(r'(GROK|CODEX|OPENROUTER|FIREWORKS|GEMINI|KIMI|CLAUDE|GPT)')


def is_deferred_to_1510(name, defaults, note):
    """True when a var is model/runner routing, which #1511's own ticket body
    says is out of scope ('Companion to #1510 (models) — this ticket covers
    every other setting'). Kept IN this inventory (every var is accounted
    for) but excluded from #1511's proposed conversion slices so a later
    slice does not mint a knob #1510's model_routes table is meant to own.
    Computed from the NAME and DEFAULTS alone — independent of which class
    (or which rule inside that class) classify() landed on, so a var that
    reaches TEST_HOOK or PLUMBING before ever touching the manual RUNNER rule
    is still correctly flagged (BH-1511 review I2: RUNNER_TRIAGE_FALLBACK,
    RUNNER_CHAT_FALLBACK and RUNNER_EVAL were TEST_HOOK/PLUMBING and leaked
    through undeferred under the prior name.endswith("_MODEL")-only check).

    BH-1530 (R2-N3): a shell/CI builtin is never #1510's either — `RUNNER_TEMP`
    is the GitHub Actions scratch directory and deferred nothing but itself."""
    up = name.upper()
    if up in SHELL_AND_CI_BUILTINS:
        return False
    if MODEL_NAME_RE.search(up):
        return True
    if RUNNER_NAME_RE.search(up) and not CI_RUNNER_NAME_RE.search(up):
        return True
    if ROUTING_WORD_RE.search(up) and VENDOR_WORD_RE.search(up):
        return True
    for d in defaults:
        if d and MODEL_VALUE_RE.search(d):
            return True
    if "#1510" in note:
        return True
    return False


# BH-5518: bin/run-build.sh (BH-478) and bin/run-triage.sh source their stage
# modules into ONE shell, so a local that one module assigns and another reads
# is the same-file case BH-1530 (R2-N4) calls plumbing. Used ONLY to keep such a
# name out of TEST_HOOK: widening the self-assigned rule below with it also
# moved 11 CONFIG names (KIND_SKIP_E2E, SQUASH_OK, ...) out of #1511's slices.
STAGE_MODULE_DRIVERS = {"bin/lib/rb/": "bin/run-build.sh", "bin/lib/rt/": "bin/run-triage.sh"}


def stage_unit(rel):
    for prefix, driver in STAGE_MODULE_DRIVERS.items():
        if rel.startswith(prefix):
            return driver
    return rel


def stage_module_assigned(assigned_files, files_reading):
    """The production files that assign a name inside the same stage-module
    unit (driver + its bin/lib/<rb|rt>/ modules) as a file that reads it."""
    units = {stage_unit(f) for f in files_reading}
    return {f for f in assigned_files if stage_unit(f) in units}


def classify(name, recs, self_assigned, test_assigned, registered, self_init_vars):
    if name in SHELL_AND_CI_BUILTINS:
        return "PLUMBING", "shell-or-ci-builtin", "bash's own special variable or a GitHub Actions runner variable — never a value this repo's registry could hold"

    if name in registered:
        entries = registered[name]
        lanes = sorted({e["lane"] for e in entries})
        return "ALREADY_REGISTERED", "registered", (
            f"registered in catalog/lanes.d for lane(s): {', '.join(lanes)}"
        )

    if SECRET_RE.search(name) and name not in SECRET_FALSE_POSITIVES:
        return "SECRET", "secret-name", "name shape matches TOKEN/SECRET/PASSWORD/CREDENTIAL(S)/KEY/PAT/DSN — stays in sealed env files"

    if name in KNOWN_BOX_LAYOUT:
        return "BOX_LAYOUT", "known-box-layout", "repo-root-relative name every lane resolves against"

    # sorted(): a plain `{...}` set's iteration order is randomized per
    # PYTHON HASH SEED (a fresh interpreter each run) — picking an "example"
    # default straight off the set made this note text flip between runs on
    # an UNCHANGED tree, which is exactly the wall-clock-shaped flakiness
    # tests/test-determinism-lint.sh exists to catch elsewhere, and it is
    # what made tests/config-inventory.bh-1511-test.sh's freshness check
    # (section 6) flake before this line was sorted.
    defaults = sorted({r["default"] for r in recs})
    box_path_defaults = [d for d in defaults if BOX_PATH_RE.search(d)]
    if box_path_defaults:
        return "BOX_LAYOUT", "box-path", f"default is a filesystem path under /root, /tmp, $HARNESS/$H, $HENV or $HOME (e.g. `{box_path_defaults[0]}`)"

    files_reading = {r["file"] for r in recs}
    # BH-1530 (R2-N4): computed BEFORE the TEST_HOOK rule, not after it. Round
    # 1's TEST_HOOK guard included "and not assigned in the reading file";
    # round 2's rewrite dropped it, so a production LOCAL that a test also
    # sets (ADDED_SQL, REPRO_RC, TOK, MSGF, OFF, GH_REST_LIB, QA_NOTE) came
    # back TEST_HOOK — a seam a slice author would go looking for and not
    # find. A name its own reading file assigns is plumbing, full stop; the
    # test assignment says nothing about it.
    same_file_assigned = self_assigned.get(name, set()) & files_reading

    # BH-1511 review B3: the ORIGINAL rule fired for ANY name a test also
    # assigns, which is exactly the set of well-tested knobs
    # (`MC_QUEUE_TTL=0`, `EVIDENCE_BLOCK=1`, …) — a sample of 25 TEST_HOOK
    # records came back 52% real config. A production self-init
    # (`NAME="${NAME:-default}"`, tracked in self_init_vars) or ANY non-empty
    # literal default the production code itself carries is knob evidence
    # that beats a test overriding the same name — TEST_HOOK is reserved for
    # a genuine seam: no self-init anywhere, and every production default
    # for the name is empty. `PR_OWNER_MAX_ACTIONS` (one read site defaults
    # to `""`, another to `5`) is exactly why this checks EVERY default, not
    # just the first one found.
    #
    # BH-1530 (R2-N4): a THIRD kind of knob evidence — an in-code fallback.
    # `br_knob_num BR_SATURATED_TICKS "${BR_SATURATED_TICKS:-}" 12`,
    # `case "${OVERLAP_WAIT_SECS:-}" in` and
    # `E2E_JOIN_MAX_S='${E2E_JOIN_MAX_S:-}' is not a whole number … treating
    # as 600` all read the var with an EMPTY literal default because the real
    # default is the next argument or the clamp below, so the "every
    # production default is empty" half of the rule was true of a dozen real
    # knobs. See fallback_shape() for the exact three shapes and what is
    # deliberately left out.
    has_knob_evidence = (
        name in self_init_vars
        or any(d != "" for d in defaults)
        or any(r.get("fallback_shape") for r in recs)
        or name in MANUAL_KNOB_EVIDENCE
    )
    if name in test_assigned and not has_knob_evidence and not same_file_assigned:
        stage = stage_module_assigned(self_assigned.get(name, set()), files_reading)
        if stage:
            return "PLUMBING", "stage-module-assigned", (
                f"assigned by a stage module of the same driver that reads it ({', '.join(sorted(stage))}) "
                "— a local of one shell split over several files, not a test seam"
            )
        return "TEST_HOOK", "test-only-assignment", "assigned only inside tests/, with no production self-init, no non-empty production default and no in-code fallback anywhere, and never assigned by a file that reads it — a seam a test pokes, not a knob it happens to override"

    if name in KNOWN_PLUMBING:
        return "PLUMBING", "known-plumbing-list", "ported from tests/lanes-registry-test.sh's reviewed PLUMBING allowlist"

    if same_file_assigned:
        # BH-1511 review B4 fixed TWO concrete shapes upstream of this check
        # (self_assigned itself, computed by scan_variables): a `NAME=` INSIDE
        # a quoted log/echo string (SCOPE_GATE_ENFORCE) is blanked before
        # assignment-detection runs, and a validation CLAMP restating the
        # var's own known default (`case … X=3600 ;; esac`,
        # MC_LANE_ROUTED_RETRY_SECS) is excluded as not a distinct value. Both
        # measurably fixed most of the review's named sample without this
        # function needing to know about them.
        #
        # A THIRD shape does not get fixed here on purpose:
        # `TICKET_IDENTITY_GUARD=$(sed … global.env)`/`POOL_SPAWN_CAP=$v`
        # read a fallback source rather than compute a state value, and are
        # real knobs the review wants reclassified — but a version of this
        # function that let "some non-empty default exists somewhere" (or
        # even "a genuine self-init exists somewhere") override self-assigned
        # ALSO promoted `RED_NAMES`, `RUNNING`, `PHASE_USD`, `BEFORE` and
        # `DRIVE_LAST` to CONFIG: real accumulators/status strings that
        # happen to be read with a sane non-empty fallback ("never", "0", "no
        # verdict line") for exactly the same reason a real knob is — that
        # idiom does not distinguish "operator setting" from "defensive
        # default for a computed value," and even restricting the override to
        # names with a genuine self-init did not save `HS_SINCE`
        # (`HS_SINCE="${HS_SINCE:-never}"` IS a syntactically real self-init,
        # over a value read from a status file two lines earlier). Measured:
        # the broad override took a 25-sample PLUMBING check from 0 misses to
        # a majority of a 30-sample CONFIG check being status output, not
        # settings — worse than the bug it fixed. Left as a known, narrow gap
        # (three named examples) rather than risk polluting #1511's
        # conversion slices with state variables.
        return "PLUMBING", "self-assigned", (
            f"assigned by the same file(s) that read it ({', '.join(sorted(same_file_assigned))}) "
            "— a local/loop variable, not an external knob"
        )

    if HAZ_RE.search(name):
        if name in MANUAL_NAME_OVERRIDES:
            cls, reason = MANUAL_NAME_OVERRIDES[name]
            return cls, "manual-name", reason
        for rx, cls, reason in MANUAL_SUFFIX_RULES:
            if rx.search(name):
                return cls, "manual-suffix", reason
        return "UNDECIDED", "hazard-shape-unresolved", (
            "name has a command/host/path/identity suffix (tests/lanes-registry-test.sh "
            "section 17's HAZ shape) that no suffix rule above resolves — needs a human "
            "read of the code"
        )

    if name in MANUAL_KNOB_EVIDENCE:
        # Say so in the artifact rather than only in the source: every other
        # hand call this generator makes is tagged `manual:<reason>` on the
        # record itself, and a slice author reading the JSON should see that
        # this one is a judgement, not a rule that fired.
        return "CONFIG", "manual-knob-evidence", MANUAL_KNOB_EVIDENCE[name]

    return "CONFIG", "default", "plain value (no registry hit, no secret/box/test/plumbing shape) — a settings-row candidate"


# ── endpoint literal scan ────────────────────────────────────────────────────

URL_RE = re.compile(r'https?://[^\s"\'`)<>]+')
VENDOR_HOST_RE = re.compile(
    r'\b(openrouter\.ai|api\.fireworks\.ai|api\.clerk\.com|api\.machines\.dev|'
    r'[a-z0-9.-]*\.workers\.dev|claude\.com|api\.github\.com|github\.com)\b'
)
# BH-1511 review I1: the ORIGINAL regex only recognized a handful of HTTP
# client shapes and an assignment ending specifically in URL/BASE/HOST — it
# missed `os.environ.get(...)`, `urllib`, a bare `Request(`, `base_url=`
# (Fireworks' provider config) and, most of all, every assignment to a
# DIFFERENTLY-named variable (`API=`, `APIB=`, `CLOCK_SYNC_SOURCES=`), which
# is what filed Fly Machines, GitHub App token minting, Anthropic OAuth usage
# and Fireworks' own base_url as DOC instead of CONFIG.
CALL_SHAPE_RE = re.compile(
    r'\bcurl\b|\bfetch\(|\baxios\.|new XMLHttpRequest|Invoke-RestMethod|\bwget\b|'
    r'\burllib\b|\brequests\.(get|post|put|patch|delete)\(|\bapi_get\(|\bRequest\(|'
    # BH-1530 (R2-N1): `api_get(` is the Python call; bash's own helper is
    # `api_get "https://…" "$tok"` (bin/vendor-spend-pull.sh calls it six
    # times), and every one of those targets filed as DOC.
    r'\bapi_get\s+["\']|'
    r'base_url\s*=|os\.environ\.get\(|process\.env\.\w+\s*(?:\|\||&&|\?)'
)
# ANY `name = <url>` / `name="<url>"` assignment is a call target regardless
# of what the name is — the fix for the vendor-coverage gap above.
ASSIGN_LHS_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*\s*=\s*["\']?$')
# BH-1530 (R2-N1): …and so is a URL that is the DEFAULT of a variable read —
# `JOBS_URL="${JOBS_URL:-https://harness-jobs.…workers.dev}"`. ASSIGN_LHS_RE
# needs `name = "` immediately before the literal and cannot see through the
# `${VAR:-`, so 11 real call targets (the worker URLs the harness talks to
# every tick) were filed as documentation.
VAR_DEFAULT_LHS_RE = re.compile(r'\$\{([A-Z][A-Z0-9_]*):-["\']?$')
# BH-1530 (R2-N1, converse): an interpolated github.com WEB url whose path is
# a pull/issue/run/commit page is a link a human clicks in a comment or a log
# line, not an address this code calls. The interpolation (`$`/`%s`) is what
# distinguishes it from a real fixed target; a `.git` remote has no such path
# and stays a call target.
DISPLAY_LINK_PATH_RE = re.compile(r'/(pull|issues|commit)/|/actions/runs/')
# A literal holding a regex metacharacter is a PATTERN, not a call target
# (`\`, `[`, `(`, `+`) — review I1's "counted as CONFIG but not call targets"
# findings were all regex/link-text literals this generator had no way to
# tell apart from a real endpoint until this check.
REGEX_META_RE = re.compile(r'[\\\[(+]')


def scan_endpoints(root):
    files = iter_files(root, ENDPOINT_SCAN_DIRS)
    out = []
    seen = set()
    for rel in files:
        try:
            with open(os.path.join(root, rel), "r", errors="replace") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for lineno, raw in enumerate(lines, 1):
            stripped = raw.strip()
            is_comment = bool(re.match(r'^(#|//|\*|/\*)', stripped))
            for m in URL_RE.finditer(raw):
                url = m.group(0).rstrip(".,;:)")
                prefix = raw[:m.start()]
                assigned = bool(ASSIGN_LHS_RE.search(prefix))
                vd = VAR_DEFAULT_LHS_RE.search(prefix)
                if vd and url.endswith("}"):
                    # The brace closes the `${VAR:-…}` expansion, it is not
                    # part of the address. URL_RE stops at a quote, not at a
                    # `}`, and these literals only became visible (CONFIG,
                    # in the endpoints checklist) with the rule above — a
                    # checklist row reading `https://api.github.com}` is a
                    # target nobody can call.
                    url = url[:-1]
                _record_endpoint(out, seen, rel, lineno, url, raw, is_comment, assigned,
                                 vd.group(1) if vd else None)
            if not URL_RE.search(raw):
                for m in VENDOR_HOST_RE.finditer(raw):
                    _record_endpoint(out, seen, rel, lineno, m.group(0), raw, is_comment, False, None)
    return out


def _is_display_link(literal, service):
    return (
        service == "github-web"
        and ("$" in literal or "%s" in literal)
        and bool(DISPLAY_LINK_PATH_RE.search(literal))
    )


def _record_endpoint(out, seen, rel, lineno, literal, raw, is_comment, assigned, default_of=None):
    key = (rel, lineno, literal)
    if key in seen:
        return
    seen.add(key)
    service = _endpoint_service(literal)
    if is_comment:
        kind = "DOC"
        reason = "inside a comment"
    elif REGEX_META_RE.search(literal):
        kind = "DOC"
        reason = "literal contains a regex metacharacter (\\, [, ( or +) — a pattern, not a literal call target"
    elif _is_display_link(literal, service):
        kind = "DOC"
        reason = "display-link builder (interpolated web URL to a pull/issue/run/commit page), not a call target"
    elif default_of:
        kind = "CONFIG"
        reason = f"literal is the default of `${{{default_of}:-…}}` — a call target the variable side already carries"
    elif assigned:
        kind = "CONFIG"
        reason = "literal is the right-hand side of an assignment to a variable — a call target regardless of that variable's name"
    elif CALL_SHAPE_RE.search(raw):
        kind = "CONFIG"
        reason = "line drives a network call (curl/fetch/axios/requests/urllib/Request/base_url=/os.environ.get/process.env)"
    else:
        kind = "DOC"
        reason = "no call-shaped context on the line (documentation / link text / log message)"
    out.append({
        "file": rel, "line": lineno, "literal": literal, "service": service,
        "kind": kind, "reason": reason, "text": raw.strip(),
    })


def _endpoint_service(literal):
    # BH-1511 review I1: Fly Machines, Fireworks, GitHub API, Anthropic,
    # OpenAI, xAI and the harness's own workers had 0 CONFIG coverage —
    # fixed by CALL_SHAPE_RE/ASSIGN_LHS_RE above; these entries are what
    # then labels the hit with the right vendor once it's caught.
    for host, name in [
        ("openrouter.ai", "openrouter"),
        ("api.fireworks.ai", "fireworks"),
        ("api.clerk.com", "clerk"),
        ("api.machines.dev", "fly-machines"),
        ("api.anthropic.com", "anthropic"),
        ("api.openai.com", "openai"),
        ("api.x.ai", "xai"),
        ("harness-jobs", "harness-jobs-worker"),
        ("harness-watchdog", "harness-watchdog-worker"),
        ("harness-locks", "harness-locks-worker"),
        (".workers.dev", "cloudflare-worker"),
        ("claude.com", "claude"),
        ("api.github.com", "github-api"),
        ("github.com", "github-web"),
    ]:
        if host in literal:
            return name
    return "other"


# ── conflicting defaults / duplicates ────────────────────────────────────────

def find_conflicts(records):
    """name -> sorted distinct defaults, for names with more than one.

    BH-1511 review I5: an empty-string default is very often a PRESENCE TEST
    (`[ -n "${X:-}" ]` before some other code supplies the real value), not a
    competing opinion about what X should default to — comparing it against a
    real default manufactures a "conflict" out of noise
    (`EXTRA_USAGE_DAY_ALERT`: `''` vs `1300`; `ORC_TURN_BUDGET_USD`: same
    shape). Dropping '' before counting distinct values removes that whole
    noise class. It does NOT catch the other half the review names — a read
    that runs AFTER a same-file self-init sees the var already set, so its
    own fallback default is dead code and shouldn't count as a competing
    value either — which needs per-file read ORDER, not tracked here. So this
    is a partial fix, and the inventory says so (`conflicts_partial`)."""
    conflicts = {}
    for name, recs in records.items():
        defaults = sorted({r["default"] for r in recs if r["default"] != ""})
        if len(defaults) > 1:
            conflicts[name] = defaults
    return conflicts


DUPLICATE_GROUPS = [
    # Known same-meaning pairs a reviewer should merge in a conversion slice.
    # This is a starting, honest list (grown as slices find more) — not a
    # claim of completeness. find_duplicate_chains() below auto-derives most
    # of the rest from the inventory's own data.
    (["ACCOUNT_COOLDOWN_SECS", "MODEL_COOLDOWN_SECS"], "account cooldown window — ACCOUNT_COOLDOWN_SECS falls back to MODEL_COOLDOWN_SECS in bin/account-pick.sh"),
]

# BH-1511 review I4: the hand-written list above is one pair; the inventory's
# OWN data holds ~70 alias/fallback chains of the shape `A` defaulting to
# `${B:-...}` (`REREVIEW_CAP` <- `MC_REREVIEW_DAILY_CAP`, `RUNNER_DECOMPOSE`
# <- `RUNNER_PLAN`, ...) — "cheap to derive," per the review, because the
# default text already says it.
CHAIN_REF_RE = re.compile(r'^\$\{([A-Z][A-Z0-9_]*)(?::-.*)?\}$')


def find_duplicate_chains(records):
    chains = []
    seen_pairs = set()
    for name in sorted(records):
        for r in records[name]:
            m = CHAIN_REF_RE.match(r["default"].strip())
            if not m:
                continue
            ref = m.group(1)
            if ref == name or ref not in records:
                continue
            pair = tuple(sorted([name, ref]))
            if pair in seen_pairs:
                continue
            seen_pairs.add(pair)
            chains.append({
                "vars": [name, ref],
                "note": f"{name}'s default is a bare reference to {ref} ({r['file']}:{r['line']}) — likely the same setting under two names",
            })
    return chains


def find_duplicates(records):
    out = []
    names = set(records)
    seen_pairs = set()
    for group, note in DUPLICATE_GROUPS:
        present = [g for g in group if g in names]
        if len(present) > 1:
            out.append({"vars": present, "note": note})
            seen_pairs.add(tuple(sorted(present[:2])))
    for chain in find_duplicate_chains(records):
        pair = tuple(sorted(chain["vars"]))
        if pair in seen_pairs:
            continue
        seen_pairs.add(pair)
        out.append(chain)
    return out


# ── owning lane resolution ───────────────────────────────────────────────────

def owning_lane(recs, lane_scripts):
    files = sorted({r["file"] for r in recs})
    lanes = sorted({lane_scripts[f] for f in files if f in lane_scripts})
    if len(lanes) == 1:
        return lanes[0]
    if len(lanes) > 1:
        return "multi:" + ",".join(lanes)
    # No file this var is read in is itself a lane's `script` — it's read only
    # inside a shared bin/lib/*.sh (or a helper no lane names directly). Name
    # the file(s) rather than a bare "unassigned", so a reader can still find
    # who is affected by a conversion.
    shown = files[:3]
    suffix = f" (+{len(files) - 3} more)" if len(files) > 3 else ""
    return "lib:" + ",".join(shown) + suffix


# ── slicing proposal ─────────────────────────────────────────────────────────
#
# BH-1511 review I3: the ORIGINAL rules tested `^(account-|claude-auth|…)`,
# `^(lane-gate|…)` and `^mc-` against FULL relative paths that all start with
# `bin/`, so none of them could ever match — every one of those three
# subsystems got zero vars, and 80% of knobs (204 of 255) fell into an
# alphabetical `other-1..6` split spanning 20-24 files each against a stated
# limit of 12, scattering one logical subsystem's vars across up to 6 PRs and
# putting `run-build.sh`/`agent-call.sh`/`jobs-watchdog.sh` in 4-5 slices
# apiece so parallel conversion PRs would conflict on them. Two separate rule
# sets fix this: PATH/FILE rules test the var's PRIMARY file (the one with
# the most read sites — a deterministic, non-arbitrary choice among a var's
# files), NAME rules test the var's own name, and each is anchored against
# the right string this time (basename for file-prefix rules, since a full
# path prefix can never match a `bin/`-relative path; full name for name
# rules, since `^MC_` was previously being tested against a FILE path, which
# can obviously never start with a shell variable's prefix).

SUBSYSTEM_PATH_RULES = [
    ("mission-control", re.compile(r'^bin/lib/mc/')),
    ("build", re.compile(r'^bin/lib/rb/')),
    ("pool/fly", re.compile(r'^fly/')),
]

SUBSYSTEM_FILE_RULES = [
    ("account/auth", re.compile(r'^(account-|claude-auth|auth-)')),
    ("lane-gate/settings", re.compile(r'^(lane-gate|lane-caps|harness-ctl)')),
    ("build", re.compile(r'^run-build')),
    ("cost/billing", re.compile(r'cost|price|spend|billing|budget', re.I)),
    ("triage", re.compile(r'triage', re.I)),
    ("merge/review", re.compile(r'merge|review|batch-resolve|rescue|blocked-resolver', re.I)),
    ("alerts", re.compile(r'alert', re.I)),
    ("pool/fly", re.compile(r'^fly-pool|^pool-', re.I)),
    ("backup/db", re.compile(r'backup|migration|d1-schema', re.I)),
    ("mission-control", re.compile(r'^mc-|mission-control', re.I)),
    ("wake/loop", re.compile(r'^wake-', re.I)),
]

SUBSYSTEM_NAME_RULES = [
    ("account/auth", re.compile(r'^(ACCOUNT_|AUTH_)')),
    ("lane-gate/settings", re.compile(r'^LANE_')),
    ("mission-control", re.compile(r'^MC_')),
]


def primary_file_for(recs):
    """The file with the most read sites for this var — a deterministic,
    non-arbitrary choice among possibly several files, used only to decide
    which subsystem a var's conversion slice belongs to."""
    counts = defaultdict(int)
    for r in recs:
        counts[r["file"]] += 1
    return sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]


def subsystem_for(name, primary_file):
    for sub, rx in SUBSYSTEM_PATH_RULES:
        if rx.search(primary_file):
            return sub
    base = os.path.basename(primary_file)
    for sub, rx in SUBSYSTEM_FILE_RULES:
        if rx.search(base):
            return sub
    for sub, rx in SUBSYSTEM_NAME_RULES:
        if rx.search(name):
            return sub
    return "other"


def file_components(config_records):
    """The vars, partitioned so that two vars sharing ANY read file are in the
    same part. Union-find keyed on files; returns a list of sorted name lists,
    ordered by each part's smallest name.

    Every iteration here is over a sorted sequence: this function decides slice
    membership and ordering, and a set's iteration order is per-interpreter
    (the same PYTHONHASHSEED flakiness classify() was already fixed for)."""
    parent = {name: name for name in sorted(config_records)}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra == rb:
            return
        # Lower name wins, so the representative does not depend on input order.
        if rb < ra:
            ra, rb = rb, ra
        parent[rb] = ra

    by_file = defaultdict(list)
    for name in sorted(config_records):
        for f in sorted(config_records[name]["files"]):
            by_file[f].append(name)
    for f in sorted(by_file):
        members = by_file[f]
        for other in members[1:]:
            union(members[0], other)

    parts = defaultdict(list)
    for name in sorted(config_records):
        parts[find(name)].append(name)
    return [parts[k] for k in sorted(parts)]


def _pack(names, config_records, max_knobs, max_files):
    """Greedily cut `names` (already sorted) into chunks under BOTH caps.
    Returns [(names, sorted files)]. A single var reading more than max_files
    files gets its own chunk that exceeds the file cap rather than being
    dropped — the caller flags it."""
    chunks = []
    cur_vars, cur_files = [], set()
    for name in names:
        files = set(config_records[name]["files"])
        if cur_vars and (len(cur_vars) >= max_knobs or len(cur_files | files) > max_files):
            chunks.append((cur_vars, sorted(cur_files)))
            cur_vars, cur_files = [], set()
        cur_vars.append(name)
        cur_files |= files
    if cur_vars:
        chunks.append((cur_vars, sorted(cur_files)))
    return chunks


def build_slices(config_records, max_knobs=40, max_files=12):
    """config_records: name -> {"files": [sorted files], "primary_file": str}.

    BH-1530: ONE FILE, ONE SLICE. The prior version grouped by the var's
    PRIMARY file's subsystem and packed in name order, but a slice's `files`
    is the union of ALL files reading its vars — so a file read by vars of
    different subsystems (or of the same subsystem split across chunks) landed
    in several slices, and 38 files did, `bin/agent-call.sh` in 9 of them.
    Nine conversion PRs cutting the same file in parallel is nine conflicts on
    a hunk no ticket is about.

    So: partition the vars into file-connected COMPONENTS first (two vars that
    share a read file are inseparable), give each component the subsystem most
    of its vars resolve to, and pack whole components into slices under both
    caps. Two independent slices can then never touch the same file.

    A component that alone exceeds a cap cannot honour both rules at once (the
    bin/agent-call.sh component is 108 knobs across 20 files against caps of
    40 and 12). It is cut into cap-respecting chunks that carry a
    `serial_group` / `order` / `blocked_by` chain instead: the files repeat,
    but only inside one chain whose links are built one PR AFTER another, not
    in parallel. Nothing is ever dropped to fit — D12."""
    comps = []
    for names in file_components(config_records):
        subs = defaultdict(int)
        for name in names:
            subs[subsystem_for(name, config_records[name]["primary_file"])] += 1
        # Most common subsystem, ties broken alphabetically.
        sub = min(sorted(subs), key=lambda s: (-subs[s], s))
        files = sorted({f for name in names for f in config_records[name]["files"]})
        comps.append((sub, names, files))

    groups = defaultdict(list)
    for sub, names, files in comps:
        groups[sub].append((names, files))

    slices_raw = []  # (subsystem, [names], [files], serial_group or None)
    for sub in sorted(groups):
        # Components in a stable order: by their smallest var name.
        components = sorted(groups[sub], key=lambda nf: nf[0][0])
        chain_idx = 0
        pack_vars, pack_files = [], set()

        def flush():
            if pack_vars:
                slices_raw.append((sub, sorted(pack_vars), sorted(pack_files), None))

        for names, files in components:
            if len(names) > max_knobs or len(files) > max_files:
                flush()
                pack_vars, pack_files = [], set()
                chain_idx += 1
                group = f"{sub}-chain-{chain_idx}"
                for chunk_vars, chunk_files in _pack(names, config_records, max_knobs, max_files):
                    slices_raw.append((sub, chunk_vars, chunk_files, group))
                continue
            if pack_vars and (len(pack_vars) + len(names) > max_knobs
                              or len(pack_files | set(files)) > max_files):
                flush()
                pack_vars, pack_files = [], set()
            pack_vars.extend(names)
            pack_files |= set(files)
        flush()

    per_sub_count = defaultdict(int)
    for sub, _, _, _ in slices_raw:
        per_sub_count[sub] += 1

    chain_len = defaultdict(int)
    for _, _, _, group in slices_raw:
        if group:
            chain_len[group] += 1

    slices = []
    per_sub_idx = defaultdict(int)
    chain_idx = defaultdict(int)
    prev_in_chain = {}
    for sub, names, files, group in slices_raw:
        per_sub_idx[sub] += 1
        label = sub if per_sub_count[sub] == 1 else f"{sub}-{per_sub_idx[sub]}"
        # Release lane (the operator's release-lanes.md doctrine): Fly builder-image
        # files bake into every build machine and must not roll one mid-build
        # — a train-window slice, not the atomic cron-script default.
        lane = "atomic"
        if any(f.startswith("fly/") for f in files):
            lane = "train-window (Fly builder image rebake — do not roll builder machines mid-build)"
        entry = {"name": label, "vars": names, "files": files, "release_lane": lane}
        if group:
            chain_idx[group] += 1
            i = chain_idx[group]
            entry["serial_group"] = group
            entry["order"] = f"{i} of {chain_len[group]}"
            entry["blocked_by"] = prev_in_chain.get(group)
            entry["note"] = (
                f"one over-cap subsystem component cut into {chain_len[group]} links: these slices "
                "share read files, so they are cut one after another (each Blocked-by the one "
                "before it) and NEVER built in parallel — two PRs editing the same file is the "
                "conflict this grouping exists to prevent."
            )
            prev_in_chain[group] = label
        if len(files) > max_files:
            # D12: a single var reading more files than the cap allows cannot
            # be split any further. It ships flagged, never dropped.
            entry["over_cap_files"] = True
        slices.append(entry)
    return slices


def build_endpoints_slice(endpoints):
    """BH-1511 review I1: the PR body promised an endpoints slice and the
    generator never emitted one. CONFIG-kind endpoint literals, grouped as a
    single named slice (not a var slice — "vars" here holds
    "service:literal" identifiers) so a conversion PR has a checklist."""
    calls = [e for e in endpoints if e["kind"] == "CONFIG"]
    if not calls:
        return None
    files = sorted({e["file"] for e in calls})
    idents = sorted({f'{e["service"]}:{e["literal"]}' for e in calls})
    return {
        "name": "endpoints",
        "vars": idents,
        "files": files,
        "release_lane": "atomic",
        "note": (
            "service_endpoints conversion. JOBS_URL (the settings resolver's own "
            "target) must stay bootstrap config or a box-local cached value — "
            "a settings row cannot resolve the address it would be fetched from."
        ),
    }


# ── main ──────────────────────────────────────────────────────────────────

def git_commit(root):
    try:
        return subprocess.check_output(
            ["git", "-C", root, "rev-parse", "--short=8", "HEAD"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return None


# ── deployment literals (BH-4080) ────────────────────────────────────────────
#
# Everything above reads `${VAR:-literal}`: a value that is ALREADY behind a
# name. This pass is for the literal with no name around it — our GitHub org,
# our box hostnames, the operator's login, our billing accounts — sitting in
# code where another operator's install would silently use OUR value. The
# families are data (catalog/deployment-literals.tsv); every hit outside the
# allowlist is a lint failure, and the default run writes
# docs/config-inventory/deployment.{json,md}, the checked-in report of where
# each family lives instead.
#
# SCOPE. Code only: the dirs below, files with the extensions below. fleet.conf,
# catalog/, prompts/, rules/, docs/, env-templates/ and tests/ are config or
# prose. A comment LINE is skipped (`#` in shell, Python and crontab; `//`, `/*`
# or ` * ` in JS); a TRAILING comment after code is not stripped, and a Python
# docstring is not a comment, so both are scanned.
#
# NOT CAUGHT, said so nobody mistakes green for proof: a literal assembled at
# runtime ("Fortu" "nian"), an extensionless script, any file outside the dirs
# below, and a deployment value no family row describes (lowercase Fly app
# names such as bh-testhost-<org> are already `${VAR:-}` knobs and are
# classified by the variable pass above).

DEPLOY_SCAN_DIRS = ["bin", "fly", "cron", "worker/jobs/src", "console-ui/src", "locks-worker/src"]
DEPLOY_EXTS = {".sh", ".py", ".mjs", ".js", ".cron"}
DEPLOY_SKIP_DIRS = {".wrangler", "node_modules", "__pycache__"}
# A comment line, by language: `#` for shell, Python and crontab; `//`, `/*` and
# a block comment's ` * ` for JS. Per extension on purpose: a shell case arm
# `  *) x=... ;;` starts with `*` and is code.
DEPLOY_COMMENT_RE = {
    ".sh": re.compile(r'^\s*#'), ".py": re.compile(r'^\s*#'), ".cron": re.compile(r'^\s*#'),
    ".js": re.compile(r'^\s*(//|/\*|\*)'), ".mjs": re.compile(r'^\s*(//|/\*|\*)'),
}


def deployment_is_comment(rel, line):
    return bool(DEPLOY_COMMENT_RE[os.path.splitext(rel)[1]].match(line))
DEPLOY_LIB_JSON = "catalog/lanes.d/_lib.deployment.json"
DEPLOY_SHELL_HOME = "bin/lib/deployment.sh"

# What the ticket listed that is ALREADY configuration, so the report can say
# where each one lives rather than leave a reader to wonder whether it was
# missed. Prose, kept here so the report stays generated.
DEPLOY_ALREADY_CONFIG = [
    ("Model routes", "DB-driven through the `model_routes` table (#1510); guardrails/hardcoded-model-ids gates a literal model id, and inventory.json flags model-shaped defaults `deferred_to_1510`."),
    ("Telegram / Slack", "`TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` and the Slack webhook are env-only (`env/global.env`); no chat id or webhook literal is in code."),
    ("Tailnet hosts and the box column", "fleet.conf columns 6 (box) and 7 (tailnet_ip), read through bin/fleet-conf.sh and bin/box-for.sh; the tailnet-ip and tailnet-host families keep new literals out."),
    ("Account ids", "Data files: catalog/auth-accounts.json, catalog/cost-accounts.json, catalog/account-aliases.json."),
    ("Hub paths (/root/harness, /root/repos)", "Already `${HARNESS:-/root/harness}`-style reads with the `HARNESS` / `H` override, classified BOX_LAYOUT in inventory.json (see `totals.by_class.BOX_LAYOUT`). Not converted by BH-4080 and not linted: the lint covers hosts, orgs, logins and accounts."),
    ("Console editability", "Every deployment knob is `settable: false` (a host or identity writable from a page is a hijack path, tests/lanes-registry-test.sh section 17); the console's two defaults live in console-ui/src/lib/deployment.js until console-driven configuration (#3979 wave 8)."),
]


class DeploymentConfigError(Exception):
    """The families catalog or the allowlist could not be read: rc 2."""


def load_deployment_families(path):
    try:
        with open(path, "r") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        raise DeploymentConfigError(f"cannot read families file {path}: {e}")
    fams = []
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) != 4 or not all(c.strip() for c in cols):
            raise DeploymentConfigError(f"{path}:{n}: want 4 non-empty TAB-separated columns, got {len(cols)}")
        try:
            rx = re.compile(cols[1])
        except re.error as e:
            raise DeploymentConfigError(f"{path}:{n}: bad regex for {cols[0]}: {e}")
        fams.append({"family": cols[0], "regex": cols[1], "rx": rx, "home": cols[2], "note": cols[3]})
    if not fams:
        raise DeploymentConfigError(f"{path}: no family rows")
    names = [f["family"] for f in fams]
    if len(set(names)) != len(names):
        raise DeploymentConfigError(f"{path}: a family is listed twice")
    return fams


def iter_deployment_files(root):
    out = []
    for d in DEPLOY_SCAN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(dn for dn in dirnames if dn not in DEPLOY_SKIP_DIRS)
            for fn in sorted(filenames):
                if os.path.splitext(fn)[1] in DEPLOY_EXTS:
                    out.append(os.path.relpath(os.path.join(dirpath, fn), root))
    return sorted(set(out))


def deployment_line_hits(line, families):
    """Families on one code line, in catalog order. A match is blanked before
    the next family runs, so the more specific row owns the text."""
    found = []
    for f in families:
        if f["rx"].search(line):
            found.append(f["family"])
            line = f["rx"].sub(lambda m: " " * len(m.group(0)), line)
    return found


def deployment_scan(root, families):
    hits = []
    for rel in iter_deployment_files(root):
        try:
            with open(os.path.join(root, rel), "r", errors="ignore") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            if deployment_is_comment(rel, line):
                continue
            for fam in deployment_line_hits(line, families):
                hits.append({"file": rel, "line": n, "family": fam, "text": line.strip()[:200]})
    return hits


def load_deployment_allowlist(path, families):
    """-> (entries {path: {"families": set, "reason": str, "line": n}}, problems).
    A malformed line is a PROBLEM (rc 1), not a read failure: the guard must
    say which line is wrong, not refuse to run."""
    try:
        with open(path, "r") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        raise DeploymentConfigError(f"cannot read allowlist {path}: {e}")
    known = {f["family"] for f in families}
    entries, problems = {}, []
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 3 or not parts[2].strip():
            problems.append(f"allowlist:{n}: {parts[0]}: no reason given")
            continue
        p, fams, reason = parts[0], set(parts[1].split(",")), parts[2].strip()
        unknown = sorted(fams - known)
        if unknown:
            problems.append(f"allowlist:{n}: {p}: unknown family {','.join(unknown)}")
            continue
        if p in entries:
            problems.append(f"allowlist:{n}: {p}: listed twice")
            continue
        entries[p] = {"families": fams, "reason": reason, "line": n}
    return entries, problems


def deployment_lint(root, families, allow_path):
    """-> (unallowed hits, allowed hits, problems, entries)."""
    entries, problems = load_deployment_allowlist(allow_path, families)
    hits = deployment_scan(root, families)
    unallowed, allowed = [], []
    for h in hits:
        e = entries.get(h["file"])
        (allowed if e and h["family"] in e["families"] else unallowed).append(h)
    for p, e in sorted(entries.items()):
        if not os.path.isfile(os.path.join(root, p)):
            problems.append(f"allowlist:{e['line']}: {p}: no such file")
            continue
        for fam in sorted(e["families"]):
            if not any(h["file"] == p and h["family"] == fam for h in allowed):
                problems.append(f"allowlist:{e['line']}: {p}: stale, no {fam} literal left in it")
    return unallowed, allowed, problems, entries


def _deployment_knobs(root):
    try:
        with open(os.path.join(root, DEPLOY_LIB_JSON), "r") as fh:
            lib = json.load(fh)
    except (OSError, ValueError):
        return {}
    out = {}
    for l in lib.get("libs", []) or []:
        for k in l.get("knobs", []) or []:
            if k.get("env"):
                out[k["env"]] = k
    return out


def _deployment_consumers(root, token):
    """Files in the scanned tree that read a knob (word match) or import a
    defaults module (an ES `from '.../<basename>'`), on a non-comment line,
    the home itself excluded. Files only — a report with line numbers would
    move on every unrelated edit."""
    if "/" in token:
        rx = re.compile(r'\bfrom\s+[\'"][^\'"]*/' + re.escape(os.path.basename(token)) + r'[\'"]')
    else:
        rx = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(token) + r'(?![A-Za-z0-9_])')
    out = []
    for rel in iter_deployment_files(root):
        if rel in (token, DEPLOY_SHELL_HOME):
            continue
        try:
            with open(os.path.join(root, rel), "r", errors="ignore") as fh:
                for line in fh:
                    if not deployment_is_comment(rel, line) and rx.search(line):
                        out.append(rel)
                        break
        except OSError:
            continue
    return out


def build_deployment_report(root, families, allow_path):
    unallowed, allowed, problems, entries = deployment_lint(root, families, allow_path)
    knobs = _deployment_knobs(root)
    fam_rows = []
    for f in families:
        homes = []
        for tok in f["home"].split():
            if tok in knobs:
                homes.append({"knob": tok, "default": knobs[tok].get("default"),
                              "consumers": _deployment_consumers(root, tok)})
            elif tok.endswith(".js") and os.path.isfile(os.path.join(root, tok)):
                homes.append({"module": tok, "consumers": _deployment_consumers(root, tok)})
        fam_rows.append({
            "family": f["family"], "regex": f["regex"], "home": f["home"], "note": f["note"],
            "homes": homes,
            "allowlisted": [{"file": p, "reason": e["reason"]} for p, e in sorted(entries.items())
                            if f["family"] in e["families"]],
            "unallowlisted_hits": [h for h in unallowed if h["family"] == f["family"]],
        })
    return {
        "generated_at_commit": git_commit(root),
        "generator": "bin/config-inventory.sh",
        "scan_dirs": DEPLOY_SCAN_DIRS,
        "families": fam_rows,
        "allowlist_problems": problems,
        "already_config": [{"what": w, "where": d} for w, d in DEPLOY_ALREADY_CONFIG],
    }


def render_deployment_md(rep):
    L = ["# Deployment assumptions (BH-4080)", "",
         "Generated by `bin/config-inventory.sh` from `catalog/deployment-literals.tsv`,",
         "`catalog/lanes.d/_lib.deployment.json` and `tests/no-hardcoded-deployment-allowlist.txt`.",
         "Do not edit by hand: re-run the generator and commit what it writes.", "",
         "Every value below is specific to the deployment this harness was built on. Each one now",
         "has ONE documented default, and an operator overrides it in `env/global.env` on the box.",
         "None is settable from the console: a host or an identity a page can write is a hijack path.",
         "`bin/deployment-lint.sh` fails on a new literal of any family outside the allowlist.", "",
         "Scanned: " + ", ".join(f"`{d}/`" for d in rep["scan_dirs"]) + " (code lines only).", ""]
    total = sum(len(f["unallowlisted_hits"]) for f in rep["families"])
    L += [f"Un-allowlisted literals: **{total}**. Allowlist problems: **{len(rep['allowlist_problems'])}**.", ""]
    for f in rep["families"]:
        L += [f"## `{f['family']}`", "", f["note"], "", f"- pattern: `{f['regex']}`", f"- lives in: {f['home']}"]
        for h in f["homes"]:
            name = h.get("knob") or h.get("module")
            if "knob" in h:
                L.append(f"- `{name}` default `{h['default']}`")
            else:
                L.append(f"- `{name}`")
            if h["consumers"]:
                L.append("  - read by: " + ", ".join(f"`{c}`" for c in h["consumers"]))
        if f["allowlisted"]:
            L.append("- allowlisted:")
            for a in f["allowlisted"]:
                L.append(f"  - `{a['file']}`: {a['reason']}")
        for h in f["unallowlisted_hits"]:
            L.append(f"- UN-ALLOWLISTED `{h['file']}:{h['line']}`")
        L.append("")
    if rep["allowlist_problems"]:
        L += ["## Allowlist problems", ""] + [f"- {p}" for p in rep["allowlist_problems"]] + [""]
    L += ["## Already configuration (reported, not converted)", ""]
    for a in rep["already_config"]:
        L.append(f"- **{a['what']}**: {a['where']}")
    L.append("")
    return "\n".join(L)


def write_deployment_report(root, out_dir):
    """Writes deployment.{json,md} when the tree has a families catalog. A
    tree without one (the bh-1511 fixture trees) gets no report, not a crash."""
    fpath = os.path.join(root, "catalog", "deployment-literals.tsv")
    if not os.path.isfile(fpath):
        return None
    families = load_deployment_families(fpath)
    allow = os.path.join(root, "tests", "no-hardcoded-deployment-allowlist.txt")
    if not os.path.isfile(allow):
        allow = os.devnull
    rep = build_deployment_report(root, families, allow)
    with open(os.path.join(out_dir, "deployment.json"), "w") as fh:
        json.dump(rep, fh, indent=2)
        fh.write("\n")
    with open(os.path.join(out_dir, "deployment.md"), "w") as fh:
        fh.write(render_deployment_md(rep))
    return rep


def deployment_lint_main(root, families_path, allow_path):
    try:
        families = load_deployment_families(families_path)
        unallowed, _allowed, problems, _e = deployment_lint(root, families, allow_path)
    except DeploymentConfigError as e:
        sys.stderr.write(f"deployment-lint: {e}\n")
        return 2
    for h in unallowed:
        print(f"{h['file']}:{h['line']}\t{h['family']}\t{h['text']}")
    for p in problems:
        print(p)
    return 1 if (unallowed or problems) else 0


# ── HTML summary ─────────────────────────────────────────────────────────────

HTML_HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Config inventory</title>
<style>
:root {
  --bg:#FCFCFC; --ink:#1A1A1A; --sub:#5B5B5B; --line:#E4E4E4; --card:#FFFFFF;
  --accent:#2563EB; --good:#0E7C3A; --warn:#B45309; --bad:#B42318; --chip:#F2F2F2;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg:#15171A; --ink:#EDEDED; --sub:#9A9A9A; --line:#2A2D31; --card:#1C1F23;
    --accent:#5B8DEF; --good:#3FBE6C; --warn:#E0A233; --bad:#F0665E; --chip:#25282C;
  }
}
:root[data-theme="dark"] {
  --bg:#15171A; --ink:#EDEDED; --sub:#9A9A9A; --line:#2A2D31; --card:#1C1F23;
  --accent:#5B8DEF; --good:#3FBE6C; --warn:#E0A233; --bad:#F0665E; --chip:#25282C;
}
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--ink);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif; }
main { max-width:1600px; margin:0 auto; padding:24px 16px 80px; }
nav.toc { position:sticky; top:0; z-index:10; background:var(--bg);
  border-bottom:1px solid var(--line); padding:10px 16px; display:flex;
  gap:14px; flex-wrap:wrap; font-size:13px; }
nav.toc a { color:var(--sub); text-decoration:none; white-space:nowrap; }
nav.toc a:hover { color:var(--accent); }
h1 { font-size:26px; margin:18px 0 4px; }
h2 { font-size:19px; margin:34px 0 10px; border-top:1px solid var(--line); padding-top:22px; }
p.lede { color:var(--sub); max-width:960px; margin:0 0 18px; }
.pills { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin:16px 0 24px; }
.pill { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:10px 14px; }
.pill .n { font-size:22px; font-weight:600; }
.pill .l { color:var(--sub); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.note { background:var(--chip); border-radius:8px; padding:10px 14px; font-size:13px; color:var(--sub); margin:10px 0 18px; max-width:960px; }
table { border-collapse:collapse; width:100%; font-size:13px; background:var(--card); }
th, td { border-bottom:1px solid var(--line); padding:6px 10px; text-align:left; vertical-align:top; }
/* BH-1511 review M4: a hardcoded top:41px assumed a one-line nav, which
   wraps to two lines under ~900px (and position:sticky computed against the
   .tablewrap overflow-x:auto container doesn't reliably pin to the PAGE
   scroll anyway) — dropped rather than reimplemented, since a plain header
   that stays correctly aligned beats a sticky one that pins at the wrong
   offset on mobile. */
th { background:var(--card); cursor:pointer; user-select:none; white-space:nowrap; }
th.sort-asc::after { content:" \\25B2"; color:var(--accent); }
th.sort-desc::after { content:" \\25BC"; color:var(--accent); }
tr:hover td { background:var(--chip); }
.tablewrap { overflow-x:auto; border:1px solid var(--line); border-radius:10px; }
code { font-family:ui-monospace,Menlo,Consolas,monospace; font-size:12px; }
.badge { display:inline-block; border-radius:999px; padding:1px 9px; font-size:11px; font-weight:600; }
.b-CONFIG { background:#DCEAFE; color:#1D4ED8; }
.b-ALREADY_REGISTERED { background:#DCFCE7; color:#15803D; }
.b-SECRET { background:#FEE2E2; color:#B91C1C; }
.b-PLUMBING { background:var(--chip); color:var(--sub); }
.b-TEST_HOOK { background:#FEF3C7; color:#B45309; }
.b-BOX_LAYOUT { background:#EDE9FE; color:#6D28D9; }
.b-UNDECIDED { background:#FFE4E6; color:#BE123C; }
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) .b-CONFIG{background:#1E3A6E;color:#93C5FD;}
  :root:not([data-theme="light"]) .b-ALREADY_REGISTERED{background:#14532D;color:#86EFAC;}
  :root:not([data-theme="light"]) .b-SECRET{background:#5B1616;color:#FCA5A5;}
  :root:not([data-theme="light"]) .b-TEST_HOOK{background:#4A3707;color:#FCD34D;}
  :root:not([data-theme="light"]) .b-BOX_LAYOUT{background:#3B2E6E;color:#C4B5FD;}
  :root:not([data-theme="light"]) .b-UNDECIDED{background:#5B1626;color:#FDA4AF;}
}
input.filter { width:100%; max-width:420px; padding:6px 10px; margin:8px 0;
  border:1px solid var(--line); border-radius:8px; background:var(--card); color:var(--ink); font-size:13px; }
.hide { display:none !important; }
.cols2 { columns:2; column-gap:32px; }
.cols2 li { break-inside:avoid; }
footer { color:var(--sub); font-size:12px; margin-top:40px; }
@media (max-width:900px) { .cols2 { columns:1; } nav.toc { overflow-x:auto; } }
</style>
</head>
<body>
<nav class="toc">
  <a href="#totals">Totals</a><a href="#slices">Proposed slices</a>
  <a href="#conflicts">Conflicts</a><a href="#duplicates">Duplicates</a>
  <a href="#endpoints">Endpoints</a><a href="#variables">Every variable</a>
</nav>
<main>
"""

HTML_SCRIPT = """
<script>
function sortTable(table, col, numeric) {
  const tbody = table.tBodies[0];
  const rows = Array.from(tbody.rows);
  const th = table.tHead.rows[0].cells[col];
  const asc = !th.classList.contains('sort-asc');
  Array.from(table.tHead.rows[0].cells).forEach(c => { c.classList.remove('sort-asc','sort-desc'); c.setAttribute('aria-sort','none'); });
  th.classList.add(asc ? 'sort-asc' : 'sort-desc');
  th.setAttribute('aria-sort', asc ? 'ascending' : 'descending');
  rows.sort((a, b) => {
    let x = a.cells[col].dataset.sort ?? a.cells[col].innerText;
    let y = b.cells[col].dataset.sort ?? b.cells[col].innerText;
    if (numeric) { x = parseFloat(x) || 0; y = parseFloat(y) || 0; return asc ? x - y : y - x; }
    return asc ? x.localeCompare(y) : y.localeCompare(x);
  });
  rows.forEach(r => tbody.appendChild(r));
}
document.querySelectorAll('table.sortable').forEach(table => {
  Array.from(table.tHead.rows[0].cells).forEach((th, i) => {
    th.addEventListener('click', () => sortTable(table, i, th.dataset.num === '1'));
  });
});
document.querySelectorAll('input.filter').forEach(inp => {
  const table = document.getElementById(inp.dataset.table);
  inp.addEventListener('input', () => {
    const q = inp.value.toLowerCase();
    Array.from(table.tBodies[0].rows).forEach(r => {
      r.classList.toggle('hide', q && !r.innerText.toLowerCase().includes(q));
    });
  });
});
</script>
</body>
</html>
"""


def _esc(s):
    return html.escape(str(s), quote=True)


def _th(cols):
    cells = "".join(
        f'<th data-num="{1 if numeric else 0}" aria-sort="none">{_esc(label)}</th>'
        for label, numeric in cols
    )
    return f"<thead><tr>{cells}</tr></thead>"


def render_html(inv):
    t = inv["totals"]
    commit = inv.get("generated_at_commit") or "unknown"

    pills = "".join(
        f'<div class="pill"><div class="n">{v}</div><div class="l">{_esc(k)}</div></div>'
        for k, v in [
            ("distinct variables", t["distinct_variables"]),
            ("read sites", t["total_read_sites"]),
            # BH-1511 review M1: `CONFIG total - ALL deferred` double-counted
            # deferred vars of OTHER classes (only 33 of 47 deferred names
            # were even CONFIG-class) — the real in-scope count is exactly
            # len(config_records), which is what feeds the slices, so use
            # that number directly rather than re-deriving it with subtraction.
            ("CONFIG (in-scope for #1511)", t["config_in_scope_for_1511"]),
            ("deferred to #1510 (models)", t["deferred_to_1510"]),
            ("already registered", t["by_class"].get("ALREADY_REGISTERED", 0)),
            ("secret", t["by_class"].get("SECRET", 0)),
            ("plumbing", t["by_class"].get("PLUMBING", 0)),
            ("test hook", t["by_class"].get("TEST_HOOK", 0)),
            ("box layout", t["by_class"].get("BOX_LAYOUT", 0)),
            ("undecided", t["by_class"].get("UNDECIDED", 0)),
            ("conflicting defaults (actionable)", t["conflicting_defaults_actionable"]),
            ("endpoint literals (call targets)", t["endpoint_config"]),
            ("proposed slices", t["proposed_slices"]),
        ]
    )

    slice_rows = []
    for s in inv["proposed_slices"]:
        # BH-1530: the chain fields, so the page says what the JSON says. A
        # slice with no serial_group is independent and the cell is empty.
        if s.get("serial_group"):
            blocked = s.get("blocked_by")
            serial = (
                f"<code>{_esc(s['serial_group'])}</code><br>{_esc(s.get('order', ''))}"
                + (f"<br>after <code>{_esc(blocked)}</code>" if blocked else "<br>first")
            )
        else:
            serial = ""
        slice_rows.append(
            "<tr>"
            f"<td><code>{_esc(s['name'])}</code></td>"
            f"<td data-sort=\"{len(s['vars'])}\">{len(s['vars'])}</td>"
            f"<td data-sort=\"{len(s['files'])}\">{len(s['files'])}</td>"
            f"<td data-sort=\"{_esc(s.get('serial_group') or '')}\">{serial}</td>"
            f"<td>{_esc(s.get('release_lane', 'atomic'))}</td>"
            f"<td>{', '.join(_esc(v) for v in s['vars'][:12])}{' …' if len(s['vars']) > 12 else ''}</td>"
            f"<td>{'<br>'.join('<code>' + _esc(f) + '</code>' for f in s['files'][:8])}{' …' if len(s['files']) > 8 else ''}</td>"
            "</tr>"
        )

    conflict_rows = []
    for c in inv["conflicts_actionable"]:
        conflict_rows.append(
            "<tr>"
            f"<td><code>{_esc(c['name'])}</code></td>"
            f"<td><span class=\"badge b-{_esc(c['class'])}\">{_esc(c['class'])}</span></td>"
            f"<td>{', '.join('<code>' + _esc(d or '(empty)') + '</code>' for d in c['defaults'])}</td>"
            "</tr>"
        )

    dup_items = "".join(
        f"<li><code>{_esc(' / '.join(d['vars']))}</code> — {_esc(d['note'])}</li>"
        for d in inv["duplicates"]
    ) or "<li>none found yet</li>"

    ep_rows = []
    for e in inv["endpoints"]:
        ep_rows.append(
            "<tr>"
            f"<td><span class=\"badge b-{'CONFIG' if e['kind']=='CONFIG' else 'PLUMBING'}\">{_esc(e['kind'])}</span></td>"
            f"<td>{_esc(e['service'])}</td>"
            f"<td><code>{_esc(e['literal'])}</code></td>"
            f"<td><code>{_esc(e['file'])}:{e['line']}</code></td>"
            f"<td>{_esc(e['reason'])}</td>"
            "</tr>"
        )

    var_rows = []
    for v in inv["variables"]:
        flags = []
        if v["deferred_to_1510"]:
            flags.append('<span class="badge b-SECRET" title="overlaps #1510, the model-routing ticket">→#1510</span>')
        if v.get("computed_default"):
            flags.append('<span class="badge b-TEST_HOOK" title="default is a shell expression, not a literal value">computed</span>')
        sites = "; ".join(f'{_esc(r["file"])}:{r["line"]}' for r in v["read_sites"][:6])
        if len(v["read_sites"]) > 6:
            sites += f' … (+{len(v["read_sites"]) - 6})'
        var_rows.append(
            "<tr>"
            f"<td><code>{_esc(v['name'])}</code></td>"
            f"<td><span class=\"badge b-{_esc(v['class'])}\">{_esc(v['class'])}</span></td>"
            f"<td>{_esc(v['rule'])}</td>"
            f"<td>{_esc(v['owning_lane'])}</td>"
            f"<td>{', '.join('<code>' + _esc(d or chr(39)+chr(39)) + '</code>' for d in v['defaults'][:4])}</td>"
            f"<td data-sort=\"{len(v['read_sites'])}\">{len(v['read_sites'])}</td>"
            f"<td><code>{sites}</code></td>"
            f"<td>{' '.join(flags)}</td>"
            f"<td>{_esc(v['note'])}</td>"
            "</tr>"
        )

    parts = [HTML_HEAD]
    parts.append(
        "<h1>Config inventory</h1>"
        f'<p class="lede">BH-1511.0 — every <code>${{VAR:-literal}}</code> read in bin/, fly/, cron/ and every '
        f"hardcoded endpoint literal in bin/, fly/, worker/jobs/src, console-ui/src, classified so #1511's "
        f"conversion slices know what becomes a settings row. Generated by "
        f"<code>bin/config-inventory.sh</code> at commit <code>{_esc(commit)}</code>. No network call, no git "
        f"write — re-run it any time the tree changes and republish.</p>"
    )

    parts.append(f'<h2 id="totals">Totals</h2><div class="pills">{pills}</div>')
    parts.append(
        '<div class="note">"CONFIG" is this generator\'s residual bucket: no registry hit, no secret/box/'
        "test/plumbing shape — a settings-row candidate. Vars ending in <code>_MODEL</code> or defaulting to a "
        "model-id-shaped string (or a runner name out of agent-call.sh's closed list) are flagged "
        '<span class="badge b-SECRET">→#1510</span> and excluded from the proposed slices below: that ticket\'s '
        "model_routes table is meant to own them, not a generic settings row here.</div>"
    )

    parts.append(
        '<h2 id="slices">Proposed conversion slices</h2>'
        '<p class="lede">CONFIG vars partitioned into FILE-DISJOINT components first — two vars that share a '
        "read file are inseparable, so no two independent slices touch the same file and they can be cut in "
        "parallel without conflicting — then grouped by subsystem (the one most of a component's vars resolve "
        "to, matched on each var's primary file, the one with the most read sites, and for "
        "account/lane-gate/mission-control on the var's own name prefix) and packed to ≤40 knobs AND ≤12 "
        "distinct files per slice so each is one reviewable PR. A component too big for those caps cannot be "
        "both file-disjoint and reviewable, so it is cut into a SERIAL chain instead: the <em>serial</em> "
        "column names the chain, the link's position in it, and the slice it is blocked by. Chain links share "
        "files and are cut one after another, never in parallel. "
        "The last row, <code>endpoints</code>, is the separate service_endpoints conversion; its \"vars\" "
        "column holds <code>service:literal</code> call targets, not variable names. Each slice becomes its "
        "own #1511.N ticket: register the knobs, seed today's values, remove the file default (resolver cache "
        "+ fail-closed), red-first tests, no behaviour change. \"Release lane\" follows this repo's own "
        "release-lanes doctrine: a slice touching a Fly builder-image file ships in a train window (image "
        "rebake, never mid-build), everything else is atomic.</p>"
        '<div class="tablewrap"><table class="sortable" id="t-slices">'
        + _th([("slice", False), ("vars", True), ("files", True), ("serial", False), ("release lane", False), ("sample vars", False), ("sample files", False)])
        + f"<tbody>{''.join(slice_rows)}</tbody></table></div>"
    )

    parts.append(
        '<h2 id="conflicts">Conflicting defaults (actionable)</h2>'
        '<p class="lede">Same var, two different literal defaults, on a name that already is or should become a '
        "settings row — the shape #1511's ticket body calls a bug worth listing. Empty-string presence-test "
        "defaults (<code>${X:-}</code>) are dropped before comparing, but a read that follows a same-file "
        "self-init still isn't excluded, so treat this list as a partial, not exhaustive, one (a conversion "
        "slice's first job is to confirm each row, not just apply it). The full, noisier list "
        "(including local/plumbing names that legitimately default differently in different scripts) is in "
        f"<code>inventory.json</code>'s <code>conflicts</code> array ({t['conflicting_defaults']} total).</p>"
        '<input class="filter" data-table="t-conflicts" placeholder="Filter by name…">'
        '<div class="tablewrap"><table class="sortable" id="t-conflicts">'
        + _th([("name", False), ("class", False), ("defaults seen", False)])
        + f"<tbody>{''.join(conflict_rows)}</tbody></table></div>"
    )

    parts.append(
        f'<h2 id="duplicates">Duplicate groups</h2>'
        '<p class="lede">Two or more knobs that carry the same meaning under different names — a conversion '
        "slice should merge these into one settings row rather than register both. Auto-derived from any "
        "default that is a bare <code>${OTHER_VAR:-...}</code> reference, plus a small hand-written seed list "
        "— partial, not a claim every alias/fallback chain in the codebase is here.</p>"
        f'<ul class="cols2">{dup_items}</ul>'
    )

    parts.append(
        '<h2 id="endpoints">Endpoint literals</h2>'
        '<p class="lede">Every hardcoded URL / known vendor hostname in the scanned trees. '
        '<span class="badge b-CONFIG">CONFIG</span> lines drive a network call and are the '
        '"endpoints" slice\'s subject; <span class="badge b-PLUMBING">DOC</span> lines are documentation, a '
        "log message or link text.</p>"
        '<input class="filter" data-table="t-endpoints" placeholder="Filter…">'
        '<div class="tablewrap"><table class="sortable" id="t-endpoints">'
        + _th([("kind", False), ("service", False), ("literal", False), ("site", False), ("reason", False)])
        + f"<tbody>{''.join(ep_rows)}</tbody></table></div>"
    )

    parts.append(
        '<h2 id="variables">Every variable</h2>'
        f'<p class="lede">All {t["distinct_variables"]} distinct names, every classification rule that fired, '
        "every read site (first 6 shown; the full list is in inventory.json), and the note explaining why.</p>"
        '<input class="filter" data-table="t-vars" placeholder="Filter by name, class, rule, lane…">'
        '<div class="tablewrap"><table class="sortable" id="t-vars">'
        + _th([
            ("name", False), ("class", False), ("rule", False), ("owning lane / lib", False),
            ("default(s)", False), ("sites", True), ("read sites", False), ("flags", False), ("note", False),
        ])
        + f"<tbody>{''.join(var_rows)}</tbody></table></div>"
    )

    parts.append(
        f'<footer>Generated by bin/config-inventory.sh at commit {_esc(commit)}. '
        "Re-run it and republish whenever bin/, fly/, cron/, worker/jobs/src or console-ui/src change — "
        "tests/config-inventory.bh-1511-test.sh fails CI if this file drifts from the generator's own output "
        "on the current tree.</footer>"
    )
    parts.append(HTML_SCRIPT)
    return "".join(parts)


def run(root, out_dir):
    registered = load_registered(root)
    lane_scripts = load_lane_scripts(root)
    records, self_assigned, self_init_vars = scan_variables(root)
    test_assigned = scan_test_assignments(root)

    variables = []
    class_counts = defaultdict(int)
    config_records = {}
    for name in sorted(records):
        recs = records[name]
        cls, rule, note = classify(name, recs, self_assigned, test_assigned, registered, self_init_vars)
        class_counts[cls] += 1
        files = sorted({r["file"] for r in recs})
        defaults = sorted({r["default"] for r in recs})
        deferred = is_deferred_to_1510(name, defaults, note)
        # Section 18 of tests/lanes-registry-test.sh already refuses this
        # shape in the registry: "a default is a VALUE, never shell text a
        # page would render as one." Flagging it here means a conversion
        # slice knows up front it must MATERIALIZE the value to seed
        # (`$(hostname)` -> today's actual hostname), not copy the expression.
        computed_default = any(re.search(r'\$\(|`', d) for d in defaults)
        entry = {
            "name": name,
            "class": cls,
            "rule": rule,
            "note": note,
            "owning_lane": owning_lane(recs, lane_scripts),
            "read_sites": [{"file": r["file"], "line": r["line"], "default": r["default"]} for r in recs],
            "defaults": defaults,
            "deferred_to_1510": deferred,
            "computed_default": computed_default,
        }
        if name in registered:
            entry["registered_as"] = registered[name]
        variables.append(entry)
        if cls == "CONFIG" and not deferred:
            config_records[name] = {"files": files, "primary_file": primary_file_for(recs)}

    class_by_name = {v["name"]: v["class"] for v in variables}
    conflicts_raw = find_conflicts(records)
    # Every PLUMBING/local var that defaults to '' in one file and something
    # else in another produces a "conflict" that is not a bug — it is two
    # unrelated locals sharing a short name (A, BASE, AGE, ...). The
    # ACTIONABLE conflicts — the ones #1511's ticket body means by "bugs
    # worth listing" — are ones on a name that is, or should become, a real
    # settings row: CONFIG and ALREADY_REGISTERED. Both lists are kept: full
    # for completeness (every one of the 1,151 must be accounted for
    # somewhere), actionable for what a human should act on first.
    conflicts = [
        {"name": n, "defaults": d, "class": class_by_name.get(n, "?")}
        for n, d in sorted(conflicts_raw.items())
    ]
    actionable_conflicts = [c for c in conflicts if c["class"] in ("CONFIG", "ALREADY_REGISTERED")]
    duplicates = find_duplicates(records)
    endpoints = scan_endpoints(root)
    slices = build_slices(config_records)
    endpoints_slice = build_endpoints_slice(endpoints)
    if endpoints_slice:
        slices.append(endpoints_slice)
    config_in_scope = len(config_records)

    inventory = {
        "generated_at_commit": git_commit(root),
        "generator": "bin/config-inventory.sh",
        "scan_dirs": {"variables": VAR_SCAN_DIRS, "endpoints": ENDPOINT_SCAN_DIRS},
        # BH-1511 review I4/I5: neither list claims completeness — see
        # find_conflicts()'s and find_duplicate_chains()'s own docstrings for
        # exactly what each still misses.
        "conflicts_partial": True,
        "duplicates_partial": True,
        "totals": {
            "distinct_variables": len(variables),
            "total_read_sites": sum(len(v["read_sites"]) for v in variables),
            "by_class": dict(sorted(class_counts.items())),
            "config_in_scope_for_1511": config_in_scope,
            "conflicting_defaults": len(conflicts),
            "conflicting_defaults_actionable": len(actionable_conflicts),
            "duplicate_groups": len(duplicates),
            "endpoint_literals": len(endpoints),
            "endpoint_config": sum(1 for e in endpoints if e["kind"] == "CONFIG"),
            "proposed_slices": len(slices),
            "deferred_to_1510": sum(1 for v in variables if v["deferred_to_1510"]),
        },
        "variables": variables,
        "conflicts": conflicts,
        "conflicts_actionable": actionable_conflicts,
        "duplicates": duplicates,
        "endpoints": endpoints,
        "proposed_slices": slices,
    }

    os.makedirs(out_dir, exist_ok=True)
    inv_path = os.path.join(out_dir, "inventory.json")
    with open(inv_path, "w") as fh:
        json.dump(inventory, fh, indent=2, sort_keys=False)
        fh.write("\n")

    html_path = os.path.join(out_dir, "index.html")
    with open(html_path, "w") as fh:
        fh.write(render_html(inventory))

    write_deployment_report(root, out_dir)

    return inventory, inv_path, html_path


def main(argv):
    root = os.getcwd()
    out = None
    lint = False
    families = allowlist = None
    i = 1
    while i < len(argv):
        if argv[i] == "--root" and i + 1 < len(argv):
            root = argv[i + 1]; i += 2
        elif argv[i] == "--out" and i + 1 < len(argv):
            out = argv[i + 1]; i += 2
        elif argv[i] == "--deployment-lint":
            lint = True; i += 1
        elif argv[i] == "--families" and i + 1 < len(argv):
            families = argv[i + 1]; i += 2
        elif argv[i] == "--allowlist" and i + 1 < len(argv):
            allowlist = argv[i + 1]; i += 2
        else:
            sys.stderr.write(f"config-inventory.py: unknown arg {argv[i]}\n")
            return 2
    root = os.path.abspath(root)
    if lint:
        # BH-4080: a pure scan. Writes nothing; 0 clean, 1 hits or allowlist
        # problems, 2 could not run.
        return deployment_lint_main(
            root,
            families or os.path.join(root, "catalog", "deployment-literals.tsv"),
            allowlist or os.path.join(root, "tests", "no-hardcoded-deployment-allowlist.txt"))
    out_dir = os.path.abspath(out) if out else os.path.join(root, "docs", "config-inventory")
    inventory, inv_path, html_path = run(root, out_dir)
    t = inventory["totals"]
    print(
        f"config-inventory: {t['distinct_variables']} vars, "
        f"{t['total_read_sites']} read sites, by_class={t['by_class']}, "
        f"deferred_to_1510={t['deferred_to_1510']}, "
        f"conflicts={t['conflicting_defaults']} ({t['conflicting_defaults_actionable']} actionable), "
        f"duplicates={t['duplicate_groups']}, "
        f"endpoints={t['endpoint_literals']} ({t['endpoint_config']} CONFIG), "
        f"slices={t['proposed_slices']} -> {inv_path} , {html_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
