#!/bin/bash
# shellcheck shell=bash
# module: record
# bin/lib/br/record.sh — BH-1176: the resolver's RECORD layer: the per-(project,
# key) json under $ST, its readers, its writers and the one EVENT line every
# rung transition leaves behind. Sourced by bin/blocked-resolver.sh, never run.
# It reads $ST and $H at CALL time and nothing at source time.
#
# This is the ONLY definition of the 22 record functions (see
# tests/br-split-layout-test.sh case 4). The BH-5241 cut deleted the inline
# copies from bin/blocked-resolver.sh, so this module is load-bearing. The cut
# also moved in the 9 the driver alone held: br_rows_count, br_cap_rows,
# br_row_closed, br_set_flag, br_push_field, br_has_field_value, br_shape,
# br_fix_cap and br_rebuild_cap.
# ---------------------------------------------------------------------------
# State. One json per (project, key). rkey is the FILE name, so it is sanitized:
# a conductor key is `example-org/project-5#510` and both of those characters are
# trouble in a path and in a lock name.
# ---------------------------------------------------------------------------
br_rkey() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }
# br_cap_key <project> <rkey> <ticket-key> — the key the REBUILD cap counts on.
# A conductor rkey carries the PR NUMBER, and a rebuild produces a NEW PR, so a
# cap counted on it starts from zero on every rung: 10 -> rebuild -> 11 ->
# rebuild -> 12, for ever. The TICKET is what is being rebuilt, so every rebuild
# of one ticket shares one counter and the ladder is bounded per ticket. The
# queue and build sources already key on the ticket, so this is their key too.
br_cap_key() {
  local p="$1" rkey="$2" tkey="$3"
  case "$tkey" in ''|-) printf '%s' "$rkey" ;; *) br_rkey "$p-$tkey" ;; esac
}
br_file() { echo "$ST/$1/$2.json"; }
br_load() { # br_load <project> <rkey> — prints the json (a fresh one if absent)
  local f row=""; f=$(br_file "$1" "$2")
  if [ -s "$f" ]; then cat "$f"; return 0; fi
  # THE FILE IS GONE: ASK THE ROW (BH-2317). br_save mirrors the counters and
  # the outcome into ledgers(kind=br_record), so a wiped or rebuilt hub gets
  # them back instead of running an ABANDONED ladder again and telling the
  # client twice. Only rc 0 restores; a real miss or an outage is today's zero
  # shape. A miss (or an outage) is remembered in $BR_ROW_MISS for the tick (the
  # lane sets it; br_load runs inside $(...), so a shell variable would not
  # survive), which keeps a never-written key at one read per tick (D21).
  if command -v job_ledger_row >/dev/null 2>&1 \
     && ! { [ -n "${BR_ROW_MISS:-}" ] && grep -qxF "$1/$2" "$BR_ROW_MISS" 2>/dev/null; }; then
    row=$(job_ledger_row br_record "$1/$2" 2>/dev/null </dev/null) \
      || { row=""; [ -n "${BR_ROW_MISS:-}" ] && printf '%s\n' "$1/$2" >> "$BR_ROW_MISS" 2>/dev/null; }
  fi
  printf '%s' "$row" | jq -c --arg p "$1" --arg k "$2" --arg t "$(STAMP)" -n '
    {project:$p,rkey:$k,first_seen:$t,rebuilds:0,fixrounds:0,mechanicals:0,regens:0,adjudications:0,rereviews:0,outcome:"",attempts:[]}
    + ((try input catch null) as $r
       | if ($r | type) != "object" then {} else
           (try ($r.detail | fromjson) catch null) as $d
           | if ($d | type) != "object" then {} else
               ($d | with_entries(select(.key as $x
                   | ["rebuilds","fixrounds","mechanicals","regens","adjudications","rereviews"] | index($x))
                 | select(.value | type == "number")))
               + (if ($d.first_seen | type) == "string" then {first_seen:$d.first_seen} else {} end)
               + {outcome: (if $r.status == "open" then "" else ($r.status // "") end), restored:"ledger"}
             end
         end)'
}
# br_save <project> <rkey> <json> — THE ONE WRITE of a ticket's record
#   (BH-2317). The file first, exactly as every writer did it, and rc 1 when
#   that fails; then the counters and the outcome as a ledgers(kind=br_record)
#   row, fail-open and its rc ignored — br_record's file-then-row order, so a
#   row with no file behind it cannot happen and the next write heals a missed
#   row. status is the outcome (`open` when there is none), detail the counters.
br_save() {
  local f status detail
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\n' "$3" > "$f" || return 1
  command -v job_ledger_put >/dev/null 2>&1 || return 0
  status=$(printf '%s' "$3" | jq -r '(.outcome // "") | if . == "" then "open" else . end' 2>/dev/null) || return 0
  detail=$(printf '%s' "$3" | jq -c '{rebuilds,fixrounds,mechanicals,regens,adjudications,rereviews,first_seen}' 2>/dev/null) || return 0
  [ -n "$status" ] && job_ledger_put br_record "$1/$2" "$status" "$detail" >/dev/null 2>&1 </dev/null
  return 0
}
br_num() { # br_num <json> <field>
  local v; v=$(printf '%s' "$1" | jq -r "(.$2 // 0)" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo 0 ;; *) echo "$v" ;; esac
}
# br_rows_count <pr-url> <rebuild|fixround|adjudicate> — how many attempts of
#   this kind the ROWS hold for this PR (BH-1388), or NOTHING at all when the
#   flag is off, the url is blank or unparseable, or the worker is out.
#
#   pr_attempt_count prints nothing at rc 1 by design: an outage is not a count,
#   and a cap that read a blink as zero would buy a rebuild it had already
#   bought (D11). rc 2 is a MEASURED zero and prints 0, which can never raise a
#   cap. So the caller's rule is simply "empty means the file's counter stands".
br_rows_count() {
  local url="${1:-}" kind="${2:-}" slug num n rc
  case "$url" in ''|-) return 0 ;; esac
  [ -n "$kind" ] || return 0
  type pr_rows_on >/dev/null 2>&1 || return 0
  pr_rows_on || return 0
  slug=$(br_slug_of_url "$url") || return 0
  num=$(mc_num_of_url "$url"); [ -n "$num" ] || return 0
  n=$(pr_attempt_count "$slug" "$num" "$kind" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$n"
}
# br_cap_rows <project> <rkey> <reason> <file-count> <pr-url> <kind> <field>
#   THE CAP IS max(file, rows), never rows-only-when-the-file-is-absent.
#   "Absent" is knowable only inside br_load, and br_hold_gate runs before every
#   cap read and can br_record a `held` attempt — which CREATES the file with
#   zero counters. An absent-only rule would then find a file and let a wiped
#   hub evade the cap, which is the one outcome BH-1388 forbids. Rows <= file
#   whenever the file is genuine (the rows are per PR and collapse on an
#   unchanged head; the file is per ticket cap-key and counts every bump), so
#   the max equals the file everywhere the file is authoritative and equals the
#   rows only after a wipe. Prints the count to use; says so when it raised one.
br_cap_rows() {
  local p="$1" rkey="$2" reason="$3" n="$4" url="$5" kind="$6" field="$7" r
  r=$(br_rows_count "$url" "$kind")
  if [ -n "$r" ] && [ "$r" -gt "$n" ] 2>/dev/null; then
    say "$p/$rkey [$reason]: the record says $n $field but pr_attempts holds $r — a rebuilt hub, the rows count"
    printf '%s' "$r"; return 0
  fi
  printf '%s' "$n"
}
# br_record <project> <rkey> <action> <reason> <detail> [field-to-bump] [pr-url] [head]
#   Appends the attempt AND bumps its counter in one write. The attempt list is
#   what the ABANDONED alert prints: "what was tried" has to be a fact on disk,
#   not a reconstruction from log greps.
#
#   THE ROW IS THE SECOND WRITE (BH-1388). When the bump is one of the three
#   ladder counters and the caller handed in the PR url, the same attempt is
#   PUT to pr_attempts — mc_attempt_put's ordering exactly (bin/lib/mc/locks.sh):
#   the FILE first, so "a row with no file line" cannot happen, then the row,
#   whose rc is ignored because the file line already exists and the next bump
#   heals the row. The url is an ARGUMENT and not a record field because the
#   record has never carried one (br_load's fresh shape), so the eight bumping
#   call sites pass it and every other caller is unchanged.
br_record() {
  local p="$1" k="$2" act="$3" why="$4" detail="$5" bump="${6:-}" purl="${7:-}" phead="${8:-}"
  local f cur kind slug num
  f=$(br_file "$p" "$k"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$p" "$k")
  # The attempt carries its PR url when the caller handed one in (the fix-round
  # and rebuild call sites do): bin/lib/br/opt/cirepair.sh reads it to tell this
  # PR's rounds from an earlier PR's on a record it has not stamped yet.
  cur=$(printf '%s' "$cur" | jq -c --arg a "$act" --arg w "$why" --arg d "$detail" --arg t "$(STAMP)" --arg u "$purl" \
    '.attempts += [{at:$t,action:$a,reason:$w,detail:$d} + (if $u == "" or $u == "-" then {} else {url:$u} end)] | .updated = $t' 2>/dev/null) || return 1
  [ -n "$bump" ] && cur=$(printf '%s' "$cur" | jq -c --arg b "$bump" '.[$b] = ((.[$b] // 0) + 1)' 2>/dev/null)
  br_save "$p" "$k" "$cur" || return 1
  # A RECORDED RUNG IS RESOLVER ACTIVITY (BH-3630). When the conductor holds a
  # claim for this PR (mc_resolver_claim), its active_at moves, and the
  # conductor's 24h re-page stays quiet while rungs keep landing. No claim, no-op.
  case "$purl" in
    https://github.com/*/pull/*)
      command -v mc_resolver_claim_touch >/dev/null 2>&1 \
        && mc_resolver_claim_touch "$(br_slug_of_url "$purl")#$(mc_num_of_url "$purl")" 2>/dev/null ;;
  esac
  case "$bump" in
    rebuilds)      kind=rebuild ;;
    fixrounds)     kind=fixround ;;
    adjudications) kind=adjudicate ;;
    *)             kind="" ;;
  esac
  case "$purl" in ''|-) kind="" ;; esac
  if [ -n "$kind" ] && type pr_rows_on >/dev/null 2>&1 && pr_rows_on; then
    if slug=$(br_slug_of_url "$purl"); then
      num=$(mc_num_of_url "$purl")
      [ -n "$num" ] && pr_attempt_put "$slug" "$num" "$kind" "${phead:--}" >/dev/null 2>&1
    fi
  fi
  return 0
}
# br_event <event> <project> <cap-key> <reason> <detail> — ONE line per rung
#   transition, in the shape every later reader wants: a grep-able `EVENT
#   <name>` line in this lane's log and a fleet_event beat for the console.
#   A ladder whose transitions are only visible as prose is a ladder nobody can
#   count, and counting them is how the next "121 rebuilds, zero fix rounds"
#   gets noticed in a day rather than in a month.
br_event() {
  local ev="$1" p="$2" ck="$3" why="$4" detail="$5"
  say "EVENT $ev $p/$ck [$why] $detail"
  command -v bhw_event_ack >/dev/null 2>&1 && bhw_event_ack "$ev"
  [ -x "$H/bin/beat.sh" ] || return 0
  "$H/bin/beat.sh" "$(jq -nc --arg e "$ev" --arg p "$p" --arg k "$ck" --arg w "$why" \
      --arg d "$detail" --arg ts "$(STAMP)" \
      '{kind:"fleet_event",project:$p,rkey:("resolver:"+$p+"/"+$k),event:$e,reason:$w,detail:$d,ts:$ts}' 2>/dev/null)" \
    >/dev/null 2>&1 || true
  return 0
}

# br_row_closed <project> <ticket-key> <record> <pr-url> <stage> <detail> <reason>
#   THE BUILD ROW OF A PR THIS LANE CLOSED UNMERGED (BH-389). br_event tells the
#   fleet feed; nothing told the closed PR's own build row, so it kept its last
#   stage and the console counted project-5 #1237/#1239/#1242/#1220 as shipped.
#   One `kind:"build"` beat, `superseded` or `abandoned`, `merged:false` always,
#   addressed by run-build's own bkey (bin/run-build.sh BKEY) when there is a
#   record and by the PR url regardless. No tier/verdict, so an earlier review
#   is not rewritten. Only ever called after br_close_pr answered 0 — which it
#   also answers for a PR that is already closed OR merged; the rungs read
#   `merged` first, so only a merge landing between that read and the close
#   could reach here with a merged PR.
#
#   A ROW FROM br_from_rebuilds SENDS NOTHING (BH-389 review B1). Those rows
#   pair the REBUILD's record with `parked_url`, the OLD PR rung 3 closed and
#   already beat `superseded`. A beat there would hang the old PR on the
#   rebuild's row (two rows claiming one PR) and say "closed unmerged" about a
#   build that never had a PR. The old row keeps its superseded stage; the
#   rebuild's own row already ended at its own dead stage. `rebuild-enqueue-failed`
#   is NOT in this list: it carries `parked_rec`, the old PR's own record, and
#   its first successor is named only when that retry lands.
br_row_closed() {
  local p="$1" tkey="${2:--}" rec="${3:--}" url="${4:--}" stage="$5" detail="$6" reason="${7:-}" bkey=""
  case "$reason" in
    rebuild-build-dead|rebuild-decompose-failed|rebuild-plan-blocked|rebuild-review-blocked) return 0 ;;
  esac
  [ -n "$rec" ] && [ "$rec" != "-" ] && [ -d "$rec" ] && [ -n "$tkey" ] && [ "$tkey" != "-" ] \
    && bkey="build:$p:$tkey:$(basename "$rec")"
  [ -n "$url" ] || url="-"
  [ -n "$bkey" ] || [ "$url" != "-" ] || return 0
  [ -x "$H/bin/beat.sh" ] || return 0
  "$H/bin/beat.sh" "$(jq -nc --arg b "$bkey" --arg p "$p" --arg k "$tkey" --arg s "$stage" \
      --arg u "$url" --arg d "$detail" \
      '{kind:"build",project:$p,ticket_key:$k,stage:$s,merged:false,detail:$d}
       + (if $b == "" then {} else {bkey:$b} end)
       + (if $u == "-" then {} else {pr_url:$u} end)' 2>/dev/null)" \
    >/dev/null 2>&1 || true
  return 0
}

br_set_outcome() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg o "$3" --arg t "$(STAMP)" '.outcome=$o | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}
br_set_flag() { # br_set_flag <project> <rkey> <field> — sets .<field>=true on the record
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --arg t "$(STAMP)" '.[$k]=true | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_set_field <project> <cap-key> <field> <value> — one scalar on the record.
# The rebuild rung uses it for `parked_url` (the PR it just closed, which the
# rebuild-outcome path needs later to move that row and name it in the comment)
# and for `rebuild_result` (the RESULT line the outcome was read from, so the
# abandon can quote it even when the evidence was a queue row rather than a
# directory). An empty value is written as "-", never as an empty string that a
# later reader would have to guess about.
# br_set_num <project> <cap-key> <field> <n> — the same, for a COUNTER.
#   br_set_field writes every value as a JSON string, and br_record's bump is
#   `.[$b] = ((.[$b] // 0) + 1)` — arithmetic, which dies on a string ("string
#   and number cannot be added") and takes the whole attempt record with it. So
#   a field any rung increments is reset through this one, with --argjson.
br_set_num() {
  local f cur v="${4:-0}"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --argjson v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}
br_set_field() {
  local f cur v="${4:-}"; [ -n "$v" ] || v="-"
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --arg v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_push_field <project> <cap-key> <field> <value> — append <value> to a JSON
# ARRAY field on the record, once. rc 1 when the write did not happen, which the
# caller must treat as "do not do the thing this mark was guarding" (D16): the
# review fix round appends the head it is about to work on BEFORE the agent
# runs, and a round whose head was not recorded is a round that runs again on
# every tick for ever.
br_push_field() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --arg v "$4" --arg t "$(STAMP)" \
        '.[$k] = (((.[$k] // []) + [$v]) | unique) | .updated=$t' 2>/dev/null) || return 1
  [ -n "$cur" ] || return 1
  br_save "$1" "$2" "$cur"
}

# br_has_field_value <json> <field> <value> — rc 0 when the array field already
# contains the value. The (PR, head) dedupe test, read off the record.
br_has_field_value() {
  printf '%s' "${1:-}" | jq -e --arg k "$2" --arg v "$3" \
    '((.[$k] // []) | index($v)) != null' >/dev/null 2>&1
}

# br_set_num <project> <cap-key> <field> <n> — the NUMERIC twin of br_set_field,
# for counters a later reader compares as a number (`enqueue_failures`). Written
# as a json number, never as a string: br_num reads either, but a counter that
# renders as "6" in the record is one more thing an operator has to think about.
br_set_num() {
  local f cur v="${4:-0}"
  case "$v" in ''|*[!0-9]*) v=0 ;; esac
  f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg k "$3" --argjson v "$v" --arg t "$(STAMP)" \
        '.[$k]=$v | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_seen_rebuild <project> <cap-key> <record-name> — remember a rebuild record
# whose outcome has been consumed, so a landed rebuild is recorded ONCE and not
# re-recorded on every tick until something else moves the ticket on.
br_seen_rebuild() {
  local f cur; f=$(br_file "$1" "$2"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$1" "$2" | jq -c --arg n "$3" --arg t "$(STAMP)" \
        '.rebuild_seen = ((.rebuild_seen // []) + [$n] | unique) | .updated=$t' 2>/dev/null) || return 1
  br_save "$1" "$2" "$cur"
}

# br_json_edit <project> <cap-key> <jq-filter> [jq args…]
#   ONE jq write over the ticket's record, in br_record's shape: load, apply,
#   rewrite. A filter that fails leaves the file exactly as it was and answers
#   rc 1 — a half-applied record is how "stamped contested without a hold"
#   happens, so there is no path here that writes part of a change.
br_json_edit() {
  local p="$1" k="$2" filter="$3"; shift 3
  local f cur
  f=$(br_file "$p" "$k"); mkdir -p "$(dirname "$f")" 2>/dev/null
  cur=$(br_load "$p" "$k" | jq -c "$@" "$filter" 2>/dev/null) || return 1
  [ -n "$cur" ] || return 1
  br_save "$p" "$k" "$cur"
  return 0
}

# ---------------------------------------------------------------------------
# THE SHAPE OF A PARK (BH-579). Two ladders, and which one a ticket is on is a
# MEASUREMENT, never a guess: `.conflict_lines` is written only by
# mc_conflict_lines (the fix round's own tree) and by the conductor's sidecar,
# and it is kept as a MAX — a stale small measure can be raised by a later
# large one, never lowered, which is the conservative side of a wrong answer.
#
# UNKNOWN IS LARGE, AND 0 IS UNKNOWN. An absent, empty or unparseable
# measurement answers `large`, which is exactly today's ladder: the small shape
# has to be earned. A measured ZERO is the same answer, because zero is what an
# honest measurement of a conflict with no `<<<<<<<` markers reports — a
# delete/modify (`UD`) conflict is exactly that shape, and it is the shape a
# sibling that DELETED or RENAMED this ticket's file leaves behind. Reading that
# 0 as "a nought-line conflict" would put the hardest conflicts on the SHORT
# ladder: one rebuild instead of three, then ABANDONED. `.conflict_lines` is a
# MAX, so the same conflict could never raise it afterwards either.
# ---------------------------------------------------------------------------
br_shape() { # br_shape <json> -> small|large
  local n
  n=$(printf '%s' "${1:-}" | jq -r '.conflict_lines // ""' 2>/dev/null)
  case "$n" in ''|0|*[!0-9]*) echo large; return 0 ;; esac
  if [ "$n" -le "${SMALL_CONFLICT_LINES:-300}" ]; then echo small; else echo large; fi
}
# br_fix_cap <json> [<reason>] — how many fix rounds THIS ticket has bought. The
#   contested bonus rides on top of whichever shape it is on, and it is read from
#   the record rather than passed around, so the rung chosen and the rung that
#   runs can never disagree.
#
#   THE REASON IS THE SECOND ARGUMENT (BH-872), because one reason does not read
#   the record at all: a review verdict is worth BR_REVIEW_FIX_ROUNDS (2) rounds,
#   since the second one answers the findings the reviewer raised on what the
#   FIRST one pushed. A review park has no conflict of its own to be small or
#   large and no contested bonus to ride on, so that branch is the whole answer.
#   Every other reason — and an absent one, which is how the ladder calls this —
#   keeps the shape-driven cap, byte for byte.
br_fix_cap() {
  local st="${1:-}" reason="${2:-}" base
  case "$reason" in
    review-changes-requested) printf '%s\n' "${BR_REVIEW_FIX_ROUNDS:-2}"; return 0 ;;
    queue-dequeued) echo 1; return 0 ;;   # BH-3728: one round per (pr, head, class) claim; the dequeue-watch lane counts rounds across heads
  esac
  # The BR_-prefixed spellings are the documented knobs; the bare ones are what
  # this script assigns them to at startup, and are read first so a caller that
  # sourced only these functions still sees the knob.
  if [ "$(br_shape "$st")" = small ]; then base="${MAX_FIXROUNDS_SMALL:-${BR_MAX_FIXROUNDS_SMALL:-2}}"
  else base="${MAX_FIXROUNDS:-${BR_MAX_FIXROUNDS:-1}}"; fi
  case "$base" in ''|*[!0-9]*) base=1 ;; esac
  echo $(( base + $(br_num "$st" fixround_bonus) ))
}
br_rebuild_cap() { # br_rebuild_cap <json>
  local cap
  if [ "$(br_shape "${1:-}")" = small ]; then cap="${MAX_REBUILDS_SMALL:-1}"; else cap="${MAX_REBUILDS:-3}"; fi
  case "$cap" in ''|*[!0-9]*) cap=3 ;; esac
  echo "$cap"
}
