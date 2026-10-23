#!/bin/bash
# shellcheck shell=bash
# bin/lib/queue-row-job.sh — ONE `build_queue` row -> ONE job.json (BH-1026.3).
# Sourced by bin/fly-dispatch.sh and bin/fly-pool.sh, never run.
#
# WHY IT IS A LIBRARY AND NOT A SECOND COPY. This is the mapping
# bin/fly-dispatch.sh has carried inline since 2026-09-10: the field extraction,
# the two rebase-meta shapes normalised into one object, and the CHARSET REFUSAL
# that stops a row whose `branch` is `x;rm -rf` from reaching a git command on a
# builder. Under `build_queue_rows_only` three callers need exactly that mapping
# — the dispatcher's flag-off materialise, its flag-on single-machine dispatch,
# and the pool's per-tick materialise — and three copies of a security check are
# three chances for two of them to drift.
#
# THE FLAG-OFF FILE IS BYTE-FOR-BYTE THE ONE THE INLINE CODE WROTE. Every field
# that was absent then is absent now: `deaths` is emitted only when the row's
# meta carries it (the pool's death requeue does; nothing else ever has), and
# `rebuild` only when the meta carries `blocked_resolver`.
# tests/fly-lane-db-test.sh, tests/hotfix-cap-exempt-test.sh, tests/stacked-child-builds-test.sh and
# tests/rebase-on-pool-reap.bh-542-test.sh pin that.

# queue_row_job_file <project> <dest> <key> <ticket_id> <attempt> <meta-json>
#   <dest> is the job file to write, or `-` to VALIDATE ONLY and write nothing
#   (the rows path refuses a bad rebase row before any claim, and must not leave
#   a file behind while doing it).
#   rc 0 -> written (or validated, for `-`)
#   rc 3 -> REFUSED. The row is closed `failed` through queue_done when the
#           client is there, one line is appended to ALERTS.log, and the one-line
#           `say` text is printed on stdout for the caller's own log.
#   rc 1 -> the jq or the mv failed, or the arguments were unusable. Nothing was
#           written; the CALLER owns handing the row back (it is the one that
#           knows whether it had claimed it).
queue_row_job_file() {
  local project="${1:-}" dest="${2:-}" key="${3:-}" ticket="${4:-}" attempt="${5:-}" meta="${6:-}"
  local h="${HARNESS:-/root/harness}" tag="${QRJ_TAG:-fly-dispatch/${1:-}}"
  local ts def sb hf fs rb bad bf bv dth tmp brs cb kd rr="" lr="" cp=""
  [ -n "$project" ] && [ -n "$dest" ] && [ -n "$key" ] || return 1
  ts=$(date -u '+%Y-%m-%d %H:%M:%SZ')
  case "${ticket:-}" in -) ticket="" ;; esac
  case "${attempt:-}" in ''|*[!0-9]*) attempt=0 ;; esac
  # VALIDATE-ONLY SKIPS THE FIELDS IT WILL NOT WRITE. The dispatcher's rows path
  # asks this question of EVERY queued row on EVERY tick, and four extra `jq`
  # processes per row per tick is a cost with no reader — the only thing a
  # validate-only call can answer is the rebase refusal.
  if [ "$dest" = "-" ]; then def=0; dth=""; sb=""; hf=false; fs=false; brs=false; cb=""
  else
    # `deferrals` is the stand-down count, carried in the row's meta so it
    # survives this hub-side round trip; `attempt` stays the death count. Losing
    # it here would reset bin/fly-pool.sh's cap on every materialise.
    def=$(printf '%s' "${meta:-}" | jq -r '.deferrals // 0' 2>/dev/null)
    case "${def:-}" in ''|*[!0-9]*) def=0 ;; esac
    # `deaths` is the count bin/fly-pool.sh's reap OBSERVED, and it only ever
    # appears on a requeue that reap wrote. Absent -> no field, which is what
    # every file this mapping wrote before carried.
    dth=$(printf '%s' "${meta:-}" | jq -r '.deaths // ""' 2>/dev/null)
    case "${dth:-}" in ''|*[!0-9]*) dth="" ;; esac
    # `stack_base` travels the same way and for the same reason (2026-09-14,
    # stacked child builds): the watcher that decided this ticket is buildable on
    # top of an open parent PR knows the branch, and the machine that will build it
    # is two hops away. A bad value drops to "no field" — a child built against
    # main is still the build that was asked for.
    sb=$(printf '%s' "${meta:-}" | jq -r '.stack_base // ""' 2>/dev/null)
    case "${sb:-}" in *[!A-Za-z0-9._/-]*) sb="" ;; esac
    # `hotfix` rides the row meta the same way (#368): a flag lost in this hop is
    # an emergency that arrives at the pool as ordinary work.
    hf=$(printf '%s' "${meta:-}" | jq -r '.hotfix // false' 2>/dev/null)
    case "${hf:-}" in true) hf=true ;; *) hf=false ;; esac
    # `fresh_spawn` likewise (BH-5025.2): a hotfix that deferred on a reused
    # machine, which the pool's reuse handoff leaves for a fresh spawn.
    fs=$(printf '%s' "${meta:-}" | jq -r '.fresh_spawn // false' 2>/dev/null)
    case "${fs:-}" in true) fs=true ;; *) fs=false ;; esac
    # `rebuild` (BH-6350): a blocked-resolver rebuild (br_enqueue_fresh puts
    # `blocked_resolver` in the row meta) is a ticket that was admitted once
    # already, so the pool's dispatch-mode filter (dm_job_admit) lets it pass.
    brs=$(printf '%s' "${meta:-}" | jq -r 'if type == "object" then ((.blocked_resolver // "") | tostring) else "" end' 2>/dev/null)
    case "${brs:-}" in ''|null|false) brs=false ;; *) brs=true ;; esac
    # `continue_branch` (BH-6821): the pool reap requeued a build whose push was
    # rejected on a remote that diverged, and the next one starts from the
    # remote head. It reaches `git` on the machine as TARGET_BRANCH, so a value
    # outside the stack_base charset is REFUSED, not dropped: a build that lost
    # it would push over the same diverged branch again.
    cb=$(printf '%s' "${meta:-}" | jq -r 'if type == "object" then (.continue_branch // "") else "" end' 2>/dev/null)
    case "${cb:-}" in
      *[!A-Za-z0-9._/-]*)
        command -v queue_done >/dev/null 2>&1 \
          && { queue_done "$project" "$key" failed "continue_branch rejected (charset)" >/dev/null 2>&1 || true; }
        [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" \
          "[$tag] $key: this row's continue_branch is not a branch name — the row is closed FAILED and NO queue file was written."
        printf '%s: continue_branch rejected — row closed failed, no queue file written\n' "$key"
        return 3 ;;
    esac
  fi
  # `rebase` is the WHOLE meta object, carried across in one piece (BH-486.2,
  # #542). Under REBASE_ON_POOL the conductor's enqueue writes a row whose meta
  # IS the job — {kind,slug,url,pr,branch,head,base} — and bin/lib/rebase-job.sh
  # documents the machine reading it back as a top-level `rebase:{...}` on
  # job.json. Re-serialising through jq is both the shape the runner expects and
  # the sanitation jq gives for free.
  #
  # TWO META SHAPES, ONE NORMALISED OBJECT. The producer writes the fields FLAT,
  # which is what mc_pool_rebase_enqueue sends; bin/lib/merge-conductor-lib.sh's
  # own comment still documents the NESTED form ({kind:"rebase",rebase:{…}}).
  # Both are accepted and collapsed to the flat object BEFORE the charset checks,
  # so a nested row is validated — and refused on a bad field — exactly like a
  # flat one, rather than failing as "slug missing".
  rb=""
  kd=$(printf '%s' "${meta:-}" | jq -r 'if type=="object" then (.kind // "") else "" end' 2>/dev/null)
  # `rereview` (BH-7635): a conductor RE-REVIEW row, `RR-<pr>-<head8>`. The key
  # and the kind must agree, both ways: rereview meta on any other key, or an
  # RR- key with no rereview meta (none, or a rebase one), is a pair the pool
  # would otherwise dispatch as an ordinary build of ticket <pr>.
  case "$kd:$key" in
    rereview:RR-*) rr=$(_qrj_rereview "$meta" "$key") || { _qrj_rr_refuse "$project" "$key" "$rr" "$h" "$tag"; return 3; } ;;
    rereview:*)    _qrj_rr_refuse "$project" "$key" key "$h" "$tag"; return 3 ;;
    *:RR-*)        _qrj_rr_refuse "$project" "$key" kind "$h" "$tag"; return 3 ;;
  esac
  # `leadreview` (BH-8027): a LEAD REVIEW row, `LR-<pr>-<head8>`, put by
  # bin/lib/lead-pool.sh. Key and kind must agree both ways, as for RR-.
  case "$kd:$key" in
    leadreview:LR-*) lr=$(_qrj_leadreview "$meta" "$key") || { _qrj_rr_refuse "$project" "$key" "$lr" "$h" "$tag" leadreview; return 3; } ;;
    leadreview:*)    _qrj_rr_refuse "$project" "$key" key "$h" "$tag" leadreview; return 3 ;;
    *:LR-*)          _qrj_rr_refuse "$project" "$key" kind "$h" "$tag" leadreview; return 3 ;;
  esac
  # `console_preview` (BH-8030): a console preview build of one PR head,
  # `CP-<pr>-<head8>-<job>`, queued by bin/console-preview-deploy.sh. The same
  # both-ways rule: the meta on another key, or a CP- key without it, would be
  # dispatched as an ordinary build of ticket <pr>.
  case "$kd:$key" in
    console_preview:CP-*) cp=$(_qrj_console_preview "$meta" "$key") || { _qrj_cp_refuse "$project" "$key" "$cp" "$h" "$tag"; return 3; } ;;
    console_preview:*)    _qrj_cp_refuse "$project" "$key" key "$h" "$tag"; return 3 ;;
    *:CP-*)               _qrj_cp_refuse "$project" "$key" kind "$h" "$tag"; return 3 ;;
  esac
  if [ "$kd" = rebase ]; then
    rb=$(printf '%s' "$meta" | jq -c 'select(type=="object") | if (.rebase|type)=="object" then (.rebase + {kind:"rebase"}) else . end' 2>/dev/null)
    bad=""
    # The same charset `stack_base` is held to, on every field that reaches a git
    # command on the machine; `pr` is a number and nothing else. `url` is exempt
    # on purpose: it rides jq-encoded into job.json and bin/lib/rebase-job.sh
    # never hands it to git or curl, and the charset here would reject every
    # `https://`.
    for bf in slug branch base head; do
      bv=$(printf '%s' "$rb" | jq -r --arg f "$bf" '.[$f] // ""' 2>/dev/null)
      case "$bv" in ''|*[!A-Za-z0-9._/-]*) bad="$bf" ;; esac
    done
    bv=$(printf '%s' "$rb" | jq -r '.pr // ""' 2>/dev/null)
    case "$bv" in ''|*[!0-9]*) bad=pr ;; esac
    if [ -n "$bad" ]; then
      # AN UNUSABLE REBASE OBJECT IS REFUSED, NOT DROPPED. Dropping it would
      # leave {ticket_id:"21",key:"RB-21-…"} — which the pool dispatches as an
      # ordinary BUILD of "ticket 21" of this project, with a PR and a board
      # comment nobody asked for. So the row is closed `failed` (a release would
      # re-offer the same bad row every two minutes forever), it says so once in
      # ALERTS.log, and no queue file is written.
      command -v queue_done >/dev/null 2>&1 \
        && { queue_done "$project" "$key" failed "rebase meta rejected ($bad)" >/dev/null 2>&1 || true; }
      mkdir -p "$h/logs" 2>/dev/null
      echo "$ts [$tag] $key: this row's rebase meta is unusable (field '$bad') — the row is closed FAILED and NO queue file was written, because a rebase job that lost its rebase object is dispatched as an ordinary build of ticket ${ticket:-?}. Fix the producer (mc_pool_rebase_enqueue in bin/lib/merge-conductor-lib.sh)." >> "$h/logs/ALERTS.log"
      printf '%s: rebase meta rejected (field %s) — row closed failed, no queue file written\n' "$key" "'$bad'"
      return 3
    fi
  fi
  # VALIDATE-ONLY: the rows path asks this function the refusal question before
  # anything is claimed, and must not leave a file behind asking it.
  [ "$dest" = "-" ] && return 0
  # Dot-prefixed temp then mv, exactly as the scp path does: bin/fly-pool.sh runs
  # on the same */2 cron and its *.json glob must never see a partial file (it
  # read TK-730.json as empty and quarantined a valid job, 2026-08-17).
  tmp="$(dirname "$dest")/.$(basename "$dest").db"
  jq -nc --arg t "$ticket" --arg k "$key" --argjson a "$attempt" --argjson d "$def" \
     --arg ts "$ts" --arg sb "${sb:-}" --arg hf "${hf:-false}" --arg rb "${rb:-}" \
     --arg dx "${dth:-}" --arg fs "${fs:-false}" --arg rbd "${brs:-false}" --arg cb "${cb:-}" --arg rr "${rr:-}" --arg lr "${lr:-}" --arg cp "${cp:-}" \
       '{ticket_id:$t,key:$k,attempt:$a,deferrals:$d,enqueued_at:$ts,source:"db"}
        + (if $sb == "" then {} else {stack_base:$sb} end)
        + (if $cb == "" then {} else {continue_branch:$cb} end)
        + (if $hf == "true" then {hotfix:true} else {} end)
        + (if $fs == "true" then {fresh_spawn:true} else {} end)
        + (if $rbd == "true" then {rebuild:true} else {} end)
        + (if $rb == "" then {} else {rebase:($rb|fromjson)} end)
        + (if $rr == "" then {} else {rereview:($rr|fromjson)} end)
        + (if $lr == "" then {} else {leadreview:($lr|fromjson)} end)
        + (if $cp == "" then {} else {console_preview:($cp|fromjson)} end)
        + (if $dx == "" then {} else {deaths:($dx|tonumber)} end)' > "$tmp" \
    && mv "$tmp" "$dest" && return 0
  rm -f "$tmp"
  return 1
}

# _qrj_rereview <meta> <key> — the normalised `rereview` object (BH-7635), or
#   rc 1 with the name of the first bad field on stdout. Flat and nested
#   ({kind:"rereview",rereview:{…}}) metas collapse to one object, and only the
#   documented fields are carried. `head` is 40 lowercase hex and names the
#   key's head8; `reviewed` is that or `-`; `pr` is a number and names the key's
#   number; `reason` is one of the three call-guard keys; `url` is the PR's own
#   url or empty (then derived), because it reaches the REST read on the machine.
#   `dedup` is carried and not checked: nothing on the machine reads it, and it
#   rides jq-encoded only.
_qrj_rereview() {
  local m="${1:-}" key="${2:-}" o f v pr head
  o=$(printf '%s' "$m" | jq -c 'select(type=="object") | if (.rereview|type)=="object" then .rereview else . end
        | {slug:(.slug // "" | tostring), url:(.url // "" | tostring), pr:(.pr // "" | tostring),
           reviewed:(.reviewed // "-" | tostring), head:(.head // "" | tostring),
           reason:(.reason // "" | tostring), dedup:(.dedup // "" | tostring)}' 2>/dev/null)
  [ -n "$o" ] || { printf 'meta'; return 1; }
  for f in slug head reviewed pr reason; do
    v=$(printf '%s' "$o" | jq -r --arg f "$f" '.[$f]' 2>/dev/null)
    case "$f:$v" in
      slug:|slug:*[!A-Za-z0-9._/-]*) printf 'slug'; return 1 ;;
      head:*) case "$v" in ''|*[!0-9a-f]*) printf 'head'; return 1 ;; esac
              [ "${#v}" = 40 ] || { printf 'head'; return 1; }; head="$v" ;;
      reviewed:|reviewed:-) ;;
      reviewed:*) case "$v" in ''|*[!0-9a-f]*) printf 'reviewed'; return 1 ;; esac
                  [ "${#v}" = 40 ] || { printf 'reviewed'; return 1; } ;;
      pr:|pr:*[!0-9]*) printf 'pr'; return 1 ;;
      pr:*) pr="$v" ;;
      reason:|reason:noverdict|reason:prov) ;;
      reason:*) printf 'reason'; return 1 ;;
    esac
  done
  [ "$key" = "RR-$pr-${head:0:8}" ] || { printf 'key'; return 1; }
  v=$(printf '%s' "$o" | jq -r '.url')
  [ -z "$v" ] || [ "$v" = "https://github.com/$(printf '%s' "$o" | jq -r '.slug')/pull/$pr" ] || { printf 'url'; return 1; }
  printf '%s' "$o" | jq -c '{kind:"rereview"} + . + {pr:(.pr|tonumber)}
    | if .url == "" then .url = ("https://github.com/" + .slug + "/pull/" + (.pr|tostring)) else . end
    | if .reviewed == "" then .reviewed = "-" else . end' 2>/dev/null
}

# _qrj_rr_refuse <project> <key> <field> <harness> <tag> [kind] — the rc 3 path
#   for a re-review row (kind rereview, the default) or a lead-review row (kind
#   leadreview, BH-8027): closed `failed` (a release would re-offer it every
#   tick), ONE alert, no queue file, and the one-line `say` text on stdout.
_qrj_rr_refuse() {
  local project="$1" key="$2" bad="${3:-meta}" h="$4" tag="$5" kind="${6:-rereview}" what=re-review msg
  [ "$kind" = leadreview ] && what=lead-review
  command -v queue_done >/dev/null 2>&1 \
    && { queue_done "$project" "$key" failed "$kind meta rejected ($bad)" >/dev/null 2>&1 || true; }
  msg="[$tag] $key: this row's $what meta is unusable (field '$bad') — the row is closed FAILED and NO queue file was written, because a $what row that lost its $kind object is dispatched as an ordinary build. Fix the producer that queued this row."
  [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" "$msg"
  printf '%s: %s meta rejected (field %s) — row closed failed, no queue file written\n' "$key" "$kind" "'$bad'"
}

# _qrj_leadreview <meta> <key> — the normalised `leadreview` object (BH-8027),
#   or rc 1 with the name of the first bad field on stdout. Flat and nested
#   ({kind:"leadreview",leadreview:{…}}) metas collapse to one object. `slug`
#   is owner/repo; `pr` is a number and `head` 40 lowercase hex, and together
#   they name the key; `request` is empty or an id of [A-Za-z0-9._-]; `mode` is
#   lowercase letters (empty = full); `item` is an object whose repo, pr and
#   head_sha are the row's own (bin/lead-review.sh item reviews exactly it).
#   `url` is derived, never carried.
_qrj_leadreview() {
  local m="${1:-}" key="${2:-}" o f v pr head slug
  o=$(printf '%s' "$m" | jq -c 'select(type=="object") | if (.leadreview|type)=="object" then .leadreview else . end
        | {slug:(.slug // "" | tostring), pr:(.pr // "" | tostring), head:(.head // "" | tostring),
           request:(.request // "" | tostring), mode:(.mode // "" | tostring),
           item:(.item | if type == "object" then . else null end)}' 2>/dev/null)
  [ -n "$o" ] || { printf 'meta'; return 1; }
  for f in slug pr head request mode; do
    v=$(printf '%s' "$o" | jq -r --arg f "$f" '.[$f]' 2>/dev/null)
    case "$f:$v" in
      slug:*) [[ $v =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { printf 'slug'; return 1; }; slug="$v" ;;
      pr:|pr:*[!0-9]*) printf 'pr'; return 1 ;;
      pr:*) pr="$v" ;;
      head:*) [[ $v =~ ^[0-9a-f]{40}$ ]] || { printf 'head'; return 1; }; head="$v" ;;
      request:|request:-) ;;
      request:*) [[ $v =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'request'; return 1; } ;;
      mode:) ;;
      mode:*) [[ $v =~ ^[a-z]+$ ]] || { printf 'mode'; return 1; } ;;
    esac
  done
  [ "$key" = "LR-$pr-${head:0:8}" ] || { printf 'key'; return 1; }
  printf '%s' "$o" | jq -e --arg s "$slug" --arg p "$pr" --arg h "$head" \
    '(.item | type) == "object" and (.item.repo // "") == $s and ((.item.pr // "") | tostring) == $p and (.item.head_sha // "") == $h' \
    >/dev/null 2>&1 || { printf 'item'; return 1; }
  printf '%s' "$o" | jq -c '{kind:"leadreview"} + . + {pr:(.pr|tonumber), url:("https://github.com/" + .slug + "/pull/" + .pr)}
    | if .mode == "" then .mode = "full" else . end' 2>/dev/null
}

# _qrj_console_preview <meta> <key> — the normalised `console_preview` object
#   (BH-8030), or rc 1 with the name of the first bad field on stdout. Only the
#   documented fields are carried, each held to the charset the machine body
#   (bin/lib/console-preview-job.sh) checks again: `slug` owner/repo, `pr` a
#   number, `head` 40 lowercase hex, `alias` a Pages branch alias, `acct` an
#   account id, `project` a Pages project name, `wrangler` x.y.z. The key must
#   be CP-<pr>-<head8>-<job>.
_qrj_console_preview() {
  local m="${1:-}" key="${2:-}" o f v pr="" head=""
  o=$(printf '%s' "$m" | jq -c 'select(type=="object")
        | {slug:(.slug // "" | tostring), pr:(.pr // "" | tostring), head:(.head // "" | tostring),
           alias:(.alias // "" | tostring), acct:(.acct // "" | tostring),
           project:(.project // "" | tostring), wrangler:(.wrangler // "" | tostring)}' 2>/dev/null)
  [ -n "$o" ] || { printf 'meta'; return 1; }
  for f in slug pr head alias acct project wrangler; do
    v=$(printf '%s' "$o" | jq -r --arg f "$f" '.[$f]' 2>/dev/null)
    case "$f" in
      slug)     [[ "$v" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { printf 'slug'; return 1; } ;;
      pr)       [[ "$v" =~ ^[0-9]{1,9}$ ]] || { printf 'pr'; return 1; }; pr="$v" ;;
      head)     [[ "$v" =~ ^[0-9a-f]{40}$ ]] || { printf 'head'; return 1; }; head="$v" ;;
      alias)    [[ "$v" =~ ^[a-z0-9][a-z0-9-]{0,27}$ ]] || { printf 'alias'; return 1; } ;;
      acct)     [[ "$v" =~ ^[0-9a-zA-Z-]{6,64}$ ]] || { printf 'acct'; return 1; } ;;
      project)  [[ "$v" =~ ^[a-z0-9][a-z0-9-]{0,57}$ ]] || { printf 'project'; return 1; } ;;
      wrangler) [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'wrangler'; return 1; } ;;
    esac
  done
  [[ "$key" =~ ^CP-${pr}-${head:0:8}-[0-9]{1,6}$ ]] || { printf 'key'; return 1; }
  printf '%s' "$o" | jq -c '{kind:"console_preview"} + . + {pr:(.pr|tonumber)}' 2>/dev/null
}

# _qrj_cp_refuse <project> <key> <field> <harness> <tag> — the rc 3 path for a
#   console preview row: closed `failed`, ONE alert, no queue file, and the
#   one-line `say` text on stdout. The hub lane reads the failed row as the
#   box's fault and queues a new row on its next tick.
_qrj_cp_refuse() {
  local project="$1" key="$2" bad="${3:-meta}" h="$4" tag="$5" msg
  command -v queue_done >/dev/null 2>&1 \
    && { queue_done "$project" "$key" failed "console preview meta rejected ($bad)" >/dev/null 2>&1 || true; }
  msg="[$tag] $key: this row's console preview meta is unusable (field '$bad') — the row is closed FAILED and NO queue file was written, because a console preview row that lost its console_preview object is dispatched as an ordinary build. Fix the producer (bin/console-preview-deploy.sh fly_one)."
  [ -x "$h/bin/alert-line.sh" ] && HARNESS="$h" "$h/bin/alert-line.sh" "$msg"
  printf '%s: console preview meta rejected (field %s) — row closed failed, no queue file written\n' "$key" "'$bad'"
}
