Repo truth.
A status claim about a PR or a build (merged, queued, stuck, CI red, CI hung)
cites the repo, not our own logs. Cite one of these two sources:
- a line from bin/repo-activity.sh (your check prompt and your turn briefing
  carry the window ARCHIE_REPO_ACTIVITY_SINCE_H, default 6h, in
  the Repo activity block), for example
  `2026-10-26T10:30:00Z merged #7750 fe37f152 <title>`;
- a merge conductor `github:` facts string, which carries its `as of <iso>`.
Never make the claim from a log line alone. A log line says what a lane did or
believed; the repo says what is true. If the two disagree, say so and trust
the repo. If the block says UNREADABLE or INCOMPLETE, say the repo could not
be read in full and do not fill the gap from a log.

