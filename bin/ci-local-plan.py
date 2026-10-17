#!/usr/bin/env python3
"""bin/ci-local-plan.py — the step plan bin/ci-local.sh runs (BH-6897).

Usage: ci-local-plan.py <workflow.yml> <jobs-csv> <skip-dir> <ctx-json>

Reads the workflow, selects the jobs whose `name:` is in <jobs-csv> (in that
order), and prints one JSON array with one object per step:

  {"n", "job", "step", "action": "run|skip|unsupported", "reason",
   "script", "env": {}, "continue_on_error", "shell_flags", "working_directory"}

A step is `skip` when it `uses:` an action, when a row of a
<skip-dir>/*.tsv file (`<job name>\t<step name>\t<reason>`) names it, or when
its `if:` is false in the emulated pull_request context. It is `unsupported`
when its `if:`, `run:` or an `env:` value holds an expression this file cannot
evaluate, or a shell other than bash. Everything else is `run`, with every
`${{ ... }}` in `run:` and `env:` already replaced.

<ctx-json> carries the values bin/ci-local.sh resolved: event_name, base_ref,
head_ref, sha, base_sha, head_sha, pr_body, repository, token, runner_temp.
`vars.<X>` reads the environment variable X (empty when unset), and
`steps.<id>.outputs.<k>` is empty: steps never run here before the plan is made.

rc 0 plan printed; rc 2 no PyYAML, a workflow that does not parse, or a named
job that is not in the workflow (a renamed job must not read as clean).
"""
import glob
import json
import os
import re
import sys

try:
    import yaml
except Exception as e:  # pragma: no cover - exercised by the L4 case
    sys.stderr.write("ci-local-plan: PyYAML is not importable (%s)\n" % e)
    sys.exit(2)


class Unsupported(Exception):
    pass


TOKEN_RE = re.compile(r"""\s*(?:
    (?P<str>'(?:[^']|'')*')
  | (?P<num>-?\d+(?:\.\d+)?)
  | (?P<op>==|!=|&&|\|\||<=|>=|<|>|!|\(|\)|,)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_\-]*(?:\.(?:[A-Za-z_][A-Za-z0-9_\-]*|\*))*)
)""", re.X)


def tokenize(expr):
    out, i = [], 0
    expr = expr.strip()
    while i < len(expr):
        if expr[i].isspace():
            i += 1
            continue
        m = TOKEN_RE.match(expr, i)
        if not m or m.end() == i:
            raise Unsupported("unknown %s" % expr[i:].split()[0])
        kind = m.lastgroup
        val = m.group(kind)
        if kind == "str":
            val = val[1:-1].replace("''", "'")
        out.append((kind, val))
        i = m.end()
    return out


def truthy(v):
    return v not in (None, False, "", 0)


def as_str(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    return str(v)


def loose_eq(a, b):
    # GitHub compares strings case-insensitively; mixed types compare as strings
    # here, which is all these workflows ever do.
    return as_str(a).lower() == as_str(b).lower()


class Ctx:
    def __init__(self, ctx, workflow_name):
        self.c = ctx
        self.workflow_name = workflow_name

    def lookup(self, path):
        g = self.c
        table = {
            "github.event_name": g.get("event_name", "pull_request"),
            "github.base_ref": g.get("base_ref", ""),
            "github.head_ref": g.get("head_ref", ""),
            "github.sha": g.get("sha", ""),
            "github.event.pull_request.base.sha": g.get("base_sha", ""),
            "github.event.pull_request.head.sha": g.get("head_sha", ""),
            "github.event.pull_request.body": g.get("pr_body", ""),
            "github.event.action": "synchronize",
            "github.event.before": "",
            "github.repository": g.get("repository", ""),
            "github.workflow": self.workflow_name,
            "github.token": g.get("token", ""),
            "github.run_id": "",
            "runner.temp": g.get("runner_temp", ""),
        }
        if path in table:
            return table[path]
        m = re.match(r"^vars\.([A-Za-z_][A-Za-z0-9_]*)$", path)
        if m:
            return os.environ.get(m.group(1), "")
        if re.match(r"^steps\.[A-Za-z0-9_\-]+\.outputs\.[A-Za-z0-9_\-]+$", path):
            return ""
        raise Unsupported("unknown %s" % path)


class Parser:
    """or := and ('||' and)* ; and := cmp ('&&' cmp)* ; cmp := un (op un)? ;
    un := '!' un | atom ; atom := str | num | true/false/null | call | path | ( or )"""

    def __init__(self, toks, ctx):
        self.t, self.i, self.ctx = toks, 0, ctx

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else (None, None)

    def take(self, val=None):
        tok = self.peek()
        if tok[0] is None or (val is not None and tok[1] != val):
            raise Unsupported("unknown %s" % (tok[1] or "end of expression"))
        self.i += 1
        return tok

    def parse(self):
        v = self.p_or()
        if self.i != len(self.t):
            raise Unsupported("unknown %s" % self.peek()[1])
        return v

    def p_or(self):
        v = self.p_and()
        while self.peek() == ("op", "||"):
            self.take()
            r = self.p_and()
            v = v if truthy(v) else r
        return v

    def p_and(self):
        v = self.p_cmp()
        while self.peek() == ("op", "&&"):
            self.take()
            r = self.p_cmp()
            v = r if truthy(v) else v
        return v

    def p_cmp(self):
        v = self.p_un()
        if self.peek()[0] == "op" and self.peek()[1] in ("==", "!="):
            op = self.take()[1]
            r = self.p_un()
            return loose_eq(v, r) if op == "==" else not loose_eq(v, r)
        if self.peek()[0] == "op" and self.peek()[1] in ("<", ">", "<=", ">="):
            raise Unsupported("unknown %s" % self.peek()[1])
        return v

    def p_un(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.p_un())
        return self.p_atom()

    def p_atom(self):
        kind, val = self.peek()
        if kind == "str":
            self.take()
            return val
        if kind == "num":
            self.take()
            return float(val) if "." in val else int(val)
        if kind == "op" and val == "(":
            self.take()
            v = self.p_or()
            self.take(")")
            return v
        if kind == "ident":
            self.take()
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            if self.peek() == ("op", "("):
                return self.call(val)
            return self.ctx.lookup(val)
        raise Unsupported("unknown %s" % (val or "end of expression"))

    def call(self, name):
        self.take("(")
        if name == "join":
            kind, path = self.take()
            if kind != "ident" or path != "github.event.pull_request.labels.*.name":
                raise Unsupported("unknown join(%s)" % path)
            if self.peek() == ("op", ","):
                self.take()
                self.p_or()
            self.take(")")
            return ""  # a local run carries no labels
        args = [self.p_or()]
        while self.peek() == ("op", ","):
            self.take()
            args.append(self.p_or())
        self.take(")")
        if name == "startsWith" and len(args) == 2:
            return as_str(args[0]).lower().startswith(as_str(args[1]).lower())
        if name == "endsWith" and len(args) == 2:
            return as_str(args[0]).lower().endswith(as_str(args[1]).lower())
        if name == "contains" and len(args) == 2:
            return as_str(args[1]).lower() in as_str(args[0]).lower()
        raise Unsupported("unknown %s()" % name)


def evaluate(expr, ctx):
    return Parser(tokenize(expr), ctx).parse()


EXPR_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def interpolate(text, ctx):
    return EXPR_RE.sub(lambda m: as_str(evaluate(m.group(1), ctx)), str(text))


def eval_if(cond, ctx):
    if isinstance(cond, bool):
        return cond
    s = str(cond).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", s, re.S)
    if m:
        s = m.group(1)
    return truthy(evaluate(s, ctx))


def load_skips(skip_dir):
    rows = {}
    for f in sorted(glob.glob(os.path.join(skip_dir, "*.tsv"))):
        with open(f) as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 3:
                    continue
                rows[(parts[0], parts[1])] = parts[2]
    return rows


def main(argv):
    if len(argv) != 5:
        sys.stderr.write("usage: ci-local-plan.py <workflow> <jobs-csv> <skip-dir> <ctx-json>\n")
        return 2
    wf_path, jobs_csv, skip_dir, ctx_json = argv[1:]
    try:
        with open(wf_path) as fh:
            wf = yaml.safe_load(fh)
        ctx_in = json.loads(ctx_json)
    except Exception as e:
        sys.stderr.write("ci-local-plan: cannot read %s: %s\n" % (wf_path, e))
        return 2
    if not isinstance(wf, dict) or not isinstance(wf.get("jobs"), dict):
        sys.stderr.write("ci-local-plan: %s has no jobs\n" % wf_path)
        return 2
    ctx = Ctx(ctx_in, as_str(wf.get("name", "")))
    skips = load_skips(skip_dir)
    by_name = {}
    for jid, job in wf["jobs"].items():
        if isinstance(job, dict):
            by_name[as_str(job.get("name", jid))] = job
    wf_env = wf.get("env") or {}
    plan, n = [], 0
    for jname in [j for j in jobs_csv.split(",") if j]:
        job = by_name.get(jname)
        if job is None:
            sys.stderr.write("ci-local-plan: no job named '%s' in %s\n" % (jname, wf_path))
            return 2
        job_env = job.get("env") or {}
        defaults = (job.get("defaults") or {}).get("run") or (wf.get("defaults") or {}).get("run") or {}
        for i, s in enumerate(job.get("steps") or []):
            n += 1
            name = as_str(s.get("name") or (("uses " + s["uses"]) if "uses" in s else "step %d" % (i + 1)))
            row = {"n": n, "job": jname, "step": name, "action": "run", "reason": "",
                   "script": "", "env": {}, "continue_on_error": bool(s.get("continue-on-error")),
                   "shell_flags": "", "working_directory": ""}
            plan.append(row)
            if "uses" in s:
                row.update(action="skip", reason="uses: %s" % s["uses"])
                continue
            if (jname, name) in skips:
                row.update(action="skip", reason=skips[(jname, name)])
                continue
            try:
                if "if" in s and not eval_if(s["if"], ctx):
                    row.update(action="skip", reason="if: %s" % as_str(s["if"]).strip())
                    continue
            except Unsupported as e:
                row.update(action="unsupported", reason="if: %s" % e)
                continue
            try:
                shell = s.get("shell", defaults.get("shell"))
                if shell is None:
                    row["shell_flags"] = "--noprofile --norc -e"
                elif shell == "bash":
                    row["shell_flags"] = "--noprofile --norc -eo pipefail"
                else:
                    raise Unsupported("shell: %s" % shell)
                if "run" not in s:
                    raise Unsupported("no run: and no uses:")
                env = {}
                for k, v in list(wf_env.items()) + list(job_env.items()) + list((s.get("env") or {}).items()):
                    env[str(k)] = interpolate(as_str(v), ctx)
                row["env"] = env
                row["script"] = interpolate(s["run"], ctx)
                wd = s.get("working-directory", defaults.get("working-directory"))
                row["working_directory"] = interpolate(wd, ctx) if wd else ""
            except Unsupported as e:
                row.update(action="unsupported", reason="%s" % e, script="", env={})
    json.dump(plan, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
