# Cromford release commits carry bullet release notes (BH-7185)

Doc: OPERATOR-SETUP, SELF-HOST

Each release commit on `cromford-ai/cromford` used to be one line. A reader saw
what changed in the code, but not why. The subject line does not change. The
body now lists the PRs merged since the previous release.

**Where the range comes from.** `bin/publish-share.sh` step 5 reads the
published head's subject (`Cromford <date> (upstream <sha12>)`) and passes it
to `bin/share/release_message.py` with `--previous-subject`, plus
`--notes-repo` (the clean upstream clone). The script resolves the sha in that
clone and requires it to be an ancestor of the new upstream sha. If any step
fails, the body is the one line `- release notes unavailable for this build`.
It never guesses and never lists the full history. A notes failure never
refuses the release.

**What is a PR.** A first-parent commit in `<prev>..<new>`, oldest first, whose
subject is `Merge pull request #<n> from ...` (the title is the first body
line) or ends in ` (#<n>)` (a squash). Direct commits get no bullet.

**What happens to a title.**
1. A raw title with a `mapping.NAME_TOKENS` entry or a
   `mapping.RELEASE_MESSAGE_FORBIDDEN` word is dropped.
2. `BH-` keys, the `mapping.TICKET_PREFIXES` keys and `#<n>` refs are removed.
3. `sanitize.rewrite` runs (the tree's host, account and id rules).
4. A result that still names anybody, or is empty, is dropped.

At most 40 bullets, then `- and N more changes`. Dropped titles are counted in a
last line `- N internal changes not listed`. stderr gets one line with the
count by class. A dropped title is never printed.

**Guards.** leakcheck and the gitleaks gate still run over the whole message.
A title with a credential shape is not dropped by the script. leakcheck refuses
the publish, as before.

**PR refs.** The spec allowed a `(#<ref>)` when the mapping makes it safe. The
mapping has no public PR numbers, so bullets carry no ref.

Tests: `tests/share-release-notes.bh-7185-test.sh` (the script and the real
publisher against a local bare repo); `tests/publish-cromford-append.bh-4901-test.sh`
A5 now expects the fallback bullet under the subject.
