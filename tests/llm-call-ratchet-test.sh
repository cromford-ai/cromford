#!/bin/bash
# tests/llm-call-ratchet-test.sh — BH-1141 phase 1. The census of every place
# this fleet invokes a model, and the ratchet that keeps it true.
#
# THE POINT. bin/agent-call.sh is supposed to be the ONE place a model call
# happens, because it is the only place a call can be priced, attributed and —
# since phase 2 — refused before the money is spent. That is a claim about the
# whole repo, and until this file existed nothing checked it: bin/orchestrate.sh
# has been calling `codex exec` and `grok -p` with a 1800s timeout and no cost
# row at all, and nothing anywhere said so. A choke point nobody counts is a
# choke point with a hole in it.
#
# ITS RELATION TO tests/no-raw-claude-test.sh. That lint is about ONE CLI and
# one flag — `claude -p` / `claude --print` under bin/, fly/ and skills/ — and
# it stays exactly as it is; it is the sharper instrument for the case it
# covers. This one is the fleet-wide CENSUS the inventory is built from: four
# CLIs, the vendor HTTP endpoints, and cron/ and checks/ as well. They agree on
# every file they both see (bin/claude-cost.sh is an exception in both), and a
# raw `claude -p` in bin/ turns both of them red, which is the right number of
# guards for the call that cost the most.
#
# WHAT COUNTS AS A VENDOR CALL. After `#` comments are stripped (quote-aware), a
# line offends when either:
#   * one of `claude|codex|grok|gemini` sits at COMMAND POSITION (line start, or
#     after `$(`, `<(`, `|`, `||`, `&&`, `;`, `{`, `(`, or one of
#     if/elif/while/until/then/do/else/!, optionally behind a `timeout N`,
#     `nice -n N`, `exec`, `env [-u NAME]`, or `NAME=value` prefix) AND the line
#     also carries an inference argument (`-p`, `--print`, `--prompt`, `exec`,
#     `-y`, `--always-approve`, or the `"${ARGS[@]}"` argv array); or
#   * the line names a vendor INFERENCE endpoint (`/v1/chat`, `/v1/responses`,
#     `/v1/messages`, `/inference/`, generativelanguage).
#
# WHAT IS DELIBERATELY NOT A VENDOR CALL: `command -v claude`, `claude --help`,
# `claude --version`, prose, a string literal, and the billing/usage/model-price
# APIs (`openrouter.ai/api/v1/keys`, `api.openai.com/v1/organization/costs`,
# `openrouter.ai/api/v1/models`) — those are how we READ a bill, not how we
# make one, and flagging them would train everyone to ignore this test.
#
# WHAT IT DOES NOT CATCH, said plainly so nobody reads a green run as proof:
#   * a call built at runtime (`$CLI exec`, `eval "codex $verb"`, a call split
#     across two lines, anything inside a `bash -c` string);
#   * an HTTP call to a vendor through a variable base URL;
#   * anything outside bin/**/*.sh, cron/*, checks/**, fly/**/*.sh and
#     skills/**/*.sh. Those last two were added in the round-1 fix: the first
#     draft stopped at bin/ and missed `timeout 90 claude -p "Reply exactly: OK"`
#     in fly/builder-runner.sh, while docs/LLM_CALL_SITES.md called itself
#     "every place the harness invokes a model". The roots are now the same
#     three tests/no-raw-claude-test.sh walks, plus cron/ and checks/.
# It is a RATCHET, not a proof: it holds the line that is already held.
#
#   bash tests/llm-call-ratchet-test.sh          exit 0 = pass
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/…
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

ALLOW="$DIR/tests/llm-call-ratchet-allowlist.txt"
CATALOG="$DIR/catalog/llm-sites.json"
BUILD="$DIR/bin/llm-sites-build.sh"

command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ── the scanner ──────────────────────────────────────────────────────────────
# A standalone script so the SAME code scans the repo and the synthetic
# fixtures below. A guard nobody has watched fail is a guard nobody knows is
# wired up. Prints "<path><TAB><line no><TAB><why>" — never the line's text,
# because a call's arguments can carry a key.
cat > "$T/scan.py" <<'PY'
import re, sys, os

roots = sys.argv[2:]
base = sys.argv[1]

CLI = re.compile(r'(?:claude|codex|grok|gemini)')
# A call built at runtime (BH-2308): the binary sits in a variable whose NAME
# names the vendor — `"$GROK"`, `$CODEX_BIN`, `"${ORC_CLAUDE}"`. The census used
# to miss bin/grok-envelope-probe.sh's `"$GROK" --always-approve -p` this way.
CLIVAR = re.compile(r'"?\$\{?[A-Za-z0-9_]*(?:CLAUDE|CODEX|GROK|GEMINI)[A-Za-z0-9_]*\}?"?', re.I)
# The prefixes a real invocation hides behind. Consumed left to right until the
# next token is the CLI name itself.
PREFIX = re.compile(
    r'^(?:'
    r'timeout(?:\s+--kill-after(?:=\S+|\s+\S+))?\s+\S+\s+'
    r'|nice\s+-n\s+\S+\s+'
    r'|exec\s+'
    r'|env\s+'
    r'|-u\s+\w+\s+'
    # An assignment's VALUE is a complete quoted string or a run with no quote
    # in it. `\S*` here would backtrack `MSG="run claude -p ..."` into
    # `MSG="run` + a prefix, and read the prose inside the string as a call.
    r'|[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|[^\s"\']*)\s+'
    r'|command\s+'
    # an argv-array prefix, e.g. `"${GENV[@]}"` (env -u ... carried in an array)
    r'|"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"\s+'
    # any other leading `${...}` word, e.g. `${ORC_TOKEN:+CLAUDE_CODE_OAUTH_TOKEN=$ORC_TOKEN}`
    # (BH-2308 review): one such word hid bin/orchestrate.sh's `"$ORC_CLAUDE" -p`.
    # A vendor-named `"${GROK}"` is tested as the command BEFORE this can eat it.
    r'|"?\$\{[^}]*\}"?\s+'
    r')'
)
# Where a command may start.
STARTS = re.compile(r'(?:^|\$\(|<\(|\|\||\||&&|;|\{|\(|\bif\s|\belif\s|\bwhile\s|\buntil\s|\bthen\s|\bdo\s|\belse\s|!\s)')
ARGS = re.compile(r'(?:(?<=\s)-p(?=\s|"|\'|$)|--print\b|--prompt\b|(?<=\s)exec(?=\s)|(?<=\s)-y(?=\s|$)|--always-approve\b|\$\{ARGS\[@\]\})')
# Vendor INFERENCE endpoints only — never a billing, usage or price read.
ENDPOINT = re.compile(
    r'(?:openrouter\.ai/api/v\d+/(?:chat|completions|responses)'
    r'|api\.anthropic\.com/v\d+/(?:messages|complete)'
    r'|api\.x\.ai/v\d+/(?:chat|responses|messages)'
    r'|api\.fireworks\.ai/inference'
    r'|generativelanguage\.googleapis\.com'
    r'|api\.openai\.com/v\d+/(?:chat|responses|completions))'
)
# `command -v claude`, `claude --help`, `claude --version`: probes, not calls.
PROBE = re.compile(r'\bcommand\s+-v\b|--help\b|--version\b')


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


def offends(line):
    code = strip_comment(line)
    if not code.strip():
        return None
    if ENDPOINT.search(code):
        return 'vendor-inference-endpoint'
    if PROBE.search(code):
        return None
    if not ARGS.search(code):
        return None
    for m in STARTS.finditer(code):
        rest = code[m.end():].lstrip()
        # Test the word as a COMMAND first, then consume it as a prefix and
        # test the next one: a vendor-named `"${GROK}"` is a call, not a prefix.
        while True:
            w = re.match(r'([A-Za-z0-9_.-]+)', rest)
            if w and CLI.fullmatch(w.group(1)):
                return 'cli-invocation'
            v = CLIVAR.match(rest)
            if v and (len(rest) == v.end() or rest[v.end()] in ' \t'):
                return 'cli-invocation-runtime'
            p = PREFIX.match(rest)
            if not p:
                break
            rest = rest[p.end():].lstrip()
    return None


# An agent-call CALLER (BH-2308): code that executes bin/agent-call.sh through a
# path built from a variable — `"$HARNESS/bin/agent-call.sh" triage ...`,
# `"$SELF/agent-call.sh"`, `AGENT_CALL="${X:-$SELF/agent-call.sh}"`. Prose that
# names the file (`bin/agent-call.sh reads .result`) has no `$` in front of it
# and is not a caller.
# A literal install path (`bash /root/harness/bin/agent-call.sh`) is a caller
# too (BH-2308 review); prose in a string is not, so the literal form must sit at
# command position or behind `bash`/`sh`/`exec`.
ACPATH = re.compile(r'(?:\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$\(dirname[^)]*\))/(?:bin/)?agent-call\.sh\b'
                    r'|(?:^\s*|[;&|({]\s*|\b(?:bash|sh|exec|timeout\s+\S+)\s+)["\']?/[A-Za-z0-9_./-]*/agent-call\.sh\b')


def calls_agent_call(line):
    code = strip_comment(line)
    return bool(code.strip()) and bool(ACPATH.search(code))


hits = []
for root in roots:
    full = os.path.join(base, root)
    if os.path.isfile(full):
        files = [full]
    else:
        files = []
        for dp, _dn, fn in os.walk(full):
            for f in fn:
                if f.endswith(('.sh', '.cron')) or dp.endswith('/checks'):
                    files.append(os.path.join(dp, f))
    for path in sorted(files):
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        for n, line in enumerate(lines, 1):
            why = offends(line)
            if why:
                hits.append((os.path.relpath(path, base), n, why))
for rel, n, why in hits:
    print(f'{rel}\t{n}\t{why}')
PY
# The same walker, asking the other question: which files CALL agent-call.sh.
sed -e 's/^            why = offends(line)$/            why = "agent-call-caller" if calls_agent_call(line) else None/' \
  "$T/scan.py" > "$T/callers.py"
grep -q 'calls_agent_call(line) else None' "$T/callers.py" || { echo "FAIL: could not derive the caller scanner"; exit 1; }

scan() { python3 "$T/scan.py" "$@"; }
callers() { python3 "$T/callers.py" "$@" | cut -f1 | sort -u; }

# ── 1. the scanner catches a planted raw call ────────────────────────────────
# Red first, on purpose: every one of these is a real shape that has appeared in
# this repo, and a scanner that misses one is a scanner that reports green on a
# fleet with a leak.
mkdir -p "$T/fixture/bin"
cat > "$T/fixture/bin/leaky.sh" <<'EOF'
#!/bin/bash
claude -p "do the thing"
timeout 120 codex exec --skip-git-repo-check "prompt"
( cd /tmp && PATH="$HOME/.grok/bin:$PATH" grok --always-approve -p "$prompt" )
out=$(env -u XAI_API_KEY gemini -y -p "hi")
curl -s https://api.anthropic.com/v1/messages -d '{}'
timeout 180 "${GENV[@]}" PATH="$GHOME/.grok/bin:$PATH" "$GROK" --always-approve --output-format json -p "$p"
"$GROK" --always-approve -p "$p"
$CODEX_BIN exec --skip-git-repo-check "prompt"
timeout 3600 env -u CLAUDECODE ${ORC_TOKEN:+CLAUDE_CODE_OAUTH_TOKEN=$ORC_TOKEN} "$ORC_CLAUDE" -p --model "$m" "$p"
${X:+A=b} claude -p "hi"
"${GROK}" --always-approve -p "$p"
EOF
mapfile -t HITS < <(scan "$T/fixture" bin)
[ "${#HITS[@]}" -eq 11 ] && ok \
  || bad "1: the scanner found ${#HITS[@]} of 11 planted raw calls: $(printf '%s ' "${HITS[@]}")"
# The runtime-built calls (BH-2308) are named as such: "$GROK" twice, $CODEX_BIN,
# "$ORC_CLAUDE" behind a ${VAR:+NAME=...} word, and "${GROK}".
[ "$(printf '%s\n' "${HITS[@]}" | grep -c 'cli-invocation-runtime')" = 5 ] && ok \
  || bad "1b: the scanner did not see all 5 runtime-built vendor calls: $(printf '%s ' "${HITS[@]}")"

# ── 2. and does NOT flag what is not a call ──────────────────────────────────
cat > "$T/fixture/bin/clean.sh" <<'EOF'
#!/bin/bash
# never call claude -p from a lane; go through agent-call.sh
command -v claude >/dev/null || exit 1
claude --help 2>/dev/null | grep -q -- '--resume'
codex --version
MSG="run claude -p yourself and see"
curl -sf https://openrouter.ai/api/v1/models
curl -sf "https://api.openai.com/v1/organization/costs?start_time=0"
curl -sf https://openrouter.ai/api/v1/keys
GROK="$GHOME/.grok/bin/grok"
VER=$(cli_version_of "$GROK")
"$GROK" --version
[ -n "$GROK" ] || exit 3
EOF
rm -f "$T/fixture/bin/leaky.sh"
mapfile -t CLEAN < <(scan "$T/fixture" bin)
[ "${#CLEAN[@]}" -eq 0 ] && ok \
  || bad "2: the scanner flagged a non-call: $(printf '%s ' "${CLEAN[@]}")"

# ── 3. the repo holds the line ───────────────────────────────────────────────
[ -r "$ALLOW" ] || { echo "FAIL: $ALLOW is missing"; exit 1; }
ALLOWED=$(grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | cut -f1 | sort -u)
# An allowlist line with no reason is itself a finding: the point of the escape
# hatch is the sentence, not the silence.
while IFS= read -r line; do
  case "$line" in ''|\#*) continue ;; esac
  p="${line%%	*}"; why="${line#*	}"
  if [ "$why" = "$line" ] || [ ${#why} -lt 20 ]; then
    bad "3: allowlist entry '$p' has no reason (or one too short to be one)"
  fi
done < "$ALLOW"

SCAN_ROOTS=(bin cron checks fly skills)
mapfile -t REPO < <(scan "$DIR" "${SCAN_ROOTS[@]}")
LEAKS=""
for h in "${REPO[@]}"; do
  f="${h%%	*}"
  [ "$f" = "bin/agent-call.sh" ] && continue
  grep -qxF "$f" <<<"$ALLOWED" && continue
  LEAKS="$LEAKS $h"
done
[ -z "$LEAKS" ] && ok || bad "3: a vendor call lives outside bin/agent-call.sh and is not written down in tests/llm-call-ratchet-allowlist.txt:$LEAKS"

# ...and the choke point is still the choke point. A repo where agent-call.sh
# itself stopped matching would pass the rule above by being empty.
AC=0
for h in "${REPO[@]}"; do case "$h" in bin/agent-call.sh*) AC=$((AC+1)) ;; esac; done
[ "$AC" -ge 4 ] && ok \
  || bad "3b: the scanner sees only $AC vendor calls in bin/agent-call.sh — the ladder has at least claude, codex, grok, gemini, openrouter and fireworks, so the scanner has stopped seeing calls it must see"

# ── 4. every allowlisted file is in the inventory ────────────────────────────
[ -r "$CATALOG" ] || { echo "FAIL: $CATALOG is missing"; exit 1; }
jq -e '.sites | type == "array" and length > 0' "$CATALOG" >/dev/null 2>&1 && ok \
  || bad "4: catalog/llm-sites.json has no sites array"
SCRIPTS=$(jq -r '.sites[].script' "$CATALOG" | sort -u)
MISSING=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  grep -qxF "$p" <<<"$SCRIPTS" || MISSING="$MISSING $p"   # BH-6097: here-string, as below
done <<< "$ALLOWED"
[ -z "$MISSING" ] && ok \
  || bad "4: allowlisted but absent from catalog/llm-sites.json —$MISSING. A raw call nobody wrote down in the inventory is exactly what this ticket is about. Add the site as a new catalog/llm-sites.d/NNNN-<id>.json fragment."

# ...and the census reaches BEYOND bin/. Round-1 review, I2: fly/builder-runner.sh
# probes `claude -p` on a machine whose harness tarball has not landed yet — a
# real vendor call, already known to tests/raw-claude-allowlist.txt, and absent
# from the first draft of this inventory because the scan roots stopped at bin/.
# A doc titled "every place the harness invokes a model" that is one short is
# worse than no doc, so the root list is asserted through its result.
# BH-2549 removed the census's one fly/ call site: the pool SMOKE now asks
# `cred_probe claude` (bin/lib/cred-probe.sh), which runs no model, so the
# fly-builder-smoke row is gone. The root list is still asserted, through a
# planted fly/ call the repo's own scan roots must reach, and the census must
# not keep a fly/ row for a site that no longer calls a model.
mkdir -p "$T/flyroot/fly"
printf '#!/bin/bash\ntimeout 90 claude -p "x"\n' > "$T/flyroot/fly/r.sh"
scan "$T/flyroot" "${SCAN_ROOTS[@]}" | grep -q '^fly/r\.sh	' && ok \
  || bad "4b: the repo scan roots (${SCAN_ROOTS[*]}) no longer reach fly/ — a raw call on a pool machine would be invisible to this ratchet"
jq -e '[.sites[] | select(.script | startswith("fly/"))] | length == 0' "$CATALOG" >/dev/null 2>&1 && ok \
  || bad "4b: catalog/llm-sites.json still lists a fly/ site — fly-builder-smoke was dropped by BH-2549 (SMOKE asks cred_probe, not a model)"

# ── 5. every catalog marker is still findable ────────────────────────────────
# The inventory names sites by a literal rather than a line number (a line
# number drifts on every unrelated edit). The cost of that choice is that a
# moved or deleted call site would rot silently, so it is checked here.
ROT=""
while IFS=$'\t' read -r id script marker; do
  [ -n "$id" ] || continue
  if [ ! -r "$DIR/$script" ]; then ROT="$ROT $id(no-file:$script)"; continue; fi
  grep -qF -- "$marker" "$DIR/$script" || ROT="$ROT $id(marker-gone)"
done < <(jq -r '.sites[] | [.id, .script, .marker] | @tsv' "$CATALOG")
[ -z "$ROT" ] && ok || bad "5: catalog/llm-sites.json points at call sites that have moved or gone —$ROT. Re-point the marker, or drop the site."

# Every site declares the fields a reader needs, and the leak list is not empty
# by accident: `through_agent_call:false` is the finding this phase exists to
# publish, so a catalog where nothing is false is a catalog someone flattened.
BADF=$(jq -r '[.sites[] | select((.id|type!="string") or (.script|type!="string") or (.marker|type!="string") or (.through_agent_call|type!="boolean") or (.priced|type!="string") or (.gated|type!="string")) | .id // "?"] | join(" ")' "$CATALOG")
[ -z "$BADF" ] && ok || bad "5b: catalog sites missing required fields: $BADF"
[ "$(jq '[.sites[] | select(.through_agent_call == false)] | length' "$CATALOG")" -ge 1 ] && ok \
  || bad "5c: no site in the catalog is marked through_agent_call:false — the inventory's whole job is to publish the leak list"

# ── 7. every agent-call CALLER is in the inventory (BH-2308) ────────────────
# Cases 3-4 only see RAW vendor calls, so a new lane that goes through
# agent-call.sh was never counted: lead-review (*/5 on every build box),
# feature-map-draft, prebuild-repro and grok-envelope-probe all shipped absent
# from catalog/llm-sites.json. The caller scanner is proved on a fixture first.
mkdir -p "$T/cfix/bin"
cat > "$T/cfix/bin/caller.sh" <<'EOF'
#!/bin/bash
AGENT_CALL_ROLE=x "$HARNESS/bin/agent-call.sh" triage p m 60 "$out" "@$pf"
EOF
cat > "$T/cfix/bin/caller2.sh" <<'EOF'
#!/bin/bash
AGENT_CALL="${X_AGENT_CALL:-$SELF/agent-call.sh}"
EOF
cat > "$T/cfix/bin/caller3.sh" <<'EOF'
#!/bin/bash
out=$(bash /root/harness/bin/agent-call.sh triage p m 60 "$o" "$p")
EOF
cat > "$T/cfix/bin/prose.sh" <<'EOF'
#!/bin/bash
# "$HARNESS/bin/agent-call.sh" in a comment is not a call
echo "see bin/agent-call.sh, it reads .result"
echo "or /root/harness/bin/agent-call.sh on a box"
EOF
[ "$(callers "$T/cfix" bin | tr '\n' ' ')" = "bin/caller.sh bin/caller2.sh bin/caller3.sh " ] && ok \
  || bad "7: the caller scanner must find exactly the three planted callers, got: $(callers "$T/cfix" bin | tr '\n' ' ')"

UNCAT=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ "$f" = "bin/agent-call.sh" ] && continue
  grep -qxF "$f" <<<"$SCRIPTS" || UNCAT="$UNCAT $f"   # BH-6097: a here-string, never a pipe into grep -q under pipefail (a SIGPIPE read as "not listed")
done < <(callers "$DIR" bin cron checks fly skills)
[ -z "$UNCAT" ] && ok \
  || bad "7: these files call agent-call.sh and are not in catalog/llm-sites.json —$UNCAT. Add a site (id, script, marker, lane, stage) for each, as a new catalog/llm-sites.d/NNNN-<id>.json fragment."

# ...and the four sites the 2026-09-25 audit found missing are there by id.
for id in lead-review feature-map-draft prebuild-repro grok-envelope-probe; do
  jq -e --arg id "$id" '[.sites[] | select(.id == $id)] | length == 1' "$CATALOG" >/dev/null 2>&1 && ok \
    || bad "7b: catalog/llm-sites.json has no site '$id'"
done

# ── 8. the orchestrator's survival lane goes through agent-call (BH-2307) ───
# It called `codex exec` and `grok -p` directly with no cost row and no gate:
# the largest dark site in the fleet. It is converted. orchestrate.sh stays on
# the allowlist for its PRIMARY claude-cost turn only (the scanner sees that
# since the review), so what is held here is narrower: no raw vendor call
# inside run_survival, and the catalog says it is priced and gated.
SURV=$(awk '/^run_survival\(\) \{/{s=NR} s && /^}/{print s" "NR; exit}' "$DIR/bin/orchestrate.sh")
if [ -z "$SURV" ]; then
  bad "8: run_survival() not found in bin/orchestrate.sh"
else
  set -- $SURV
  RAWSURV=$(scan "$DIR" bin/orchestrate.sh | awk -F'\t' -v a="$1" -v b="$2" '$2 >= a && $2 <= b')
  [ -z "$RAWSURV" ] && ok || bad "8: run_survival calls a vendor CLI directly again: $RAWSURV"
fi
jq -e '.sites[] | select(.id == "orchestrate-survival") | .through_agent_call == true and .priced == "yes"' "$CATALOG" >/dev/null 2>&1 && ok \
  || bad "8: catalog site orchestrate-survival must say through_agent_call:true, priced:yes"

# ── 6. the reading copy is GENERATED AND NOT COMMITTED (BH-1268) ────────────
# It used to be committed and compared byte for byte, which meant every marker
# re-point carried a regenerated doc (#1237, #1191) and every PR that touched
# neither could still be re-reddened by a neighbour's rebase. The catalog is the
# source and cases 1–5 above are about the catalog; what is left to prove here
# is that the RENDER is deterministic and that nobody put the render back into
# git. CI, the share mirror and every box run the generator.
[ -x "$BUILD" ] && ok || bad "6: bin/llm-sites-build.sh is missing or not executable"
if [ -x "$BUILD" ]; then
  "$BUILD" --check --repo "$DIR" >/dev/null 2>&1 && ok \
    || bad "6: bin/llm-sites-build.sh --check refuses this repo — run it for the reason"
  # The doc is not in git, and --check is the gate that says so. The .gitignore
  # is only the fence: a PR that drops the ignore line and `git add -f`s the doc
  # must not be able to switch its own check off by doing it.
  [ -z "$(git -C "$DIR" ls-files -- docs/LLM_CALL_SITES.md 2>/dev/null)" ] && ok \
    || bad "6: docs/LLM_CALL_SITES.md is TRACKED in git — it is generated from catalog/llm-sites.json and must not be committed (BH-1268)"
  # ...and the drift check RENDERS INTO $TMPDIR, never into the repo it is
  # checking (round-2 review follow-up). It publishes nothing, so a temp file
  # beside docs/LLM_CALL_SITES.md would have this script create and delete a path inside a
  # checkout it does not own — which is what checks/tests-scratch-only stops,
  # and it is a RUNTIME tracer, so this very suite tripped it in CI by calling
  # --check against the repo. Asserted by taking $TMPDIR away: the render then
  # cannot happen at all and the script exits 2 ("could not run"), which it can
  # only do if that is where it was rendering.
  ( TMPDIR="$T/nonexistent-tmpdir" "$BUILD" --check --repo "$DIR" >/dev/null 2>&1 )
  [ "$?" = 2 ] && ok \
    || bad "6c: --check still renders inside the repo — it must use \$TMPDIR, because a check that publishes nothing must not create or delete a path in a checkout it does not own"
  # ...and the generator is a generator: two builds of the same catalog produce
  # the same bytes. That is the claim the byte comparison against a committed
  # copy used to make, minus the committed copy — a render nobody can reproduce
  # is one nobody can publish, and there is no longer a file in git to notice it
  # through.
  mkdir -p "$T/repo/catalog" "$T/repo/docs" "$T/repo/bin"
  cp "$CATALOG" "$T/repo/catalog/llm-sites.json"
  cp "$BUILD" "$T/repo/bin/llm-sites-build.sh"
  ( cd "$T/repo" && bash bin/llm-sites-build.sh --repo "$T/repo" >/dev/null 2>&1 )
  if [ -r "$T/repo/docs/LLM_CALL_SITES.md" ]; then
    cp "$T/repo/docs/LLM_CALL_SITES.md" "$T/first.md"
    ( cd "$T/repo" && bash bin/llm-sites-build.sh --repo "$T/repo" >/dev/null 2>&1 )
    cmp -s "$T/first.md" "$T/repo/docs/LLM_CALL_SITES.md" && ok \
      || bad "6b: two builds of the same catalog produced different bytes — the render is not deterministic"
  else
    bad "6b: the generator produced no docs/LLM_CALL_SITES.md"
  fi
  # ...and --check REFUSES a tracked copy, in a repo that has one. Same shape as
  # bin/verification-map-build.sh --check (BH-1175): the fence is .gitignore,
  # this is the gate.
  git -C "$T/repo" init -q 2>/dev/null
  git -C "$T/repo" add -A >/dev/null 2>&1
  git -C "$T/repo" -c user.email=t@example.com -c user.name=t commit -qm base >/dev/null 2>&1
  ( cd "$T/repo" && bash bin/llm-sites-build.sh --check --repo "$T/repo" >/dev/null 2>&1 )
  [ "$?" = 1 ] && ok \
    || bad "6b2: --check accepted a repo that COMMITS docs/LLM_CALL_SITES.md — a PR that re-commits the render would switch this gate off by doing so"
  git -C "$T/repo" rm -q --cached docs/LLM_CALL_SITES.md >/dev/null 2>&1
  git -C "$T/repo" -c user.email=t@example.com -c user.name=t commit -qm uncommit >/dev/null 2>&1
  ( cd "$T/repo" && bash bin/llm-sites-build.sh --check --repo "$T/repo" >/dev/null 2>&1 )
  [ "$?" = 0 ] && ok \
    || bad "6b2: --check refuses the same repo once the render is out of git — the refusal was not about the tracked copy"
  # A refused/absent catalog must NOT leave a half-written doc behind.
  printf 'not json' > "$T/repo/catalog/llm-sites.json"
  before=$(cat "$T/repo/docs/LLM_CALL_SITES.md")
  ( cd "$T/repo" && bash bin/llm-sites-build.sh --repo "$T/repo" >/dev/null 2>&1 )
  rc=$?
  [ "$rc" -ne 0 ] && ok || bad "6c: the generator accepted a catalog that is not JSON"
  [ "$(cat "$T/repo/docs/LLM_CALL_SITES.md")" = "$before" ] && ok \
    || bad "6c: a refused build overwrote docs/LLM_CALL_SITES.md"
fi

echo "llm-call-ratchet: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
