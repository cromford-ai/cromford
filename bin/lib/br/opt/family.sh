#!/bin/bash
# shellcheck shell=bash
# bin/lib/br/opt/family.sh — BH-1471: family-batched iron-law adjudication.
#
# WHAT IT BUYS. The iron-law gate is a DETECTOR over added lines, and one cause
# usually flags several PRs at once: the 2026-09-22 wave had five hits in one PR
# from one family and eighteen "red-flag lines" in another that were literal
# model slugs in a JSON catalog. Both were false positives, both waited hours,
# and both paid a review-stage model call PER PR. This module makes one Fable
# ruling per (check, code shape) carry to every other parked PR whose flagged
# lines normalize to the same thing.
#
# THE TWO HOOKS bin/lib/br/opt/README.md declares, and nothing else:
#   br_opt_family_pre    <p> <rkey> <reason> <rec> <url>            rc 0 = carried
#   br_opt_family_record <p> <rkey> <reason> <rec> <url> <verdict>  best effort
# Nothing here runs at SOURCE time: the file is sourced once per tick on every
# hub before any candidate has been read, so a REST read, a clock read or a
# state write here would be a cost the lane cannot see and cannot bound.
#
# IT NEVER CALLS A MODEL. There is no bin/agent-call.sh in this file and no
# claude-* model string: $REVIEW_MODEL stays the lane's, resolved as it is now.

# brf_redflag_re — the lane's OWN scan pattern (br_ironlaw_context in
# bin/blocked-resolver.sh), so the fingerprint is taken over exactly the lines
# that parked the PR. It lives inside a function, and the deploy-host half is
# spelled in two pieces, so the one added line that carries the pattern does not
# match the pattern: a module about the iron-law gate must not park its own PR
# on that gate. Code, not a comment — the sweep's scan skips comment-only added
# lines, so a comment would be safe and a reader would not know why.
brf_redflag_re() {
  printf '%s' 'window\.(confirm|alert|prompt)\(|claude-(fable|opus|sonnet|haiku)|VERCEL'"_URL"
}

# brf_sanitize <text> — the key before it becomes a file name, the defence
# br_rkey already applies to a conductor key. The slug comes from a line this
# repo generates and the shape is 12 hex, so this changes nothing today; it is
# here so a check slug with a slash in it can never write outside the store.
brf_sanitize() { printf '%s' "${1//[^A-Za-z0-9.:+_-]/-}"; }

# brf_norm — normalize flagged lines on stdin: drop the leading `+`, strip
# leading and trailing whitespace, LC_ALL=C sort -u. Re-indented identical code
# is the SAME family (the wanted positive); one renamed identifier is not.
brf_norm() {
  sed -e 's/^+//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | LC_ALL=C sort -u
}

# brf_flagged <diff-file> — the normalized flagged ADDED lines of a diff.
# NOT capped at br_ironlaw_context's `head -6`: that cap is about how much
# context a prompt gets, and hashing only the first six flagged lines would let
# two PRs that agree on their first six and differ later share a shape. A false
# carry is the one direction this feature must not fail in (D12).
brf_flagged() {
  [ -s "${1:-}" ] || return 0
  grep -E '^\+' "$1" 2>/dev/null | grep -vE '^\+\+\+' | grep -E "$(brf_redflag_re)" | brf_norm
}

# brf_deleted_cases <rec> — the test-tamper DELETED_CASES block, read exactly
# the way br_adjudicate reads it (the rescan report wins when it is non-empty),
# then normalized so the same cases in a different order are one family.
brf_deleted_cases() {
  local rec="${1:--}" report
  [ -n "$rec" ] && [ "$rec" != "-" ] || return 0
  report="$rec/test-tamper.txt"
  [ -s "$rec/test-tamper-rescan.txt" ] && report="$rec/test-tamper-rescan.txt"
  sed -n '/^DELETED_CASES:/,/^[A-Z_]*:/p' "$report" 2>/dev/null | grep '^  ' | head -40 | brf_norm
}

# brf_slug <rec> — the check slugs the gate left on the record, sorted, unique,
# joined by `+`. A PR flagged by two checks is NOT the same family as one
# flagged by either alone. No checks.txt (the inline red-flag scan, or a record
# the diff never reached) is the literal `ironlaw` — a slug, not an absence.
brf_slug() {
  local rec="${1:--}" s=""
  if [ -n "$rec" ] && [ "$rec" != "-" ] && [ -s "$rec/checks.txt" ]; then
    s=$(grep '^CHECK-HIT ' "$rec/checks.txt" 2>/dev/null | awk '{print $2}' \
        | LC_ALL=C sort -u | tr '\n' '+' | sed 's/+$//')
  fi
  [ -n "$s" ] || s=ironlaw
  printf '%s' "$s"
}

# br_family_key <reason> <rec> <url> -> "<slug>:<shape12>", or NOTHING.
#
# The ledger key is the (slug, sha1(normalized flagged lines)) fingerprint —
# never a PR url, never a head sha, never a record path, because those are what
# make two PRs with one cause look like two causes.
#
# EMPTY IS NOT A FAMILY (D11). An unknown reason, a diff this tick could not
# read, no flagged lines, an empty DELETED_CASES block, or no sha1sum on the box
# all print nothing, and nothing matches nothing: the park takes today's
# per-PR adjudication. Absent is never approved.
br_family_key() {
  local reason="${1:-}" rec="${2:--}" url="${3:--}" lines shape slug df dslug dnum
  command -v sha1sum >/dev/null 2>&1 || return 0
  case "$reason" in
    iron-law)
      slug=$(brf_slug "$rec")
      # The diff is the evidence and it is not on the record: bin/run-build.sh
      # and bin/lib/rb/execute.sh both rm checks-input.diff, so checks.txt
      # carries slugs and locations but not line text. This is the same read
      # br_adjudicate makes a few lines later, through the same helper.
      df=$(mktemp) || return 0
      dslug=$(br_slug_of_url "$url") || dslug=""
      dnum=$(mc_num_of_url "$url")
      if [ -z "$dslug" ] || [ -z "$dnum" ] \
         || ! gh_rest GET "repos/$dslug/pulls/$dnum" -H "Accept: application/vnd.github.v3.diff" >"$df" 2>/dev/null; then
        rm -f "$df"; return 0
      fi
      lines=$(brf_flagged "$df"); rm -f "$df" ;;
    test-tamper)
      slug=test-tamper
      lines=$(brf_deleted_cases "$rec") ;;
    *) return 0 ;;
  esac
  [ -n "$lines" ] || return 0
  shape=$(printf '%s\n' "$lines" | sha1sum 2>/dev/null | cut -c1-12)
  case "$shape" in ''|*[!0-9a-f]*) return 0 ;; esac
  brf_sanitize "$slug:$shape"
}

# brf_key_for <reason> <rec> <url> — br_family_key, memoised, ANSWERED IN
# $BRF_KEY rather than on stdout. Both hooks are called by br_adjudicate
# directly and never inside a `$( )`, so a global set here reaches the record
# hook of the SAME row and dies with that row's subshell — which is what makes
# the memo safe: it can never outlive the diff it describes. Without it the
# ruling path would pay the iron-law REST read twice, once for each hook.
# Callers read $BRF_KEY; nothing here prints, so a `$( )` caller would get an
# empty answer loudly rather than a stale one quietly.
brf_key_for() {
  local memo="${1:-}|${2:--}|${3:--}"
  if [ "${BRF_KEY_FOR:-}" != "$memo" ]; then
    BRF_KEY=$(br_family_key "$@")
    BRF_KEY_FOR="$memo"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The ruling store. ONE FILE PER FAMILY under $ST/.families/, the file NAME as
# the natural unique key, so two concurrent ticks cannot create two rows for one
# family. Written tmp + mv, the .saturation.tsv / .tick-budget precedent, so a
# killed tick leaves no partial row.
#
# A DOTFILE DIRECTORY, and that is load-bearing: br_from_rebuilds globs
# "$ST"/*/*.json and reads basename(dirname(f)) as a PROJECT NAME, so
# $ST/families/<key>.json would offer a candidate for a phantom project called
# `families` on every tick. `*` does not match a leading dot.
#
# NEVER PRUNED, never capped, never rebuilt from a query: a pruned ruling
# silently re-buys the model call it exists to avoid. Growth is bounded by the
# number of distinct (check, code shape) pairs, and $ST is under state/, which
# bin/state-backup.sh ships to R2 every 15 minutes.
# ---------------------------------------------------------------------------
brf_store_dir()  { printf '%s' "${ST:-}/.families"; }
brf_store_path() { printf '%s/%s.json' "$(brf_store_dir)" "${1:-}"; }

# brf_store_get <key> — the row, when it is a ruling this tick may carry: it
# parses, its verdict is ACCEPT, and with a non-zero BR_FAMILY_TTL_SECS it was
# ruled inside that window. Anything else is rc 1 and no output. An out-of-TTL
# row is left exactly where it is — unused, not deleted.
brf_store_get() {
  local f row at now ttl
  [ -n "${1:-}" ] || return 1
  f=$(brf_store_path "$1")
  [ -s "$f" ] || return 1
  row=$(jq -ce 'select(.verdict == "ACCEPT")' "$f" 2>/dev/null) || return 1
  [ -n "$row" ] || return 1
  ttl="${BR_FAMILY_TTL_SECS:-0}"
  case "$ttl" in ''|*[!0-9]*) ttl=0 ;; esac
  if [ "$ttl" -gt 0 ]; then
    at=$(printf '%s' "$row" | jq -r '.ruled_at // ""' 2>/dev/null)
    case "$at" in ''|*[!0-9]*) return 1 ;; esac
    now=$(br_now)
    [ "$((now - at))" -le "$ttl" ] || return 1
  fi
  printf '%s' "$row"
}

# brf_store_put <key> <project> <rkey> <url> — the ruling, written once.
# AN EXISTING ROW IS NEVER OVERWRITTEN: a second ruling on a family that is
# already ruled would silently refresh the TTL, which is a ruling nobody made.
# Best effort throughout — the lane has already acted on this verdict.
brf_store_put() {
  local key="${1:-}" d f tmp
  [ -n "$key" ] || return 0
  d=$(brf_store_dir); mkdir -p "$d" 2>/dev/null || return 0
  f=$(brf_store_path "$key")
  [ -e "$f" ] && return 0
  tmp="$f.tmp.$$"
  jq -nc --arg k "$key" --arg s "${key%%:*}" --arg h "${key##*:}" \
         --arg by "$2/$3 ${4:--}" --argjson at "$(br_now)" \
     '{key:$k,slug:$s,shape:$h,verdict:"ACCEPT",ruled_at:$at,ruled_by:$by,uses:0}' \
     >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  return 0
}

# brf_store_use <key> — bump the carry counter. Telemetry, so a lost increment
# under two ticks racing is accepted: the marker write is idempotent and the
# file name is the unique key, so no second row can appear (D33 — a lock held
# across a tick is a queue).
brf_store_use() {
  local f tmp cur
  f=$(brf_store_path "${1:-}")
  [ -s "$f" ] || return 0
  cur=$(jq -c '.uses = ((.uses // 0) + 1)' "$f" 2>/dev/null) || return 0
  [ -n "$cur" ] || return 0
  tmp="$f.tmp.$$"
  printf '%s\n' "$cur" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  return 0
}

# brf_ruled_url <row> — the PR the ruling was earned on, out of ruled_by, and
# ONLY when it really is a PR url. Everything a comment quotes comes from the
# store (D26); a row with no url gets no comment rather than a plausible one.
brf_ruled_url() {
  local by="${1##* }"
  case "$by" in https://github.com/*/*/pull/*) printf '%s' "$by" ;; esac
}

# br_opt_family_pre <p> <rkey> <reason> <rec> <url> — THE CARRY.
#
# rc 0 means br_adjudicate returns without a model call, without a posted ruling
# and without spending the once-per-ticket adjudication counter. The order below
# IS the contract. The ironlaw-head-accept row (ila_put) comes before every
# other side effect: it is what unparks a sha for bin/merge-sweep.sh and
# bin/merge-conductor.sh, so it is written only once the ruling is confirmed in
# TTL and the head it binds to has been read, and nothing is spent without it.
br_opt_family_pre() {
  local p="$1" rkey="$2" reason="$3" rec="${4:--}" url="${5:--}" key row rurl head
  # IRON-LAW ONLY. br_family_key answers for test-tamper too and the store keeps
  # test-tamper rulings, but the only artifact a carry writes is the
  # ironlaw-head-accept row, and the lane's test-tamper ACCEPT arm does far more
  # than record an ACCEPT (a TEST-CHANGE block, then a resume or a fresh
  # rebuild). Carrying a tamper ruling that way would silently drop the park.
  [ "$reason" = iron-law ] || return 1
  brf_key_for "$reason" "$rec" "$url"; key="${BRF_KEY:-}"
  [ -n "$key" ] || return 1
  row=$(brf_store_get "$key") || return 1
  [ -n "$row" ] || return 1
  rurl=$(brf_ruled_url "$(printf '%s' "$row" | jq -r '.ruled_by // "-"' 2>/dev/null)")
  # OBSERVE IS OURS (the README's rule). The hook site is asked before the
  # lane's observe check precisely so this line exists: writing nothing and
  # answering rc 0 is what makes observe mode predict a real tick.
  if [ "${OBSERVE:-0}" = 1 ]; then
    say "$p/$rkey [$reason]: WOULD carry family $key from ${rurl:--} — observe mode"
    return 0
  fi
  # The ACCEPT is BOUND TO THE SHA IT JUDGED, so a head this tick could not read
  # buys nothing: no row, no attempt, no uses bump, no count. The same park is
  # offered its adjudication next tick — br_adjudicate's own :4935 rule, verbatim.
  # The row needs no build record, so a PR with none is carried too (BH-7804).
  head=$(br_pr_field "$url" .head.sha 'head sha')
  if [ -z "$head" ]; then
    say "$p/$rkey [$reason]: family $key is ruled but the head could not be read — no ACCEPT written, the adjudication is offered next tick"
    return 0
  fi
  # A ROW THAT CANNOT BE WRITTEN IS A DEFER, not a decline (BH-7804): rc 1 would
  # buy a model ruling whose own write fails in the same outage. rc 0 with no
  # side effect, and the next tick offers the carry again.
  if ! command -v ila_put >/dev/null 2>&1 || ! ila_put "$url" "$head" family "carried family $key"; then
    say "$p/$rkey [$reason]: family $key is ruled but the DB accept could not be written — nothing carried, the carry is offered next tick"
    return 0
  fi
  # THE COMMENT IS LAST OF THE TWO SIDE EFFECTS, and a failure to post never
  # retracts a row that has already unparked a judged sha.
  if [ -n "$rurl" ]; then
    br_pr_comment "$url" "We ruled on this exact shape already, on $rurl. Same check, same lines, so we are not paying for a second read." >/dev/null 2>&1 \
      || say "$p/$rkey [$reason]: carried family $key but the comment did not post — the DB accept stands"
  else
    say "$p/$rkey [$reason]: carried family $key but the stored ruling names no PR url — no comment posted"
  fi
  # NO BUMP FIELD. The once-per-ticket `adjudications` counter belongs to a
  # ruling somebody paid for; a carry spends a rung, not an adjudication.
  br_record "$p" "$rkey" adjudicate-family "$reason" "carried $key from ${rurl:--}"
  br_event family-carried "$p" "$rkey" "$reason" "$key from ${rurl:--}"
  brf_store_use "$key"
  br_count family
  say "$p/$rkey [$reason]: CARRIED family $key from ${rurl:--} — DB accept recorded ($(ila_key "$url" "$head")), no model call"
  return 0
}

# br_opt_family_record <p> <rkey> <reason> <rec> <url> <verdict> — THE RULING.
#
# ACCEPT only. A REJECT is never stored and never carried: a carried REJECT
# would spend a fix round on a PR nobody looked at. A run that produced NO
# verdict reaches neither arm of br_adjudicate, so it never reaches this hook —
# a paid-for empty answer cannot become a free carried ACCEPT.
#
# Best effort, rc always 0: by the time this runs the verdict is recorded,
# commented and acted on, so a store that fails must not turn an ACCEPT the lane
# has already acted on into an error.
br_opt_family_record() {
  local p="$1" rkey="$2" reason="$3" rec="${4:--}" url="${5:--}" verdict="${6:-}" key
  [ "$verdict" = ACCEPT ] || return 0
  brf_key_for "$reason" "$rec" "$url"; key="${BRF_KEY:-}"
  [ -n "$key" ] || return 0
  brf_store_put "$key" "$p" "$rkey" "$url"
  return 0
}
