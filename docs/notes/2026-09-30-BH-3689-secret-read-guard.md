# A PreToolUse tripwire stops agents printing env and secret files (BH-3689)

Doc: OPERATOR-SETUP

## Why

On 2026-09-29 a review subagent ran a filtered `grep` over `env/global.env` and
printed `HARNESS_SECRET` into its transcript. A prompt rule can't stop that. A
hook on the tool call can stop the obvious version of it.

## What changed

- **`bin/secret-read-guard.py`** is a Claude Code `PreToolUse` hook on
  `Read|Grep|Bash`. It exits 2 (deny, with a reason the model sees) when:
  - Read's `file_path` is a secret path;
  - Grep's `path` is a secret path, or its `glob` matches `*.env`, `.netrc`,
    `.git-credentials` or `*.pem`;
  - a Bash simple command runs one of `cat tac nl less more head tail grep egrep
    fgrep zgrep rg sed awk cut sort uniq strings xxd od base64 diff` on a
    secret path, or any command redirects `<` from one. Leading `VAR=val` and
    `sudo`, `command`, `env`, `nohup`, `time`, `nice`, `timeout`, `rtk` and
    `rtk proxy` are stripped first.

  Secret paths are basenames `*.env`, `.git-credentials`, `.netrc`,
  `*.private-key.pem` and `github-app*.pem`, anything ending
  `/.orgo/credentials`, and anything in `$HARNESS/env`, `/etc/harness/env`,
  `~/.aikido` or `~/.orgo` (also compared after following symlinks).
- **Still allowed:** `set -a; . env/global.env; set +a` and `source …`. They
  print nothing. `grep -rn global.env bin/` is allowed too. For grep, sed and
  awk the first argument is the pattern, and it only counts as a file when it
  exists on disk.
- **Heredoc bodies are not commands.** A `<<WORD` or `<<-WORD` body, through
  its terminator line, is stdin to the verb, so the hook drops it before
  judging. `cat > note.md <<'EOF'` with a body that says `cat env/global.env`
  is allowed, and so is prose with an apostrophe in it. The line carrying the
  `<<` is still judged, so `cat env/global.env <<EOF` is denied. A `<<WORD`
  with no terminator line is judged as written.
- **An unbalanced quote is not a crash.** When `shlex` can't tokenize the
  command, the hook falls back to a loose split (separators, then whitespace,
  quotes stripped) and judges that. It logs nothing.
- **Every denial is logged** with tool, verb and path only, never the command,
  the pattern or file bytes. On a box or Fly it goes through
  `bin/alert-line.sh --severity warn`, spawned detached so the verdict never
  waits. On a Mac (no `$HARNESS/logs`) it goes to
  `~/.claude/logs/secret-read-guard.log`.
- **A broken payload never blocks the fleet.** If the payload is empty, isn't
  JSON or has no `tool_name`, the hook allows the call and logs one line. If
  it crashes while judging, it denies only when the raw payload names a
  secret-looking path. Otherwise it allows. Either way it logs the exception
  class.
- **Where it's wired:**
  - `rules/settings.json` has the entry with
    `/root/harness/bin/secret-read-guard.py`, so every box gets it via
    `update-runners.sh` and `fleet-propagate.sh`.
  - `update-runners.sh` now ALERTs when the guard or `python3` is missing, the
    same as rtk and codegraph.
  - `fly/builder-runner.sh` runs `bin/secret-read-guard-install.sh
    --no-backup` after its per-job settings copy. That points the entry at
    `/data/harness/bin`. No `.bak` is written there, because the file is a fresh
    copy of canon on every job.

## Heads-up for builders: `fly/warm-env/*.env`

The tracked `fly/warm-env/*.env` files hold dummy values only, but they are
named `*.env`, so Read, Grep and `cat` on them are denied, and the Edit tool
can't be used on a file Read refused. A ticket that has to change one of them
should rewrite the file whole from Bash with a heredoc
(`cat > fly/warm-env/x.env <<'EOF'` is allowed). `sed -i` is denied, because
`sed` is a reader. Don't spend a session fighting the hook over these.

## Mac (operator step, once)

From the checkout on the Mac:

```bash
~/cromford/bin/secret-read-guard-install.sh
```

It merges one entry into `~/.claude/settings.json`, keeps everything else,
writes a `.bak-<stamp>` of the old file, and replaces instead of duplicating on
a re-run. Run it again after moving the checkout, because the entry holds the
absolute path. `--settings <file>` targets another file. It needs `jq` and
`python3`.

## What it does not stop

This is a tripwire, not a sandbox. It does not stop:

- `python3 -c 'open(...)'`, node or perl one-liners;
- `bash -c "<string>"`, `eval` or backticks;
- copy-then-print (`cp env/x.env /tmp/y; cat /tmp/y`);
- reader verbs not on the list;
- a recursive grep over a parent of a secret dir (`grep -r X /root/harness`);
- any tool other than Read, Grep and Bash.

It also only runs where the `user` settings source is loaded. A session
started with `SESSION_PROFILE_SETTING_SOURCES=project,local` does not load it.
