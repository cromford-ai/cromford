# shellcheck shell=bash
# bin/blocked-resolver.d/bh-8458-wt-streak.sh — BH-8458: a fix round's git
# error reaches the hub, and a run of worktree-add failures sends one alert.
#
# WHY. The pool image clones with `--depth 50` (single-branch), so a pool fix
# round never saw origin/ticket/<key> and every `worktree add` failed. The
# reason said "see the git error in logs/blocked-resolver.log", a log on a
# machine the reap destroys. project-6-os FXR-1087, 1095, 1096, 1097
# (2026-10-26): four rounds, 0 model tokens, no git line anywhere.
#
# THE FIX in br_fix_round (driver): it fetches the PR branch by name
# (`+refs/heads/<br>:refs/remotes/origin/<br>`) after the plain fetch, and a
# failed worktree add puts `git: <br_git_why line>` in the setup-blocked
# reason. That reason rides `FIX_RESULT setup-blocked <b64>` to the hub, where
# br_fix_adopt decodes it into the hub log and calls br_wt_streak.
# BR_OPT_OFF=bh-8458-wt-streak does not source this file: the reason then has
# no git line (never an unredacted one) and nothing is counted.

# br_git_why <stderr> — git's stderr as ONE line a hub log may keep: every
#   token shape scrubbed (bin/lib/token-redact.sh), then mc_git_fail_line (the
#   last fatal:/error: line, 160 chars). Fail closed: a scrub that cannot load
#   prints a fixed text, never the raw stderr.
br_git_why() {
  local l
  command -v token_redact >/dev/null 2>&1 || . "$H/bin/lib/token-redact.sh" 2>/dev/null
  command -v token_redact >/dev/null 2>&1 || { printf '%s' '(git stderr withheld: the token scrub could not load)'; return 0; }
  l=$(printf '%s\n' "$1" | token_redact)
  if command -v mc_git_fail_line >/dev/null 2>&1; then
    mc_git_fail_line "$l"
  else
    l=$(printf '%s\n' "$l" | grep -E '^(fatal|error):' | tail -n 1)
    printf '%s' "${l:-(no stderr)}" | cut -c1-160
  fi
}

# br_wt_streak <project> <box> <result> — the per-project run of fix rounds
#   that could not create their worktree, kept in $ST/<project>/wt-fail-streak
#   as `<count>\t<alerted 0|1>\t<last-at>`.
#   counts  `setup-blocked <b64>` whose decoded text starts
#           `worktree add failed for origin/` (the old and the new text)
#   resets  done, terminal, rebuild-fresh: a round that got past setup. The
#           file is deleted, and an alert that was sent is resolved.
#   else    any other result (another setup cause, box-paused, a b64 that
#           does not decode, an unknown word) leaves the count as it is.
#   At BR_WT_FAIL_STREAK (settings row catalog/lanes.d/blocked-resolver.knobs.d/
#   BR_WT_FAIL_STREAK.json; 3 is its documented fallback; 0 = off) failures in
#   a row, ONE lane alert, id br-wt-streak:<project>, that names the kill knob.
#   Always rc 0.
br_wt_streak() {
  local p="$1" box="$2" res="$3" n="${BR_WT_FAIL_STREAK:-3}" f what c="" a="" tmp
  case "$n" in ''|*[!0-9]*) say "$p: BR_WT_FAIL_STREAK='$n' is not a whole number — the worktree-add streak uses 3"; n=3 ;; esac
  [ "$((10#$n))" -eq 0 ] && return 0
  n=$((10#$n)); f="$ST/$p/wt-fail-streak"
  case "$res" in
    done|terminal|rebuild-fresh)
      [ -e "$f" ] || return 0
      IFS=$'\t' read -r c a _ < "$f" 2>/dev/null
      rm -f "$f" 2>/dev/null
      [ "$a" = 1 ] && { "$H/bin/lane-alert.sh" --resolve --id "br-wt-streak:$p" blocked-resolver \
        "$p: a fix round got past setup on $box ($res) — the worktree-add streak is over" >/dev/null 2>&1 || true; }
      return 0 ;;
    "setup-blocked "?*) what=$(printf '%s' "${res#setup-blocked }" | base64 -d 2>/dev/null) || return 0 ;;
    *) return 0 ;;
  esac
  case "$what" in "worktree add failed for origin/"*) ;; *) return 0 ;; esac
  [ -r "$f" ] && IFS=$'\t' read -r c a _ < "$f" 2>/dev/null
  case "$c" in ''|*[!0-9]*) c=0 ;; esac
  [ "$a" = 1 ] || a=0
  c=$((10#$c + 1)); tmp="$f.tmp.$$"
  if ! { mkdir -p "$ST/$p" 2>/dev/null && printf '%s\t%s\t%s\n' "$c" "$a" "$(date -u +%FT%TZ)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; }; then
    rm -f "$tmp" 2>/dev/null
    say "WT-STREAK $p: could not write $f — this worktree-add failure is not counted"
    return 0
  fi
  if [ "$c" -ge "$n" ] && [ "$a" = 0 ]; then
    "$H/bin/lane-alert.sh" --id "br-wt-streak:$p" blocked-resolver \
      "$p: $c fix rounds in a row could not create their worktree (last on $box: $what). Rounds spend nothing but do no work. Kill knob: lane_placement.blocked-resolver-fix.$p=box." >/dev/null 2>&1 || true
    a=1
    printf '%s\t%s\t%s\n' "$c" "$a" "$(date -u +%FT%TZ)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  fi
  say "WT-STREAK $p $c/$n (alerted=$a, last on $box)"
  return 0
}
