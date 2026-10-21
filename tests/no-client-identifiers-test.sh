#!/bin/bash
# tests/no-client-identifiers-test.sh — this copy must not name anybody.
#
# In this repository every project, person, machine, account and credential is
# an example name. This test fails if a real one comes in.
#
# WHY THERE ARE NO NAMES IN THIS FILE, IN ANY FORM. The obvious way to write
# this check is to grep for the real names, which would put every one of them in
# plaintext in a public repository, inside the file whose job is to keep them
# out. A leak guard that is itself the leak.
#
# The less obvious version has the same problem. An earlier draft carried salted
# sha256 digests of the names instead of the names — but the salt has to ship
# with them for the check to run, and a digest you can compute is an ORACLE:
# anyone could hash a company name, compare, and get a yes-or-no answer to "is
# this one of their clients?". Confirming the guess is the disclosure. A list
# you can query one name at a time is still a list.
#
# So this file matches SHAPES only. Shapes identify by form rather than by
# spelling — private network addresses, account uuids, long hex ids, hosting and
# messaging ids, ticket keys that are not the placeholder TK-, the per-project
# environment-variable convention, machine hostnames, and the credential shapes
# gitleaks looks for. None of them need a name to work, and none of them can be
# asked whether a particular name is on a list, because there is no list.
#
# Names are checked by the maintainers' own guard, which runs against this tree
# before every release with nothing exempted. Accepted contributions go through
# that same guard when they are carried in, so a name reintroduced in a PR here
# is still caught. Just not by you, and not by telling the internet what it was
# looking for.
#
# usage: bash tests/no-client-identifiers-test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2

python3 - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".wrangler", "dist", "build"}

# Credential-shaped strings that are fixtures. The repo tests its own secret
# handling, so it has to contain some. Matched as exact strings, never by path:
# a path exemption would also wave through a real key pasted into one of these
# same files, which is the likeliest way a key actually escapes.
KNOWN_FAKE_CREDENTIALS = {
    '-----BEGIN RSA PRIVATE KEY-----',
    'AKIAEXAMPLEFIXTUREXX',
    'AKIAIOSFODNN7EXAMPLE',
    'Bearer eyJhbGciOiJIUzI1NiJ9payloadpart.sigsigsig',
    'ghp_abcdefghijklmnopqrstuvwxyz1234',
    'sk-abcdefghijklmnop',
    'sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAA',
    'sk-ant-api03-EXAMPLE-FIXTURE-NOT-A-REAL-KEY',
    'sk-ant-oat01-FAKE-TEST-TOKEN-do-not-ship-0123456789abcdef',
    'sk-ant-oat01-FIXTURE-ACCESS-do-not-ship-b',
    'sk-ant-oat01-FIXTURE-PARENT-token',
    'sk-ant-oat01-FIXTURE2-do-not-ship-c',
    'sk-ant-oat01-FIXTURE-MASTER-token',
    'sk-ant-oat01-FIXTURE-do-not-ship-aaa',
    'sk-ant-oat01-FIXTURE-do-not-ship-bbb',
    'sk-live-DEADBEEF-do-not-exfiltrate',
    'sk-or-v1-FIXTUREKEYNOTREAL0001',
    'sk-or-v1-LEAKYLABEL9999',
    'sk-or-v1-LEAKYPAYLOAD9999',
    'xoxb-1234567890-abcdefghijk',
}

# Identifier-shaped strings that are fixtures, on the same terms: exact
# strings, never a path. Each one is provably not the thing it resembles — a
# uuid whose 32 hex digits use at most two distinct characters is nobody's
# generated uuid, and every address below is outside the 100.64/10 range
# private network addresses are drawn from, so none can be one. (Written
# 100.64/10 rather than in full: the guard above matches any 100.x.x.x, this
# file included, and it is right to.)
KNOWN_FAKE_IDENTIFIERS = {
    '100.0.0.1',
    '100.0.0.8',
    '100.0.0.9',
    '11111111-1111-1111-1111-111111111111',
    '1111111b-1111-1111-1111-111111111111',
    '1111111c-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '2222222b-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    '44444444-4444-4444-4444-444444444444',
    '55555555-5555-5555-5555-555555555555',
    '77777777-7777-7777-7777-777777777777',
    '88888888-8888-8888-8888-888888888888',
    '99999999-9999-9999-9999-999999999999',
}
KNOWN_FAKES = KNOWN_FAKE_CREDENTIALS | KNOWN_FAKE_IDENTIFIERS

# Published checksums of third-party release artifacts — kept apart from the
# two lists above because these are NOT fakes, they are real sha256 sums of
# files anyone can download. The `64-hex token` pattern cannot tell a release
# checksum from a secret and is right not to try, so the exemption is per
# literal. A value belongs here only if it is the sha256 of a PUBLIC
# open-source release asset, the comment names the tool, version and file so a
# reviewer can re-hash it, and nothing is secret about knowing it. A checksum
# of anything built here, or of anything behind a credential, does not qualify.
KNOWN_PUBLIC_CHECKSUMS = {
    # ShellCheck 0.11.0, the pin in bin/ci-shellcheck.sh — release assets
    # shellcheck-v0.11.0.linux.x86_64.tar.xz and .linux.aarch64.tar.xz.
    '8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198',
    '12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588',
    # gitleaks 8.30.1, the pin in .github/workflows/harness-ci.yml — release
    # asset gitleaks_8.30.1_linux_x64.tar.gz.
    '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb',
    # The published SHA-256 test vectors (FIPS 180-2): sha256 of the empty
    # string and of "abc". Anyone re-hashes them in one command (BH-5558).
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    # Postgres 16.14 for the pool suite run, the pin in bin/lib/pgtest-pin.sh —
    # the npm tarball @embedded-postgres/linux-x64 16.14.0-beta.17 (BH-5962).
    'dfe7ecd8365ab907786e5f3d69179399f9675ac800153219efb2590257c2d551',
}

# The second exemption: a credential-shaped literal whose own text says it is a
# fixture. The marker must sit INSIDE the matched string — a comment earlier on
# the line exempts nothing, or every real key would be one comment away from
# shipping. The exact lists above stay for fixtures that cannot carry a marker.
FIXTURE_MARKERS = ('fixture', 'do-not-ship', 'example')


def is_fixture_literal(s):
    low = s.lower()
    return any(m in low for m in FIXTURE_MARKERS)


# A binary is a file this guard cannot read, and a screenshot of a dashboard is
# a client list in exactly that form. Only these extensions may hold bytes that
# are not valid text (the malformed-input fixtures carry control bytes on
# purpose); anything else non-text is refused outright.
TEXT_EXT = {'', '.conf', '.cron', '.css', '.csv', '.diff', '.dockerfile', '.drop', '.editorconfig',
            '.eml', '.env', '.example', '.gitignore', '.golden', '.html', '.js',
            '.json', '.jsonc', '.jsonl', '.jsx', '.list', '.lock', '.log', '.md',
            '.mjs', '.cjs', '.order', '.patch', '.py', '.ro', '.rw', '.wo', '.sh', '.sql', '.svg', '.toml',
            '.ts', '.tsx', '.tsv', '.txt', '.xml', '.yaml', '.yml'}
FONT_EXT = {'.eot', '.otf', '.ttf', '.woff', '.woff2'}

# ---- 1. shapes -------------------------------------------------------------
PATTERNS = [
    ("private network address", r"\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    ("board ticket key",     r"\b(?:AR|FR|PB|IA|SO|TS|MK|OM|CF|SG|MO|AIO)-\d{1,5}\b"),
    ("account uuid",         r"\b(?!00000000-0000-0000-0000-)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),
    ("32-hex account id",    r"\b(?!0{32})(?!x{32})[0-9a-f]{32}\b"),
    ("hosting project id",   r"\b(?:team|prj)_(?!EXAMPLE)[A-Za-z0-9]{20,}\b"),
    ("messaging chat id",    r"-100(?!0000000000\b)\d{10}\b"),
    ("openai/anthropic key", r"\bsk-[A-Za-z0-9_\-]{16,}"),
    ("stripe live key",      r"\bsk_live_[A-Za-z0-9]{8,}"),
    ("github token",         r"\b(?:ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}"),
    ("github pat",           r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    ("slack token",          r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"),
    ("aws access key",       r"\bAKIA[0-9A-Z]{16}\b"),
    ("private key block",    r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("bearer literal",       r"Bearer\s+[A-Za-z0-9_\-\.]{24,}"),
    ("64-hex token",         r"\b(?!0{64})[0-9a-f]{64}\b"),
]
pats = [(label, re.compile(rx, re.I)) for label, rx in PATTERNS]

# The upstream fleet's box hostnames follow a naming convention this copy does
# not use — boxes here are box-*. The HYPHENATED or underscored form of that
# convention is a hostname and must not appear; the same two words with a space
# between them are ordinary description ("machine-per-OS board watchers",
# "kills a board's watcher") and are left alone, because a guard that fires on
# prose gets ignored, and being ignored is how a guard fails.
#
# NOT CHECKED HERE: the per-project environment-variable prefixes. The
# convention is <PREFIX>_API_BASE, <PREFIX>_INTERNAL_API_TOKEN and so on, and
# there is no shape that separates a real customer's prefix from a legitimate
# one — this tree contains vendor vars and test fixtures in exactly that form.
# Telling them apart needs the list of real prefixes, which is precisely what
# must not ship. That check runs upstream instead.
STRUCTURAL = [
    ("machine hostname", r"board[-_]watchers?\b"),
]
pats += [(label, re.compile(rx, re.I)) for label, rx in STRUCTURAL]

hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for name in filenames:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        # No self-exemption: this file contains no names, so it has nothing to
        # hide from its own scan. The path is scanned like any other line.
        for label, rx in pats:
            for m in rx.finditer(rel):
                hits.append((rel, 0, "%s in path: %s" % (label, m.group(0)[:60])))
        ext = os.path.splitext(rel)[1].lower()
        if ext in FONT_EXT:
            continue
        if ext not in TEXT_EXT:
            hits.append((rel, 0, "un-auditable non-text file (%s)" % (ext or "no extension")))
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                for label, rx in pats:
                    for m in rx.finditer(line):
                        if (m.group(0) in KNOWN_FAKES
                                or m.group(0) in KNOWN_PUBLIC_CHECKSUMS
                                or is_fixture_literal(m.group(0))):
                            continue
                        hits.append((rel, n, "%s: %s" % (label, m.group(0)[:60])))

if hits:
    for rel, n, what in hits[:200]:
        print("%s:%d: %s" % (rel, n, what))
    if len(hits) > 200:
        print("... and %d more" % (len(hits) - 200))
    print("\nFAIL: %d hit(s). This tree is public — none of these may ship." % len(hits))
    sys.exit(1)
print("PASS: no client, person, machine, account or credential identifiers.")
PY
