"""lane-stage-check.py <root> <lanes.d dir> — the checker behind
tests/lane-stage-ratchet.bh-2304-test.sh (lanes pass) and
tests/lane-stage-ratchet.bh-2539-test.sh (sites pass). Prints
  LANE <id> registered=<a,b> called=<a,b> sites=<n>
per lane with >=1 direct agent-call site in its own script, then, when
<root>/catalog/llm-sites.json exists, for every `kind: agent-call` site
  SITE <id> stage=<declared> called=<called> project=<declared> called_project=<literal>
or `SKIP SITE <id> <reason>` when its script has no call the scanner can
resolve. A `FAIL: ...` line per problem (one per file whose heredoc is
still open at end of file); exit 1 when any FAIL was printed."""
import json, os, re, sys

root, lanes_dir = sys.argv[1], sys.argv[2]

STAGE = re.compile(r'[a-z][a-z0-9-]*$')
# A path word through a variable ending in agent-call.sh, optionally quoted.
PATHCALL = re.compile(r'"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(?:/[A-Za-z0-9_.-]+)*/agent-call\.sh"?(?=\s|$)')
HEREDOC = re.compile(r'<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1')


def strip_comment(line):
    out, q = [], None
    for i, ch in enumerate(line):
        if q:
            out.append(ch)
            if ch == q:
                q = None
            continue
        if ch in ('"', "'"):
            q = ch
            out.append(ch)
            continue
        if ch == '#' and (i == 0 or line[i - 1] in ' \t;|&('):
            break
        out.append(ch)
    return ''.join(out)


def heredoc_start(code):
    """The HEREDOC match of the first `<<NAME` bash reads as a heredoc start
    in one comment-stripped line, or None. Text inside '...' and "...", a
    backslash-escaped character, a `<<<` here-string and `<<` inside
    `((...))` arithmetic are not heredocs; a `$(...)` inside "..." is code
    again, so `"$(cmd <<'PY'` is one."""
    q, subs, i, n = None, [], 0, len(code)
    while i < n:
        ch = code[i]
        if q == "'":
            if ch == "'":
                q = None
        elif ch == '\\':
            i += 1
        elif q == '"':
            if ch == '"':
                q = None
            elif code.startswith('$(', i) and not code.startswith('$((', i):
                subs.append([q, 1])
                q, i = None, i + 1
        elif ch in '"\'':
            q = ch
        elif code.startswith('((', i) or code.startswith('$((', i):
            j, depth = i + (2 if ch == '(' else 3), 2
            while j < n and depth:
                depth += {'(': 1, ')': -1}.get(code[j], 0)
                j += 1
            i = j
            continue
        elif ch == '(' and subs:
            subs[-1][1] += 1
        elif ch == ')' and subs:
            subs[-1][1] -= 1
            if not subs[-1][1]:
                q = subs.pop()[0]
        elif code.startswith('<<<', i):
            i += 3
            continue
        elif code.startswith('<<', i):
            m = HEREDOC.match(code, i)
            if m:
                return m
            i += 2
            continue
        i += 1
    return None


def code_lines(text):
    """-> ([(lineno, code)], open) with comments stripped, heredoc bodies
    dropped and backslash continuations joined onto the line that starts the
    command. `open` is (lineno, terminator) of a heredoc the file never
    closes, else None."""
    out, pend, pend_no, term, term_no = [], '', 0, None, 0
    for no, raw in enumerate(text.splitlines(), 1):
        if term is not None:
            if raw.strip() == term:
                term = None
            continue
        code = strip_comment(raw)
        m = heredoc_start(code)
        if m:
            term, term_no = m.group(2), no
        if not pend:
            pend_no = no
        if code.rstrip().endswith('\\'):
            pend += code.rstrip()[:-1] + ' '
            continue
        out.append((pend_no, pend + code))
        pend = ''
    if pend:
        out.append((pend_no, pend))
    return out, ((term_no, term) if term is not None else None)


def unquote(w):
    w = w.strip()
    if len(w) >= 2 and w[0] == w[-1] and w[0] in '"\'':
        w = w[1:-1]
    return w


def resolve(word, assigns):
    """A literal, or $NAME / "${NAME}" with exactly one literal assignment."""
    if STAGE.match(word):
        return word
    vm = re.fullmatch(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?', word)
    vals = assigns.get(vm.group(1), set()) if vm else set()
    if len(vals) == 1 and STAGE.match(next(iter(vals))):
        return next(iter(vals))
    return None


# rel path -> the FAIL line for a heredoc that file never closes. A dict, so
# a file both passes scan prints its FAIL once.
UNCLOSED = {}


def scan(path):
    """-> (set of stages, [site lines], [problems], set of literal projects)"""
    text = open(path, encoding='utf-8', errors='replace').read()
    lines, unclosed = code_lines(text)
    rel = os.path.relpath(path, root)
    if unclosed:
        UNCLOSED[rel] = (f'FAIL: {rel}:{unclosed[0]}: heredoc <<{unclosed[1]} opened here '
                         'is never closed (end of file reached inside it)')
    assigns = {}
    for _, code in lines:
        for m in re.finditer(r'(?:^|[\s;(])(?:export\s+|local\s+|readonly\s+|declare\s+)?([A-Za-z_][A-Za-z0-9_]*)=("[^"]*"|\'[^\']*\'|[^\s;"\']*)', code):
            assigns.setdefault(m.group(1), set()).add(unquote(m.group(2)))
    # Variables that hold the agent-call path, e.g.
    # AGENT_CALL="${PROMPT_EVAL_AGENT_CALL:-$SELF/agent-call.sh}"
    callvars = sorted(n for n, vs in assigns.items()
                      if vs and all(v.rstrip('}').endswith('agent-call.sh') for v in vs))
    tok = [PATHCALL]
    for n in callvars:
        tok.append(re.compile(r'"?\$\{?' + re.escape(n) + r'\}?"?(?=\s|$)'))
    stages, sites, probs, projects = set(), [], [], set()
    for no, code in lines:
        for rx in tok:
            for m in rx.finditer(code):
                rest = code[m.end():].split()
                if not rest:
                    continue
                arg = rest[0]
                if arg[0] in '])|&;<>':
                    continue            # a test, a redirect or a mention, not an invocation
                stage = resolve(unquote(arg), assigns)
                if stage is None:
                    probs.append(f'FAIL: {rel}:{no}: agent-call stage argument {arg} does not resolve to one literal stage')
                    continue
                if len(rest) > 1:
                    proj = resolve(unquote(rest[1]), assigns)
                    if proj is not None:
                        projects.add(proj)
                stages.add(stage)
                sites.append(f'{rel}:{no}:{stage}')
    return stages, sites, probs, projects


def registered(lane):
    cs = (lane.get('stats') or {}).get('cost_stage')
    if cs is None:
        return set()
    if isinstance(cs, str):
        return {cs}
    if isinstance(cs, list) and all(isinstance(s, str) for s in cs):
        return set(cs)
    return None


fails = 0
for fn in sorted(os.listdir(lanes_dir)):
    if not fn.endswith('.json') or fn.startswith('_'):
        continue
    try:
        lane = json.load(open(os.path.join(lanes_dir, fn)))
    except Exception as e:
        print(f'FAIL: {fn}: unparseable ({e})'); fails += 1; continue
    lid, script = lane.get('id'), lane.get('script')
    if not lid or not script:
        continue
    sp = os.path.join(root, script)
    if not os.path.isfile(sp):
        continue
    called, sites, probs, _ = scan(sp)
    # BH-2489: `stats.cost_stage_via` names helper scripts the lane runs as a
    # child with its AGENT_CALL_LANE inherited (run-product -> draft-proposal),
    # so their agent-call stages are this lane's too. Only a DECLARED helper is
    # followed: following every bin/*.sh a lane invokes would quietly change
    # other lanes' called sets.
    for via in (lane.get('stats') or {}).get('cost_stage_via') or []:
        vp = os.path.join(root, via)
        if not os.path.isfile(vp):
            print(f'FAIL: lane {lid}: stats.cost_stage_via names {via}, which does not exist'); fails += 1
            continue
        vc, vs, vpr, _ = scan(vp)
        called |= vc; sites += vs; probs += vpr
    for p in probs:
        print(p); fails += 1
    if not sites and not probs:
        continue
    reg = registered(lane)
    if reg is None:
        print(f'FAIL: {lid}: stats.cost_stage is neither a string, an array of strings nor null'); fails += 1
        continue
    print(f'LANE {lid} registered={",".join(sorted(reg))} called={",".join(sorted(called))} sites={len(sites)}')
    if reg != called:
        print(f'FAIL: lane {lid} registers cost_stage [{",".join(sorted(reg))}] but {script} calls agent-call.sh with [{",".join(sorted(called))}] ({"; ".join(sites)})')
        fails += 1

# BH-2539: the SITES pass. catalog/llm-sites.json declares, per agent-call
# site, the stage and project its cost rows carry; the script's own calls must
# say the same. cost-readout billed review/project-1 and runner-bench billed
# triage (so run-triage's cap) while no lane's script was theirs, so the lanes
# pass above never looked at them.
sites_path = os.path.join(root, 'catalog', 'llm-sites.json')
if os.path.isfile(sites_path):
    try:
        cat = json.load(open(sites_path))
    except Exception as e:
        print(f'FAIL: catalog/llm-sites.json: unparseable ({e})'); cat = {}; fails += 1
    for site in cat.get('sites') or []:
        if site.get('kind') != 'agent-call':
            continue
        sid, script = site.get('id'), site.get('script') or ''
        sp = os.path.join(root, script)
        if not os.path.isfile(sp):
            print(f'FAIL: site {sid}: script {script} does not exist'); fails += 1
            continue
        called, calls, probs, projects = scan(sp)
        if os.path.relpath(sp, root) in UNCLOSED:
            continue                    # its FAIL is printed below, not a SKIP
        if probs:
            print(f'SKIP SITE {sid} unresolvable stage argument ({len(probs)} call(s))')
            continue
        if not calls:
            print(f'SKIP SITE {sid} no direct agent-call site in {script}')
            continue
        declared = set(str(site.get('stage') or '').split('|')) - {''}
        dproj = str(site.get('project') or '')
        print(f'SITE {sid} stage={",".join(sorted(declared))} called={",".join(sorted(called))} '
              f'project={dproj} called_project={",".join(sorted(projects))}')
        if declared != called:
            print(f'FAIL: site {sid} declares stage [{",".join(sorted(declared))}] but {script} calls agent-call.sh with [{",".join(sorted(called))}] ({"; ".join(calls)})')
            fails += 1
        if dproj and '$' not in dproj and projects - {dproj}:
            print(f'FAIL: site {sid} declares project {dproj} but {script} calls agent-call.sh with project [{",".join(sorted(projects))}]')
            fails += 1
for line in sorted(UNCLOSED.values()):
    print(line); fails += 1
sys.exit(1 if fails else 0)
