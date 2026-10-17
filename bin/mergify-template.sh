#!/bin/bash
# bin/mergify-template.sh — render and compare a repo's .mergify.yml from its
# config/mergify/repos/<repo>.conf (BH-1673).
#
# THE INTERFACE (frozen by BH-1697; the renderer sibling fills in the bodies
# without changing it):
#   render <conf>              the rendered YAML on stdout. rc 0, or rc 2 on a
#                              bad conf, naming the offending line.
#   compare <conf> <yaml>      rc 0 semantically equal, rc 1 drift (a diff on
#                              stdout), rc 3 cannot compare (PyYAML missing,
#                              unparseable file). rc 3 is NEVER "in sync".
#   marker <yaml>              rc 0 when the file carries
#                              `# harness-mergify: override <non-empty reason>`
#                              (the reason on stdout), otherwise rc 1.
#   --check                    every config/mergify/repos/*.conf render checked
#                              against the repo. rc 0 or 1.
#   A usage error (unknown verb, wrong arg count) is rc 2 with a usage line on
#   stderr.
#
# Callers invoke it as
#   "${MERGIFY_TEMPLATE_BIN:-$HARNESS_ROOT/bin/mergify-template.sh}"
# so a caller's test can substitute a stub comparator.
#
# The YAML work is in the inline python3 block below. compare and --check need PyYAML.
set -uo pipefail

usage() {
  echo "usage: mergify-template.sh render <conf> | compare <conf> <yaml> | marker <yaml> | --check" >&2
  exit 2
}

# marker <yaml>: the first `# harness-mergify: override <reason>` line with a
# non-blank reason. Plain shell, so it answers without PyYAML.
marker() {
  local reason
  reason=$(sed -nE 's/^[[:space:]]*#[[:space:]]*harness-mergify:[[:space:]]*override[[:space:]]+(.*[^[:space:]].*)$/\1/p' "$1" 2>/dev/null | head -n 1)
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  [ -n "$reason" ] || return 1
  printf '%s\n' "$reason"
}

case "${1:-}" in
  render)  [ "$#" -eq 2 ] || usage ;;
  compare) [ "$#" -eq 3 ] || usage ;;
  marker)  [ "$#" -eq 2 ] || usage; marker "$2"; exit ;;
  --check) [ "$#" -eq 1 ] || usage ;;
  *)       usage ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "mergify-template: python3 not found" >&2
  case "$1" in compare) exit 3 ;; --check) exit 1 ;; *) exit 2 ;; esac
fi

MT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MT_SELF="$MT_ROOT/bin/$(basename "$0")"
export MT_ROOT MT_SELF
exec python3 - "$@" <<'PY'
import difflib, glob, json, os, re, subprocess, sys

ROOT, SELF = os.environ["MT_ROOT"], os.environ["MT_SELF"]
TEMPLATE = os.path.join(ROOT, "config/mergify/template.yml")
DEFAULTS = {"merge_method": "squash", "batch_size": "4", "batch_max_wait_time": "3 min",
            "checks_timeout": "45 min", "max_parallel_checks": "3", "max_checks_retries": "0",
            "base": "main", "queue_mode": "serial", "scope_default_capacity": "1"}
KNOWN = set(DEFAULTS) | {"slug", "check", "queue_check", "status_check", "default_status_check", "override", "batch_failure_attempts", "solo_label", "flake_fix_label"}
# batch_failure_attempts (BH-4980): optional, no default. Set, it renders
# `batch_max_failure_resolution_attempts: <n>` on the default queue only (the
# hotfix queue's batch is 1, so there is nothing to split). 0 stops Mergify
# bisecting a failed batch: it dequeues every member and the merge conductor's
# impact map ejects the one PR that reaches the failing test
# (bin/lib/mc-batch-impact.sh). Unset renders nothing, byte-for-byte as before.
# solo_label (BH-5430, no default): the label that routes a PR into a `solo`
# queue of batch_size 1. The merge conductor adds it before merge-queue when a
# PR's break-risk score reaches queue_risk.threshold (bin/lib/queue-risk.sh), so
# a risky PR never fails a batch of 8 and every batch stacked behind it. The
# queue sits between hotfix and default and carries no priority rule, so it
# never interrupts running checks. A conf without the key renders byte-for-byte
# as before. The harness's own labels are refused: merge-queue would put every
# PR in solo, fix-main-red is the hotfix lane's.
# flake_fix_label (BH-7279, no default): the label that routes a PR into a
# `flake-fix` queue of batch_size 1, listed after hotfix and before solo and
# default, so Mergify serves it first after a hotfix. The merge conductor adds
# it before merge-queue when a PR changes a suite on the batch-fail list and
# touches only the fix scope (bin/lib/queue-flake-fix.sh). No priority rule:
# it never interrupts running checks. The solo and default rules exclude it, so
# a PR matches one rule. A conf without the key renders byte-for-byte as
# before. Refused: the harness's own labels (merge-queue, fix-main-red, the
# pool's hotfix build label) and the solo_label value.
# queue_mode (BH-4979): serial|parallel. parallel renders `merge_queue.mode:
# parallel` and manual scopes, which the merge conductor uploads per commit
# (bin/lib/queue-partition.sh); serial renders neither, so a conf without the
# key renders byte-for-byte as before. scope_default_capacity bounds the
# batches per scope and may not exceed max_parallel_checks, the global ceiling.
# status_check (repeatable, BH-3348): a commit STATUS context queue_conditions
# require after the queue checks (`check-success=<name>` matches a status as
# well as a check run). Never in merge_conditions: those are evaluated on the
# batch draft, whose sha never carries a status posted on the PR head, so it
# would stall every batch — and a name that is also a check= would land there,
# so that is refused. cromford uses it for `lead-verdict`, which only a
# head-bound verdict publishes (bin/lib/verdict-status.sh). A conf without it
# renders byte-for-byte as before.
# default_status_check (repeatable, BH-5441): the same as status_check, but in
# the DEFAULT queue's queue_conditions only, never the hotfix queue's. That keeps
# `fix-main-red` the deliberate override for a status the hotfix path does not
# wait on (`prequeue-verdict`, bin/lib/mc-prequeue.d/status.sh). The same
# refusals as status_check apply, and a name may not also be a check=,
# queue_check= or status_check= line. A conf without it renders byte-for-byte
# as before.
# queue_check (repeatable, 2026-09-24, "each tree is tested exactly once"). A repo that runs its test corpus ONLY on the merge
# queue's batch draft cannot ask for those checks before a PR enters the queue
# — an ordinary PR never runs them, so queue_conditions would never pass. Its
# conf lists the fast PR checks as queue_check= and every check as check=:
# queue_conditions take the queue_check list, merge_conditions (evaluated on the
# batch draft) the check list. With the two lists different Mergify never checks
# a PR in place — it always builds a draft, even for a batch of one — so no
# allow_inplace_checks knob is needed (Mergify deprecated it on 2025-09-30). A
# conf without queue_check= renders byte-for-byte as before.
# max_parallel_checks multiplies CI runner minutes, so it has a ceiling. It was
# 3 until the operator raised cromford to 8 on 2026-09-23 (#1775: MonkCI gives each
# job its own VM, and the Max plan carries 20,000 minutes); the ceiling is that
# decision, and going past it is another deliberate edit here.
# max_checks_retries (default queue only; hotfix stays 0) re-runs a failed batch
# before Mergify splits it; 0 keeps every conf that omits it byte-identical.
INTS = {"batch_size": (1, 10), "max_parallel_checks": (1, 8), "max_checks_retries": (0, 2),
        "scope_default_capacity": (1, 8), "batch_failure_attempts": (0, 8)}
PATTERNS = {"batch_max_wait_time": r"[0-9]+ ?[a-z]+( [0-9]+ ?[a-z]+)*",
            "checks_timeout": r"[0-9]+ ?[a-z]+( [0-9]+ ?[a-z]+)*",
            "base": r"[A-Za-z0-9._/-]+",
            "slug": r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+"}
COND_KEYS = {"conditions", "queue_conditions", "merge_conditions"}
# The queue label the template's pull_request_rules key on (MC_MERGIFY_LABEL).
LABEL = "merge-queue"


class Bad(Exception):
    """A conf or template that will not render (render rc 2, compare rc 3)."""


class CannotCompare(Exception):
    pass


def err(msg):
    print("mergify-template: " + msg, file=sys.stderr)


def check_value(key, val):  # -> the problem, or None
    if key in INTS:
        lo, hi = INTS[key]
        if not re.fullmatch(r"[0-9]+", val):
            return "%s %r is not an integer" % (key, val)
        if key == "max_parallel_checks" and int(val) > hi:
            return "max_parallel_checks %d > %d (multiplies CI runner minutes, docs/CI-RUNNERS.md)" % (int(val), hi)
        if not lo <= int(val) <= hi:
            return "%s %s is outside %d..%d" % (key, val, lo, hi)
    elif key == "queue_mode" and val not in ("serial", "parallel"):
        return "queue_mode %r is not serial|parallel" % val
    elif key == "merge_method" and val not in ("squash", "merge", "rebase"):
        return "merge_method %r is not squash|merge|rebase" % val
    elif key == "solo_label" and not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", val):
        return "solo_label %r is not a lowercase label of 1-50 [a-z0-9-] characters" % val
    elif key == "solo_label" and val in ("merge-queue", "fix-main-red"):
        return "solo_label %r is a label the harness already uses for another queue" % val
    elif key == "flake_fix_label" and not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,49}", val):
        return "flake_fix_label %r is not a lowercase label of 1-50 [a-z0-9-] characters" % val
    elif key == "flake_fix_label" and val in ("merge-queue", "fix-main-red", "hotfix"):
        return "flake_fix_label %r is a label the harness already uses for another purpose" % val
    elif key in PATTERNS and not re.fullmatch(PATTERNS[key], val):
        return "%s %r is malformed" % (key, val)
    return None


def parse(path):
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise Bad("%s: cannot read: %s" % (path, e))
    vals, seen, checks, qchecks, schecks, dschecks = {}, {}, [], [], [], []
    for n, raw in enumerate(lines, 1):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        at = "%s:%d: " % (path, n)
        m = re.fullmatch(r"([a-z_]+)=(\S.*)", line)
        if not m:
            raise Bad(at + "not key=value: " + raw)
        key, val = m.groups()
        if key not in KNOWN:
            raise Bad(at + "unknown key " + key)
        if key in ("check", "queue_check"):
            if re.search(r'["\\\x00-\x1f\x7f]', val):
                raise Bad(at + "check name holds a quote, backslash or control character")
            (checks if key == "check" else qchecks).append(val)
            continue
        if key == "status_check":
            if re.search(r'["\\\x00-\x1f\x7f]', val):
                raise Bad(at + "status_check name holds a quote, backslash or control character")
            if val in schecks:
                raise Bad(at + "duplicate status_check %s" % val)
            schecks.append(val)
            continue
        if key == "default_status_check":
            if re.search(r'["\\\x00-\x1f\x7f]', val):
                raise Bad(at + "default_status_check name holds a quote, backslash or control character")
            if val in dschecks:
                raise Bad(at + "duplicate default_status_check %s" % val)
            dschecks.append(val)
            continue
        if key in seen:
            raise Bad(at + "duplicate %s (first at line %d)" % (key, seen[key]))
        seen[key] = n
        problem = check_value(key, val)
        if problem:
            raise Bad(at + problem)
        vals[key] = val
    if "slug" not in vals:
        raise Bad("%s: no slug= line" % path)
    if not checks:
        raise Bad("%s: no check= line" % path)
    missing = [q for q in qchecks if q not in checks]
    if missing:
        raise Bad("%s: queue_check %r is not also a check= line — a PR could enter the queue on a check the batch never has to pass" % (path, missing[0]))
    both = [x for x in schecks if x in checks or x in qchecks]
    if both:
        raise Bad("%s: status_check %r is also a check= or queue_check= line — merge_conditions run on the batch draft, which never carries the status" % (path, both[0]))
    dboth = [x for x in dschecks if x in checks or x in qchecks or x in schecks]
    if dboth:
        raise Bad("%s: default_status_check %r is also a check=, queue_check= or status_check= line" % (path, dboth[0]))
    if "flake_fix_label" in vals and vals["flake_fix_label"] == vals.get("solo_label"):
        raise Bad("%s:%d: flake_fix_label %r equals solo_label — a PR would match two queue rules" % (
            path, seen["flake_fix_label"], vals["flake_fix_label"]))
    conf = dict(DEFAULTS, **vals)
    if int(conf["scope_default_capacity"]) > int(conf["max_parallel_checks"]):
        raise Bad("%s:%d: scope_default_capacity %s > max_parallel_checks %s" % (
            path, seen.get("scope_default_capacity", 0), conf["scope_default_capacity"], conf["max_parallel_checks"]))
    conf["checks"] = checks
    conf["queue_checks"] = (qchecks or checks) + schecks
    conf["default_status_checks"] = dschecks
    return conf


def render(path):
    c = parse(path)
    subs = {"@@BASE@@": c["base"], "@@MERGE_METHOD@@": c["merge_method"],
            "@@BATCH_SIZE@@": str(int(c["batch_size"])), "@@BATCH_MAX_WAIT@@": c["batch_max_wait_time"],
            "@@CHECKS_TIMEOUT@@": c["checks_timeout"], "@@MAX_PARALLEL@@": str(int(c["max_parallel_checks"])),
            "@@MAX_RETRIES@@": str(int(c["max_checks_retries"]))}
    try:
        with open(TEMPLATE, encoding="utf-8") as f:
            tpl = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise Bad("%s: cannot read: %s" % (TEMPLATE, e))
    par = c["queue_mode"] == "parallel"
    solo = c.get("solo_label")
    flake = c.get("flake_fix_label")
    cond = lambda lst: ["    - " + json.dumps("check-success=" + x, ensure_ascii=False) for x in lst]
    blocks = {"QUEUE_MODE_BLOCK": ["mode: parallel"] if par else [],
              # BH-5430: default's conditions plus the label, alone in its batch.
              "SOLO_QUEUE_BLOCK": ["- name: solo",
                                   "  # A high break-risk PR (bin/lib/queue-risk.sh) never shares a batch (BH-5430).",
                                   "  queue_conditions:", "    - base=" + c["base"], "    - label=" + solo,
                                   '    - "#changes-requested-reviews-by=0"'] + cond(c["queue_checks"])
                                  + ["  merge_conditions:", '    - "#changes-requested-reviews-by=0"'] + cond(c["checks"])
                                  + ["  merge_method: " + c["merge_method"], "  batch_size: 1", "  batch_max_wait_time: 0 s",
                                     "  max_checks_retries: 0", "  checks_timeout: " + c["checks_timeout"]] if solo else [],
              "SOLO_PR_RULE_BLOCK": ["- name: queue on the solo label", "  conditions:", "    - base=" + c["base"],
                                     "    - label=" + LABEL, "    - label=" + solo,
                                     "    # A fix-main-red PR takes the hotfix rule even when it scores high.",
                                     "    - -label=fix-main-red"]
                                    + (["    - -label=" + flake] if flake else [])
                                    + ["  actions:", "    queue:", "      name: solo"] if solo else [],
              "SOLO_EXCLUDE": ["- -label=" + solo] if solo else [],
              # BH-7279: default's conditions plus the label, alone in its batch.
              "FLAKE_QUEUE_BLOCK": ["- name: flake-fix",
                                    "  # A batch-fail suite fix (bin/lib/queue-flake-fix.sh) goes first after a hotfix (BH-7279).",
                                    "  queue_conditions:", "    - base=" + c["base"], "    - label=" + flake,
                                    '    - "#changes-requested-reviews-by=0"'] + cond(c["queue_checks"])
                                   + ["  merge_conditions:", '    - "#changes-requested-reviews-by=0"'] + cond(c["checks"])
                                   + ["  merge_method: " + c["merge_method"], "  batch_size: 1", "  batch_max_wait_time: 0 s",
                                      "  max_checks_retries: 0", "  checks_timeout: " + c["checks_timeout"]] if flake else [],
              "FLAKE_PR_RULE_BLOCK": ["- name: queue on the flake-fix label", "  conditions:", "    - base=" + c["base"],
                                      "    - label=" + LABEL, "    - label=" + flake,
                                      "    # A fix-main-red PR takes the hotfix rule.",
                                      "    - -label=fix-main-red",
                                      "  actions:", "    queue:", "      name: flake-fix"] if flake else [],
              "FLAKE_EXCLUDE": ["- -label=" + flake] if flake else [],
              "SCOPES_BLOCK": ["scopes:", "  source:", "    manual: {}",
                               "  default_capacity: %d" % int(c["scope_default_capacity"])] if par else [],
              "BATCH_FAILURE_BLOCK": ["batch_max_failure_resolution_attempts: %d" % int(c["batch_failure_attempts"])]
                                     if "batch_failure_attempts" in c else []}
    out = []
    for n, line in enumerate(tpl, 1):
        m = re.fullmatch(r"(\s*)@@(QUEUE_MODE_BLOCK|SCOPES_BLOCK|BATCH_FAILURE_BLOCK|SOLO_QUEUE_BLOCK|SOLO_PR_RULE_BLOCK|SOLO_EXCLUDE|FLAKE_QUEUE_BLOCK|FLAKE_PR_RULE_BLOCK|FLAKE_EXCLUDE)@@", line)
        if m:
            out += [m.group(1) + x for x in blocks[m.group(2)]]
            continue
        m = re.fullmatch(r"(\s*)@@(QUEUE_|DEFAULT_STATUS_)?CHECKS@@", line)
        if m:
            lst = {"QUEUE_": c["queue_checks"], "DEFAULT_STATUS_": c["default_status_checks"]}.get(m.group(2), c["checks"])
            out += [m.group(1) + "- " + json.dumps("check-success=" + x, ensure_ascii=False) for x in lst]
            continue
        for tok, val in subs.items():
            line = line.replace(tok, val)
        if "@@" in line:
            raise Bad("%s:%d: unresolved token: %s" % (TEMPLATE, n, line.strip()))
        out.append(line)
    return "\n".join(out) + "\n"


def norm(s):
    s = re.sub(r"\s*=\s*", "=", s.strip())
    key, eq, val = s.partition("=")
    if eq and len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
        s = key + "=" + val[1:-1]
    return s


def canon(obj):
    if isinstance(obj, dict):
        # `manual: {}` and a bare `manual:` (null) are the same manual scopes.
        return {k: ([norm(x) if isinstance(x, str) else canon(x) for x in v]
                    if k in COND_KEYS and isinstance(v, list)
                    else {} if k == "manual" and v is None else canon(v))
                for k, v in obj.items()}
    if isinstance(obj, list):
        return [canon(x) for x in obj]
    return obj


def load(yaml, text, name):
    try:
        obj = yaml.safe_load(text)
    except yaml.YAMLError as e:
        raise CannotCompare("%s does not parse: %s" % (name, str(e).splitlines()[0]))
    if not isinstance(obj, dict):
        raise CannotCompare("%s is not a mapping" % name)
    return obj


def import_yaml():
    try:
        import yaml
        return yaml
    except ImportError:
        raise CannotCompare("PyYAML is not installed")


def compare(conf, path):  # -> (rc, unified diff)
    yaml = import_yaml()
    try:
        rendered = render(conf)
    except Bad as e:
        raise CannotCompare(str(e))
    try:
        with open(path, encoding="utf-8") as f:
            theirs = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise CannotCompare("%s: cannot read: %s" % (path, e))
    a, b = (json.dumps(canon(load(yaml, t, n)), sort_keys=True, indent=2, ensure_ascii=False).splitlines(True)
            for t, n in ((rendered, "render:" + conf), (theirs, path)))
    if a == b:
        return 0, ""
    return 1, "".join(difflib.unified_diff(a, b, fromfile="render:" + conf, tofile=path))


def check():
    fails = 0
    confs = sorted(glob.glob(os.path.join(ROOT, "config/mergify/repos/*.conf")))
    if not confs:
        print("FAIL: no config/mergify/repos/*.conf")
        return 1
    try:
        yaml = import_yaml()
    except CannotCompare as e:
        print("FAIL: cannot compare: %s" % e)
        return 1
    for conf in confs:
        name = os.path.basename(conf)
        try:
            obj = load(yaml, render(conf), "render:" + name)
        except (Bad, CannotCompare) as e:
            print("FAIL: %s: %s" % (name, e))
            fails += 1
            continue
        qr = obj.get("queue_rules")
        names = [q.get("name") for q in qr if isinstance(q, dict)] if isinstance(qr, list) else []
        if "solo" in names:
            if not ("hotfix" in names and "default" in names
                    and names.index("hotfix") < names.index("solo") < names.index("default")):
                print("FAIL: %s: queue_rules must list hotfix, solo, default in that order (got %s)" % (name, names))
                fails += 1
                continue
        elif not ("hotfix" in names and "default" in names and names.index("hotfix") < names.index("default")):
            print("FAIL: %s: queue_rules must list hotfix before default (got %s)" % (name, names))
            fails += 1
            continue
        if "flake-fix" in names:
            ff = names.index("flake-fix")
            if not ("hotfix" in names and "default" in names and names.index("hotfix") < ff < names.index("default")
                    and ("solo" not in names or ff < names.index("solo"))):
                print("FAIL: %s: queue_rules must list hotfix, flake-fix, then solo/default (got %s)" % (name, names))
                fails += 1
                continue
        if name == "cromford.conf":
            root = os.path.join(ROOT, ".mergify.yml")
            if not os.path.exists(root):
                print("ok: %s renders; no .mergify.yml, nothing to sync" % name)
                continue
            try:
                rc, diff = compare(conf, root)
            except CannotCompare as e:
                rc, diff = 3, "cannot compare: %s\n" % e
            if rc != 0:
                m = subprocess.run([SELF, "marker", root], stdout=subprocess.PIPE, universal_newlines=True)
                if m.returncode == 0:
                    print("ok: %s: .mergify.yml differs but carries an override: %s" % (name, m.stdout.strip()))
                    continue
                print("FAIL: %s: .mergify.yml drifted from the render and carries no override marker" % name)
                sys.stdout.write(diff)
                fails += 1
                continue
            print("ok: %s renders and matches .mergify.yml" % name)
            continue
        print("ok: %s renders" % name)
    return 1 if fails else 0


verb, args = sys.argv[1], sys.argv[2:]
if verb == "render":
    try:
        text = render(args[0])
    except Bad as e:
        err(str(e))
        sys.exit(2)
    sys.stdout.write(text)
elif verb == "compare":
    try:
        rc, diff = compare(args[0], args[1])
    except CannotCompare as e:
        err("cannot compare: %s" % e)
        sys.exit(3)
    sys.stdout.write(diff)
    sys.exit(rc)
else:
    sys.exit(check())
PY
