#!/bin/bash
# bin/lead-review-enqueue.sh tick — BH-3545 (BH-3479.1): the hub trigger for
# lead reviews. Every 5 minutes (cron/lanes/713-lead-review-enqueue.cron) it
# asks for ONE lead review per PR head that a builder APPROVE'd, so nobody has
# to run `bin/lead-verdict.sh request` by hand. NO model call, NO SSH: the
# review itself is bin/lead-review.sh on the box that owns the repo (BH-1950),
# and bin/lead-review-land.sh promotes its answer.
#
# For each repo in LEAD_REVIEW_AUTO_REPOS (registered on lead-review-land, read
# through its lane_env_apply; empty = not configured, nothing is asked), one
# harness_pr_list read, then per non-draft PR, in this order:
#   head     prs_pr_get (bin/lib/pr-snapshot.sh, BH-4658) .head.sha. Not a
#            full sha = unreadable. A snapshot hit is still the live head: it
#            needs the list's head = the stored key's head = the cached body's
#            .head.sha, with an unchanged updated_at and base tip, and a body is
#            only stored when its head was the list head. Anything else is a
#            live gh_rest GET pulls/<n>, as is every read on a box without the
#            lib. One `<slug> PR-SNAPSHOT hit=<n> miss=<n>` line per repo read.
#   qa       (BH-5909) the harness repo only: a standing lead BLOCK whose
#            reviewer model is console-qa-gate (bin/lead-review.sh) has its
#            request reset (POST /api/lead-reviews/<id>/reset, lead token) once
#            a QA: PASS comment names <head>, once per comment
#            (state/lead-review-enqueue/qa-reset-*), and the PR is done for
#            this tick. The box reviews the same head again; no push.
#   approve  job_verdict must be APPROVE with reviewed_sha == head, or
#            job_verdict_headbound == reapproved@<head>. An APPROVE on an older
#            full sha, with bin/lib/lead-delta.sh loaded, is UNAPPROVED (BH-5294):
#            it may only take the replay below, and then is skipped_no_approve.
#            Anything else (no row, rc 1/2, "-", a BLOCK) = skipped_no_approve.
#            BH-5630: that is the rule only with LEAD_REVIEW_REQUIRE_BUILDER_APPROVE
#            =1. At 0 (the default) a head with NO builder row (rc 2), or with
#            the builder's APPROVE on an earlier head, is UNAPPROVED: it takes
#            the replay below, and is then requested when CI is green on it
#            (ci_green_head, the lead lane's lr_ci_green) and no lead/human/
#            risk-tier verdict stands on it; not green = skipped_ci. A builder
#            BLOCK and an unreadable ledger stay skipped_no_approve. The risk
#            tier never signs off such a head, except a lead-authored low
#            rules-text head (BH-5325, below). The scope note says
#            `auto: CI green on <sha12>`.
#   carry    (BH-7043, bin/lib/builder-carry.sh) a builder APPROVE on an
#            earlier head A, with no reapproved@<head>, is CARRIED to <head>
#            when bc_carry proves <head> carries A's patch (patch_same:
#            identical, main-merge or patch-id; the answer is cached in
#            builder-carry.tsv, 7 days). Then the head is approved and goes on
#            to the verdict read and the replay below. The carry stands only
#            when the history read below succeeds and the newest lead word on
#            another head is not a BLOCK; else the head is unapproved again, as
#            before. A carry that stands writes one modes.tsv `builder-replay`
#            row per head (`from=<A12> how=<how>`), counts builder_replayed=,
#            and logs `builder APPROVE carried from <A12> (how:<how>)`. A head
#            it still requests carries the scope note `auto: builder APPROVE
#            carried from <A12> (how:<how>) on <sha12>`, and the risk tier never
#            signs it off. bc_carry posts no verdict row and writes no
#            head-bound artifact. A fetch that fails (bc_carry rc 2, or the
#            replay's own fetch) counts fetch_failed= once per PR, and the log
#            line names the redacted git error (PS_FETCH_ERR). Any other rc 2
#            or a refusal leaves the head as before.
#   stepdone (BH-6696, bin/lib/lead-step-done.sh) a builder REQUEST_CHANGES or
#            BLOCK bound to the head is answered when the PR's author is
#            confirmed not a lead (rt_lead_skip), and lsd_check finds, on the
#            ticket issue (to_pr_issue), a person's HUMAN-STEP-DONE: or RESUME
#            comment after the newest NEEDS-HUMAN: comment and strictly after
#            the builder verdict row's updated_at. Then the head goes on to the
#            request path below (verdict, traced, risk, self, cap), never to the
#            replay, and the risk tier never signs it off (REQFOR is set). The
#            scope note says `auto: HUMAN-STEP-DONE after the builder's <V> on
#            <sha12>; human step answered after the builder's <V>: <url> by
#            @<login> at <at>: <text>`. Not answered = skipped_no_approve as
#            before; a thread, verdict time or issue it cannot read is the same
#            skip, its reason ending `; human-step check: <why>`.
#   verdict  vd_standing on the head: a lead/human/risk-tier verdict stands =
#            skipped_verdict; rc 2 = unreadable. A standing risk-tier row whose
#            status post returned rc 4 (marker state/lead-review-enqueue/
#            risk-pub-<slug>-<n>-<sha12>, holding the description) is
#            published again through vs_publish; rc 0 removes the marker.
#   rebase   (BH-5796) a head not yet in the ledger, about to be requested
#            (after the replay and the risk tier), is HELD (skipped_rebase,
#            one `NEEDS_REBASE` log line, asked again next tick) when it
#            conflicts with its base: the conductor's row (pr-state.tsv) has
#            this head NEEDS_REBASE or REBASING, or parked conflict-unresolvable;
#            or GitHub lists the head DIRTY (mergeable_state, from the PR body
#            already read), or `git merge-tree` on the objects the hub clone under
#            REPOS_ROOT already holds (no fetch) names conflicted paths, because main
#            rewrote lines the PR also changes. A head that merges clean but
#            may duplicate main (BH-5802, bin/lib/dup-main.sh: it re-adds a file
#            main added after the PR's base, or adds 5+ of the same lines main
#            added there) is NOT held, because nothing rebases a CLEAN head and
#            the hold would never end. It is requested, and its scope notes say
#            `possible duplicate of <sha> (<path>)` for checklist item 12. A
#            merge-tree that cannot run holds nothing.
#            LEAD_REVIEW_REBASE_HOLD=0 turns it off.
#            8 review BLOCKs found such a head by hand before this.
#   replay   (BH-3930) only for a reapproved@<head> approval: the newest
#            source=lead MERGE/MERGE-WITH-NOTES/BLOCK row on another head of
#            this PR (GET /api/verdicts?repo=&pr=), and bin/lib/patch-same.sh
#            proving <head> carries that head's patch, on the clone under
#            REPOS_ROOT. Then bin/lead-verdict.sh post puts that word on <head>
#            (--source lead, note lead-replay:<prev12> how:<HOW>). Post rc 0, 4
#            or 5 = replayed, nothing requested. A source=lead row on <head>
#            whose note carries lead-replay: is a replay already recorded: it
#            counts as replayed and is never posted again. Anything else, an
#            unreadable or truncated read included, falls through below.
#            BH-5294, with bin/lib/lead-delta.sh: the replay also runs for an
#            UNAPPROVED head (the builder's APPROVE is on an earlier head; the
#            builder's own replay is review-prs.sh's BH-2310 block), and for a
#            head the builder approved directly. Its standing read is the history
#            itself: any lead/human/risk-tier row on <head> = skipped_verdict.
#            ld_classify <clone> origin/main <prev> <head> <slug> <word>
#            decides, after the
#            same fetch: `replay <how>` = the post above; `delta <lines> <max>
#            <files>` = the request below carries `lead-delta:<prev> lines:..`
#            in scope_notes and prior_verdict_ref `lead <word> on <prev12>
#            (verdict row #<id>)`, and bin/lead-review.sh reviews the delta on
#            the same lead.review model route; `full <reason>` = the request as
#            before. BH-5909: with the settings row
#            lane.lead-review.lead_review_console_qa_gate = 1 (unreadable = 1),
#            no MERGE is replayed onto a harness head that changes
#            console-ui/src/ with no QA: PASS naming it; it is requested.
#            A protected path, .mergify.yml, .github/, schema or
#            migrations file in the PR's own delta is full, unless (BH-5582)
#            the word is MERGE or MERGE-WITH-NOTES and the own delta is at
#            most LEAD_DELTA_PROTECTED_MAX_LINES lines: then the delta class
#            ends ` protected:<p1>,<p2>` and the scope note carries that
#            token, so the review names each file for full scrutiny. Only a MERGE or
#            MERGE-WITH-NOTES is replayed onto an unapproved head or delta
#            reviewed; a BLOCK is only replayed (as a BLOCK) onto a rebound head.
#            What git settled is cached in delta.tsv per head pair and knob
#            value, so a waiting head is not fetched every tick. A class that
#            a protected path or the line count decided also keys on
#            <LEAD_DELTA_PROTECTED_MAX_LINES>:<word> (an 8th column). An unapproved
#            head stops here. Every replay, delta and full request is one row of
#            modes.tsv (30 days); the summary carries delta=, full= and today_*.
#   prev     (BH-6391, bin/lib/lead-prev.sh) a head whose PR has an earlier
#            lead row (MERGE, MERGE-WITH-NOTES or BLOCK, not a lead-replay:
#            row) on another head G is requested with ONE more scope note
#            group, in delta and full mode alike: `lead-prev:<G> word:<W>
#            report:state/lead-reviews/lr-<pr>-<G12>.md own-commits:<n|?>
#            own-files:<csv> main-files:<csv>` (lpv_note), logged as
#            `re-review of <G12> (<W>)`. It is computed right before the
#            request, with a fetch only when the clone lacks G or the head.
#            git that cannot answer gives `?` fields; the request still goes.
#            request() fits scope_notes to the worker's 4000 chars (lpv_fit).
#   traced   (BH-5795) a head not yet in the ledger is HELD (skipped_traced,
#            one log line with the reason, asked again next tick) when the PR
#            is DIRTY (mergeable_state dirty: GitHub runs no CI on it; only with
#            LEAD_REVIEW_REBASE_HOLD=0, else the rebase hold owns it), or when
#            its base is not the repo's default branch and no check run on the
#            head whose name starts LEAD_REVIEW_TRACED_JOB ("Tests, traced")
#            ran: none at all, or every one skipped. An unreadable check-run
#            list holds too. A base on the default branch is not held: the
#            merge-queue batch tests that head, so its skipped shards are the
#            design (2026-09-24). LEAD_REVIEW_TRACED_WAIT=0 turns the hold off.
#            The hold starts a real run and has a bound, so it never stalls a
#            PR: on the first held tick it dispatches LEAD_REVIEW_TRACED_WORKFLOW
#            (harness-ci.yml) with scope=impact on the PR's head branch (POST
#            actions/workflows/<wf>/dispatches, one attempt per head, logged),
#            and the marker state/lead-review-enqueue/traced-<slug>-<n>-<sha12>
#            records when the hold began. After LEAD_REVIEW_TRACED_MAX_WAIT_MIN
#            minutes (default 30) the head is requested anyway, and its scope
#            note says `tests did not run: <reason>`. A marker that cannot be
#            written or read holds nothing: the head is requested with that note.
#            22 review BLOCKs said "no suite ran on this head" before this.
#   risk     (BH-5022) only when rt_mode (bin/lib/risk-tier.sh) is shadow or
#            enforce for the repo: risk_tier.mode.<owner>.<name>, else
#            risk_tier.mode, else off (wave 1: example-org/cromford only,
#            every other repo is off). A lead-authored PR (to_is_lead,
#            bin/lib/ticket-ownership.sh, on the PR body's .user.login, against
#            the same lead_pr_authors row the merge fence to_lead_merge_hold
#            reads) is classified, but only a low rules-text answer (BH-5325,
#            rt_rules_low) goes on: the fence clears a lead PR on a risk-tier
#            row only with reviewer risk-tier:rules-text:<box>. Any other
#            answer for it posts no /api/risk-tiers row, writes a `lead` line
#            in risk.tsv (the next ticks read no compare for it), and is
#            requested as before (risk_lead). An unreadable author or row, or
#            no lib, is never classified and is requested as before (risk_lead).
#            A compare that rt_rules_shape calls rules text gets the hub's
#            render check on the head first (rrh_check, bin/lib/rules-render-
#            head.sh, on the clone under REPOS_ROOT with $H/bin/render-rules.sh);
#            without the lib no rules head is low. The
#            head's compare is read ONCE into
#            $WORK/cmp-<n> (the self check below reuses it). A Lead-Lane:
#            commit, or a compare that cannot be read whole, is never
#            classified: it falls through, and an `unclassified` line in
#            risk.tsv stops the next ticks reading its compare again for the
#            tier (it is requested as before, never low). Otherwise rt_classify
#            answers low|medium|high, a new head is recorded (POST
#            /api/risk-tiers, then one line in risk.tsv: <epoch>\t<slug>\t<n>
#            \t<head>\t<tier>\t<reasons>\t<rules sig>\t<path|evidence|->,
#            column 8 the rule that made the head low (rt_low_rule, BH-6968;
#            a line written before it has 7 columns), kept 7 days; a failed
#            POST still writes the line, and logs the missing row), and a head already in
#            risk.tsv under the SAME rules sig (RT_RULES_SIG: a rules row that
#            changed reclassifies every head) reuses its last line with no
#            compare read. Then:
#              low + enforce  bin/lead-verdict.sh post <head> MERGE --source
#                             risk-tier --reviewer risk-tier:<box> (a rules-text
#                             low: risk-tier:rules-text:<box>) --note "low risk:
#                             <reasons>". A head no reviewer approved (BH-5630)
#                             is never posted, unless it is a lead-authored
#                             rules-text low: the lead wrote it, its CI is
#                             green and the hub's render check passed. A
#                             non-lead rules-text head keeps the refusal.
#                             rc 0 or 4
#                             = risk_signed, nothing requested (rc 4 writes the
#                             risk-pub marker); rc 3 = the head moved, next tick;
#                             rc 5 = withheld (a protected path, or authority
#                             not lane's or unreadable): no row was written, so
#                             it is requested with priority 1, and a `withheld`
#                             line in risk.tsv stops the next 7 days of ticks
#                             posting it again (they re-confirm the request,
#                             priority 1, and spend nothing); any other rc
#                             falls through to a request.
#              low + shadow   one `WOULD sign off` line per head; requested as below.
#              medium         requested as below; under enforce (BH-5023), first
#                             held for the in-build lead-grade review the build
#                             runs (bin/inbuild-lead-review.sh), but only while
#                             a build job for this PR is running or queued and
#                             bound to this head (BH-5740, inbuild_job_on_head).
#                             With no such job the head is requested at once
#                             and one `inbuild-grace skipped` line says why; an
#                             unreadable job read holds as before. A held head
#                             with no ledger line gets the marker state/lead-review-
#                             enqueue/inbuild-wait-<slug>-<n>-<sha12> on first
#                             sight, and while it is younger than rt_inbuild_grace
#                             (risk_tier.inbuild_grace_s, fallback 3600 s) the
#                             head is not requested (`awaiting the in-build
#                             lead-grade review`, risk_inbuild_wait). Past it,
#                             requested as below, so a head no build reviews is
#                             never stranded. A rebound (reapproved@<head>) head
#                             is never held: no build settled on it, so no build
#                             reviews it. A marker that cannot be written or read
#                             holds nothing. Markers go after 7 days.
#              high           requested as below with priority 1 (claimed first).
#            The first enforce tick is the backfill: every approved head with
#            no standing verdict is classified in it.
#            LOW-SMALL (BH-7041): a head rt_classify calls medium THIS tick goes
#            through rt_low_small_apply (bin/lib/risk-tier.sh), which asks
#            rt_low_small when risk_tier.low_small_mode (no row = shadow; a bad
#            or unreadable row = off, logged once per repo) reads shadow or
#            enforce. Enforce + yes: the head is cached and handled as low with
#            reasons `low-small: <own> code lines, ...`, so the low + enforce
#            path above signs it off (the REQFOR and silence refusals hold; a
#            lead-authored head stays `lead`). Shadow + yes: one `risk-tier
#            WOULD sign off (low-small: ...)` line, and the head stays medium.
#            No: one `low-small no (<why>); medium` line. The worklist gate
#            (bin/lib/lead-gates.d/60-risk.sh) applies the same call, so the
#            shared risk.tsv holds one answer per head whichever lane saw it
#            first. Only enforce is in RT_RULES_SIG, so a flip to or from
#            enforce reclassifies each head once.
#   jev      (BH-5024) only inside `risk`, only for a head classified THIS
#            tick, and only when the jev_risk.mode row reads exactly `shadow`
#            (trimmed, any case; anything else, a 404 or an unreadable row is
#            off, and off reads no other jev_risk row). Then bin/jev-risk.sh ask
#            runs as its own process under `timeout` (jev_risk.timeout_s + 10)
#            with the compare already read, and its answer is ONE log line next
#            to the rule tier (`jev shadow <status> <tier> <prob> (rule tier
#            <tier>)`) and the jev_shadow count. It never changes the tier, the
#            sign-off, the priority or the request. jev_risk.max_per_tick (3)
#            asks a tick; a head over it gets one `not asked` line and is not
#            asked later.
#   intent   (BH-6967) at the end of `risk`: a head it classified low (or
#            withheld), medium or high ends its scope_notes with
#            `review-tier:<low|medium|high> review-mode:<full|intent>`. intent
#            only for a medium head, with no `lead-delta:` note, while the
#            settings row risk_tier.medium_mode reads intent (trimmed, any case,
#            read once a tick; no row, an unreadable row or another value is
#            full, and a bad value is one log line a tick). bin/lead-review.sh
#            reviews that head with prompts/lead-review.d/intent.md on route
#            review-intent, and bin/lead-review-land.sh writes both tokens onto
#            the verdict row. Both read the tokens only as the LAST group of
#            the notes, and request() rewrites `review-tier:`/`review-mode:` in
#            every earlier part (paths, subjects, comment text) to `=`. The
#            reviewer also reads risk_tier.medium_mode again and needs intent.
#            The first ask stores its tokens in
#            state/lead-review-enqueue/review-tier-<slug>-<n>-<sha12> (7 days);
#            a re-confirm sends only what that file holds, so its notes never
#            change. An unclassified head gets no tokens. The risk-tier sign-off
#            posts --review-tier low --review-mode risk-tier; a replay posts the
#            mode of the row it replays (full when that row has none). The
#            summary counts review_intent=.
#   self     (BH-5798) a head not yet in the ledger runs bin/pr-self-check.sh's
#            psc_check (bin/lib/pr-self-check.sh, rules catalog/pr-self-check.tsv)
#            over the PR body, on the hub clone under REPOS_ROOT after one fetch
#            of the base and the head: Closes on a partial build, evidence on an
#            older head, files outside the plan, and (BH-5790) a PR-body
#            section the lead would BLOCK on (body-* rows; the linked issue,
#            read once, is the ticket text). A refusal holds the head
#            (skipped_selfcheck), posts ONE PR comment per (head, body) naming the
#            findings, and is bounded: after PR_SELF_CHECK_MAX_WAIT_MIN (default
#            30) it is requested anyway with `self-check: <findings>` in the scope
#            note. A check that cannot run holds nothing. PR_SELF_CHECK=0 is off.
#            It sits after the risk tier, so a risk-tier sign-off is not held.
#   recorded the head is already in state/lead-review-enqueue/requested.tsv:
#            POST again with the same notes. The worker answers existing:true
#            and nothing is spent; a 201 there means a second review was bought
#            and pages critical (lead-repeat-<slug>-<n>-<sha12>).
#   failed   the request for this head (recorded, or an existing row the POST
#            hands back) came back `failed`: POST /api/lead-reviews/<id>/reset
#            with the lead token, the same call as bin/lead-verdict.sh reset, at
#            most LEAD_REVIEW_FAILED_RETRY_MAX times per head (default 2). The
#            resets this lane made are counted in state/lead-review-enqueue/
#            failed-retry.tsv (<epoch>\t<slug>\t<n>\t<head>\t<id>\t<reset|
#            alerted>\t<detail>, kept 30 days); a hand reset spends nothing. A
#            reset counts toward the per-tick cap and the tripwire (one ledger
#            line), and a 409 (a review in flight) spends nothing. Past the
#            budget, one warn alert lead-failed-<slug>-<n>-<sha12> names the
#            last reason and the manual verdict command; nothing is retried.
#            An environment failure (exactly checkout, no-checkout, empty, or
#            review-failed: env:) is not reset here WHILE bin/lead-review-land.sh
#            requeues it, which its lane file says by registering
#            LEAD_REVIEW_ENV_RETRY_MAX (BH-5793): it gets one `[skip env-failed]`
#            line. Without that registration it is reset here like any other
#            failure, within the same budget.
#   tripwire LEAD_REVIEW_MAX_PER_PR_DAY requests for this PR in 24h = tripped,
#            one warn (lead-trip-<slug>-<n>-<UTC day>).
#   cap      LEAD_REVIEW_ENQUEUE_MAX_PER_TICK new asks a tick; the rest are
#            deferred and seen again next tick.
#   self     gh_rest GET compare/<base>...<head>: a non-merge commit with a line
#            starting `Lead-Lane:` = skipped_self and one warn
#            (lead-self-<slug>-<n>-<sha12>) naming the manual request command.
#            A failed or truncated compare = unreadable.
#   silence  (BH-5797) ss_gate (bin/lib/silence-scan.sh), BEFORE the risk tier
#            (a low-tier sign-off never skips it), on a head not yet asked for,
#            on the compare rt_compare caches for the tick.
#            A public-leak allow-list line (KNOWN_FAKE_*, a gitleaks marker)
#            labels the PR needs-human with one comment, = skipped_silence; a
#            label a person removed lets it on. Any other allow-list line or
#            marker goes into the request notes for the lead to judge (kept for
#            the head, so a re-confirm sends the same notes).
#            LEAD_REVIEW_SILENCE_CHECK=0 skips the check.
#   request  POST /api/lead-reviews with the lead token (lr_post_lead), the
#            same body bin/lead-verdict.sh request sends (plus priority:1 for a
#            high head). 201 = requested and
#            one ledger line; existing:true or a 409 carrying the row = existing.
#            BH-5351: the body carries head_authors (head_authors_json): the
#            build job's box or participant and every fix round's box and
#            claimer, for the worker's separation-of-duties check. A failed
#            read is logged and the rest is still sent; with no identity at
#            all the request goes without head_authors, and the log says why.
# Skip lines: every PR that this tick does not request is ONE skip,
# `<slug>#<n> @<sha12>: <reason> [skip <class>]`, written to the log only when
# its (PR, head, class) differs from the last tick's (state skip-last.tsv);
# the summary counts skips= and skips_logged=. The class is one of draft,
# malformed, unreadable, no-approve, verdict, replayed, ci, risk-signed,
# head-moved, inbuild-wait, existing, failed-exhausted, reset-refused,
# tripped, deferred, self, env-failed. A builder BLOCK or REQUEST_CHANGES on a
# lead-authored PR (lead_pr_authors) names the author and the manual request
# command. A reason that came from the worker is redacted first (URL
# credentials and gh?_ tokens).
# Reclaim: once a tick, before the repos, POST /api/lead-reviews/reclaim-stale
# with the lead token. The worker sends a `running` row with no heartbeat past
# its deadline back to requested (the second time, to failed, which the
# `failed` rung then owns); each reclaimed row is one log line. A worker
# without the route, or no answer, is one log line and the tick goes on.
# Unreadable is never "go": nothing is requested on a read that failed.
# Hub only. Kill switch: flags/lane-off-lead-review-enqueue.
# A new optional lib or helper is a file in bin/lead-review-enqueue.d/, not one
# more source line here (bin/lead-review-enqueue.d/README.md).
# Log: logs/lead-review-enqueue.log, one `tick repos=..` summary line a tick.
#
# bin/lead-review-enqueue.sh pr <owner/repo>#<n>=<trigger>|<owner/repo>@<sha>=<trigger>...
# runs the same gates for the named PRs only, at once. bin/wake-loop.sh on the
# hub launches it from a pr synchronize/reopened/ready_for_review or a
# check_suite.completed wake (bin/lib/lead-reenqueue.sh). A head is asked for
# only when a source=lead verdict stands on an earlier head of the PR and the
# head is not in the ledger yet; anything else is left to the tick. It holds
# its own pr.lock, never tick.lock, and never prunes. LEAD_REENQUEUE_ON_PUSH=0
# turns it off. One `immediate lead review request` line per request.
set -uo pipefail
H="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/env-path.sh
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
set -a
# shellcheck source=/dev/null
. "$HENV/global.env" 2>/dev/null; set +a

RUNMODE=tick; LRE_ARGS=()
case "${1:-tick}" in
  tick) ;;
  pr) RUNMODE=pr; shift; LRE_ARGS=("$@") ;;
  *) echo "usage: bin/lead-review-enqueue.sh tick | pr <owner/repo>#<n>=<trigger>|<owner/repo>@<sha>=<trigger>..." >&2; exit 2 ;;
esac

# >>> lane gate (BH-1165). Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off lead-review-enqueue.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit lead-review-enqueue
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-enqueue
# LEAD_REVIEW_AUTO_REPOS is lead-review-land's knob (BH-3479.0 contract).
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    lead-review-land

LOG="$H/logs/lead-review-enqueue.log"
STATE="$H/state/lead-review-enqueue"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
log() { mkdir -p "$H/logs" 2>/dev/null; echo "$(STAMP) $*" >> "$LOG"; }
# The per-PR mode (header): its knob and its items, before any other read.
if [ "$RUNMODE" = pr ]; then
  # shellcheck source=bin/lib/lead-reenqueue.sh
  . "$H/bin/lib/lead-reenqueue.sh" 2>/dev/null || { log "pr: missing bin/lib/lead-reenqueue.sh; nothing requested"; exit 0; }
  [ "${LEAD_REENQUEUE_ON_PUSH:-1}" = 0 ] && { log "pr: LEAD_REENQUEUE_ON_PUSH=0; nothing requested, the */15 tick covers it"; exit 0; }
  lre_parse "${LRE_ARGS[@]}" || { log "pr: no valid item${LRE_BAD:+ ($LRE_BAD)}; nothing requested"; exit 0; }
  [ -n "$LRE_BAD" ] && log "pr: dropped malformed item(s): $LRE_BAD"
fi

# shellcheck source=bin/lib/hub-box.sh
. "$H/bin/lib/hub-box.sh" 2>/dev/null || { log "missing bin/lib/hub-box.sh; lead-review-enqueue tick skipped"; exit 0; }
BOX=$(local_box_name)
if ! is_hub_box "$BOX"; then log "not the hub (${BOX:-unnamed}); lead-review-enqueue runs on the hub only"; exit 0; fi

# jobs-client.sh exits its caller on a missing module, so every piece is checked first.
for f in bin/jobs-client.sh bin/lib/jobs/req.sh bin/lib/lead-reviews.sh bin/lib/verdicts.sh \
         bin/lib/gh-rest.sh bin/lib/gh-pr-list.sh bin/lib/gh-budget.sh bin/lane-alert.sh; do
  [ -r "$H/$f" ] || { log "missing $f; lead-review-enqueue tick skipped"; exit 0; }
done
# shellcheck source=/dev/null
{ . "$H/bin/jobs-client.sh"; . "$H/bin/lib/lead-reviews.sh"; . "$H/bin/lib/verdicts.sh"
  . "$H/bin/lib/gh-rest.sh"; . "$H/bin/lib/gh-pr-list.sh"; . "$H/bin/lib/gh-budget.sh"; }
# The lead-chain doorbell (BH-4057) is fail-open: without the lib a fresh
# request rings nothing and bin/lead-review.sh's own cron finds it.
# shellcheck source=bin/lib/lead-chain-wake.sh
LCW=0; . "$H/bin/lib/lead-chain-wake.sh" 2>/dev/null && LCW=1
# The same-patch test for the lead replay (BH-3930). Missing, nothing is
# replayed and every rebound head is requested as before.
. "$H/bin/lib/patch-same.sh" 2>/dev/null || true
# A builder APPROVE on an earlier head carried to a head with the same patch
# (BH-7043, header `carry`). Missing, that head is unapproved as before.
. "$H/bin/lib/builder-carry.sh" 2>/dev/null || true
# Replay without the builder, and delta mode (BH-5294). Missing, BH-3930 alone.
LD=0; . "$H/bin/lib/lead-delta.sh" 2>/dev/null && command -v ld_classify >/dev/null 2>&1 && LD=1
# The re-review token (BH-6391, header `prev`). Missing, no request carries it.
. "$H/bin/lib/lead-prev.sh" 2>/dev/null || true
# A person's answer to the builder's refusal (BH-6696, header `stepdone`).
# Missing, a refused head is skipped as before.
. "$H/bin/lib/lead-step-done.sh" 2>/dev/null || true
# BH-5630: ONE REVIEW GATE. A head with no builder APPROVE bound to it is
# requested when its CI is green, read through the lead lane's own definition
# (bin/lead-review.sh's `lead ci green` block: every check the base branch's
# .mergify.yml queue requires succeeded on exactly this sha, and no Actions run
# there is pending or failed). Missing block = no head is ever green here, so
# such a head waits exactly as before. LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1
# restores the builder gate (catalog/lanes.d/lead-review-enqueue.json).
LCG=0
# shellcheck source=/dev/null
[ -r "$H/bin/lead-review.sh" ] && . <(sed -n '/^# >>> lead ci green/,/^# <<< lead ci green/p' "$H/bin/lead-review.sh") 2>/dev/null \
  && command -v lr_ci_green >/dev/null 2>&1 && LCG=1
REQB="${LEAD_REVIEW_REQUIRE_BUILDER_APPROVE:-0}"; [ "$REQB" = 1 ] || REQB=0
# BH-5798: the pre-review self-check (header, `self`). Missing lib = off.
PSC="${PR_SELF_CHECK:-1}"; [ "$PSC" = 0 ] || PSC=1
PSCMAX="${PR_SELF_CHECK_MAX_WAIT_MIN:-30}"; [[ "$PSCMAX" =~ ^[0-9]{1,5}$ ]] || PSCMAX=30
. "$H/bin/lib/pr-self-check.sh" 2>/dev/null || PSC=0
command -v psc_check >/dev/null 2>&1 || PSC=0
# BH-5795: hold a head CI never tested (header, `traced`). Registry knobs;
# anything but 0 is on, and an empty job name is the registry default.
TWAIT="${LEAD_REVIEW_TRACED_WAIT:-1}"; [ "$TWAIT" = 0 ] || TWAIT=1
TJOB="${LEAD_REVIEW_TRACED_JOB:-}"; [ -n "$TJOB" ] || TJOB="Tests, traced"
TWF="${LEAD_REVIEW_TRACED_WORKFLOW:-}"; [ -n "$TWF" ] || TWF="harness-ci.yml"
TMAX="${LEAD_REVIEW_TRACED_MAX_WAIT_MIN:-30}"; [[ "$TMAX" =~ ^[0-9]{1,5}$ ]] || TMAX=30
# BH-5796: hold a head that conflicts with its base (header, `rebase`).
RBHOLD="${LEAD_REVIEW_REBASE_HOLD:-1}"; [ "$RBHOLD" = 0 ] || RBHOLD=1
# The risk tier (BH-5022). Missing, the mode is off and every head is today's
# path. verdict-status.sh carries vs_publish and the lead-authority lib.
. "$H/bin/lib/verdict-status.sh" 2>/dev/null || true
RT=0; . "$H/bin/lib/risk-tier.sh" 2>/dev/null && command -v rt_classify >/dev/null 2>&1 && RT=1
# The render check on a rules head (BH-5325). Missing, no rules head is ever low.
. "$H/bin/lib/rules-render-head.sh" 2>/dev/null || true
# The lead list the merge fence reads (to_is_lead). Missing, no PR is risk-tiered.
# shellcheck source=bin/lib/ticket-ownership.sh
. "$H/bin/lib/ticket-ownership.sh" 2>/dev/null || true
# The ticket-branch parser (BH-3835). Missing, head_authors_json reads no ticket key.
# shellcheck source=bin/lib/ticket-branch.sh
. "$H/bin/lib/ticket-branch.sh" 2>/dev/null || true
# shellcheck source=bin/lib/live-probes.sh
# BH-5801: lp_run_for_head, the `live probes` block below. Missing, no probe runs.
. "$H/bin/lib/live-probes.sh" 2>/dev/null || true
# shellcheck source=bin/lib/dup-main.sh
# BH-5802: dup_main_pr, rebase_hold's duplicate arm. A tree without it holds nothing for it.
. "$H/bin/lib/dup-main.sh" 2>/dev/null || true
# The PR snapshot (BH-4658). Missing, every head is today's live read, and the
# PR-SNAPSHOT line still counts it as a miss.
. "$H/bin/lib/pr-snapshot.sh" 2>/dev/null || true
# BH-5797: the pre-review silence check (an allow-list line or a lint-silencing
# marker is needs-human, not a lead review). Missing lib = no check.
. "$H/bin/lib/silence-scan.sh" 2>/dev/null || true
# BH-5909: the hub half of the console QA gate (bin/lib/console-qa-gate.sh).
# A standing console-qa-gate BLOCK is reset once a QA: PASS names its head, and
# while the gate row is on no lead word is replayed onto a console-ui/src/ head
# with no PASS. Missing lib = neither: a gate BLOCK then waits for a new head.
CQG=0; . "$H/bin/lib/console-qa-gate.sh" 2>/dev/null && CQG=1
CQG_HREPO=$(awk '$1 == "cromford" {print $2; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
# >>> lead-review-enqueue.d fragments (BH-8396)
# A new optional lib is its own file, bin/lead-review-enqueue.d/<key>-<name>.sh,
# not one more source line above: bin/list-file-lint.sh refuses that. Each
# regular *.sh there is sourced once, in LC_ALL=C name order, after the in-file
# libs. A fragment that does not parse or fails to source is one log line, and
# the tick goes on.
mapfile -t _lre_frags < <(set +f; for _f in "$H"/bin/lead-review-enqueue.d/*.sh; do [ -f "$_f" ] && printf '%s\n' "$_f"; done | LC_ALL=C sort)
for _lre_frag in "${_lre_frags[@]}"; do
  bash -n "$_lre_frag" 2>/dev/null || { log "lead-review-enqueue.d: ${_lre_frag##*/} does not parse; skipped this tick"; continue; }
  # shellcheck source=/dev/null
  . "$_lre_frag" || log "lead-review-enqueue.d: ${_lre_frag##*/} failed to source (rc $?); skipped this tick"
done
unset _lre_frags _lre_frag
# <<< lead-review-enqueue.d fragments (BH-8396)
# cqg_gate_on — the lead lane's LEAD_REVIEW_CONSOLE_QA_GATE, read as its settings
# row (lane.lead-review.lead_review_console_qa_gate) once per tick. No row = off;
# an unreadable row = on, so a replay is held and the head gets a review.
CQG_ON=""
cqg_gate_on() {
  local v rc=0
  if [ -z "$CQG_ON" ]; then
    v=$(setting_get lane.lead-review.lead_review_console_qa_gate 2>/dev/null) || rc=$?
    case "$rc" in
      0) CQG_ON=0; [ "$(printf '%s' "$v" | tr -d '[:space:]')" = 1 ] && CQG_ON=1 ;;
      2) CQG_ON=0 ;;
      *) CQG_ON=1 ;;
    esac
  fi
  [ "$CQG_ON" = 1 ]
}
# rv_medium_mode — sets RVMODE to intent or full from risk_tier.medium_mode
#   (BH-6967, header `intent`). In THIS shell, never in $(...): the row is read
#   once a tick.
RVMODE=""
rv_medium_mode() {
  local v rc=0
  [ -n "$RVMODE" ] && return 0
  v=$(setting_get risk_tier.medium_mode 2>/dev/null) || rc=$?
  v=$(printf '%s' "$v" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  RVMODE=full
  case "$rc:$v" in
    0:intent) RVMODE=intent ;;
    0:full|2:*) ;;
    0:*) log "risk_tier.medium_mode reads '$v', not full or intent; a medium head gets the full review this tick" ;;
    *) log "risk_tier.medium_mode unreadable (rc $rc); a medium head gets the full review this tick" ;;
  esac
}
command -v prs_pr_get >/dev/null 2>&1 || prs_pr_get() {
  [ -n "${PRS_COUNT_FILE:-}" ] && printf 'MISS %s\n' "$2" >> "$PRS_COUNT_FILE"
  gh_rest GET "repos/$1/pulls/$2" > "$6"; }

mkdir -p "$STATE" 2>/dev/null
# A tick dedupe, never a queue: a second tick while one runs skips.
if [ "$RUNMODE" = pr ]; then
  # Its own lock: a pr run never makes a cron tick skip.
  exec 9>"$STATE/pr.lock"; flock -n 9 || { log "another pr run holds pr.lock; ${LRE_ARGS[*]} left to the */15 tick"; exit 0; }
else
  exec 9>"$STATE/tick.lock"; flock -n 9 || { log "another tick holds $STATE/tick.lock; skipped"; exit 0; }
fi

# alert_once <id> <severity> <text> [--critical] — one lane-alert per id, deduped
#   by state/lead-review-enqueue/alerted-<id>, written only after the call
#   returned 0 (a failed call is retried next tick).
alert_once() {
  local id="$1" sev="$2" text="$3" crit=()
  [ "${4:-}" = --critical ] && crit=(--critical)
  [ -e "$STATE/alerted-$id" ] && return 1
  "$H/bin/lane-alert.sh" "${crit[@]}" --severity "$sev" --id "$id" lead-review-enqueue "$text" >/dev/null 2>&1 \
    || { log "lane-alert.sh failed for $id; next tick retries"; return 2; }
  : > "$STATE/alerted-$id" 2>/dev/null || log "alerted $id but could not write its marker; this may alert again"
  return 0
}

DAY=$(date -u +%Y%m%d)
TOKF="${LEAD_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/lead-verdict-token}"
export LEAD_VERDICT_TOKEN_FILE="$TOKF"
if [ ! -r "$TOKF" ]; then
  alert_once "lead-enqueue-no-token-$DAY" warn "no lead verdict token on the hub: LEAD_VERDICT_TOKEN_FILE ($TOKF) is not readable, so no lead review can be requested automatically. Install the token file (mode 600) on the hub." || true
  log "LEAD_VERDICT_TOKEN_FILE $TOKF not readable; nothing requested"
  exit 0
fi

# Both knobs are required registry knobs: no literal here. Empty or not a
# positive integer means the registry was not read, and that is never "go".
MAXT="${LEAD_REVIEW_ENQUEUE_MAX_PER_TICK:-}"
MAXD="${LEAD_REVIEW_MAX_PER_PR_DAY:-}"
for kv in "LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=$MAXT" "LEAD_REVIEW_MAX_PER_PR_DAY=$MAXD"; do
  case "${kv#*=}" in ''|*[!0-9]*|0*) log "${kv%%=*}='${kv#*=}' is not a positive integer; nothing requested"; exit 0 ;; esac
done
# Owned by lead-review-land and exported by its lane_env_apply above; not
# re-registered here. Empty = not configured, never "all repos".
AUTO_REPOS=""; [ -n "${LEAD_REVIEW_AUTO_REPOS+x}" ] && AUTO_REPOS=$LEAD_REVIEW_AUTO_REPOS
[ -n "${AUTO_REPOS// /}" ] || { log "LEAD_REVIEW_AUTO_REPOS is empty; nothing requested"; exit 0; }

LEDGER="$STATE/requested.tsv"
RISK="$STATE/risk.tsv"
# BH-5294: delta.tsv caches what git settled for a head pair, <epoch>\t<slug>\t
# <n>\t<G>\t<H>\t<max lines>\t<class>[\t<protected max>:<word>] (a changed knob
# reclassifies; the 8th column is on protected and over-max rows); modes.tsv
# is one row per decision that saved or spent a lead review, <epoch>\t<UTC day>
# \t<replay|delta|full>\t<slug>\t<n>\t<head>\t<detail>, kept 30 days: the
# per-day count the tick summary's today_* fields read. BH-7043 adds the mode
# builder-replay (a carried builder APPROVE, detail from=<A12> how=<how>), one
# row per head, which the today_* fields do not count.
DELTA="$STATE/delta.tsv"
MODES="$STATE/modes.tsv"
# The `failed` rung's own budget (header): the resets this lane made, per head.
FRETRY="$STATE/failed-retry.tsv"
NOW=$(date +%s)
touch "$LEDGER" "$RISK" "$DELTA" "$MODES" "$FRETRY" 2>/dev/null
# Ledger lines are <epoch>\t<slug>\t<n>\t<head>\t<id>; keep 7 days. risk.tsv the same.
# Only the tick prunes; a pr run only appends.
if [ "$RUNMODE" = tick ]; then
  for f in "$LEDGER" "$RISK" "$DELTA"; do
    awk -F'\t' -v c=$((NOW - 604800)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  done
  for f in "$MODES" "$FRETRY"; do
    awk -F'\t' -v c=$((NOW - 2592000)) '$1 ~ /^[0-9]+$/ && $1 >= c' "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f"
  done
  # builder-carry.tsv (BH-7043): the same 7 days as delta.tsv.
  command -v bc_prune >/dev/null 2>&1 && bc_prune "$STATE"
fi
# The reset budget per head. Not a whole number = the registry default, said once a tick.
RETRYMAX="${LEAD_REVIEW_FAILED_RETRY_MAX:-2}"
[[ "$RETRYMAX" =~ ^[0-9]+$ ]] || { log "LEAD_REVIEW_FAILED_RETRY_MAX='$RETRYMAX' is not a whole number; 2 is used"; RETRYMAX=2; }
# The delta knob, read once a tick: a cached class is only reused under the same value.
LDMAX=""; [ "$LD" = 1 ] && { LDMAX=$(ld_knob LEAD_DELTA_REVIEW_MAX_LINES) || LDMAX="unresolved"; }
# BH-5582: and the protected allowance, which keys the protected and over-max rows.
LDPMAX=""; [ "$LD" = 1 ] && { LDPMAX=$(ld_knob LEAD_DELTA_PROTECTED_MAX_LINES) || LDPMAX="unresolved"; }
find "$STATE" -maxdepth 1 -name 'risk-pub-*' -mtime +7 -delete 2>/dev/null
find "$STATE" -maxdepth 1 -name 'inbuild-wait-*' -mtime +7 -delete 2>/dev/null
find "$STATE" -maxdepth 1 -name 'traced-*' -mtime +7 -delete 2>/dev/null
find "$STATE" -maxdepth 1 -name 'alerted-*' -mtime +7 -delete 2>/dev/null
# The self-check's per-head hold files (BH-5798) age out the same way.
find "$STATE" -maxdepth 1 -name 'selfcheck-*' -mtime +7 -delete 2>/dev/null
# The per-head review tokens (BH-6967) age out the same way.
find "$STATE" -maxdepth 1 -name 'review-tier-*' -mtime +7 -delete 2>/dev/null
# The silence check's per-head note files (BH-5797) age out the same way.
find "$STATE/silence" -maxdepth 1 \( -name 'note-*' -o -name 'scanned-*' \) -mtime +7 -delete 2>/dev/null

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lead-review-enqueue.XXXXXX") || { log "mktemp failed; tick skipped"; exit 0; }
trap 'rm -rf "$WORK"' EXIT

# The snapshot store is bounded: closed PRs' files go after 3 days.
command -v prs_gc >/dev/null 2>&1 && prs_gc
export PRS_COUNT_FILE="$WORK/prs-count"

SELFCHK=0; RBASE=0; TRACED=0; TBOUND=0; TDISP=0; NOCI=0; REPOS=0; PRS=0; REQUESTED=0; REPLAYED=0; BREPLAYED=0; PSFETCHF=0; PSFF_KEY=""; RDELTA=0; RFULL=0; EXISTING=0; DEFERRED=0; NOAPP=0; VERD=0; SELF=0; SILENCE=0; TRIPPED=0; UNREAD=0; ASKED=0; RUNG=0
RLOW=0; RSIGNED=0; RSHADOW=0; RMED=0; RHIGH=0; RLEADN=0; RWAIT=0; GRACE=""
JASKED=0; JEV=0; RINTENT=0
FAILRESET=0; FAILX=0; RECLAIMED=0; SKDRAFT=0; REQ_STATUS=""; REQ_ID=""

# mode_row <replay|delta|full|builder-replay> <slug> <n> <head> <detail> — one modes.tsv row
# (BH-5294; builder-replay is BH-7043, and the today_* counts do not read it).
mode_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$(date -u +%Y%m%d)" "$1" "$2" "$3" "$4" "$5" >> "$MODES" 2>/dev/null || true
}

# fetch_failed_once — count fetch_failed= (BH-7043) at most once per PR a tick.
fetch_failed_once() {
  [ "$PSFF_KEY" = "$SLUG#$N" ] && return 0
  PSFF_KEY="$SLUG#$N"; PSFETCHF=$((PSFETCHF + 1))
}

# skip_line <class> <message> — the one log line of a PR this tick does not
#   request (header, `Skip lines`). The message bytes are written unchanged.
# A line is written only when this PR's (head, class) differs from what the
# last tick logged for it; a repeat is counted, not written (one open PR on a
# 5-minute tick was ~29,000 lines a day). state/lead-review-enqueue/
# skip-last.tsv holds `<repo>#<n> @<sha12>\t<class>` for every PR skipped by
# the last tick, rewritten at the end of each tick; the summary carries
# skips=<all> skips_logged=<written>.
SKIPLAST="$STATE/skip-last.tsv"
declare -A SKIP_PREV=() SKIP_NOW=()
if [ -r "$SKIPLAST" ]; then
  while IFS=$'\t' read -r SK SC; do [ -n "$SK" ] && SKIP_PREV["$SK"]="$SC"; done < "$SKIPLAST"
fi
SKIPS=0; SKIPLOGGED=0
skip_line() {
  local key="${2%%: *}"
  SKIPS=$((SKIPS + 1)); SKIP_NOW["$key"]="$1"
  [ "${SKIP_PREV[$key]:-}" = "$1" ] && return 0
  SKIPLOGGED=$((SKIPLOGGED + 1)); log "$2 [skip $1]"
}
# skip_event <class> <message> — a skip that is also an ACTION this tick (a
# replay posted): always written, and it leaves the dedupe state alone, so the
# next tick's own skip for the PR is still written once.
skip_event() { SKIPS=$((SKIPS + 1)); SKIPLOGGED=$((SKIPLOGGED + 1)); log "$2 [skip $1]"; }
# lr_env_failure <detail> — rc 0 when <detail> is one of the shapes
#   bin/lead-review-land.sh requeues as an environment failure (BH-5793,
#   lrl_env_failure): exactly checkout, no-checkout or empty, or a
#   `review-failed: env:` prefix. The same `case` as the land lane, so the two
#   lanes never disagree: `checkout: merge conflict` is a real failure.
lr_env_failure() {
  case "${1:-}" in
    checkout|no-checkout|empty|"review-failed: env:"*) return 0 ;;
  esac
  return 1
}
# lr_land_owns_env — rc 0 when the land lane requeues environment failures on
#   this tree: its lane file registers LEAD_REVIEW_ENV_RETRY_MAX (BH-5793,
#   #5809). Without it (main before #5809) nothing else requeues them, so the
#   `failed` rung resets them here, within the same budget (lead review of
#   abc4e89a).
lr_land_owns_env() {
  grep -q '"LEAD_REVIEW_ENV_RETRY_MAX"' "$H/catalog/lanes.d/lead-review-land.json" 2>/dev/null
}

# redact — stdin to stdout with URL credentials and GitHub tokens masked, for
#   any reason text that came from the worker or from git.
redact() { sed -E 's#://[^/@[:space:]]*@#://***@#g; s#gh[pousr]_[A-Za-z0-9]{20,}#gh*_***#g'; }

# head_authors_json <slug> <n> <head-ref> <project> — BH-5351: who wrote this
#   head, for the worker's separation-of-duties check. Prints one JSON array
#   (rc 0): the build job's identity first (GET /api/verdict?pr= .job.box and
#   .job.participant), then the box and claimed_by of every fix round on the
#   PR. Fix rounds come from GET /api/fix-rounds?project=&cap_key=<project>-<KEY>
#   (br_cap_key's form, KEY from a ticket/<key> head ref) and ?project= alone,
#   keeping rows whose cap_key names the ticket, starts dqw-<n>-, or whose
#   args[3] is the PR url. Trimmed, lowercased, de-duplicated, at most 16 of at
#   most 128 chars. A failed or truncated read is one log line and the rest is
#   still sent. No identity at all is rc 1 with the reason on stdout.
head_authors_json() {
  local slug="$1" n="$2" ref="$3" project="$4" url q v rc key frq ids='[]' rows='[]' f all
  url="https://github.com/$slug/pull/$n"
  q=$(jq -rn --arg u "$url" '$u | @uri')
  rc=0; v=$(JOBS_ALERT=0 _jobs_req GET "/api/verdict?pr=$q" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ids=$(jq -c '[.job.box?, .job.participant?] | map(strings)' <<<"$v" 2>/dev/null) || ids='[]'
       [ "$ids" != '[]' ] || log "$slug#$n: the build job names no box; head_authors has no build identity" ;;
    2) log "$slug#$n: no build job recorded the PR; head_authors has no build identity" ;;
    *) log "$slug#$n: build identity read failed (rc $rc); head_authors has no build identity" ;;
  esac
  # The ticket key through the one parser (bin/lib/ticket-branch.sh, BH-3835):
  # ticket/<prefix>-<n> and its rebuild form -r<k>. Anything else (or no lib)
  # is no key, and only the project-wide fix-round read below runs.
  key=""; command -v ticket_branch_key >/dev/null 2>&1 && key=$(ticket_branch_key "$ref") || key=""
  for frq in ${key:+"project=$project&cap_key=$project-$key&limit=500"} "project=$project&limit=500"; do
    rc=0; f=$(JOBS_ALERT=0 _jobs_req GET "/api/fix-rounds?$frq" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || ! jq -e '.fix_round_jobs | type == "array"' <<<"$f" >/dev/null 2>&1; then
      log "$slug#$n: fix-round lookup ($frq) failed (rc $rc); head_authors may be incomplete"; continue
    fi
    [ "$(jq -r '.truncated == true' <<<"$f")" = true ] && log "$slug#$n: fix-round list truncated; head_authors may be incomplete"
    rows=$(jq -c --argjson a "$rows" '$a + .fix_round_jobs' <<<"$f")
  done
  # The ticket key, bounded so BH-12 never matches BH-123.
  all=$(jq -c --argjson ids "$ids" --arg k "$key" --arg n "$n" --arg u "$url" '
    def named: ($k != "" and ((.cap_key // "") | ascii_downcase
                 | test("(^|[^a-z0-9])" + ($k | ascii_downcase) + "($|[^0-9])")));
    def ours: named or ((.cap_key // "") | startswith("dqw-" + $n + "-"))
              or ((.args | if type == "array" then .[3] else null end) == $u);
    $ids + [.[] | select(ours) | .box, .claimed_by]
    | map(strings | gsub("^\\s+|\\s+$"; "") | ascii_downcase | select(. != ""))
    | reduce .[] as $a ([]; if index([$a]) then . else . + [$a] end)' <<<"$rows") \
    || { echo "head authors could not be built"; return 1; }
  [ "$(jq '[.[] | select(length > 128)] | length' <<<"$all")" = 0 ] \
    || { log "$slug#$n: head_authors over 128 chars dropped"; all=$(jq -c 'map(select(length <= 128))' <<<"$all"); }
  [ "$(jq length <<<"$all")" -le 16 ] || { log "$slug#$n: head_authors over 16; first 16 sent"; all=$(jq -c '.[:16]' <<<"$all"); }
  [ "$all" != '[]' ] || { echo "no build or fix-round identity was readable"; return 1; }
  printf '%s\n' "$all"
}

# inbuild_job_on_head <pr-url> <head> — is a build job for this PR running or
#   queued, bound to <head>? The in-build lead-grade review (bin/run-build.sh's
#   `inbuild lead review` block) runs only inside that job, on the sha its
#   verdict is bound to. One GET /api/verdict?pr= (the ledger's build job first,
#   BH-1024; reviewed_sha is answered for provisional rows too).
#   rc 0 = yes. rc 1 = no (no job, not a build, a status that is not running,
#   queued, queued_for_retry or claimed, or bound to another head or none).
#   rc 2 = the read failed. IBJWHY says which, in words.
inbuild_job_on_head() {
  local q v rc
  q=$(jq -rn --arg u "$1" '$u | @uri')
  rc=0; v=$(JOBS_ALERT=0 _jobs_req GET "/api/verdict?pr=$q" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    2) IBJWHY="no job recorded the PR"; return 1 ;;
    *) IBJWHY="build job read failed (rc $rc)"; return 2 ;;
  esac
  IBJWHY=$(jq -r --arg h "$2" '
    if (.job | type) != "object" then "no job row"
    elif (.job.kind // "") != "build" then "the PR job is \(.job.kind // "no kind"), not a build"
    elif ((.job.status // "") | IN("running", "queued", "queued_for_retry", "claimed") | not)
      then "build job \(.job.id // "?") is \(.job.status // "no status")"
    elif ((.reviewed_sha // "") | ascii_downcase) != $h
      then "build job \(.job.id // "?") is bound to \((.reviewed_sha // "no head") | .[0:12])"
    else "ok" end' <<<"$v" 2>/dev/null) || { IBJWHY="build job answer unparseable"; return 2; }
  [ -n "$IBJWHY" ] || { IBJWHY="build job answer unparseable"; return 2; }
  [ "$IBJWHY" = ok ]
}

# request <slug> <n> <head> <recorded 0|1> [priority 0|1] [delta note] [prior ref]
#   — one POST and its accounting. A delta note (BH-5294, `lead-delta:<G> ...`)
#   rides in scope_notes, where bin/lead-review.sh reads it; the prior ref names
#   the lead row it builds on.
request() {
  local slug="$1" n="$2" head="$3" rec="$4" prio="${5:-0}" dnote="${6:-}" dprior="${7:-}" body resp rc err id safe lrc=3 notes authors rvt rvf rvl
  notes="auto: ${REQFOR:-builder APPROVE} on ${head:0:12}"
  [ -n "$dnote" ] && notes="$notes; $dnote"
  [ -n "${PSCNOTE:-}" ] && notes="$notes; $PSCNOTE"
  [ -n "${TNOTE:-}" ] && notes="$notes; $TNOTE"
  [ -n "${SDNOTE:-}" ] && notes="$notes; $SDNOTE"
  # BH-6967 (header, `intent`): the tier and mode tokens end the notes. A first
  # ask sends this head's RVTOK; a re-confirm sends only what the first ask stored.
  # The note parts before them carry text a PR author or a commenter controls
  # (diff paths, commit subjects, a HUMAN-STEP-DONE body), so the same words
  # there are rewritten: the readers trust only the last group.
  notes="${notes//review-tier:/review-tier=}"; notes="${notes//review-mode:/review-mode=}"
  rvf="$STATE/review-tier-$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')-$n-${head:0:12}"
  if [ "$rec" = 1 ]; then rvt=$(cat "$rvf" 2>/dev/null); else rvt="${RVTOK:-}"; fi
  # The worker caps scope_notes at 4000 chars (worker/jobs/src/routes/lead-reviews.js);
  # over it, the lead-prev file lists become their counts (BH-6391).
  rvl=4000; [ -n "$rvt" ] && rvl=$((4000 - ${#rvt} - 2))
  command -v lpv_fit >/dev/null 2>&1 && notes=$(lpv_fit "$notes" "$rvl")
  [ -n "$rvt" ] && notes="$notes; $rvt"
  if ! authors=$(head_authors_json "$slug" "$n" "$(jq -r '.head.ref // empty' "$WORK/pr" 2>/dev/null)" "$PROJECT"); then
    log "$slug#$n @${head:0:12}: no head authorship ($authors); requested without head_authors"
    authors=""
  fi
  body=$(jq -nc --arg r "$slug" --argjson p "$n" --arg h "$head" --arg by "lead-review-enqueue:$BOX" \
    --arg notes "$notes" --arg pr "$prio" --arg pv "$dprior" --arg au "$authors" \
    '{repo:$r, pr:$p, head_sha:$h, requested_by:$by, scope_notes:$notes} + (if $pr == "1" then {priority:1} else {} end)
     + (if $pv == "" then {} else {prior_verdict_ref:$pv} end)
     + (if $au == "" then {} else {head_authors:($au | fromjson)} end)')
  rc=0; resp=$(lr_post_lead '' "$body" 2>"$WORK/err") || rc=$?
  err=$(tr '\n' ' ' < "$WORK/err")
  id=$(jq -r '.request.id // empty' <<<"$resp" 2>/dev/null)
  # For the caller: the row the worker answered with, on every path.
  REQ_ID="$id"; REQ_STATUS=$(jq -r '.request.status // empty' <<<"$resp" 2>/dev/null)
  if [ "$rc" = 0 ] && [ "$(jq -r '.existing // false' <<<"$resp" 2>/dev/null)" = true ]; then
    [ "$REQ_STATUS" = failed ] && { lr_failed_retry "$slug" "$n" "$head" "$resp" "$rec"; return $?; }
    EXISTING=$((EXISTING + 1)); lr_existing_line "$slug" "$n" "$head" "$resp"; return 0
  fi
  if [ "$rc" != 0 ] && [[ "$err" == *"HTTP 409"* ]] && [ -n "$id" ]; then
    log "$slug#$n @${head:0:12}: a request with other notes already exists ($id)"
    [ "$REQ_STATUS" = failed ] && { lr_failed_retry "$slug" "$n" "$head" "$resp" "$rec"; return $?; }
    EXISTING=$((EXISTING + 1)); lr_existing_line "$slug" "$n" "$head" "$resp"; return 0
  fi
  if [ "$rc" != 0 ] || [ -z "$id" ]; then
    skip_line unreadable "$slug#$n @${head:0:12}: POST /api/lead-reviews failed ($err$(printf '%s' "$resp" | tr '\n' ' ' | head -c 200)); next tick retries"
    UNREAD=$((UNREAD + 1)); return 1
  fi
  REQUESTED=$((REQUESTED + 1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" >> "$LEDGER"
  if [ -n "$rvt" ]; then
    [ "$rec" = 1 ] || printf '%s' "$rvt" > "$rvf" 2>/dev/null \
      || log "$slug#$n @${head:0:12}: could not store the review tokens in $rvf; a re-confirm may be refused 409"
    case "$rvt" in *review-mode:intent*) RINTENT=$((RINTENT + 1)); log "$slug#$n @${head:0:12}: intent review requested ($rvt)" ;; esac
  fi
  [ "$RUNMODE" = pr ] && log "$slug#$n @${head:0:12}: immediate lead review request ($id), trigger=$LRE_TRIG"
  # Delta only when the note carries `lead-delta:` (bin/lead-review.sh enters
  # delta mode on exactly that). A note that is only `possible duplicate of …`
  # (BH-5802) rides in scope_notes on a FULL review, and is counted as one.
  case "$dnote" in
    *lead-delta:*)
      RDELTA=$((RDELTA + 1)); mode_row delta "$slug" "$n" "$head" "$dnote"
      log "$slug#$n @${head:0:12}: lead review requested ($id) in delta mode ($dnote)" ;;
    *)
      RFULL=$((RFULL + 1)); mode_row full "$slug" "$n" "$head" "-"
      log "$slug#$n @${head:0:12}: lead review requested ($id)${dnote:+ with a note ($dnote)}" ;;
  esac
  # Ring the owning box's lead review only now, after the 201 and its ledger
  # line. rc 3 = the lib is not here; 1 = off or bad input; 2 = not delivered.
  [ "$LCW" = 1 ] && { lrc=0; lcw_ring lead-review "$slug" "$n" "$head" || lrc=$?; }
  if [ "$lrc" = 0 ]; then
    RUNG=$((RUNG + 1)); log "$slug#$n @${head:0:12}: lead-review doorbell rung"
  else
    log "$slug#$n @${head:0:12}: doorbell not rung (rc $lrc); the */15 cron covers it"
  fi
  if [ "$rec" = 1 ]; then
    safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
    alert_once "lead-repeat-$safe-$n-${head:0:12}" critical "$slug#$n @${head:0:12}: the jobs worker created a SECOND lead review request ($id) for a head this lane already requested, so a second model review is being bought. Check the worker's ON CONFLICT(repo,pr,head_sha) on lead_review_requests." --critical || true
  fi
  return 0
}

# lr_existing_line <slug> <n> <head> <resp-json> — the skip line of a head the
#   worker already holds a request for (not failed: lr_failed_retry owns that).
lr_existing_line() {
  local st det
  st=$(jq -r '.request.status // "unknown"' <<<"$4" 2>/dev/null)
  det=""
  [ "$st" = superseded ] && det="; the owning box superseded it ($(jq -j '(.request.detail // "no detail") | tostring | gsub("[\\n\\t]"; " ")' <<<"$4" 2>/dev/null | redact | head -c 300))"
  skip_line existing "$1#$2 @${3:0:12}: already requested (${REQ_ID:-no id}, status ${st:-unknown})$det"
}

# lr_failed_retry <slug> <n> <head> <resp-json> <recorded 0|1> — the `failed`
#   rung (header). <recorded> 0 = the new-head path, which already spent this
#   tick's cap slot and passed the tripwire for this POST. rc 0 = reset, or a
#   skip line was written; rc 1 = the reset was refused or failed (skip line).
lr_failed_retry() {
  local slug="$1" n="$2" head="$3" resp="$4" counted="${5:-1}" id detail k safe h12 rrc rresp rerr dayn lrc=3 text
  h12=${head:0:12}
  safe=$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')
  id=$(jq -r '.request.id // empty' <<<"$resp" 2>/dev/null)
  detail=$(jq -j '(.request.detail // "no detail") | tostring | gsub("[\\n\\t]"; " ")' <<<"$resp" 2>/dev/null | redact | head -c 300)
  [ -n "$detail" ] || detail="no detail"
  if [ -z "$id" ]; then
    UNREAD=$((UNREAD + 1)); skip_line unreadable "$slug#$n @$h12: a failed lead review came back with no id; next tick retries"; return 1
  fi
  # An ENVIRONMENT failure is bin/lead-review-land.sh's to requeue (BH-5793,
  # #5809, LEAD_REVIEW_ENV_RETRY_MAX on the request's reset_count): a second
  # reset here would double its budget. Only while the land lane owns them;
  # otherwise they take the reset rung below like any failure.
  if lr_env_failure "$detail" && lr_land_owns_env; then
    skip_line env-failed "$slug#$n @$h12: lead review $id failed on the environment ($detail); bin/lead-review-land.sh requeues it (LEAD_REVIEW_ENV_RETRY_MAX)"
    return 0
  fi
  k=$(awk -F'\t' -v s="$slug" -v n="$n" -v h="$head" '$2 == s && $3 == n && tolower($4) == h && $6 == "reset"' "$FRETRY" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$k" -ge "$RETRYMAX" ]; then
    text="$slug#$n @$h12: the lead review request $id failed $((k + 1)) times on this head; last reason: $detail. Nothing is retried. Read the owning box's logs/lead-review.log, then review by hand: bin/lead-verdict.sh post $slug $n $head <VERDICT>"
    alert_once "lead-failed-$safe-$n-$h12" warn "$text" \
      && printf '%s\t%s\t%s\t%s\t%s\talerted\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" "${detail:0:200}" >> "$FRETRY"
    FAILX=$((FAILX + 1))
    skip_line failed-exhausted "$slug#$n @$h12: lead review $id failed ($detail); $k resets used of $RETRYMAX, not retried"
    return 0
  fi
  # A reset buys a new review: it takes a cap slot and counts toward the tripwire.
  if [ "$counted" = 1 ] && [ "$ASKED" -ge "$MAXT" ]; then
    DEFERRED=$((DEFERRED + 1))
    skip_line deferred "$slug#$n @$h12: failed lead review $id not reset this tick (LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=$MAXT reached)"
    return 0
  fi
  dayn=$(awk -F'\t' -v s="$slug" -v n="$n" -v c=$((NOW - 86400)) '$2 == s && $3 == n && $1 >= c' "$LEDGER" | wc -l | tr -d ' ')
  if [ "$dayn" -ge "$MAXD" ]; then
    TRIPPED=$((TRIPPED + 1))
    skip_line tripped "$slug#$n @$h12: $dayn lead review requests in 24h (LEAD_REVIEW_MAX_PER_PR_DAY=$MAXD); failed lead review $id not reset"
    alert_once "lead-trip-$safe-$n-$DAY" warn "$slug#$n has had $dayn lead review requests in 24h (LEAD_REVIEW_MAX_PER_PR_DAY=$MAXD), so the failed lead review $id @$h12 was not reset. Look at the PR before asking again with bin/lead-verdict.sh reset $id" || true
    return 0
  fi
  rrc=0; rresp=$(lr_post_lead "/$id/reset" '{}' 2>"$WORK/rerr") || rrc=$?
  rerr=$(tr '\n' ' ' < "$WORK/rerr")
  if [ "$rrc" = 0 ] && [ "$(jq -r '.request.status // empty' <<<"$rresp" 2>/dev/null)" = requested ]; then
    [ "$counted" = 1 ] && ASKED=$((ASKED + 1))
    FAILRESET=$((FAILRESET + 1))
    printf '%s\t%s\t%s\t%s\t%s\treset\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" "${detail:0:200}" >> "$FRETRY"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$slug" "$n" "$head" "$id" >> "$LEDGER"
    mode_row full "$slug" "$n" "$head" "reset:$id"
    log "$slug#$n @$h12: lead review $id failed ($detail); reset $((k + 1))/$RETRYMAX for a new review"
    [ "$LCW" = 1 ] && { lrc=0; lcw_ring lead-review "$slug" "$n" "$head" || lrc=$?; }
    if [ "$lrc" = 0 ]; then
      RUNG=$((RUNG + 1)); log "$slug#$n @$h12: lead-review doorbell rung"
    else
      log "$slug#$n @$h12: doorbell not rung (rc $lrc); the */15 cron covers it"
    fi
    return 0
  fi
  if [[ "$rerr" == *"HTTP 409"* ]]; then
    skip_line reset-refused "$slug#$n @$h12: reset of $id refused (a review is in flight): $(printf '%s' "$rresp" | tr '\n' ' ' | redact | head -c 200)"
  else
    UNREAD=$((UNREAD + 1))
    skip_line unreadable "$slug#$n @$h12: reset of $id failed (${rerr:-the answer was not a requested row}); next tick retries"
  fi
  return 1
}

# rt_compare <slug> <base> <head> <n> — GET compare/<base>...<head> ONCE a tick
# per head into $WORK/cmp-<n>; sets CRC (the gh rc) and SELFHIT (true|false|
# unreadable|truncated: a non-merge commit with a line starting `Lead-Lane:`).
rt_compare() {
  local f="$WORK/cmp-$4"
  if [ ! -e "$f.rc" ] || [ "$(cat "$f.head" 2>/dev/null)" != "$3" ]; then
    CRC=0; gh_rest GET "repos/$1/compare/$(jq -rn --arg b "$2" '$b|@uri')...$3" > "$f" 2>/dev/null || CRC=$?
    printf '%s' "$CRC" > "$f.rc"; printf '%s' "$3" > "$f.head"
  fi
  CRC=$(cat "$f.rc")
  SELFHIT=$(jq -r 'if (.commits|type) != "array" or (.total_commits|type) != "number" then "unreadable"
    elif .total_commits > (.commits|length) then "truncated"
    else ([.commits[] | select((.parents|length) < 2) | .commit.message // "" | split("\n")[] | select(test("^Lead-Lane:"))] | length > 0) end' \
    "$f" 2>/dev/null)
  [ "$CRC" = 0 ] || SELFHIT=unreadable
}

# ss_early <slug> <n> <head> <base> — the silence check (BH-5797) for a head
# not yet asked for. rc 1 = the caller continues (held, or unreadable, both
# counted here); rc 0 = go, with SNOTE set and SSDONE=1. A head scanned before
# with no human hit (state/.../silence/scanned-<repo>-<n>-<sha12>) costs no
# compare read: its lead note, if any, is read back.
ss_early() {
  local mk="$STATE/silence/scanned-${1//\//_}-$2-${3:0:12}"
  SSDONE=1; SNOTE=""
  command -v ss_gate >/dev/null 2>&1 || return 0
  awk -F'\t' -v s="$1" -v n="$2" -v h="$3" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER" && return 0
  if [ ! -e "$mk" ]; then
    rt_compare "$1" "$4" "$3" "$2"
    [ "$CRC" = 0 ] || return 0
    ss_gate "$1" "$2" "$3" "$WORK/cmp-$2" "$WORK/pr" "$STATE/silence"
    case $? in
      1) SILENCE=$((SILENCE + 1))
         skip_line silence "$1#$2 @${3:0:12}: not requested: the silence check holds this head (a leak allow-list entry; the label stays until a human clears it)"
         return 1 ;;
      2) UNREAD=$((UNREAD + 1))
         skip_line unreadable "$1#$2 @${3:0:12}: not requested: the silence check could not read this head; next tick retries"
         return 1 ;;
    esac
    mkdir -p "$STATE/silence" 2>/dev/null; : > "$mk" 2>/dev/null
  fi
  SNOTE=$(ss_note "$STATE/silence" "$1" "$2" "$3")
  return 0
}

# rt_lead_skip <pr body file> — sets RLEAD to why the risk tier must not touch
# this PR (a lead author, or one that cannot be told apart from one), empty when
# it may, and RLAUTH=1 only for a confirmed lead author (BH-5325: classified,
# and signed only as a rules-text low). In THIS shell: to_is_lead memoises the
# lead_pr_authors row per tick.
rt_lead_skip() {
  local who
  RLEAD=""; RLAUTH=0
  who=$(jq -r '.user.login // empty' "$1" 2>/dev/null)
  if ! command -v to_is_lead >/dev/null 2>&1; then RLEAD="no bin/lib/ticket-ownership.sh, so a lead author cannot be told"
  elif [ -z "$who" ]; then RLEAD="PR author unreadable"
  else
    to__lead_load  # TO_LEAD_AUTHORS is the trimmed row, empty when it was not read
    if [ -z "$TO_LEAD_AUTHORS" ]; then RLEAD="lead_pr_authors row unreadable"
    elif to_is_lead "$who"; then RLEAD="lead-authored ($who): a risk-tier row never clears a lead PR"; RLAUTH=1
    fi
  fi
}

# noapp_why — sets NAWHY, the reason of a skip at the builder-verdict step (V
# is not APPROVE). In THIS shell, so the lead_pr_authors read stays one a tick.
# A lead author is named only when rt_lead_skip confirmed it (RLAUTH=1).
noapp_why() {
  local who
  if [ "$JRC" = 1 ]; then NAWHY="builder verdict unreadable (job_verdict rc 1)"; return 0; fi
  if [ "$JRC" = 2 ] || [ -z "$V" ]; then NAWHY="no builder verdict and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=$REQB"; return 0; fi
  rt_lead_skip "$WORK/pr"
  if [ "$RLAUTH" = 1 ]; then
    who=$(jq -r '.user.login // empty' "$WORK/pr" 2>/dev/null)
    NAWHY="the builder's $V on ${RSHA:0:12} stands and the PR is lead-authored ($who): the author must push a fix, or ask by hand with bin/lead-verdict.sh request $SLUG $N $HEAD --notes \"...\""
  else
    NAWHY="the builder's $V on ${RSHA:0:12} stands; the fix round owns it"
  fi
}

# self_check_hold <slug> <n> <head> <base> <project> — rc 0 (PSCOUT: the
# refusals) when the PR body fails the pre-review self-check (BH-5798, header
# `self`); rc 1 = go. One fetch of the base and the head into the hub clone,
# and none when the clone already has both.
self_check_hold() {
  local repo="${REPOS_ROOT:-/root/repos}/$5" bf out rc tf tn ij it il ir itn tk
  PSCOUT=""; PSCNOTES=""
  [ "$PSC" = 1 ] && [ -d "$repo/.git" ] || return 1
  bf="$WORK/body-$2"
  jq -r '.body // ""' "$WORK/pr" > "$bf" 2>/dev/null || return 1
  # Fetch only what the clone lacks: a head the replay/delta path already
  # fetched this tick or earlier (its cached head pair) costs no second fetch.
  if ! git -C "$repo" cat-file -e "$3^{commit}" 2>/dev/null \
     || ! git -C "$repo" rev-parse -q --verify "origin/$4^{commit}" >/dev/null 2>&1; then
    git -C "$repo" fetch -q origin "$4" "$3" >/dev/null 2>&1 || return 1
  fi
  # BH-5790: the linked issue is the ticket text the body-* rules read (a probe
  # its Done when names). One REST read per held head per tick; none = no text.
  # BH-6380: the same read gives the title and labels the perf trigger reads,
  # and the repo and number its one parent hop needs. A failed read = all empty.
  tf="$WORK/ticket-$2"; : > "$tf"; ij="$WORK/ticket-$2.json"; : > "$ij"; it=""; il=""; ir=""; itn=""
  tn=$(grep -oiE '(closes|fixes|resolves|refs|part of)[[:space:]]+#[0-9]+' "$bf" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
  if [ -n "$tn" ] && gh_rest GET "repos/$1/issues/$tn" > "$ij" 2>/dev/null; then
    jq -r '.body // ""' "$ij" > "$tf" 2>/dev/null
    it=$(jq -r '.title // ""' "$ij" 2>/dev/null); il=$(jq -r '[.labels[]?.name] | join(",")' "$ij" 2>/dev/null)
    ir="$1"; itn="$tn"
  fi
  # BH-6392: the title key (`BH-N: ...`) is the PR's own key for test-ownership.
  tk=$(jq -r '.title // ""' "$WORK/pr" 2>/dev/null | sed -nE 's/^([A-Za-z]+-[0-9]+(\.[0-9]+)*):.*/\1/p')
  out=$(PR_SELF_CHECK_CATALOG="${PR_SELF_CHECK_CATALOG:-$H/catalog/pr-self-check.tsv}" PSC_PR_KEY="$tk" \
        PSC_TICKET_TITLE="$it" PSC_TICKET_LABELS="$il" PSC_TICKET_REPO="$ir" PSC_TICKET_N="$itn" \
        PSC_PR_REPO="$1" PSC_PR_N="$2" PSC_PROJECT="$5" \
        psc_check "$repo" "origin/$4" "$3" "$bf" "$tf" 2>/dev/null); rc=$?
  # BH-5790: a `note` body rule (mutation evidence, the D1 callout) holds
  # nothing; its finding rides in the request notes for the lead to judge.
  PSCNOTES=$(printf '%s\n' "$out" | sed -n 's/^NOTE \(body-[a-z0-9-]*: the body is missing .*\)/\1/p')
  # BH-7815: a path the PR deletes that the merge with the base still names.
  PSCNOTES=$(printf '%s\n%s\n' "$PSCNOTES" "$(printf '%s\n' "$out" | sed -n 's/^NOTE \(callers-not-ported: .*\)/\1/p')" | sed '/^$/d')
  [ "$rc" = 1 ] || return 1
  PSCOUT=$(printf '%s\n' "$out" | sed -n 's/^REFUSE //p')
  return 0
}

# ci_green_head <slug> <head> <base> <n> — rc 0 when CI is green on <head> by
# the lead lane's definition (lr_ci_green, `lead ci green` in bin/lead-review.sh).
# The base branch's .mergify.yml is read ONCE a tick per (repo, base) over REST,
# never the PR's own copy. Anything unread is not green; CIWHY says why.
# rebase_hold <slug> <n> <head> <base> <project> — rc 0 (RBWHY says why) when
# the head conflicts with its base and must not be reviewed yet; rc 1 = go
# (BH-5796, header `rebase`). The conductor's word first, then GitHub's DIRTY,
# then a `git merge-tree` on the hub clone's own objects. No network at all.
# Anything that cannot run is go. On go, DUPNOTE may carry `possible duplicate
# of <sha> (<path>)` (BH-5802) for the request's scope notes.
rebase_hold() {
  local st rh rr repo out mrc dup
  RBWHY=""; DUPNOTE=""
  [ "$RBHOLD" = 1 ] || return 1
  IFS=$'\t' read -r st rh rr < <(awk -F'\t' -v k="$1#$2" '$1 == k {print $2 "\t" tolower($4) "\t" $7; exit}' \
    "$H/state/merge-conductor/pr-state.tsv" 2>/dev/null)
  if [ "${rh:-}" = "$3" ]; then
    case "$st:$rr" in
      NEEDS_REBASE:*|REBASING:*) RBWHY="NEEDS_REBASE: the conductor has this head $st (${rr:-no reason})"; return 0 ;;
      BLOCKED_HUMAN:conflict-unresolvable*) RBWHY="NEEDS_REBASE: the conductor parked this head ${rr%%:*} for a fix round"; return 0 ;;
    esac
  fi
  # GitHub's own word, free: the PR body already read this tick.
  if [ "$(jq -r '.mergeable_state // empty' "$WORK/pr" 2>/dev/null)" = dirty ]; then
    RBWHY="NEEDS_REBASE: GitHub lists this head DIRTY against $4"; return 0
  fi
  # Then git, on the objects the hub clone already holds: no fetch here (the
  # replay above fetches what it needs, and a cached head pair must cost none,
  # tests/lead-replay-merge-only.bh-5294-test.sh R5). A head the clone does
  # not have is not judged.
  repo="${REPOS_ROOT:-/root/repos}/$5"
  [ -d "$repo/.git" ] || return 1
  git -C "$repo" cat-file -e "$3^{commit}" 2>/dev/null || return 1
  git -C "$repo" rev-parse -q --verify "origin/$4^{commit}" >/dev/null 2>&1 || return 1
  out=$(git -C "$repo" merge-tree --write-tree --name-only --no-messages "origin/$4" "$3" 2>/dev/null); mrc=$?
  if [ "$mrc" = 1 ]; then
    RBWHY="NEEDS_REBASE: conflicts with origin/$4 in $(printf '%s\n' "$out" | sed 1d | grep . | head -5 | paste -sd' ' -)"
    return 0
  fi
  # BH-5802: a head that merges clean can still redo what main already did (a
  # file re-added with main's content, the same hunk added twice). It is never
  # held: the conductor rebases only DIRTY or CONFLICTING heads, so a CLEAN
  # head held here would wait forever. The lead reads the note (item 12).
  if command -v dup_main_pr >/dev/null 2>&1 && dup=$(dup_main_pr "$repo" "origin/$4" "$3"); then
    DUPNOTE="possible duplicate of ${dup%% *} (${dup#* })"
  fi
  return 1
}

ci_green_head() {
  local mf
  # One file per (repo, base), named by a hash: `release/x_y` and `release_x/y`
  # must never share a cached .mergify.yml.
  mf="$WORK/mergify-$(printf '%s\n%s' "$1" "$3" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32)"
  CIWHY=""
  [ "$LCG" = 1 ] || { CIWHY="no lead ci green block in bin/lead-review.sh"; return 1; }
  if [ ! -e "$mf.read" ]; then
    : > "$mf"; : > "$mf.read"
    gh_rest GET "repos/$1/contents/.mergify.yml?ref=$(jq -rn --arg b "$3" '$b|@uri')" > "$mf.json" 2>/dev/null \
      && jq -r '.content // empty' "$mf.json" 2>/dev/null | tr -d '\n' | base64 -d > "$mf" 2>/dev/null
  fi
  # shellcheck disable=SC2034  # read by lr_ci_fetch: one check-run read per head
  LR_CI_SHA=""
  lr_ci_green "$1" "$2" "$mf" "$WORK/checks-$4" && return 0
  CIWHY="$LR_CI_WHY"; return 1
}

# Reclaim (header): fail-open, nothing below depends on it.
RCRC=0; RCOUT=$(lr_post_lead /reclaim-stale '{}' 2>"$WORK/rcerr") || RCRC=$?
if [ "$RCRC" = 0 ] && jq -e '(.reclaimed | type) == "array"' <<<"$RCOUT" >/dev/null 2>&1; then
  RECLAIMED=$(jq '.reclaimed | length' <<<"$RCOUT")
  while IFS=$'\t' read -r RCID RCREPO RCPR RCHEAD RCTO RCBEAT; do
    log "$RCREPO#$RCPR @${RCHEAD:0:12}: lead review $RCID ran with no heartbeat since $RCBEAT; reclaimed to $RCTO (deadline $(jq -r '.deadline_s // "?"' <<<"$RCOUT") s)"
  done < <(jq -r '.reclaimed[] | [(.id // "?"), (.repo // "?"), (.pr // "?" | tostring), (.head_sha // ""), (.to // "?"), (.last_beat // "never")] | @tsv' <<<"$RCOUT" | redact)
  [ "$(jq -r '.truncated == true' <<<"$RCOUT")" = true ] && log "reclaim-stale reclaimed $RECLAIMED rows and was truncated; the next tick takes the rest"
else
  RCWHY=$(tr '\n' ' ' < "$WORK/rcerr" | redact | head -c 200); RCWHY="${RCWHY% }"
  log "reclaim-stale not answered (${RCWHY:-unparseable answer}); stale running rows are not reclaimed this tick"
fi

# traced_hold <slug> <head> <base> <n> — rc 0 (TWHY says why) when the head
# must wait for a real test run (BH-5795, header `traced`); rc 1 = go. Reads
# the PR body in $WORK/pr, and the check runs only for a base that is not the
# default branch (one read a head, shared with ci_green_head through lr_ci_fetch).
traced_hold() {
  local dflt ms f="$WORK/checks-$4" counts total done run where
  TWHY=""
  [ "$TWAIT" = 1 ] || return 1
  ms=$(jq -r '.mergeable_state // empty' "$WORK/pr" 2>/dev/null)
  dflt=$(jq -r '.base.repo.default_branch // empty' "$WORK/pr" 2>/dev/null); dflt="${dflt:-main}"
  # A DIRTY head is the rebase hold's (BH-5796) while it is on: no test run can
  # land it before a rebase, so none is dispatched for it here.
  if [ "$ms" = dirty ] && [ "${RBHOLD:-0}" = 1 ]; then return 1
  elif [ "$ms" = dirty ]; then where="DIRTY against $3 (GitHub runs no pull_request CI on a conflicting head)"
  elif [ "$3" != "$dflt" ]; then where="base $3 is not $dflt"
  else return 1; fi
  # The head's own traced checks decide, for a DIRTY head too: the impact run
  # the hold dispatches lands its checks on this sha and releases it.
  if command -v lr_ci_fetch >/dev/null 2>&1; then
    lr_ci_fetch "$1" "$2" "$f" || { TWHY="$where and the check runs are unreadable ($LR_CI_WHY)"; return 0; }
  elif ! gh_rest GET "repos/$1/commits/$2/check-runs?per_page=100&filter=latest" > "$f" 2>/dev/null; then
    TWHY="$where and the check runs are unreadable (HTTP ${GH_REST_STATUS:-000})"; return 0
  fi
  # <traced runs> <completed and not skipped> <not completed>; one page or unreadable.
  counts=$(jq -r --arg s "$2" --arg j "$TJOB" '
    if type != "object" or (.check_runs | type) != "array" or (.total_count // 0) > (.check_runs | length) then empty
    else [.check_runs[] | select(.head_sha == $s and ((.name // "") | startswith($j)))]
      | "\(length) \([.[] | select(.status == "completed" and .conclusion != "skipped")] | length) \([.[] | select(.status != "completed")] | length)" end' "$f" 2>/dev/null)
  read -r total done run <<<"$counts"
  if ! [[ "$total" =~ ^[0-9]+$ && "$done" =~ ^[0-9]+$ && "$run" =~ ^[0-9]+$ ]]; then
    TWHY="$where and the check runs are unreadable (malformed, or more than one page)"; return 0
  fi
  # A traced job still queued or running holds: its result is not in yet.
  if [ "$run" -gt 0 ]; then
    TWHY="$where and $run '$TJOB' job(s) on this head are still queued or running; waiting for the result"; return 0
  fi
  [ "$done" -gt 0 ] && return 1
  if [ "$total" = 0 ]; then
    TWHY="$where and no '$TJOB' job ran on this head; waiting for a CI run that tests it"; return 0
  fi
  TWHY="$where and every '$TJOB' job on this head is skipped ($total); waiting for a CI run that tests it"; return 0
}

for SLUG in $AUTO_REPOS; do
  [ "$RUNMODE" = pr ] && ! lre_repo_wanted "$SLUG" && continue
  REPOS=$((REPOS + 1))
  case "$SLUG" in */*) ;; *) log "'$SLUG' in LEAD_REVIEW_AUTO_REPOS is not owner/repo; skipped"; continue ;; esac
  PROJECT=$(awk -v r="$SLUG" '$1 !~ /^#/ && $2 == r {print $1; exit}' "${FLEET_CONF:-$H/fleet.conf}" 2>/dev/null)
  [ -n "$PROJECT" ] || { log "no fleet.conf project for $SLUG; skipped"; continue; }
  SAFE=$(printf '%s' "${SLUG//\//_}" | tr -cd 'A-Za-z0-9._-')
  if gh_budget_low lead-review-enqueue; then log "$PROJECT: GitHub budget is low; $SLUG skipped this tick"; continue; fi
  RMODE=off; RWHY=""
  [ "$RT" = 1 ] && IFS=$'\t' read -r RMODE RWHY < <(rt_mode "$SLUG")
  [ -n "$RWHY" ] && log "$SLUG risk tier: $RWHY"
  RT_RULES_LOADED=""; RT_RULES_SIG=""; RT_LOW_SMALL_MODE=off; RT_LOW_SMALL_WHY=""
  { [ "$RMODE" = shadow ] || [ "$RMODE" = enforce ]; } && rt_rules_load
  [ -n "${RT_LOW_SMALL_WHY:-}" ] && log "$SLUG risk tier: $RT_LOW_SMALL_WHY"
  # >>> jev shadow (BH-5024): header, `jev`. Only an exact `shadow` row turns it
  # on; anything else, an unreadable row or no row is off, and off reads nothing more.
  JMODE=off; JMAX=0; JT=30
  if { [ "$RMODE" = shadow ] || [ "$RMODE" = enforce ]; } && [ -x "$H/bin/jev-risk.sh" ]; then
    JMV=$(setting_get jev_risk.mode 2>/dev/null) \
      && [ "$(printf '%s' "$JMV" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')" = shadow ] && JMODE=shadow
    if [ "$JMODE" = shadow ]; then
      JMAX=$(setting_get jev_risk.max_per_tick 2>/dev/null | tr -d '[:space:]'); [[ "$JMAX" =~ ^[0-9]{1,3}$ ]] || JMAX=3
      JT=$(setting_get jev_risk.timeout_s 2>/dev/null | tr -d '[:space:]'); [[ "$JT" =~ ^[1-9][0-9]{0,3}$ ]] || JT=30
    fi
  fi
  # <<< jev shadow
  harness_pr_list "$SLUG" open number,url,isDraft,baseRefName,headRefOid,updatedAt > "$WORK/list" 2>/dev/null; RC=$?
  if [ "$RC" != 0 ] || ! jq -e 'type == "array"' "$WORK/list" >/dev/null 2>&1; then
    log "$PROJECT: the open PR list for $SLUG is unreadable (rc $RC); next tick retries"; UNREAD=$((UNREAD + 1)); continue
  fi
  : > "$PRS_COUNT_FILE"
  while IFS=$'\t' read -r N URL DRAFT BASE LHEAD LUPD; do
    [ "$DRAFT" = true ] && { SKDRAFT=$((SKDRAFT + 1)); skip_line draft "$SLUG#$N @${LHEAD:0:12}: draft PR"; continue; }
    case "$N" in ''|*[!0-9]*) UNREAD=$((UNREAD + 1)); skip_line malformed "$SLUG#$N @${LHEAD:0:12}: '$SLUG#$N': PR number is not numeric"; continue ;; esac
    [ "$RUNMODE" = pr ] && ! lre_row_wanted "$SLUG" "$N" "$LHEAD" && continue
    PRS=$((PRS + 1))
    # The head from the PR body: live on a miss, and on a hit a stored body whose
    # head, updated_at and base tip all still match this list row (header, above).
    HEAD=""
    prs_pr_get "$SLUG" "$N" "$LHEAD" "$LUPD" "$BASE" "$WORK/pr" 2>/dev/null && HEAD=$(jq -r '.head.sha // empty' "$WORK/pr" 2>/dev/null | tr 'A-F' 'a-f')
    [[ "$HEAD" =~ ^[0-9a-f]{40}$ ]] || { skip_line unreadable "$SLUG#$N: live head unreadable (HTTP ${GH_REST_STATUS:-000}); skipped"; UNREAD=$((UNREAD + 1)); continue; }
    H12=${HEAD:0:12}
    [ "$RUNMODE" = pr ] && ! lre_row_go "$SLUG" "$N" "$HEAD" "$LEDGER" && continue
    # >>> console qa clear (BH-5909): a console-qa-gate BLOCK on this head is
    # reviewed again, with no push, once a QA: PASS comment names the head.
    if [ "$CQG" = 1 ] && [ -n "$CQG_HREPO" ] && [ "${SLUG,,}" = "${CQG_HREPO,,}" ]; then
      if CQL=$(cqg_clear_block "$SLUG" "$N" "$HEAD" "$STATE"); then log "$SLUG#$N @$H12: $CQL"; continue; fi
      [ -n "$CQL" ] && log "$SLUG#$N @$H12: $CQL"
    fi
    # <<< console qa clear
    # A builder APPROVE bound to that head. BH-5294: an APPROVE bound to an
    # EARLIER head is no approval of this one, but the lead may still replay
    # its word here (APPROVED=0, below); anything else is skipped_no_approve.
    # BH-5630: with the builder gate off (REQB=0, the default) a head with no
    # builder row at all (job_verdict rc 2), or a builder APPROVE on an EARLIER
    # head, is UNAPPROVED, not skipped: it takes the replay below, and then a
    # request only if its CI is green. A builder BLOCK or REQUEST_CHANGES on
    # THIS head is still skipped (the fix round owns it), unless a person
    # answered its NEEDS-HUMAN step (BH-6696). One on an EARLIER head does not
    # stand: it is unapproved, like an APPROVE on an earlier head (BH-6696,
    # second case). An unreadable ledger (rc 1) is skipped too.
    V=""; RSHA=""; REQFOR=""; JRC=0; TNOTE=""; SDONE=0; SDNOTE=""; RVTOK=""; BCARRY=0; BCHOW=""
    JV=$(job_verdict "$URL" 2>/dev/null) || JRC=$?
    [ "$JRC" = 0 ] && IFS=$'\t' read -r V _ _ _ _ RSHA <<<"$JV"
    RSHA=$(printf '%s' "$RSHA" | tr 'A-F' 'a-f')
    REBOUND=0; APPROVED=1
    if [ "$JRC" = 2 ] && [ "$REQB" = 0 ]; then
      APPROVED=0
    elif [ "$V" != APPROVE ] && [[ "$RSHA" =~ ^[0-9a-f]{40}$ ]] && [ "$RSHA" != "$HEAD" ]; then
      # BH-6696 (second case): a builder REQUEST_CHANGES or BLOCK bound to an
      # EARLIER head does not stand here: a fix round pushed since. The head is
      # unapproved, like an APPROVE on an earlier head: replay, then the CI gate.
      if [ "$REQB" = 1 ]; then NOAPP=$((NOAPP + 1))
        skip_line no-approve "$SLUG#$N @$H12: the builder's $V is on ${RSHA:0:12}, not this head, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"; continue
      fi
      log "$SLUG#$N @$H12: the builder's $V is on ${RSHA:0:12}, an earlier head; it does not stand on this head"
      APPROVED=0
    elif [ "$V" != APPROVE ]; then
      # BH-6696 (header, `stepdone`): a person answered the step the builder's
      # refusal of THIS head raised. Only for a confirmed non-lead author.
      SDRC=1; SDWHY=""
      if { [ "$V" = REQUEST_CHANGES ] || [ "$V" = BLOCK ]; } && [ "$RSHA" = "$HEAD" ] && command -v lsd_check >/dev/null 2>&1; then
        rt_lead_skip "$WORK/pr"
        if [ -z "$RLEAD" ]; then
          lsd_check "$SLUG" "$WORK/pr" "$URL" "$V"; SDRC=$?
          [ "$SDRC" = 2 ] && SDWHY="; human-step check: $LSDWHY"
        fi
      fi
      if [ "$SDRC" = 0 ]; then
        SDONE=1; SDNOTE="$LSDNOTE"; REQFOR="HUMAN-STEP-DONE after the builder's $V"
        log "$SLUG#$N @$H12: the builder's $V is answered by $LSDLOG; requesting a lead review on the same head"
      else
        NOAPP=$((NOAPP + 1)); noapp_why; skip_line no-approve "$SLUG#$N @$H12: $NAWHY$SDWHY"; continue
      fi
    elif [ "$RSHA" != "$HEAD" ]; then
      HB=$(job_verdict_headbound "$URL" 2>/dev/null | tr 'A-F' 'a-f')
      BCRC=3
      if [ "$HB" != "reapproved@$HEAD" ] && [[ "$RSHA" =~ ^[0-9a-f]{40}$ ]] && command -v bc_carry >/dev/null 2>&1; then
        # BH-7043 (header, `carry`): the APPROVE on an earlier head with the same patch.
        BCRC=0; bc_carry "${REPOS_ROOT:-/root/repos}/$PROJECT" "$SLUG" "$N" "$RSHA" "$HEAD" "$STATE" || BCRC=$?
        if [ "$BCRC" = 2 ]; then
          case "$BC_WHY" in "fetch of "*) fetch_failed_once ;; esac
          log "$SLUG#$N @$H12: builder APPROVE on ${RSHA:0:12} not carried: $BC_WHY"
        fi
      fi
      if [ "$HB" = "reapproved@$HEAD" ]; then REBOUND=1
      elif [ "$BCRC" = 0 ]; then BCARRY=1; BCHOW=$BC_HOW
      elif [ "$LD" = 1 ] && [[ "$RSHA" =~ ^[0-9a-f]{40}$ ]]; then APPROVED=0
      elif [ "$REQB" = 1 ]; then NOAPP=$((NOAPP + 1))
        skip_line no-approve "$SLUG#$N @$H12: the builder's APPROVE is on ${RSHA:0:12}, not this head, and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"; continue
      else APPROVED=0
      fi
    fi
    # No lead/human/risk-tier verdict standing on it. An unapproved head skips
    # this read: the history read below answers the same question for it.
    if [ "$APPROVED" = 1 ]; then
      VLINE=$(vd_standing "$SLUG" "$N" "$HEAD" 2>/dev/null); VRC=$?
      case "$VRC" in
        0) VERD=$((VERD + 1))
           # A risk-tier row whose status post failed (rc 4): publish it again.
           RPUB="$STATE/risk-pub-$SAFE-$N-$H12"
           if [ -f "$RPUB" ] && [ "$(cut -f2 <<<"$VLINE")" = risk-tier ] && command -v vs_publish >/dev/null 2>&1; then
             if vs_publish "$SLUG" "$HEAD" success "$(head -c 140 "$RPUB")" "https://github.com/$SLUG/pull/$N" 2>/dev/null; then
               rm -f "$RPUB"; log "$SLUG#$N @$H12: risk-tier lead-verdict status published on retry"
             else
               log "$SLUG#$N @$H12: risk-tier lead-verdict status still not published; next tick retries"
             fi
           fi
           IFS=$'\t' read -r VW VS VID _ <<<"$VLINE"
           skip_line verdict "$SLUG#$N @$H12: a $VW by $VS stands on this head (verdict row #$VID)"
           continue ;;
        1) ;;
        *) skip_line unreadable "$SLUG#$N @$H12: standing verdict unreadable; skipped"; UNREAD=$((UNREAD + 1)); continue ;;
      esac
    fi
    # >>> lead replay (BH-3930, BH-5294): the lead's word on an earlier head G
    # is kept when this head carries the same patch, and a small change to the
    # PR's own files is reviewed in delta mode on the same lead model route.
    # Every step that cannot prove it falls through to the request path below
    # (an unapproved head: to skipped_no_approve). With bin/lib/lead-delta.sh,
    # ld_classify decides (header of that file); without it, BH-3930 alone:
    # a rebound head on patch_same. A BLOCK is only ever replayed as a BLOCK,
    # onto a rebound head; it is never delta-reviewed and never replayed onto
    # an unapproved head.
    DMODE=""; DNOTE=""; DPRIOR=""; DUPNOTE=""; LPVH=""; LPVW=""; LPVNOTE=""
    # BH-6696: a head the builder refused (SDONE=1) is never replayed or
    # delta-reviewed: it gets a full lead review.
    if [ "$SDONE" = 0 ] && { [ "$REBOUND" = 1 ] || [ "$APPROVED" = 0 ] || [ "$LD" = 1 ] || [ "$BCARRY" = 1 ]; }; then
      PH=""; PW=""; PID=""; PM=""; WHY=""
      # A truncated history cannot prove which lead row is newest: unreadable.
      if ! JOBS_ALERT=0 _jobs_req GET "/api/verdicts?repo=$SLUG&pr=$N" > "$WORK/vd" 2>/dev/null \
         || ! jq -e '(.rows | type) == "array" and .truncated != true' "$WORK/vd" >/dev/null 2>&1; then
        WHY="verdicts read failed; requesting as before"
      elif jq -e --arg h "$HEAD" 'any(.rows[]; .source == "lead" and ((.head_sha // "") | ascii_downcase) == $h
             and ((.note // "") | split(" ") | any(startswith("lead-replay:"))))' "$WORK/vd" >/dev/null 2>&1; then
        # Already replayed onto this head (an advice row, rc 5, may not stand):
        # the row is the record, so never post it a second time.
        REPLAYED=$((REPLAYED + 1))
        skip_line replayed "$SLUG#$N @$H12: lead word already replayed onto this head; no post, no review requested"
        continue
      elif { [ "$APPROVED" = 0 ] || [ "$BCARRY" = 1 ]; } && jq -e --arg h "$HEAD" 'any(.rows[]; ((.head_sha // "") | ascii_downcase) == $h
             and ((.source // "") | IN("lead", "human", "risk-tier")))' "$WORK/vd" >/dev/null 2>&1; then
        VERD=$((VERD + 1)); skip_line verdict "$SLUG#$N @$H12: a lead/human/risk-tier row stands on this head (verdict history)"; continue
      else
        # BH-6391: the earlier REVIEWED head (a replay row has no review behind it).
        IFS=$'\t' read -r LPVH LPVW < <(jq -r --arg h "$HEAD" '[.rows[] | select(.source == "lead"
            and ((.head_sha // "") | ascii_downcase) != $h
            and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK"))
            and (((.note // "") | split(" ") | any(startswith("lead-replay:"))) | not))]
          | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)"' "$WORK/vd" 2>/dev/null)
        [[ "$LPVH" =~ ^[0-9a-f]{40}$ ]] || { LPVH=""; LPVW=""; }
        IFS=$'\t' read -r PH PW PID PM < <(jq -r --arg h "$HEAD" '[.rows[] | select(.source == "lead"
            and ((.head_sha // "") | ascii_downcase) != $h
            and ((.verdict // "") | IN("MERGE", "MERGE-WITH-NOTES", "BLOCK")))]
          | max_by(.id) // empty | "\(.head_sha | ascii_downcase)\t\(.verdict)\t\(.id)\t\(.review_mode // "")"' "$WORK/vd" 2>/dev/null)
        [[ "$PH" =~ ^[0-9a-f]{40}$ ]] || PH=""
        # BH-5294: a BLOCK never leaves its own head but through BH-3930's rebound replay.
        [ "$PW" = BLOCK ] && [ "$REBOUND" != 1 ] && PH=""
      fi
      # BH-7043: a carried APPROVE never stands on an unread history or over a
      # lead BLOCK; the head is unapproved, as before the carry.
      if [ "$BCARRY" = 1 ]; then
        BCNO=""
        case "$WHY" in "verdicts read failed"*) BCNO="the verdict history is unreadable" ;; esac
        [ -z "$BCNO" ] && [ "$PW" = BLOCK ] && BCNO="the newest lead verdict on another head is a BLOCK"
        if [ -n "$BCNO" ]; then
          APPROVED=0; BCARRY=0
          log "$SLUG#$N @$H12: builder APPROVE on ${RSHA:0:12} not carried: $BCNO"
        else
          if ! awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$3 == "builder-replay" && $4 == s && $5 == n && $6 == h {f=1} END {exit !f}' "$MODES" 2>/dev/null; then
            mode_row builder-replay "$SLUG" "$N" "$HEAD" "from=${RSHA:0:12} how=$BCHOW"
            BREPLAYED=$((BREPLAYED + 1))
            log "$SLUG#$N @$H12: builder APPROVE carried from ${RSHA:0:12} (how:$BCHOW)"
          fi
          REQFOR="builder APPROVE carried from ${RSHA:0:12} (how:$BCHOW)"
        fi
      fi
      if [ -n "$PH" ]; then
        PS_REPO="${REPOS_ROOT:-/root/repos}/$PROJECT"
        HOW=""; CLS=""
        if [ "$LD" = 1 ]; then
          # A protected or over-max class is only reused under the same allowance and word (BH-5582).
          CLS=$(awk -F'\t' -v s="$SLUG" -v n="$N" -v g="$PH" -v h="$HEAD" -v m="$LDMAX" -v k="$LDPMAX:$PW" \
            '$2 == s && $3 == n && $4 == g && $5 == h && $6 == m \
             && (($7 !~ /^full (protected:|over-max:)/ && $7 !~ / protected:/) || $8 == k) {c = $7} END {print c}' "$DELTA")
        fi
        if [ -n "$CLS" ]; then :
        elif ! command -v patch_same >/dev/null 2>&1; then WHY="bin/lib/patch-same.sh not loaded; requesting as before"
        elif [ ! -d "$PS_REPO/.git" ]; then WHY="no checkout at $PS_REPO; requesting as before"
        elif ! patch_same_fetch "$PS_REPO" "$PH" "$HEAD" "$N"; then
          fetch_failed_once; WHY="fetch of ${PH:0:12}/$H12 failed ($PS_FETCH_ERR); requesting as before"
        elif [ "$LD" = 1 ]; then
          CLS=$(ld_classify "$PS_REPO" origin/main "$PH" "$HEAD" "$SLUG" "$PW")
          log "$SLUG#$N @$H12: since ${PH:0:12}: $CLS"
          # Only answers git settled are cached; a knob or read that failed is asked again.
          case "$CLS" in
            "full protected:"*|"full over-max:"*|"delta "*" protected:"*)
              printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$PH" "$HEAD" "$LDMAX" "$CLS" "$LDPMAX:$PW" >> "$DELTA" ;;
            "replay "*|"delta "*|"full binary"|"full knob-off")
              printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$PH" "$HEAD" "$LDMAX" "$CLS" >> "$DELTA" ;;
          esac
        elif HOW=$(patch_same "$PS_REPO" origin/main "$PH" "$HEAD"); then CLS="replay $HOW"
        else WHY="patch changed since ${PH:0:12}; requesting a lead review"
        fi
        case "$CLS" in
          "replay "*)
            HOW=${CLS#replay }
            # BH-5909: a console-ui/src/ head needs its own QA: PASS; a replayed
            # MERGE would skip the gate, so the head is reviewed instead.
            if [ "$PW" != BLOCK ] && [ "$CQG" = 1 ] && [ -n "$CQG_HREPO" ] && cqg_gate_on \
               && CQH=$(cqg_replay_hold "$SLUG" "$N" "$HEAD" "$PS_REPO" origin/main "$CQG_HREPO"); then
              WHY="no lead $PW replay from ${PH:0:12} ($CQH); requesting a lead review"
            else
            # BH-6967: the replayed row's own mode; a row with none was a full review.
            case "$PM" in full|intent) ;; *) PM=full ;; esac
            PRC=0; OUT=$("$H/bin/lead-verdict.sh" post "$SLUG" "$N" "$HEAD" "$PW" --source lead --reviewer "box:$BOX" \
              --note "lead-replay:${PH:0:12} how:$HOW" --review-mode "$PM" 2>&1) || PRC=$?
            case "$PRC" in
              0|4|5)
                REPLAYED=$((REPLAYED + 1)); mode_row replay "$SLUG" "$N" "$HEAD" "from=${PH:0:12} how=$HOW"
                skip_event replayed "$SLUG#$N @$H12: lead $PW replayed from ${PH:0:12} (how:$HOW, post rc $PRC); no review requested"
                continue ;;
            esac
            WHY="lead $PW replay from ${PH:0:12} not recorded (post rc $PRC: $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)); requesting as before"
            fi ;;
          "delta "*)
            if [ "$PW" != BLOCK ]; then
              DP=""; read -r _ DL DM DF DP <<<"$CLS"
              DMODE=delta
              DNOTE="lead-delta:$PH lines:$DL/$DM files:$DF${DP:+ $DP}"
              DPRIOR="lead $PW on ${PH:0:12} (verdict row #$PID)"
            fi ;;
          "full "*) WHY="since ${PH:0:12}: ${CLS}; a full lead review" ;;
        esac
      fi
      [ -n "$WHY" ] && [ "$APPROVED" = 0 ] && [ "$REQB" = 1 ] && WHY="${WHY%%;*}; nothing replayed, and the builder's APPROVE is on ${RSHA:0:12}, so nothing is requested"
      [ -n "$WHY" ] && log "$SLUG#$N @$H12: $WHY"
    fi
    # An unapproved head stops here when the builder gate is on (REQB=1).
    # BH-5630, the gate off: it is requested when CI is green on it and no
    # lead/human/risk-tier verdict stands on it. A head already in the ledger
    # was green when it was asked: re-confirming it needs no CI read.
    if [ "$APPROVED" = 0 ]; then
      [ "$REQB" = 1 ] && { NOAPP=$((NOAPP + 1)); skip_line no-approve "$SLUG#$N @$H12: no builder APPROVE on this head and LEAD_REVIEW_REQUIRE_BUILDER_APPROVE=1"; continue; }
      if ! awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER"; then
        ci_green_head "$SLUG" "$HEAD" "$BASE" "$N" \
          || { NOCI=$((NOCI + 1)); skip_line ci "$SLUG#$N @$H12: no builder APPROVE on this head and CI not known green ($CIWHY); not requested yet"; continue; }
      fi
      VLINE=$(vd_standing "$SLUG" "$N" "$HEAD" 2>/dev/null); VRC=$?
      case "$VRC" in
        0) VERD=$((VERD + 1)); IFS=$'\t' read -r VW VS VID _ <<<"$VLINE"
           skip_line verdict "$SLUG#$N @$H12: a $VW by $VS stands on this head"; continue ;;
        1) ;;
        *) skip_line unreadable "$SLUG#$N @$H12: standing verdict unreadable; skipped"; UNREAD=$((UNREAD + 1)); continue ;;
      esac
      REQFOR="CI green"
    fi
    # <<< lead replay
    # >>> traced hold (BH-5795): header, `traced`. A head already asked for is
    # only re-confirmed below, which spends nothing.
    if ! awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER" \
       && traced_hold "$SLUG" "$HEAD" "$BASE" "$N"; then
      TF="$STATE/traced-$SAFE-$N-$H12"; T0=""
      [ -e "$TF" ] || date +%s > "$TF" 2>/dev/null
      T0=$(head -1 "$TF" 2>/dev/null)
      if ! [[ "$T0" =~ ^[0-9]+$ ]]; then
        TNOTE="tests did not run: $TWHY (hold marker unusable)"
        log "$SLUG#$N @$H12: hold marker $TF unusable; requesting now: $TWHY"
      else
        # One real run per held head, started here (header, `traced`). Not when
        # the bound is 0 (no hold at all), not for a fork's branch, and not when
        # an UNFINISHED pull_request run of the workflow is on this head: each
        # tree is tested once (2026-09-24), and that run is the test. A
        # COMPLETED one is not: the head is held, so its traced shards all
        # skipped (a DIRTY head after main moved, or a stacked base whose plan
        # predates BH-5795), and only a dispatched run tests it.
        if [ "$TMAX" -gt 0 ] && ! grep -q '^dispatch ' "$TF" 2>/dev/null; then
          TREF=$(jq -r '.head.ref // empty' "$WORK/pr" 2>/dev/null)
          TREPO=$(jq -r '.head.repo.full_name // empty' "$WORK/pr" 2>/dev/null)
          TPRN=""
          if gh_rest GET "repos/$SLUG/actions/runs?head_sha=$HEAD&event=pull_request&per_page=20" > "$WORK/runs-$N" 2>/dev/null; then
            TPRN=$(jq -r --arg w "$TWF" '[.workflow_runs[]? | select((.path // "") | endswith($w)) | select((.status // "") != "completed")] | length' "$WORK/runs-$N" 2>/dev/null)
          fi
          if [ -z "$TREF" ]; then echo "dispatch none: no head branch" >> "$TF"
          elif [ -n "$TREPO" ] && [ "$TREPO" != "$SLUG" ]; then echo "dispatch none: the head lives in $TREPO" >> "$TF"
          elif [[ "$TPRN" =~ ^[0-9]+$ ]] && [ "$TPRN" -gt 0 ]; then
            echo "dispatch none: an unfinished pull_request run of $TWF is on this head" >> "$TF"
            log "$SLUG#$N @$H12: not dispatched: a pull_request run of $TWF is still running on this head; waiting for its traced jobs"
          elif gh_rest POST "repos/$SLUG/actions/workflows/$TWF/dispatches" -f "ref=$TREF" -f "inputs[scope]=impact" >/dev/null 2>&1; then
            TDISP=$((TDISP + 1)); echo "dispatch ok $TWF $TREF" >> "$TF"
            log "$SLUG#$N @$H12: dispatched $TWF scope=impact on $TREF"
          else
            echo "dispatch failed http=${GH_REST_STATUS:-000}" >> "$TF"
            log "$SLUG#$N @$H12: dispatch of $TWF scope=impact on $TREF failed (HTTP ${GH_REST_STATUS:-000}); the ${TMAX}m bound still applies"
          fi
        fi
        TAGE=$(( $(date +%s) - T0 ))
        if [ "$TAGE" -lt $((TMAX * 60)) ]; then
          TRACED=$((TRACED + 1)); skip_line traced "$SLUG#$N @$H12: not requested: $TWHY (held ${TAGE}s of ${TMAX}m)"; continue
        fi
        TBOUND=$((TBOUND + 1))
        TNOTE="tests did not run: $TWHY (held ${TAGE}s, LEAD_REVIEW_TRACED_MAX_WAIT_MIN=$TMAX)"
        log "$SLUG#$N @$H12: hold bound reached (${TAGE}s >= ${TMAX}m); requesting anyway: tests did not run"
      fi
    fi
    # <<< traced hold
    # >>> silence check (BH-5797): BEFORE the risk tier, so a low-tier sign-off
    # can never skip it (lead review lr-5811-82fcc1df2aa1: a gitleaks marker in
    # a new suite was signed off with no person seeing it). Only a head not yet
    # asked for; a re-confirm reads its stored note (ss_note). A head with lead
    # markers is not signed off as low either: the lead must see them.
    # With the risk tier off nothing signs a head off, and this check runs at
    # its old place, after the cap, so a deferred head costs no compare read.
    # A head already scanned clean or with only lead notes is not read again
    # (state/.../silence/scanned-*), so a head deferred by the cap is read once.
    SNOTE=""; SSDONE=0
    if [ "$RMODE" = shadow ] || [ "$RMODE" = enforce ]; then
      ss_early "$SLUG" "$N" "$HEAD" "$BASE" || continue
    fi
    # <<< silence check
    # >>> risk tier (BH-5022): header, `risk`. Never low on anything unread.
    PRIO=0; RLEAD=""; RLAUTH=0
    if [ "$RMODE" = shadow ] || [ "$RMODE" = enforce ]; then
      rt_lead_skip "$WORK/pr"
      [ -n "$RLEAD" ] && [ "$RLAUTH" != 1 ] && { RLEADN=$((RLEADN + 1)); log "$SLUG#$N @$H12: risk tier skipped ($RLEAD); requested as before"; }
    fi
    if { [ -z "$RLEAD" ] || [ "$RLAUTH" = 1 ]; } && { [ "$RMODE" = shadow ] || [ "$RMODE" = enforce ]; }; then
      TIER=""; WHY=""; NEWC=0
      IFS=$'\t' read -r TIER WHY < <(awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" \
        -v g="${RT_RULES_SIG:-}" '$2 == s && $3 == n && tolower($4) == h && $7 == g {t = $5 "\t" $6} END {if (t != "") print t}' "$RISK")
      if [ -z "$TIER" ]; then
        rt_compare "$SLUG" "$BASE" "$HEAD" "$N"
        if [ "$SELFHIT" = false ]; then
          RT_RULES_RENDER=""
          rt_rules_shape "$WORK/cmp-$N" && command -v rrh_check >/dev/null 2>&1 \
            && RT_RULES_RENDER=$(rrh_check "${REPOS_ROOT:-/root/repos}/$PROJECT" "$HEAD" "$H/bin/render-rules.sh")
          # BH-6968: rule 2c's inputs, only while its lane is on; never carried to the next head.
          RT_EVIDENCE_SCORE=""; RT_EVIDENCE_SUITES=""; RT_EVIDENCE_PREQUEUE=""; RT_EVIDENCE_WHY=""
          # RT_LOW_SCORE_MAX is the risk_tier.low_score_max settings row, set by
          # rt_rules_load above (this branch runs only after it); not an env knob.
          [ "$RT_LOW_SCORE_MAX" -gt 0 ] && rt_evidence_load "$SLUG" "$N" "$HEAD" "$WORK/cmp-$N" "$WORK/pr"
          IFS=$'\t' read -r TIER WHY RLINES RFILES < <(rt_classify "$WORK/cmp-$N" "$SLUG")
          case "$TIER" in low|medium|high) NEWC=1 ;; *) TIER=""; WHY="compare files unreadable" ;; esac
          # BH-7041 low-small (header, `risk`): only a head classified now; the lib decides.
          if [ "$NEWC" = 1 ]; then
            LST=""; LSW=""; LSLOG=""
            IFS=$'\t' read -r LST LSW LSLOG < <(rt_low_small_apply "$WORK/cmp-$N" "$SLUG" "$TIER" "$WHY")
            [ -n "$LST" ] && { TIER="$LST"; WHY="$LSW"; }
            [ -n "$LSLOG" ] && log "$SLUG#$N @$H12: $LSLOG"
          fi
        else
          WHY="compare $SELFHIT (a Lead-Lane commit, or not read whole)"
        fi
        # Never classified: cached as unclassified so later ticks do not read
        # the compare again for it. Requested as before, never low.
        if [ -z "$TIER" ]; then
          TIER=unclassified
          printf '%s\t%s\t%s\t%s\tunclassified\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$HEAD" "$WHY" "${RT_RULES_SIG:-}" >> "$RISK"
          log "$SLUG#$N @$H12: risk tier not classified ($WHY); as before"
        fi
      fi
      # BH-5325: a lead PR goes on only as a rules-text low. Anything else is
      # cached as `lead` and skipped, posting nothing: TIER=lead, NEWC=0 match
      # no branch below.
      if [ "$RLAUTH" = 1 ]; then
        if rt_rules_low "$TIER" "$WHY"; then
          RLEAD=""
        else
          [ "$NEWC" = 1 ] && printf '%s\t%s\t%s\t%s\tlead\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$HEAD" "$TIER: $WHY" "${RT_RULES_SIG:-}" >> "$RISK"
          TIER=lead; NEWC=0
          RLEADN=$((RLEADN + 1)); log "$SLUG#$N @$H12: risk tier skipped ($RLEAD); requested as before"
        fi
      fi
      case "$TIER" in
        low)    RLOW=$((RLOW + 1)) ;;
        medium) RMED=$((RMED + 1)) ;;
        high)   RHIGH=$((RHIGH + 1)); PRIO=1 ;;
        # low, but an earlier tick's sign-off was withheld (rc 5): never posted again.
        withheld) RLOW=$((RLOW + 1)); PRIO=1 ;;
      esac
      if [ "$NEWC" = 1 ]; then
        case "$TIER:$RMODE" in
          low:enforce) RACT=sign-off ;; low:shadow) RACT=would-sign-off ;;
          high:*) RACT=request-first ;; *) RACT=request ;;
        esac
        RBODY=$(jq -nc --arg r "$SLUG" --argjson p "$N" --arg h "$HEAD" --arg pj "$PROJECT" --arg t "$TIER" \
          --arg m "$RMODE" --arg a "$RACT" --arg w "$WHY" --arg l "${RLINES:-}" --arg f "${RFILES:-}" \
          '{repo:$r, pr:$p, head_sha:$h, project:$pj, tier:$t, mode:$m, action:$a, reasons:$w}
           + (if ($l|test("^[0-9]+$")) then {lines:($l|tonumber)} else {} end)
           + (if ($f|test("^[0-9]+$")) then {files:($f|tonumber)} else {} end)')
        # The tier is cached either way: a failed POST costs the console its
        # row for this head, never a compare read every tick.
        JOBS_ALERT=0 _jobs_req POST /api/risk-tiers "$RBODY" >/dev/null 2>&1 \
          || log "$SLUG#$N @$H12: POST /api/risk-tiers failed (http ${JOBS_HTTP:-none}); the console has no row for this head"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$HEAD" "$TIER" "$WHY" "${RT_RULES_SIG:-}" "$(rt_low_rule "$TIER" "$WHY")" >> "$RISK"
        log "$SLUG#$N @$H12: risk tier $TIER ($WHY), mode $RMODE"
        [ "$TIER" = low ] && [ "$RMODE" = shadow ] && log "$SLUG#$N @$H12: risk-tier WOULD sign off (low risk: $WHY); shadow, so the lead review is requested as before"
        # >>> jev shadow (BH-5024): its answer is a log line and a counter. It
        # never assigns TIER, WHY, PRIO, RACT or RMODE.
        if [ "$JMODE" = shadow ]; then
          if [ "$JASKED" -ge "$JMAX" ]; then
            log "$SLUG#$N @$H12: jev shadow not asked (jev_risk.max_per_tick=$JMAX reached this tick)"
          else
            JASKED=$((JASKED + 1)); JS=""; JTI=""; JP=""; JX=""
            IFS=$'\t' read -r JS JTI JP _ JX < <(JEV_CALLER="shadow:$BOX" timeout -k 5 $((JT + 10)) \
              "$H/bin/jev-risk.sh" ask "$SLUG" "$N" "$HEAD" "$TIER" "$WORK/cmp-$N" 2>>"$LOG")
            JOUT="no answer"; [ -n "$JS" ] && { JEV=$((JEV + 1)); JOUT="$JS $JTI $JP${JX:+ $JX}"; }
            log "$SLUG#$N @$H12: jev shadow $JOUT (rule tier $TIER); shadow only, nothing changed"
          fi
        fi
        # <<< jev shadow
      fi
      [ "$TIER" = low ] && [ "$RMODE" = shadow ] && RSHADOW=$((RSHADOW + 1))
      # BH-5630: a head no reviewer approved (REQFOR set) is never signed off by
      # the risk tier: no builder review stands behind it, so the lead reviews it.
      # BH-5325: except a lead-authored rules-text low (RLAUTH is still 1 here):
      # the lead wrote it, and its CI and the hub's render check on the head are
      # green. A non-lead rules-text head keeps the refusal. A rules-text low is
      # signed as risk-tier:rules-text:<box>.
      RREV="risk-tier:$BOX"; RTXT=0
      rt_rules_low "$TIER" "$WHY" && { RREV="risk-tier:rules-text:$BOX"; RTXT=1; }
      if [ "$TIER" = low ] && [ "$RMODE" = enforce ] && [ -n "$REQFOR" ] && { [ "$RTXT" = 0 ] || [ "$RLAUTH" != 1 ]; }; then
        log "$SLUG#$N @$H12: risk tier low, but no reviewer approved this head ($REQFOR); no risk-tier sign-off, the lead review is requested"
      elif [ "$TIER" = low ] && [ "$RMODE" = enforce ] && [ -n "$SNOTE" ]; then
        log "$SLUG#$N @$H12: risk tier low, but the diff adds silence markers for the lead to judge; no risk-tier sign-off, the lead review is requested"
      elif [ "$TIER" = low ] && [ "$RMODE" = enforce ]; then
        PRC=0; OUT=$("$H/bin/lead-verdict.sh" post "$SLUG" "$N" "$HEAD" MERGE --source risk-tier --reviewer "$RREV" \
          --note "low risk: $WHY" --review-tier low --review-mode risk-tier 2>&1) || PRC=$?
        case "$PRC" in
          0) RSIGNED=$((RSIGNED + 1)); skip_line risk-signed "$SLUG#$N @$H12: signed off by risk-tier (low risk: $WHY); no lead review requested"; continue ;;
          4) RSIGNED=$((RSIGNED + 1)); printf 'low risk: %s' "$WHY" > "$STATE/risk-pub-$SAFE-$N-$H12"
             skip_line risk-signed "$SLUG#$N @$H12: risk-tier MERGE recorded but its status not published (rc 4); the next tick publishes it"; continue ;;
          3) skip_line head-moved "$SLUG#$N @$H12: head moved before the risk-tier sign-off; the next tick classifies the new head"; continue ;;
          5) PRIO=1
             printf '%s\t%s\t%s\t%s\twithheld\t%s\t%s\t%s\n' "$(date +%s)" "$SLUG" "$N" "$HEAD" "$WHY" "${RT_RULES_SIG:-}" "$(rt_low_rule withheld "$WHY")" >> "$RISK" ;;
        esac
        log "$SLUG#$N @$H12: risk-tier sign-off not recorded (post rc $PRC: $(printf '%s' "$OUT" | tr '\n' ' ' | head -c 200)); requesting as before"
      fi
      # >>> in-build grace (BH-5023): header, `medium`.
      if [ "$TIER" = medium ] && [ "$RMODE" = enforce ] && [ "$REBOUND" = 0 ] \
         && ! awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER"; then
        [ -n "$GRACE" ] || GRACE=$(rt_inbuild_grace)
        # BH-5740: hold only while a build job that will run the in-build review
        # is live on this head (inbuild_job_on_head). With none, the head is
        # requested in this tick like a low or high one. A failed read holds as
        # before. A grace of 0 holds nothing, so it reads nothing.
        IBJ=0
        if [[ "$GRACE" =~ ^[0-9]+$ ]] && [ "$GRACE" -gt 0 ]; then
          inbuild_job_on_head "$URL" "$HEAD" || IBJ=$?
          case "$IBJ" in
            1) log "inbuild-grace skipped #$N head=$H12: no build job for this head ($SLUG; $IBJWHY)" ;;
            2) log "$SLUG#$N @$H12: $IBJWHY; the in-build grace holds as before" ;;
          esac
        fi
        if [ "$IBJ" != 1 ]; then
          WAITF="$STATE/inbuild-wait-$SAFE-$N-$H12"
          [ -e "$WAITF" ] || : > "$WAITF" 2>/dev/null
          WT0=$(stat -c %Y "$WAITF" 2>/dev/null)
          # The age is read against the clock NOW, not the tick's start ($NOW): a
          # marker written later in this tick is newer than $NOW, and `$NOW - WT0`
          # went negative. A grace of 0 holds nothing at all.
          WNOW=$(date +%s)
          if [[ "$WT0" =~ ^[0-9]+$ ]] && [[ "$GRACE" =~ ^[0-9]+$ ]] && [ "$GRACE" -gt 0 ] && [ $((WNOW - WT0)) -lt "$GRACE" ]; then
            RWAIT=$((RWAIT + 1))
            skip_line inbuild-wait "$SLUG#$N @$H12: awaiting the in-build lead-grade review ($((GRACE - (WNOW - WT0)))s left)"
            continue
          fi
          if [[ "$WT0" =~ ^[0-9]+$ ]]; then log "$SLUG#$N @$H12: in-build grace spent ($GRACE s, no in-build lead verdict); requesting a lead review"
          else log "$SLUG#$N @$H12: in-build grace marker $WAITF unusable; requesting a lead review"; fi
        fi
      fi
      # <<< in-build grace
      # BH-6967 (header, `intent`): the tier and mode tokens of this head's request.
      case "$TIER" in
        low|withheld) RVTOK="review-tier:low review-mode:full" ;;
        high) RVTOK="review-tier:high review-mode:full" ;;
        medium)
          RVTOK="review-tier:medium review-mode:full"
          case "$DNOTE" in
            *lead-delta:*) ;;
            *) rv_medium_mode; [ "$RVMODE" = intent ] && RVTOK="review-tier:medium review-mode:intent" ;;
          esac ;;
      esac
    fi
    # <<< risk tier
    # >>> self check (BH-5798): header, `self`. Bounded: never a hold for ever.
    PSCNOTE=""; PSCNOTES=""
    # BH-5790: the note rules' findings for this head, stored when it was first
    # asked, so a re-confirm sends the same notes (a 409 otherwise).
    PSNF="$STATE/selfcheck-notes-$SAFE-$N-$H12"
    if awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER"; then
      [ -s "$PSNF" ] && PSCNOTE=$(cat "$PSNF")
    elif ! self_check_hold "$SLUG" "$N" "$HEAD" "$BASE" "$PROJECT"; then
      if [ -n "$PSCNOTES" ]; then
        PSCNOTE="self-check notes: $(printf '%s' "$PSCNOTES" | tr '\n' ';' | cut -c1-400)"
        printf '%s' "$PSCNOTE" > "$PSNF" 2>/dev/null
      fi
    else
      PSF="$STATE/selfcheck-$SAFE-$N-$H12"; PSH=$(jq -r '.body // ""' "$WORK/pr" 2>/dev/null | cksum | cut -d' ' -f1)
      [ -e "$PSF" ] || date +%s > "$PSF" 2>/dev/null
      PS0=$(head -1 "$PSF" 2>/dev/null)
      if ! grep -qx "commented $PSH" "$PSF" 2>/dev/null; then
        if [ "$PSCMAX" -eq 0 ]; then
          # BH-5905: a 0-minute wait requests the review on this same tick.
          printf 'The pre-review self-check (`bin/pr-self-check.sh`, BH-5798) refused this PR body on head `%s`:\n\n%s\n\nThe lead review is requested now; the findings ride in its scope note.\n' \
            "$H12" "$(printf '%s\n' "$PSCOUT" | sed 's/^/- /')" > "$WORK/psc-comment"
        else
          printf 'The pre-review self-check (`bin/pr-self-check.sh`, BH-5798) refused this PR body on head `%s`, so no lead review is requested yet:\n\n%s\n\nFix the body (or the branch) and the next tick checks again. After %s minutes the lead review is requested anyway, with these findings in its notes.\n' \
            "$H12" "$(printf '%s\n' "$PSCOUT" | sed 's/^/- /')" "$PSCMAX" > "$WORK/psc-comment"
        fi
        if gh_rest POST "repos/$SLUG/issues/$N/comments" -F "body=@$WORK/psc-comment" >/dev/null 2>&1; then
          echo "commented $PSH" >> "$PSF"
        else
          log "$SLUG#$N @$H12: the self-check comment did not post (HTTP ${GH_REST_STATUS:-000}); next tick retries"
        fi
      fi
      PSAGE=$(( $(date +%s) - ${PS0:-0} ))
      if [[ "$PS0" =~ ^[0-9]+$ ]] && [ "$PSAGE" -lt $((PSCMAX * 60)) ]; then
        SELFCHK=$((SELFCHK + 1))
        # A skip line like the others (BH-5779 dedupe): written once per (PR, head, class).
        skip_line selfcheck "$SLUG#$N @$H12: not requested: self-check refused ($(printf '%s' "$PSCOUT" | tr '\n' ';' | cut -c1-300)) — held ${PSAGE}s of ${PSCMAX}m"
        continue
      fi
      PSCNOTE="self-check: $(printf '%s' "$PSCOUT" | tr '\n' ';' | cut -c1-400)"
      [ -n "$PSCNOTES" ] && PSCNOTE="$PSCNOTE; self-check notes: $(printf '%s' "$PSCNOTES" | tr '\n' ';' | cut -c1-400)"
      printf '%s' "$PSCNOTE" > "$PSNF" 2>/dev/null
      log "$SLUG#$N @$H12: self-check still refused after ${PSCMAX}m; requesting anyway with the findings in the note"
    fi
    # <<< self check
    # >>> rebase hold (BH-5796): header, `rebase`. Here, right before the
    # request: a head the replay, the verdict or the risk tier already settled
    # costs no fetch, and a head already asked for is only re-confirmed below.
    if ! awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER" \
       && rebase_hold "$SLUG" "$N" "$HEAD" "$BASE" "$PROJECT"; then
      RBASE=$((RBASE + 1)); skip_line rebase "$SLUG#$N @$H12: not requested: $RBWHY"; continue
    fi
    if [ -n "${DUPNOTE:-}" ]; then
      log "$SLUG#$N @$H12: requested with a note: $DUPNOTE"
      DNOTE="${DNOTE:+$DNOTE; }$DUPNOTE"; DUPNOTE=""
    fi
    # BH-6391: the earlier review and the delta since it ride in the notes, in
    # delta and full mode alike. Here, after every skip, so no skipped head pays
    # the git work. A fetch only when the clone lacks G or the head.
    if [ -n "$LPVH" ] && command -v lpv_note >/dev/null 2>&1; then
      PS_REPO="${REPOS_ROOT:-/root/repos}/$PROJECT"
      if [ -d "$PS_REPO/.git" ]; then
        if ! git -C "$PS_REPO" cat-file -e "$LPVH^{commit}" 2>/dev/null || ! git -C "$PS_REPO" cat-file -e "$HEAD^{commit}" 2>/dev/null; then
          command -v patch_same_fetch >/dev/null 2>&1 && patch_same_fetch "$PS_REPO" "$LPVH" "$HEAD" "$N"
        fi
        LPVNOTE=$(lpv_note "$PS_REPO" origin/main "$LPVH" "$LPVW" "$HEAD" "$N")
        DNOTE="${DNOTE:+$DNOTE; }$LPVNOTE"
        LPVC=${LPVNOTE#* own-commits:}
        log "$SLUG#$N @$H12: re-review of ${LPVH:0:12} ($LPVW): own-commits:${LPVC%% *}"
      else
        log "$SLUG#$N @$H12: re-review of ${LPVH:0:12} ($LPVW): no checkout at $PS_REPO; requested with no lead-prev token"
      fi
    fi
    # <<< rebase hold
    # >>> live probes (BH-5801): the PR's declared read-only probes, run once per
    # head on the hub and posted to the PR before the lead review is asked, so
    # the review reads the evidence. Only catalog/live-probes.tsv probes run
    # (bin/lib/live-probes.sh). Fail-open, LIVE_PROBES=0 turns it off.
    if command -v lp_run_for_head >/dev/null 2>&1; then
      lp_run_for_head "$SLUG" "$N" "$HEAD" "$WORK/pr" || true
    fi
    # <<< live probes
    # Already asked for this head: re-confirm, which spends nothing.
    if awk -F'\t' -v s="$SLUG" -v n="$N" -v h="$HEAD" '$2 == s && $3 == n && tolower($4) == h {f=1} END {exit !f}' "$LEDGER"; then
      # The same notes as the first ask, the silence markers included (BH-5797).
      SNOTE=""; command -v ss_note >/dev/null 2>&1 && SNOTE=$(ss_note "$STATE/silence" "$SLUG" "$N" "$HEAD")
      request "$SLUG" "$N" "$HEAD" 1 "$PRIO" "${DNOTE}${SNOTE:+${DNOTE:+; }$SNOTE}" "$DPRIOR"; continue
    fi
    DAYN=$(awk -F'\t' -v s="$SLUG" -v n="$N" -v c=$((NOW - 86400)) '$2 == s && $3 == n && $1 >= c' "$LEDGER" | wc -l)
    if [ "$DAYN" -ge "$MAXD" ]; then
      TRIPPED=$((TRIPPED + 1))
      skip_line tripped "$SLUG#$N @$H12: $DAYN lead review requests in 24h (LEAD_REVIEW_MAX_PER_PR_DAY=$MAXD); not requested"
      alert_once "lead-trip-$SAFE-$N-$DAY" warn "$SLUG#$N has had $DAYN lead review requests in 24h (LEAD_REVIEW_MAX_PER_PR_DAY=$MAXD), so the new head @$H12 was not requested. Something is pushing this PR over and over; look at it before asking again with bin/lead-verdict.sh request $SLUG $N $HEAD --notes \"...\"" || true
      continue
    fi
    [ "$ASKED" -lt "$MAXT" ] || { DEFERRED=$((DEFERRED + 1)); skip_line deferred "$SLUG#$N @$H12: LEAD_REVIEW_ENQUEUE_MAX_PER_TICK=$MAXT reached; asked next tick"; continue; }
    # The lead lane never verdicts its own commits (the risk block's read reused).
    rt_compare "$SLUG" "$BASE" "$HEAD" "$N"
    if [ "$CRC" != 0 ] || { [ "$SELFHIT" != true ] && [ "$SELFHIT" != false ]; }; then
      skip_line unreadable "$SLUG#$N @$H12: compare $BASE...$H12 unreadable (rc $CRC, ${SELFHIT:-unparseable}); skipped"; UNREAD=$((UNREAD + 1)); continue
    fi
    if [ "$SELFHIT" = true ]; then
      SELF=$((SELF + 1))
      alert_once "lead-self-$SAFE-$N-$H12" warn "$SLUG#$N @$H12 carries a Lead-Lane: commit, so the lead lane will not verdict its own work. To ask anyway: bin/lead-verdict.sh request $SLUG $N $HEAD --notes \"...\"" || true
      skip_line self "$SLUG#$N @$H12: carries a Lead-Lane: commit; the lead lane does not verdict its own work (ask by hand: bin/lead-verdict.sh request $SLUG $N $HEAD --notes \"...\")"
      continue
    fi
    if [ "$SSDONE" = 0 ]; then ss_early "$SLUG" "$N" "$HEAD" "$BASE" || continue; fi
    ASKED=$((ASKED + 1))
    request "$SLUG" "$N" "$HEAD" 0 "$PRIO" "${DNOTE}${SNOTE:+${DNOTE:+; }$SNOTE}" "$DPRIOR"
  done < <(jq -r '.[] | [(.number|tostring), .url, (.isDraft|tostring), (.baseRefName // "main"),
      ((.headRefOid // "") | if . == "" then "-" else . end), ((.updatedAt // "") | if . == "" then "-" else . end)] | @tsv' "$WORK/list")
  log "$SLUG PR-SNAPSHOT hit=$(grep -c '^HIT ' "$PRS_COUNT_FILE" 2>/dev/null) miss=$(grep -c '^MISS ' "$PRS_COUNT_FILE" 2>/dev/null)"
done

TODAY=$(date -u +%Y%m%d)
TCOUNT=$(awk -F'\t' -v d="$TODAY" '$2 == d {c[$3]++} END {printf "today_replay=%d today_delta=%d today_full=%d", c["replay"], c["delta"], c["full"]}' "$MODES" 2>/dev/null)
# The skip dedupe's memory for the next tick (header, `Skip lines`): every PR
# this tick skipped, so a PR that is requested or closes drops out of it. A pr
# run sees one PR, so only the tick writes it.
if [ "$RUNMODE" = tick ]; then
  { for SK in "${!SKIP_NOW[@]}"; do printf '%s\t%s\n' "$SK" "${SKIP_NOW[$SK]}"; done; } > "$SKIPLAST.tmp" 2>/dev/null \
    && mv -f "$SKIPLAST.tmp" "$SKIPLAST" 2>/dev/null
fi
TRIGW=""; [ "$RUNMODE" = pr ] && TRIGW=" trigger_items=$LRE_N"
log "$RUNMODE repos=$REPOS prs=$PRS requested=$REQUESTED replayed=$REPLAYED builder_replayed=$BREPLAYED fetch_failed=$PSFETCHF delta=$RDELTA full=$RFULL ${TCOUNT:-today_replay=? today_delta=? today_full=?} existing=$EXISTING deferred=$DEFERRED skipped_no_approve=$NOAPP skipped_ci=$NOCI skipped_verdict=$VERD skipped_self=$SELF skipped_silence=$SILENCE tripped=$TRIPPED unreadable=$UNREAD failed_reset=$FAILRESET failed_alerted=$FAILX reclaimed=$RECLAIMED skipped_draft=$SKDRAFT risk_low=$RLOW risk_signed=$RSIGNED risk_shadow=$RSHADOW risk_medium=$RMED risk_high=$RHIGH risk_lead=$RLEADN risk_inbuild_wait=$RWAIT review_intent=$RINTENT jev_shadow=$JEV skips=$SKIPS skips_logged=$SKIPLOGGED skipped_traced=$TRACED traced_dispatched=$TDISP traced_bound=$TBOUND skipped_selfcheck=$SELFCHK skipped_rebase=$RBASE$TRIGW rung=$RUNG"
exit 0
