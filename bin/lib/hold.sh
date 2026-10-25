#!/bin/bash
# bin/lib/hold.sh — IS THIS TICKET HELD? One reading, shared by both lanes that
# re-enqueue builds (bin/blocked-resolver.sh, bin/orphan-reconcile.sh).
#
# WHY IT EXISTS (console alert 6726, 2026-09-14). project-5 #414's parent PR was
# CLOSED, the issue put on HOLD and de-labelled by the operator ("do not rebuild",
# 07:03Z) — and bin/blocked-resolver.sh enqueued a fresh build of it three times
# that morning. The rung that rebuilds a ticket read the PR and its own
# counters; nothing on that path ever read the ISSUE. A human instruction on the
# ticket was invisible to the lane whose whole job is restarting tickets.
#
# THREAD RECENCY IS THE LAW, IN BOTH DIRECTIONS. bin/orphan-reconcile.sh already
# honoured a HOLD, but treated any HOLD ever written as permanent — so a ticket
# the operator later said RESUME on stayed parked for ever, in a harness where nothing
# waits on a person to unstick it (the operator, 2026-09-13). So the NEWEST HUMAN
# comment wins: the first decisive comment walking backwards decides, neutral
# comments (the harness's own close-outs) are skipped, and only then do the
# title and body get a say.
#
# WHAT LIFTS A HOLD IS A SHORT, EXPLICIT VOCABULARY, and that is deliberate.
# Under the other reading — any later human comment lifts — the harness's own
# PAT-posted "we rebuilt this ticket fresh" comment would have lifted the operator's
# hold, which is the incident again.
#
# UNREADABLE IS ITS OWN ANSWER, never "clear" (the 1-vs-2 split br_pr_ref
# learned on 2026-09-16): a rate-limited read says nothing about the ticket, so
# the caller retries next tick instead of spending a rung on a rebuild GitHub
# never authorised.
#
# Sourced, never executed. Two entry points:
#   hold_classify <issue-json> <comments-json>   PURE (jq only, no network)
#   hold_check    <owner/repo> <issue-number>    the gh read, then hold_classify
# Both print "<held|clear|unreadable><TAB><why>" and answer rc 1 / 0 / 2.
# The held tails are hold:comment|title|body|label, abandon:comment, closed,
# label-absent, hold:waiting-on-human <at> <action> (BH-3443) and
# hold:human-fix <at> <line> (BH-5125); the clear tails are no-hold,
# lifted-by-comment <at>, lifted-by-human-step <at> and
# hold:go-live <at> <step> (BH-7123 wave B: an open go-live step that gates
# nothing; BH-7873: hold_is_pause reads it as clear too, so it defers no build).
#
# THE WHY NAMES THE LINE THAT DECIDED (BH-1461): `hold:body <line>`,
# `hold:title <line>`, `hold:comment <at> <line>`. The verdict TOKEN in front is
# unchanged and stays the thing to match on; the tail is for humans, and
# bin/fly-pool.sh quotes it back on the ticket so a skip is never silent.

# THE FOUR REGEXES ARE THE SHARED SURFACE. They are exported because
# bin/orphan-reconcile.sh classifies inside a python3 heredoc, and two copies of
# "what counts as a hold" is the drift that this whole file exists to remove.
# Both engines (jq's oniguruma and python3 `re`) accept every construct used
# here — lookarounds, scoped `(?i:…)`, `\x27` for the apostrophe.
#
# HOLD as a WORD and in CAPITALS: `HOLD —`, `(HOLD)`, `HOLD:`. Never `hold` in
# prose ("until the operator lifts the hold" is a description of one, not a new one).
# Verbatim the regex bin/orphan-reconcile.sh has used since it shipped. It no
# longer decides a comment (HOLD_COMMENT_RE does): it stays exported for the
# python fallbacks of a box that has not synced this file.
HOLD_WORD_RE='(?<![A-Za-z])HOLD(?![A-Za-z])'
# A COMMENT HOLDS ONLY WHEN ITS FIRST NON-BLANK LINE STARTS WITH HOLD (BH-6297).
# #5239 waited 4 h 27 min on 2026-10-12: a decision comment said, in its fourth
# line, that two OTHER PRs "are on HOLD here", and the word regex read that as a
# hold on the ticket. `HOLD`, `HOLD —`, `HOLD:` and `HOLD this until …` opening
# the comment hold; a later line, `Please HOLD`, `> HOLD`, `- HOLD`, a code span,
# `HOLD-free`, `HOLDING` and `HOLD_X` do not. `\A` means the same in jq's
# Oniguruma and python3 `re` (bin/launch-fastpath.sh's fallback reads it too).
HOLD_COMMENT_RE='\A[ \t\r\n]*HOLD(?![A-Za-z0-9_]|-[A-Za-z0-9])'
# THE LIFT VOCABULARY. The capital words RESUME / UNHOLD, or an explicit
# "hold lifted / lift the hold / hold is off" phrase, anywhere in a comment.
# `resume` in lower case mid-sentence is harness prose ("the resume lane's
# BUILD_DEAD"); opening the comment it is a lift (HOLD_LIFT_LEAD_RE below).
HOLD_LIFT_RE='(?<![A-Za-z])(RESUME|UNHOLD)(?![A-Za-z])|(?i:(?<![A-Za-z])unhold(?![A-Za-z])|(?<![A-Za-z])hold\s+(is\s+|was\s+)?(lifted|released|cleared|off)(?![A-Za-z])|(?<![A-Za-z])(lift|lifted|lifting|release|released|releasing|clear|cleared|clearing)\s+the\s+hold(?![A-Za-z]))'
# A NEGATION OR A CONDITION in front of the lift verb turns a would-be lift back
# into silence: "Do NOT RESUME this yet", "until the operator lifts the hold", "if the
# hold is lifted we can build". A comment is a lift only when LIFT matches and
# this does not.
# `abandon` and `close-pr` ride in the same alternation for the same reason:
# "Do NOT ABANDON this yet" is not an instruction to close anything (BH-1460).
HOLD_NEG_RE='(?i:(?<![A-Za-z])(not|never|don\x27?t|do\s+not|until|unless|before|once|if|when)(\W+\w+){0,3}\W+(resum|unhold|lift|releas|clear|abandon|close-pr))'
# PAUSE AND ABANDON ARE DIFFERENT DECISIONS, SO THEY GET DIFFERENT WORDS
# (BH-1460, 2026-09-22). A HOLD means "stop the automation on this ticket" — no
# fix rounds, no rebuilds, no re-reviews — and it must NEVER touch an open PR:
# on 2026-09-22 the lead held #1386 to adjudicate the park on its PR #1453 by
# hand, and twenty minutes later that green, approved PR was closed and a person
# had to reopen it. One gesture was doing two jobs, so throwing the work away
# now needs a word that says so: ABANDON, or CLOSE-PR.
#
# Capitals and word-bounded, the style HOLD_LIFT_RE sets — lower-case `abandon`
# is harness prose ("the abandoned branch is still there") and never an
# instruction. THREAD ONLY: a title or a body never abandons, which is BH-1461's
# lesson applied before the incident instead of after it.
HOLD_ABANDON_RE='(?<![A-Za-z])(ABANDON|CLOSE-PR)(?![A-Za-z])'
# A BODY HOLD IS A LINE, NEVER A WORD IN PROSE (BH-1461, 2026-09-22). A ticket
# BODY is where this harness documents itself, so the word HOLD appears in it
# constantly as a NOUN — and HOLD_WORD_RE held every such ticket for ever. On
# 2026-09-22 the pool skipped BH-1325 ("after the operator HOLD (...)"), BH-1381
# ("merge-conductor.held_pages") and BH-1419 ("a per-project HOLD row") on every
# tick for four hours: a ticket that DESCRIBES the hold mechanism could never be
# built, and the queue those three sat in read as a wedged pool.
#
# So a body holds only when a LINE BEGINS with the instruction: `HOLD` alone,
# `HOLD:`, `HOLD —` (or an en dash / hyphen, which is the same gesture typed
# differently). A mid-line mention, a code span, a `>` quote and a `| HOLD |`
# table cell all fail it, because none of them starts the line with the word.
#
# AND THE SHAPES THAT NOW HOLD NOTHING, said out loud because a non-hold is
# silent by design: `**HOLD**`, `- HOLD: …`, `## HOLD`, `HOLD until …` are all
# prose to this regex. The first three do not start the line with the bare word
# and the fourth has no `:`/dash after it. That is in contract (BH-1461): an
# operator who means it types `HOLD:` on its own line.
#
# `(?m)` IS REQUIRED BY BOTH ENGINES that read this string: Python `re` and
# jq's Perl-syntax Oniguruma both anchor `^` to the whole STRING without it, so
# dropping it makes a mid-body `HOLD:` line invisible to EITHER. Measured on
# jq 1.7.1: `"prose\nHOLD: x" | test("^HOLD")` is false and `test("(?m)^HOLD")`
# is true; `(?m)` is not dot-matches-newline there either
# (`"a\nb" | test("(?m)a.b")` is false). `\r?$` because GitHub serves issue
# bodies CRLF.
#
# COMMENTS ARE NOT THIS. A comment takes HOLD_COMMENT_RE: its first non-blank
# line, not any line.
HOLD_BODY_RE='(?m)^HOLD[ \t]*(?:[:—–-]|\r?$)'
# A TITLE HOLDS ONLY IN THE IDIOM (2026-09-28): `(HOLD)`, `(ON HOLD)` or
# `[HOLD]` anywhere, or `HOLD` / `ON HOLD` opening the title (after the ticket
# key it may lead with, `TK-9:`) followed by `:` or a dash — the body rule's
# `:—–-`. `Compliance P7 (HOLD): EU residency` is the real one. Titles used to take HOLD_WORD_RE, and a title that NAMES the hold
# feature held its own ticket for ever: "per-PR HOLD / RESUME / DROP", and
# REVIEW_D1_HOLD_MAX_H, where `_` was not a word character to the lookarounds.
# BH-1461's body lesson, one field over. `_` is a word character here, so
# `HOLD_X: …` opening a title is a symbol, not the instruction.
HOLD_TITLE_RE='\((?:ON[ \t]+)?HOLD\)|\[(?:ON[ \t]+)?HOLD\]|^[ \t]*(?:[A-Z]+-[0-9]+(?:\.[0-9]+)*[: \t]+)?(?:ON[ \t]+)?HOLD(?![A-Za-z_])[ \t]*[:—–-]'
# A LIFT WORD OPENING A PERSON'S COMMENT LIFTS, WHATEVER FOLLOWS (BH-3435,
# 2026-09-29). project-5 #3354: "RELEASED (the operator, 2026-09-28). Proceed on the
# decision in #3348 … This supersedes the HOLD." matched no lift above, so its
# capital HOLD read as a fresh hold and the ticket sat 15.6 hours. So the first
# word of the comment (after whitespace), any case, is asked BEFORE the abandon
# and hold tests: RESUME, RELEASE, RELEASED, UNHOLD, PROCEED. Followed by a
# letter, digit, `_`, `-` or `?` it is not the word ("Proceeding once", "Proceed?
# not yet"). HOLD_NEG_RE still applies: "RESUME once #12 merges" lifts nothing,
# and it re-holds nothing either. `\A` means the same in jq's Oniguruma and
# python3 `re` (bin/launch-fastpath.sh reads this string too).
HOLD_LIFT_LEAD_RE='\A[ \t\r\n]*(?i:resume|release|released|unhold|proceed)(?![A-Za-z0-9_?-])'
# A PERSON'S COMMENT THAT OPENS WITH `HOLD:` IS A HOLD, WHATEVER FOLLOWS
# (BH-6091, 2026-10-12). The mirror of the lead-lift rule above. #5962: the operator
# wrote "HOLD: the lead reversed the RESUME above" at 23:36:14Z and "HOLD: …
# Please make no pool push until the PR is open and RESUME …" at 00:16:03Z.
# Both carried a capital RESUME, the lift-anywhere arm read each as a lift, and
# a running pool build pushed twice under them. Capital HOLD first (after
# whitespace), then `:` or a dash, the body rule's `:—–-`. "HOLD lifted" has
# no colon or dash and is not this, so it still lifts. Asked after the lead-lift
# arm, so "RESUME: the HOLD above is withdrawn" still lifts. `\A` means the same
# in jq's Oniguruma and python3 `re` (bin/launch-fastpath.sh reads it too).
# A BARE `HOLD` LINE IS THE SAME HOLD (review of 82abecc2): the lead's HOLD
# comments on #6091 are `HOLD`, a blank line, then text that names RESUME. So
# a first non-empty line that is only `hold` (any case, trailing blanks) holds
# too. The dash needs a word boundary: "HOLD-free comment: RESUME now" is not
# a hold. `\Z` and `(?i:…)` mean the same in Oniguruma and python3 `re`.
HOLD_LEAD_RE='\A[ \t\r\n]*(?:HOLD[ \t]*(?:[:—–]|-(?![A-Za-z0-9]))|(?i:hold)[ \t]*(?:\r?\n|\Z))'
# WAITING ON A HUMAN (BH-3443, slice 2 of BH-3433). BH-3348 paid $6.53 in
# rebuilds of a review block that only the hub could clear: every rebuild ended
# on the same step, and nothing on the ticket said a person had to take it. So
# a comment whose line opens with `NEEDS-HUMAN: <action>` parks the ticket as
# `hold:waiting-on-human <at> <action>`, a pause to every lane that reads this
# file (hold_is_pause). bin/needs-human-hold.sh writes it as the App, which is a
# Bot, so a Bot comment is heard for this marker ONLY and only when it carries
# the placer's hidden `<!-- nh-fp:<hex> -->` tag: a harness close-out quoting a
# marker line holds nothing. A person may type one by hand, tag or not.
#   WHAT LIFTS IT: a person's `HUMAN-STEP-DONE:` line, or a `## Hub probe … PASS`
#   heading, DIRECTLY over the marker (lifted-by-human-step <at>), or the lift
#   vocabulary above (RESUME, UNHOLD …: lifted-by-comment). A done lifts only
#   the marker: a person's HOLD or ABANDON under it still stands, and a done
#   with no marker beneath it says nothing. A bot's done never releases.
#   Only comments are read for either: a title or a body describing the
#   feature quotes both words all the time.
HOLD_NEEDS_HUMAN_RE='(?m)^NEEDS-HUMAN:[ \t]*\S'
HOLD_HUMAN_DONE_RE='(?m)^(HUMAN-STEP-DONE:|##[ \t]+Hub probe\b.*\bPASS\b)'
HOLD_NH_TAG_RE='<!--[ \t]*nh-fp:[0-9a-f]+[ \t]*-->'
# A PERSON HAS TAKEN THE FIX (BH-5125). On 2026-10-07 triage skipped #5022 four
# ticks running with "fix round … is already in progress (orchestrator/operator)":
# the operator had posted a narrowing comment, which was DIRECTION for the next agent
# round, and the model read it as a person doing the work. Nothing was running.
# So "a person took this" is a marker, never an inference: a comment LINE that
# opens `Taken by: <person>` or `[human-fix]` parks the ticket as
# `hold:human-fix <at> <line>`, a pause to every lane that reads this file.
# Line-anchored like NEEDS-HUMAN: — mid-line, a `>` quote, `**Taken by:**` and a
# code span hold nothing. Heard from PEOPLE only: a bot comment never takes a
# fix, and there is no tag escape hatch for one. Comments only, never the title
# or body. Lifted exactly as NEEDS-HUMAN: is (a person's done directly over it,
# or the lift vocabulary), and a person's HOLD/ABANDON under it still stands.
HOLD_HUMAN_FIX_RE='(?m)^(Taken by:[ \t]*\S|\[human-fix\])'
# A GO-LIVE STEP IS VISIBLE, NEVER A PAUSE (BH-7123 wave B). A review's
# `NEEDS_HUMAN:` for a step a user depends on at go-live (a live connector key,
# a vendor console, DNS, a product decision; catalog/review-golive.tsv) used to
# park the ticket like any other human step and fail the merge gate with it. A
# marker whose action opens `go-live:` (bin/needs-human-hold.sh, source go-live)
# classifies CLEAR with the tail `hold:go-live <at> <step>`: bin/fly-pool.sh and
# bin/blocked-resolver.sh read the first word and proceed, hold_is_pause answers
# false (BH-7873), so bin/lib/ticket-ownership.sh and HOLD_STAGE_CHECK build it,
# the console still shows the open step from the tail, and a
# person's HUMAN-STEP-DONE / RESUME directly over it lifts it exactly as an
# ordinary marker. Everything else on the thread decides as if the go-live
# marker were not there: a person's HOLD, an ABANDON or an unanswered ordinary
# NEEDS-HUMAN under or over it still holds. Same bot rule: the placer's tagged
# marker is heard, an untagged bot line is nothing.
HOLD_GOLIVE_RE='(?m)^NEEDS-HUMAN:[ \t]*go-live:'
export HOLD_WORD_RE HOLD_COMMENT_RE HOLD_LIFT_RE HOLD_NEG_RE HOLD_BODY_RE HOLD_ABANDON_RE HOLD_TITLE_RE HOLD_LIFT_LEAD_RE HOLD_LEAD_RE
export HOLD_NEEDS_HUMAN_RE HOLD_HUMAN_DONE_RE HOLD_NH_TAG_RE HOLD_HUMAN_FIX_RE HOLD_GOLIVE_RE

# THE MARKER ON OUR OWN AMBIGUITY NOTE (hold_ambiguous_note). The note names the
# lift words in capitals and a box may post it on a PAT (user.type User), so a
# comment carrying it is never read as a person's word, in either direction.
HOLD_AMBIGUOUS_MARK='<!-- harness:hold-ambiguous'

# THE TWO READINGS OF A `held` VERDICT (BH-1460). Both answer rc 1 — an abandon
# is also "do not build" — so a caller that reads only the rc is unchanged. A
# caller that can CLOSE something has to know which one it is looking at, and it
# must not learn that by matching the string in three different spellings.
#
#   hold_is_pause    the ticket says stop: hold:comment / hold:title / hold:body
#                    / hold:label (the `hold` label, BH-2504) /
#                    hold:waiting-on-human (BH-3443) / hold:human-fix (BH-5125)
#   hold_is_abandon  the ticket says throw it away: abandon:comment
#
# `closed` and `label-absent` are neither: they are facts about the issue, not
# instructions on it, so they answer false to both and every caller keeps
# deciding them the way it already does.
#
# THE FIRST FIELD DECIDES (BH-7873). A pause is `held` (or `hold`) AND a
# `hold:` tail. `clear<TAB>hold:go-live <at> <step>` has the tail but is clear:
# matching only the tail made to_hold_verdict say held, HOLD_STAGE_CHECK defer
# every build, and bin/fly-pool.sh (first word: clear) spawn a Fly machine per
# re-offer that deferred at once. TK-1296 deferred 10 times, TK-1292 12 times.
hold_is_pause()   { case "${1:-}" in held"	hold:"*|hold"	hold:"*) return 0 ;; esac; return 1; }
hold_is_abandon() { case "${1:-}" in *"	abandon:"*) return 0 ;; esac; return 1; }

# hold__read <file-or-json> — a path when it is one, the string itself otherwise.
# The fixture suite table-drives hold_classify with literal JSON; the gh wrapper
# hands it whatever gh answered.
hold__read() {
  if [ -f "${1:-}" ]; then cat "$1"; else printf '%s' "${1:-}"; fi
}

# THE jq DEFINITIONS hold_classify AND hold_ambiguous SHARE, so "what is a
# decisive comment" and "which comment is the newest person's" have one spelling.
# The program that uses them passes $lift $neg $ab $hold $lead $holdlead $mark
# $nh $hf $done.
#
# A comment is DECISIVE-LIFT when it opens with a lift word (HOLD_LIFT_LEAD_RE,
# BH-3435) or the lift vocabulary matches, and no negation/condition precedes
# it; DECISIVE-ABANDON on the same terms for the abandon vocabulary;
# DECISIVE-HOLD when the comment opens with HOLD ($hold is HOLD_COMMENT_RE) and
# it was neither of those; neutral otherwise. A negated lead word is neutral,
# never a hold: the sentence was about lifting.
#
# A comment that OPENS with `HOLD:` or `HOLD —` (HOLD_LEAD_RE, BH-6091) is
# DECISIVE-HOLD, asked right after the lead-lift and before the lift
# vocabulary: "HOLD: the lead reversed the RESUME above" is a hold.
#
# THE ORDER: needs-human, human-fix, lead-lift, lead-HOLD, lift, abandon, done,
# hold. Apart from the two lead arms, LIFT IS ASKED FIRST so the recency law
# reads the same in every direction:
# an ABANDON that a later RESUME lifts is clear, and a HOLD newer than an
# ABANDON is a pause again. NEEDS-HUMAN is asked before even that (BH-3443):
# the placer's own comment names RESUME in its release line and must never read
# as a lift. HUMAN-FIX is asked right after it (BH-5125), for the same reason: a
# person taking the fix may well write "I'll RESUME the agents after". DONE is
# asked after abandon and before hold, and on its own it is neutral:
# hold_classify's recency law decides what it lifts.
#
# THE VERDICT NAMES THE LINE THAT DECIDED (BH-1461). "hold:body" alone sends
# the author hunting through their own ticket for a word they did not know
# was an instruction — and bin/fly-pool.sh quotes this back to them on the
# ticket. First matching line, flattened and capped so a verdict stays one
# readable line in a log, a comment and a TAB-separated record alike.
#
# thread($c): every comment but our own ambiguity note ($mark), NEWEST FIRST,
# each carrying `bot`. people($c): the same list with the bots dropped. REST answers oldest-first and --paginate
# concatenates pages, so the order is rebuilt from created_at here. A timestamp
# that is not an ISO date sorts OLDEST: it can never be "the newest word". The
# original index breaks ties, so two comments in the same second keep the order
# GitHub gave them.
HOLD__JQ_DEFS='
    def decide: if test($nh) and test($gl) then "golive"
                elif test($nh) then "needs-human"
                elif test($hf) then "human-fix"
                elif test($lead) then (if test($neg) then "none" else "lift" end)
                elif test($holdlead) then "hold"
                elif test($lift) and ((test($neg)) | not) then "lift"
                elif test($ab) and ((test($neg)) | not) then "abandon"
                elif test($done) then "done"
                elif test($hold) then "hold"
                else "none" end;
    def hit($re): [ (split("\n")[] | sub("\r$"; "")) | select(test($re)) ] | first // "";
    def say($re): (hit($re) | gsub("\t"; " ") | .[0:160]) as $l
                  | if $l == "" then "" else " " + $l end;
    def thread($c): [ ($c | to_entries[])
        | select((.value | type) == "object")
        | select(((.value.body // "") | tostring | contains($mark)) | not)
        | { body: ((.value.body // "") | tostring), at: ((.value.created_at // "") | tostring), i: .key, id: .value.id,
            bot: ((((.value.user // {}).type // "") | ascii_downcase) == "bot") }
        | . + { k: (if (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) then .at else "" end) }
      ] | sort_by([.k, .i]) | reverse;
    def people($c): thread($c) | map(select(.bot | not));
'

# hold_classify <issue-json> <comments-json>
#   Input: the REST issue object (state, title, body, labels[].name) and the
#   REST comments array (body, created_at, user.type).
#   stdout: "held\t<why>" | "clear\t<why>" | "unreadable\t<why>"
#   rc:     1 held, 0 clear, 2 unreadable.
#
#   DECISION ORDER, and it is deliberate: state, then label, then the thread by
#   recency, then the title, then the body. `closed` is asked first because a
#   closed issue carrying the label is still closed, and a de-labelled issue is
#   the fleet's own "do not build this" gesture (a decomposed parent).
#
#   ABSENT IS NOT CLEAR (D11). An issue object that does not parse, or that
#   carries no `state` at all, is UNREADABLE — never defaulted into an answer.
hold_classify() {
  local ij cj out
  ij=$(hold__read "${1:-}")
  cj=$(hold__read "${2:-}")
  [ -n "$cj" ] || cj='[]'
  printf '%s' "$ij" | jq -e 'type=="object"' >/dev/null 2>&1 \
    || { printf 'unreadable\tthe issue json did not parse as an object\n'; return 2; }
  printf '%s' "$ij" | jq -e 'has("state")' >/dev/null 2>&1 \
    || { printf 'unreadable\tthe issue json carries no state field\n'; return 2; }
  printf '%s' "$cj" | jq -e 'type=="array"' >/dev/null 2>&1 \
    || { printf 'unreadable\tthe comments json did not parse as an array\n'; return 2; }
  # BOTH DOCUMENTS RIDE IN ON STDIN, and that is not a style choice. A thread is
  # unbounded — every what-shipped and adjudication comment this harness posts is
  # 1–3 KB — and `jq --argjson c "$cj"` puts the whole array in ARGV, which Linux
  # caps at 131072 bytes for a single string (MAX_ARG_STRLEN). Past that jq is
  # never even exec'd, the classifier answers nothing, and a long-lived ticket
  # reads as UNREADABLE on every tick for ever: never rebuilt, never lifted, and
  # silent about it. A pipe has no such ceiling, so the two JSON values are fed
  # to `jq -n` and picked up with `input`. Pinned in section 1 of the suite with
  # a thread larger than the argv limit.
  out=$( { printf '%s\n' "$ij"; printf '%s\n' "$cj"; } | jq -rn \
        --arg hold "$HOLD_COMMENT_RE" --arg lift "$HOLD_LIFT_RE" --arg neg "$HOLD_NEG_RE" \
        --arg bodyre "$HOLD_BODY_RE" --arg ab "$HOLD_ABANDON_RE" --arg titlere "$HOLD_TITLE_RE" \
        --arg lead "$HOLD_LIFT_LEAD_RE" --arg holdlead "$HOLD_LEAD_RE" --arg mark "$HOLD_AMBIGUOUS_MARK" \
        --arg nh "$HOLD_NEEDS_HUMAN_RE" --arg hf "$HOLD_HUMAN_FIX_RE" --arg done "$HOLD_HUMAN_DONE_RE" \
        --arg gl "$HOLD_GOLIVE_RE" \
        --arg nhtag "$HOLD_NH_TAG_RE" "$HOLD__JQ_DEFS"'
    input as $i
    | input as $c
    | (($i.state // "") | ascii_downcase) as $state
    | [ ($i.labels // [])[] | if type == "object" then (.name // "") else tostring end ] as $labels
    | if $state != "open" then "held\t" + $state
      # THE `hold` LABEL IS A PAUSE (BH-2504), and a label is state, not a
      # comment: no RESUME in the thread lifts it — taking the label off does.
      # Asked before the ai-build label so a held, de-labelled ticket still
      # reads as the instruction it is (hold_is_pause), not as label-absent.
      elif ($labels | index("hold")) != null then "held\thold:label hold"
      elif ($labels | index("ai-build")) == null then "held\tlabel-absent"
      else
        # NEWEST FIRST, our own note skipped (thread, HOLD__JQ_DEFS). A bot is
        # heard only for the tagged marker the placer writes (BH-3443), so the filter
        # runs after decide: every other bot comment is dropped, as before — a
        # human-fix from a bot included (BH-5125: only a person takes a fix).
        ( thread($c)
            | map(. + { d: (.body | decide) })
            | map(select(.d != "none"))
            | map(select((.bot | not) or (.d == "needs-human" and (.body | test($nhtag))) or (.d == "golive" and (.body | test($nhtag))))) ) as $dsall
        # THE GO-LIVE STEP IS TRANSPARENT TO THE DECISION (BH-7123 wave B): the
        # thread decides as if its go-live markers were not there ($ds), and only
        # a CLEAR answer is then re-worded to name the newest open step
        # (hold:go-live, below). A held answer is never softened by one.
        | ($dsall | map(select(.d != "golive"))) as $ds
        | ($dsall | to_entries | map(select(.value.d == "golive")) | first) as $gi
        | (($i.title // "") | tostring) as $title
        | (($i.body // "") | tostring) as $body
        # THE BODY NEEDS AN EXPLICIT LINE, THE TITLE ITS IDIOM (HOLD_TITLE_RE):
        # `Compliance P7 (HOLD): EU residency`. A title that names the hold
        # FEATURE ("per-PR HOLD / RESUME") is a description, not a hold.
        | def titlebody($dflt):
            if ($title | test($titlere)) then "held\thold:title" + ($title | say($titlere))
            elif ($body | test($bodyre)) then "held\thold:body" + ($body | say($bodyre))
            else $dflt end;
        # golive($ans): a clear answer names the newest go-live marker that no
        # newer lift word lifted: a done DIRECTLY over it lifts it (the ordinary
        # marker rule), a newer done or lift anywhere lifts it, else the step is
        # open and the verdict reads `clear<TAB>hold:go-live <at> <step>`.
        def golive($ans):
            if ($ans | startswith("clear")) and $gi != null then
              ($dsall[:$gi.key] | map(select(.d == "lift" or .d == "done"))) as $newer
              | if ($newer | length) == 0 then
                  "clear\thold:go-live " + $gi.value.at + " "
                  + ($gi.value.body | hit($gl) | sub("^NEEDS-HUMAN:[ \t]*go-live:[ \t]*"; "") | gsub("\t"; " ") | .[0:160])
                elif $gi.key > 0 and $dsall[$gi.key - 1].d == "done" and ($ans | startswith("clear\tno-hold")) then
                  "clear\tlifted-by-human-step " + $dsall[$gi.key - 1].at
                else $ans end
            else $ans end;
        # THE HUMAN STEP (BH-3443): the newest non-done entry is a marker with a
        # done directly over it. The done lifts that marker, and every older
        # marker and done with it (the person answered the newest ask), but
        # never a HOLD or ABANDON a person wrote further down. A human-fix
        # marker (BH-5125) is lifted the same way.
        ([ $ds | to_entries[] | select(.value.d != "done") | .key ] | first) as $k
        | golive(
          if $k != null and $k > 0 and ($ds[$k].d == "needs-human" or $ds[$k].d == "human-fix") then
            $ds[$k - 1] as $lifter
            | ($ds[$k + 1:] | map(select(.d == "hold" or .d == "abandon" or .d == "lift")) | first) as $rest
            | if $rest == null then titlebody("clear\tlifted-by-human-step " + $lifter.at)
              elif $rest.d == "hold" then "held\thold:comment " + $rest.at + ($rest.body | say($hold))
              elif $rest.d == "abandon" then "held\tabandon:comment " + $rest.at + ($rest.body | say($ab))
              else "clear\tlifted-by-human-step " + $lifter.at end
          else
            # A done with no marker directly beneath it is neutral.
            ($ds | map(select(.d != "done")) | first) as $dec
            | if $dec == null then titlebody("clear\tno-hold")
              elif $dec.d == "lift" then "clear\tlifted-by-comment " + $dec.at
              elif $dec.d == "abandon" then "held\tabandon:comment " + $dec.at + ($dec.body | say($ab))
              elif $dec.d == "needs-human" then "held\thold:waiting-on-human " + $dec.at + " "
                + ($dec.body | hit($nh) | sub("^NEEDS-HUMAN:[ \t]*"; "") | gsub("\t"; " ") | .[0:160])
              elif $dec.d == "human-fix" then "held\thold:human-fix " + $dec.at + ($dec.body | say($hf))
              else "held\thold:comment " + $dec.at + ($dec.body | say($hold)) end
          end)
      end' 2>/dev/null)
  case "$out" in
    held*)  printf '%s\n' "$out"; return 1 ;;
    clear*) printf '%s\n' "$out"; return 0 ;;
    *)      printf 'unreadable\tthe classifier produced no verdict for this issue json\n'; return 2 ;;
  esac
}

# hold__arm <owner/repo> — the App token for this repo, the way br_use_token's
# first arm does it. The hub's default PAT 404s on example-org/project-5, and a
# 404 read must not become "this ticket has no hold". The caller owns the reset
# (br_reset_token / gh_auth_reset): arming here and resetting here would drop a
# token the caller installed for the rest of its own work.
hold__arm() {
  command -v gh_auth_for >/dev/null 2>&1 && gh_auth_for "${1:-}"
  return 0
}

# hold_check <owner/repo> <issue-number> — the gh read, then hold_classify.
#   rc 0 clear, rc 1 held, rc 2 unreadable (gh non-zero or an empty body; the
#   first line of gh's stderr rides out on stdout).
#
#   REST, NEVER GRAPHQL (docs/verification-map/gh-pr-list-rest.md): `gh issue
#   view --json` is a GraphQL call and spends the 5000/hr bucket the whole hub
#   shares — the one that was exhausted while this was being written. `gh api
#   repos/…/issues/N` spends the far larger core bucket and carries every field
#   this needs. Two calls per gated decision, and nothing is written anywhere.
# hold__gh <args> (BH-7421): gh with the pool's per-read cut when
# POOL_GH_READ_TIMEOUT_S is a positive number; plain gh otherwise (other callers).
hold__gh() {
  case "${POOL_GH_READ_TIMEOUT_S:-}" in ''|0|*[!0-9]*) gh "$@" ;; *)
    if command -v timeout >/dev/null 2>&1; then timeout "$POOL_GH_READ_TIMEOUT_S" gh "$@"; else gh "$@"; fi ;; esac
}
hold_check() {
  local slug="${1:-}" n="${2:-}" ij errf err rc
  case "$slug" in */*) ;; *) printf 'unreadable\tno owner/repo to read\n'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) printf 'unreadable\tno issue number to read\n'; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'unreadable\tjq is not on PATH\n'; return 2; }
  hold__arm "$slug"
  errf=$(mktemp 2>/dev/null) || errf=/dev/null
  ij=$(hold__gh api "repos/$slug/issues/$n" 2>"$errf"); rc=$?
  if [ "$rc" != 0 ] || [ -z "$ij" ]; then
    err=$(head -n 1 "$errf" 2>/dev/null | tr -d '\r')
    [ -n "$err" ] || err="gh api repos/$slug/issues/$n answered an empty body (rc=$rc)"
    [ "$errf" = /dev/null ] || rm -f "$errf"
    printf 'unreadable\t%s\n' "$err"; return 2
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  hold__from_issue "$slug" "$n" "$ij"
}

# hold_check_issue <owner/repo> <issue-number> <issue-json> (BH-7942) — hold_check
# for a caller that already holds the issue object (the pool's open ai-build
# listing): the comments read, then hold_classify. No issue GET. Same output,
# rc and token arming as hold_check. An empty issue json is unreadable.
hold_check_issue() {
  local slug="${1:-}" n="${2:-}" ij="${3:-}"
  case "$slug" in */*) ;; *) printf 'unreadable\tno owner/repo to read\n'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) printf 'unreadable\tno issue number to read\n'; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'unreadable\tjq is not on PATH\n'; return 2; }
  [ -n "$ij" ] || { printf 'unreadable\tno issue json to classify\n'; return 2; }
  hold__arm "$slug"
  hold__from_issue "$slug" "$n" "$ij"
}

# hold__from_issue <owner/repo> <n> <issue-json> — the comments read, the
# classify and the ambiguous note: the tail hold_check and hold_check_issue share.
hold__from_issue() {
  local slug="$1" n="$2" ij="$3" cj raw errf err rc
  errf=$(mktemp 2>/dev/null) || errf=/dev/null
  raw=$(hold__gh api --paginate "repos/$slug/issues/$n/comments?per_page=100" 2>"$errf"); rc=$?
  if [ "$rc" != 0 ]; then
    err=$(head -n 1 "$errf" 2>/dev/null | tr -d '\r')
    [ -n "$err" ] || err="gh api repos/$slug/issues/$n/comments answered rc=$rc"
    [ "$errf" = /dev/null ] || rm -f "$errf"
    printf 'unreadable\t%s\n' "$err"; return 2
  fi
  [ "$errf" = /dev/null ] || rm -f "$errf"
  # --paginate concatenates one array per page, so the pages are flattened into
  # the single array hold_classify reads. An empty answer is an empty thread.
  if [ -z "$raw" ]; then cj='[]'; else
    cj=$(printf '%s' "$raw" | jq -sc '[ .[] | if type == "array" then .[] else . end ]' 2>/dev/null) || cj=""
    [ -n "$cj" ] || { printf 'unreadable\tthe comments for %s#%s did not parse\n' "$slug" "$n"; return 2; }
  fi
  local v vrc
  v=$(hold_classify "$ij" "$cj"); vrc=$?
  printf '%s\n' "$v"
  # A held ticket whose newest person comment says neither (BH-3435) reaches
  # the operator. The verdict line and rc above are unchanged by it.
  case "$v" in "held	hold:comment"*|"held	hold:title"*|"held	hold:body"*)
    hold_ambiguous_note "$slug" "$n" "$ij" "$cj" >/dev/null 2>&1 </dev/null ;;
  esac
  return "$vrc"
}

# hold_ambiguous <issue-json> <comments-json> — PURE (jq only). Is this a HELD
# ticket (by a comment, the title or the body — not the `hold` label, which a
# comment never lifts) whose NEWEST person comment neither lifts nor re-holds
# it? That is a person talking to a held ticket in words the classifier does
# not act on (BH-3435: #3354 sat 15.6 hours and only a ticket comment said so).
#   rc 0: prints "<comment id>\t<created_at>\t<first non-empty line, ≤160>"
#   rc 1: not ambiguous (clear, unreadable, label-held, the newest person comment
#         is decisive, or it carries no numeric id to dedupe on); prints nothing.
hold_ambiguous() {
  local ij cj v out
  ij=$(hold__read "${1:-}")
  cj=$(hold__read "${2:-}")
  v=$(hold_classify "$ij" "$cj"); [ $? = 1 ] || return 1
  case "$v" in "held	hold:comment"*|"held	hold:title"*|"held	hold:body"*) ;; *) return 1 ;; esac
  [ -n "$cj" ] || return 1
  out=$(printf '%s\n' "$cj" | jq -rn \
        --arg hold "$HOLD_COMMENT_RE" --arg lift "$HOLD_LIFT_RE" --arg neg "$HOLD_NEG_RE" \
        --arg ab "$HOLD_ABANDON_RE" --arg lead "$HOLD_LIFT_LEAD_RE" --arg holdlead "$HOLD_LEAD_RE" --arg mark "$HOLD_AMBIGUOUS_MARK" \
        --arg nh "$HOLD_NEEDS_HUMAN_RE" --arg hf "$HOLD_HUMAN_FIX_RE" --arg done "$HOLD_HUMAN_DONE_RE" \
        --arg gl "$HOLD_GOLIVE_RE" "$HOLD__JQ_DEFS"'
    input as $c
    | (people($c) | first) as $p
    | if $p == null or ($p.body | decide) != "none" or ($p.id | type) != "number" then empty
      else ($p.id | tostring) + "\t" + $p.at + "\t"
           + ([ $p.body | split("\n")[] | sub("\r$"; "") | select(test("\\S")) ] | first // ""
              | gsub("\t"; " ") | .[0:160])
      end' 2>/dev/null)
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# hold_ambiguous_note <owner/repo> <n> <issue-json> <comments-json> — when
# hold_ambiguous says so, ONE operator alert per comment and one ticket comment
# naming the lift words (BH-3435: "never only a ticket comment"). rc 0 always,
# nothing on stdout: every caller reads hold_check's verdict, not this.
#   ORDER: claim (a per-box `mkdir`, atomic, one owner per comment) -> the
#   ledgers row `hold_ambiguous "<slug>#<n> <id>"` (another box alerted: stop;
#   the worker down or no row: alert anyway, a duplicate beats a miss) -> the
#   alert through bin/lane-alert.sh --severity warn -> the ledger row -> the
#   ticket comment. A failed alert drops the claim so the next read retries, and
#   posts nothing. The ticket comment is best effort, once, on the armed token.
#   NO ROOT, NO WRITES (BH-2613): the root is ${HARNESS:-${H:-}} and nothing else.
hold_ambiguous_note() {
  local slug="${1:-}" n="${2:-}" root="${HARNESS:-${H:-}}" amb id at first why claim f
  [ -n "$root" ] && [ -x "$root/bin/lane-alert.sh" ] || return 0
  case "$slug" in */*) ;; *) return 0 ;; esac
  amb=$(hold_ambiguous "${3:-}" "${4:-}") || return 0
  IFS='	' read -r id at first <<<"$amb"
  mkdir -p "$root/state/hold-ambiguous" 2>/dev/null || return 0
  claim="$root/state/hold-ambiguous/${slug%%/*}__${slug#*/}-$n-$id"
  mkdir "$claim" 2>/dev/null || return 0
  if command -v job_ledger_get >/dev/null 2>&1; then
    job_ledger_get hold_ambiguous "$slug#$n $id" >/dev/null 2>&1 </dev/null && return 0
  fi
  why=$(hold_classify "${3:-}" "${4:-}" | cut -f2 | cut -d' ' -f1)
  if ! "$root/bin/lane-alert.sh" --severity warn --id "hold-ambiguous:$slug#$n:$id" hold \
      "$slug#$n is on HOLD ($why) and a person's newest comment ($at) neither lifts nor re-holds it: \"$first\". It stays held. A comment starting with RESUME, RELEASE, RELEASED, UNHOLD or PROCEED lifts it." \
      >/dev/null 2>&1 </dev/null; then
    rmdir "$claim" 2>/dev/null
    return 0
  fi
  command -v job_ledger_put >/dev/null 2>&1 \
    && job_ledger_put hold_ambiguous "$slug#$n $id" alerted >/dev/null 2>&1 </dev/null
  f=$(mktemp "${TMPDIR:-/tmp}/hold-ambiguous.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n\n%s\n' \
    "We read your last comment as neither lifting this hold nor keeping it, so the ticket is still on hold and nothing will build. To lift it, start a comment with one of these words: RESUME, RELEASE, RELEASED, UNHOLD or PROCEED (any case works). A comment from a bot never lifts a hold. We've flagged this for the operator as well." \
    "$HOLD_AMBIGUOUS_MARK $id -->" > "$f"
  gh api "repos/$slug/issues/$n/comments" -F "body=@$f" >/dev/null 2>&1 </dev/null
  rm -f "$f"
  return 0
}

# hold_check_thread <owner/repo> <number> — IS THIS PR (or issue) HELD BY ITS OWN
# THREAD? (BH-1668, review of #1926 blocking 1). A HOLD written on a PR binds the
# merge lanes the way a HOLD on its ticket does: project-5 #3214 carried
# `HOLD: do not enqueue or merge automatically` on the PR while its ticket #3108
# carried nothing, and every merge path read only the ticket. The same
# vocabulary and recency law as a ticket, but LINE-ANCHORED (hold_classify_thread
# below): ONLY the comments speak — a PR has no ai-build label, and a
# harness-written PR body is prose, never an instruction.
#   REST through gh_rest (the caller's armed token; ETag-cached, so an unchanged
#   thread is a 304), paged 100 at a time up to 1000 comments. Anything it could
#   not read — no gh_rest on the box, a non-2xx, a non-array page, more than
#   1000 comments — is UNREADABLE, never "no hold".
#   stdout/rc: hold_classify_thread's — rc 1 held, 0 clear, 2 unreadable.
hold_check_thread() {
  local slug="${1:-}" n="${2:-}" t acc='[]' page len rc
  case "$slug" in */*) ;; *) printf 'unreadable\tno owner/repo to read\n'; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) printf 'unreadable\tno number to read\n'; return 2 ;; esac
  command -v gh_rest >/dev/null 2>&1 || { printf 'unreadable\tno REST contract lib (gh_rest) on this box\n'; return 2; }
  t=$(mktemp "${TMPDIR:-/tmp}/hold-thread.XXXXXX" 2>/dev/null) || { printf 'unreadable\tno temp file\n'; return 2; }
  for page in 1 2 3 4 5 6 7 8 9 10; do
    rc=0; gh_rest GET "repos/$slug/issues/$n/comments?per_page=100&page=$page" > "$t" 2>/dev/null || rc=$?
    if [ "$rc" != 0 ] || ! jq -e 'type == "array"' "$t" >/dev/null 2>&1; then
      rm -f "$t"; printf 'unreadable\tthe thread of %s#%s could not be read (HTTP %s)\n' "$slug" "$n" "${GH_REST_STATUS:-000}"; return 2
    fi
    acc=$(jq -sc '.[0] + .[1]' <(printf '%s\n' "$acc") "$t" 2>/dev/null) \
      || { rm -f "$t"; printf 'unreadable\tthe thread of %s#%s did not parse\n' "$slug" "$n"; return 2; }
    len=$(jq 'length' "$t")
    [ "$len" -lt 100 ] && break
    [ "$page" = 10 ] && { rm -f "$t"; printf 'unreadable\t%s#%s has more than 1000 comments\n' "$slug" "$n"; return 2; }
  done
  rm -f "$t"
  hold_classify_thread "$acc"
}

# A PR THREAD IS JUDGED LINE-ANCHORED, BOTH WAYS (review of #1926 round 2). A
# ticket thread is short gestures; a PR thread is where lead reviews land, posted
# as a User, and they discuss holds all the time. Judged by HOLD_WORD_RE, review
# prose held four live PRs (the knob name MAIN_RED_HOLD_OVERRUN was enough), and
# a later review quoting "RESUME on the PR lifts it" would silently lift a real
# HOLD. So on a PR thread a comment is an instruction only when a LINE BEGINS
# with it — BH-1461's rule for ticket bodies, applied to every PR comment:
#   hold    a line starting `HOLD` alone, `HOLD:` or `HOLD —` (HOLD_BODY_RE)
#   lift    a line starting `RESUME` or `UNHOLD`, as a word
#   abandon a line starting `ABANDON` or `CLOSE-PR`, as a word
# A quote (`> HOLD`), a list item, a code span or a mid-line mention is prose.
HOLD_LIFT_LINE_RE='(?m)^(RESUME|UNHOLD)(?![A-Za-z0-9_-])'
HOLD_ABANDON_LINE_RE='(?m)^(ABANDON|CLOSE-PR)(?![A-Za-z0-9_-])'
export HOLD_LIFT_LINE_RE HOLD_ABANDON_LINE_RE

# hold_classify_thread <comments-json> — PURE (jq only). The newest decisive
# HUMAN comment wins (bots skipped, the same recency law and tie-break as
# hold_classify); a comment with no instruction LINE is neutral. Output and rc
# are hold_classify's: "held\thold:comment <at> <line>" rc 1,
# "held\tabandon:comment …" rc 1, "clear\tlifted-by-comment <at>" rc 0,
# "clear\tno-hold" rc 0, "unreadable\t…" rc 2.
hold_classify_thread() {
  local cj out
  cj=$(hold__read "${1:-}")
  [ -n "$cj" ] || cj='[]'
  printf '%s' "$cj" | jq -e 'type=="array"' >/dev/null 2>&1 \
    || { printf 'unreadable\tthe comments json did not parse as an array\n'; return 2; }
  out=$(printf '%s\n' "$cj" | jq -rn \
        --arg hold "$HOLD_BODY_RE" --arg lift "$HOLD_LIFT_LINE_RE" --arg ab "$HOLD_ABANDON_LINE_RE" '
    def decide: if test($lift) then "lift" elif test($ab) then "abandon" elif test($hold) then "hold" else "none" end;
    def hit($re): [ (split("\n")[] | sub("\r$"; "")) | select(test($re)) ] | first // "";
    def say($re): (hit($re) | gsub("\t"; " ") | .[0:160]) as $l | if $l == "" then "" else " " + $l end;
    input as $c
    | ( [ ($c | to_entries[])
          | select((.value | type) == "object")
          | select((((.value.user // {}).type // "") | ascii_downcase) != "bot")
          | { body: ((.value.body // "") | tostring | gsub("\r"; "")), at: ((.value.created_at // "") | tostring), i: .key }
          | . + { k: (if (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) then .at else "" end) }
        ] | sort_by([.k, .i]) | reverse
          | map(. + { d: (.body | decide) })
          | map(select(.d != "none")) | first ) as $dec
    | if $dec == null then "clear\tno-hold"
      elif $dec.d == "lift" then "clear\tlifted-by-comment " + $dec.at
      elif $dec.d == "abandon" then "held\tabandon:comment " + $dec.at + ($dec.body | say($ab))
      else "held\thold:comment " + $dec.at + ($dec.body | say($hold)) end' 2>/dev/null)
  case "$out" in
    held*)  printf '%s\n' "$out"; return 1 ;;
    clear*) printf '%s\n' "$out"; return 0 ;;
    *)      printf 'unreadable\tthe thread classifier produced no verdict\n'; return 2 ;;
  esac
}
