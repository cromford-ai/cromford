#!/bin/bash
# tests/no-raw-claude-test.sh — nothing under bin/, fly/ or skills/ may run
# `claude -p` / `claude --print` except bin/agent-call.sh, bin/claude-cost.sh,
# and the files named in tests/raw-claude-allowlist.txt with a reason.
#
# THE HOLE THIS CLOSES. A cost row is written by whatever wraps the call, so a
# script that runs the CLI itself spends real money and leaves NOTHING in
# logs/cost.csv. That is not a lane reporting wrong numbers, it is a lane
# reporting none — the class the orchestrator was in until it was instrumented,
# the class the per-box chat was in, the class bin/greenfield.sh was in on the
# day this lint was written. Every one of them was found by grep, months apart,
# after the spend had already happened. A grep that runs in CI finds the next
# one before it does.
#
# The rule is deliberately about the WRAPPER, not about the money: a call that
# is cheap today is a loop tomorrow, and "it is only haiku" is exactly the
# reasoning that made $18,863 invisible. The only standing exceptions are
# credential PROBES, where wrapping the call would change what it proves, and
# they are listed with that reason.
#
# Self-tested: the scanner is run against fixture trees as well as the repo, so
# a lint that has quietly stopped matching (a regex edit, a refactor) fails here
# rather than passing silently — a green lint that greps for nothing is worse
# than no lint, because it is trusted.
# Run from anywhere: tests/no-raw-claude-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# scan <root> <allowlist> — prints "path:lineno:text" for every offending line.
# The matcher, in words: a command WORD `claude` (start of a command, not part
# of claude-cost.sh or a --flag or a path), whose arguments up to the end of the
# command include -p, a bundle containing p (-pc), or --print. Comments are
# skipped: half this repo TALKS about `claude -p` in its header, and a lint a
# comment can trip is a lint people turn off.
scan() {
  ROOT="$1" ALLOW="$2" python3 - <<'PY'
import os, re, sys

root  = os.environ["ROOT"]
allow_file = os.environ["ALLOW"]

# Always allowed: the two wrappers themselves. They are the ones that ARE the
# instrumented path, so the rule cannot apply to them.
WRAPPERS = {"bin/agent-call.sh", "bin/claude-cost.sh"}

allowed = set()
try:
    for line in open(allow_file, errors="ignore"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        path, _, reason = line.partition(":")
        if path.strip() and reason.strip():
            allowed.add(path.strip())
except OSError:
    pass

# `claude` as a command word. Not preceded by a path separator, a dash or a word
# character, so bin/claude-cost.sh, ./claude-cost.sh and $CLAUDE_BIN never match;
# the `-cost.sh` suffix is excluded by requiring whitespace after the word.
CMD = re.compile(r'(?:^|[\s;&|(`]|\$\()claude\s')
# -p, --print, or a short bundle carrying p (-pc). Not --permission-mode and not
# a long flag that merely contains p.
PFLAG = re.compile(r'(?:^|\s)(?:--print|-[a-zA-Z]*p[a-zA-Z]*)(?=\s|$|=)')

hits = []
for sub in ("bin", "fly", "skills"):
    base = os.path.join(root, sub)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules")]
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            if rel in WRAPPERS or rel in allowed:
                continue
            try:
                if os.path.getsize(full) > 4_000_000:
                    continue
                text = open(full, errors="ignore").read()
            except OSError:
                continue
            if "claude" not in text:
                continue
            for n, line in enumerate(text.splitlines(), 1):
                stripped = line.lstrip()
                if stripped.startswith("#"):
                    continue
                m = CMD.search(line)
                if not m:
                    continue
                # Only the arguments of THIS command, up to the next separator,
                # so `claude foo | grep -p` is not a hit.
                rest = line[m.end():]
                rest = re.split(r'[;|&]|\breturn\b', rest)[0]
                # A long flag's VALUE may legitimately contain -p; drop the
                # quoted strings before looking for the flag.
                rest = re.sub(r'"[^"]*"|\'[^\']*\'', " ", rest)
                if PFLAG.search(" " + rest):
                    hits.append("%s:%d:%s" % (rel, n, stripped[:120]))

for h in hits:
    print(h)
PY
}

ALLOW="$DIR/tests/raw-claude-allowlist.txt"

# ── 1. the lint itself, against this repo ────────────────────────────────────
HITS=$(scan "$DIR" "$ALLOW")
if [ -z "$HITS" ]; then
  ok
else
  bad "raw \`claude -p\` outside bin/agent-call.sh and bin/claude-cost.sh:
$HITS

Route the call through bin/claude-cost.sh (same argv, same stdout, same exit
code, plus a cost row priced from the run's transcript) or through
bin/agent-call.sh if it wants the model ladder and failover too. If the call is
a credential PROBE and wrapping it would change what it proves, add it to
tests/raw-claude-allowlist.txt with that reason."
fi

# ── 2. the allowlist is a list of REASONS, not a list of paths ───────────────
# An entry with no reason is a silent exemption, which is the thing being
# prevented wearing a different hat.
[ -f "$ALLOW" ] && ok || bad "tests/raw-claude-allowlist.txt must exist (an empty allowlist is fine; a missing one is a lint nobody can read)"
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  P="${line%%:*}"; R="${line#*:}"
  [ -n "$(printf '%s' "$R" | tr -d ' ')" ] \
    || bad "allowlist entry '$P' carries no reason"
  [ -e "$DIR/$P" ] \
    || bad "allowlist names $P, which does not exist — a stale exemption silently widens the rule"
done < "$ALLOW"
ok

# ── 3. the scanner actually fires (a lint that matches nothing is not a lint) ─
mkdir -p "$T/repo/bin" "$T/repo/fly" "$T/repo/skills" "$T/repo/tests"
: > "$T/repo/tests/allow.txt"
cat > "$T/repo/bin/offender.sh" <<'EOF'
#!/bin/bash
OUT=$(claude -p --model x "hello")
EOF
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] \
  && ok || bad "the scanner must flag a plain \`claude -p\`"

# the same call behind `env`, `timeout` and a pipe — every shape the repo uses
cat > "$T/repo/bin/offender.sh" <<'EOF'
#!/bin/bash
echo hi | timeout 60 env IS_SANDBOX=1 claude -p --model x
EOF
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] \
  && ok || bad "the scanner must see through timeout/env/pipe wrapping"

cat > "$T/repo/bin/offender.sh" <<'EOF'
#!/bin/bash
claude --print "hello"
EOF
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] \
  && ok || bad "the scanner must flag \`claude --print\`"

cat > "$T/repo/bin/offender.sh" <<'EOF'
#!/bin/bash
claude -pc --model x "hello"
EOF
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] \
  && ok || bad "the scanner must flag a bundled short flag (-pc)"

# fly/ and skills/ are scanned too, not just bin/
rm -f "$T/repo/bin/offender.sh"
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo/fly/offender.sh"
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] && ok || bad "fly/ must be scanned"
rm -f "$T/repo/fly/offender.sh"
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo/skills/offender.sh"
[ -n "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] && ok || bad "skills/ must be scanned"
rm -f "$T/repo/skills/offender.sh"

# ── 4. and it does NOT fire on the things that are fine ──────────────────────
cat > "$T/repo/bin/ok.sh" <<'EOF'
#!/bin/bash
# this file TALKS about claude -p in a comment, at length, because that is what
# half the headers in this repo do:   claude -p --model x
   # claude --print "indented comment"
"$HARNESS/bin/claude-cost.sh" -p --model x "hello"
"$(dirname "$0")/claude-cost.sh" -p --model x "hello"
CLAUDE_BIN=/root/harness/bin/claude-cost.sh
"$CLAUDE_BIN" -p --model x "hello"
claude --version
claude mcp list
claude -p_not_a_flag
echo "claude -p" > /tmp/doc.txt
EOF
H=$(scan "$T/repo" "$T/repo/tests/allow.txt")
[ -z "$H" ] && ok || bad "false positives on the legitimate forms:
$H"

# a quoted string containing -p is not a flag
printf '#!/bin/bash\nclaude mcp add --transport stdio x -- y --port 1\n' > "$T/repo/bin/ok.sh"
[ -z "$(scan "$T/repo" "$T/repo/tests/allow.txt")" ] \
  && ok || bad "a non -p subcommand must not be flagged"
rm -f "$T/repo/bin/ok.sh"

# ── 5. the allowlist exempts, and ONLY the file it names ─────────────────────
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo/bin/probe.sh"
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo/bin/other.sh"
printf 'bin/probe.sh: it is a credential probe\n' > "$T/repo/tests/allow.txt"
H=$(scan "$T/repo" "$T/repo/tests/allow.txt")
grep -q 'bin/other.sh' <<<"$H" && ok || bad "a file NOT on the allowlist must still be flagged"
grep -q 'bin/probe.sh' <<<"$(printf '%s' "$H")" && bad "an allowlisted file must not be flagged" || ok
rm -f "$T/repo/bin/probe.sh" "$T/repo/bin/other.sh"

# ── 6. the two wrappers are exempt by construction, never by allowlist ───────
# If they had to be listed, deleting the list would make the instrumented path
# itself the violation.
mkdir -p "$T/repo2/bin" "$T/repo2/fly" "$T/repo2/skills"
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo2/bin/agent-call.sh"
printf '#!/bin/bash\nclaude -p hello\n' > "$T/repo2/bin/claude-cost.sh"
: > "$T/empty-allow.txt"
[ -z "$(scan "$T/repo2" "$T/empty-allow.txt")" ] \
  && ok || bad "bin/agent-call.sh and bin/claude-cost.sh must be exempt with no allowlist at all"

# ── 7. the real wrappers really are the instrumented path ────────────────────
# The lint means nothing if what it points people at does not write a row.
grep -q 'cost_append' "$DIR/bin/claude-cost.sh" \
  && ok || bad "bin/claude-cost.sh must append a cost row — the lint sends callers there"
grep -q 'cost_append' "$DIR/bin/agent-call.sh" \
  && ok || bad "bin/agent-call.sh must append a cost row"
grep -q 'cost_append' "$DIR/bin/lib/cost-row.sh" \
  && ok || bad "bin/lib/cost-row.sh must define the shared row writer both wrappers use"

echo "no-raw-claude: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
