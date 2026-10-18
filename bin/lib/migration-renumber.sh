#!/bin/bash
# bin/lib/migration-renumber.sh — renumber a branch-added migration whose number
# main already took (BH-7365). Sourced, never executed: no `set -e`, no `exit`,
# no output and no file written at source time.
#
# WHY. A repo that numbers its migrations by hand (project-6-os: prisma/sql/
# NNNN_slug.sql, and a unit test that refuses a shared number) has every
# parallel build pick "highest on main + 1". Two builds pick the same number,
# and git merges them cleanly because the two file names differ. So the
# collision is only seen as a red unit test after the merge of main.
#
# WHO CALLS IT. mc_rebase (bin/lib/mc/rebase.sh) after it merges main into a
# PR branch, its pool twin (bin/lib/rebase-job.sh), and the builder's pre-PR
# step (`# >>> migration renumber (BH-7365)` in bin/lib/rb/pr.sh).
#
# THE KNOBS (settings rows; the env value wins; `.<project>` wins over the bare key):
#   migration_renumber.dir[.<project>]          MNR_DIR          the migration dir; empty = off
#   migration_renumber.mode[.<project>]         MNR_MODE         fix (default) | check | off
#   migration_renumber.lock_prefix[.<project>]  MNR_LOCK_PREFIX  ^[a-z]{1,3}$; empty = no lock keys
#
# THE RULE. A migration is a name in <dir>/ (one level) that matches
# ^[0-9]+_[a-z0-9_]+\.sql$. TAKEN = the numbers of <base-ref>'s migrations.
# BRANCH = the migrations the branch ADDED (`--diff-filter=A`, `--no-renames`),
# sorted by (number, name). The first BRANCH file whose number is TAKEN, or is
# the number of an earlier BRANCH file, is the first collision. Files before it
# keep their number (a free number below main's highest is legal). That file
# and every BRANCH file after it move, in order, to the next numbers above
# max(main's highest, the highest kept BRANCH number). The digit width stays.
#
# THE REFERENCES. One pass per file, so a chain (0213 -> 0235 while the
# branch's own 0235 -> 0236) never moves a reference twice:
#   every text file the branch added or modified: the old stem `0213_x`
#     (bounded by a char outside [A-Za-z0-9_]) becomes `0235_x`.
#   every text file the branch added, except a kept migration of the branch:
#     `migration:0213`, `<prefix>0213` and the lock key (the integer of the
#     ASCII bytes of `<prefix>0213`) become the new number's forms. A modified
#     file keeps them: there the number can name main's own file.
#
# THE COMMIT. One commit, `BH-7365: renumber migration(s) past <base> <sha8>`,
# with one `Union-resolved: <old> -> <new> (BH-7365, migration renumbered)`
# trailer per move. mc_rebase reads that trailer and does NOT rebind the
# approval (rc 5): a renumber writes lines no reviewer read.

# _mnr_knob <name> <project> — the env value, else the project row, else the
# bare row, else empty. Always rc 0.
_mnr_knob() {
  local name="$1" p="$2" v=""
  command -v setting_get >/dev/null 2>&1 || return 0
  if [ -n "$p" ]; then
    v=$(setting_get "migration_renumber.$name.$p" 2>/dev/null) || v=""
  fi
  [ -n "$v" ] || { v=$(setting_get "migration_renumber.$name" 2>/dev/null) || v=""; }
  printf '%s' "$v"
}

# mnr_conf <project> — sets MNR_C_DIR, MNR_C_MODE, MNR_C_PREFIX. A bad value
# prints one warning on stderr. MNR_C_DIR empty or MNR_C_MODE=off = off.
mnr_conf() {
  local p="${1:-}"
  MNR_C_DIR="${MNR_DIR:-}"
  [ -n "$MNR_C_DIR" ] || MNR_C_DIR=$(_mnr_knob dir "$p")
  MNR_C_DIR="${MNR_C_DIR%/}"
  case "$MNR_C_DIR" in
    '') ;;
    /*|*..*|*[!A-Za-z0-9._/-]*)
      echo "migration renumber: migration_renumber.dir '$MNR_C_DIR' is not a relative repo path — off" >&2
      MNR_C_DIR="" ;;
  esac
  MNR_C_MODE=off; MNR_C_PREFIX=""
  [ -n "$MNR_C_DIR" ] || return 0
  MNR_C_MODE="${MNR_MODE:-}"
  [ -n "$MNR_C_MODE" ] || MNR_C_MODE=$(_mnr_knob mode "$p")
  case "$MNR_C_MODE" in
    '') MNR_C_MODE=fix ;;
    fix|check|off) ;;
    *) echo "migration renumber: migration_renumber.mode '$MNR_C_MODE' is not fix|check|off — read as check" >&2
       MNR_C_MODE=check ;;
  esac
  MNR_C_PREFIX="${MNR_LOCK_PREFIX:-}"
  [ -n "$MNR_C_PREFIX" ] || MNR_C_PREFIX=$(_mnr_knob lock_prefix "$p")
  if [ -n "$MNR_C_PREFIX" ] && ! [[ "$MNR_C_PREFIX" =~ ^[a-z]{1,3}$ ]]; then
    echo "migration renumber: migration_renumber.lock_prefix '$MNR_C_PREFIX' is not ^[a-z]{1,3}\$ — lock keys are not rewritten" >&2
    MNR_C_PREFIX=""
  fi
  return 0
}

# mnr_lock_int <str> — the decimal integer of the ASCII bytes of <str>
# (project-6: pg_advisory_xact_lock(120307137458744) is "mk0128"). At most 8
# bytes, each below 0x80, so the value fits a signed 64-bit integer. rc 1 else.
mnr_lock_int() {
  local s="${1:-}" v=0 i c
  [ -n "$s" ] && [ "${#s}" -le 8 ] || return 1
  for ((i = 0; i < ${#s}; i++)); do
    printf -v c '%d' "'${s:i:1}"
    [ "$c" -gt 0 ] && [ "$c" -lt 128 ] || return 1
    v=$(( v * 256 + c ))
  done
  printf '%s\n' "$v"
}

# _mnr_names <wt> <git-ls-output...> — reads paths on stdin and prints
# "<number>\t<basename>" for each one-level migration name of $MNR_C_DIR.
_mnr_names() {
  local f b
  while IFS= read -r f; do
    [ "${f%/*}" = "$MNR_C_DIR" ] || continue
    b="${f##*/}"
    [[ "$b" =~ ^([0-9]+)_[a-z0-9_]+\.sql$ ]] || continue
    printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$b"
  done
}

# mnr_plan <wt> <base-ref> — after mnr_conf. Prints one row per moved file:
#   MOVE<TAB><old-name><TAB><new-name><TAB><message>
#   DECLINE<TAB><old-name><TAB>-<TAB><message>
# rc 0 = nothing declined (zero rows = no collision), 1 = a decline, 2 = could
# not run (the base ref does not resolve, or a git read failed).
mnr_plan() {
  local wt="$1" base="$2" label="${2#origin/}" bl al n b w f
  local -A taken=() used=() keep=()
  local -a bnum=() bname=()
  git -C "$wt" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "the base ref $base does not resolve"; return 2; }
  bl=$(git -C "$wt" ls-tree --name-only "$base" -- "$MNR_C_DIR/" 2>/dev/null) || { echo "git ls-tree $base failed"; return 2; }
  al=$(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" HEAD -- "$MNR_C_DIR/" 2>/dev/null) || { echo "git diff $base HEAD failed"; return 2; }
  [ -n "$al" ] || return 0
  local basemax=0
  while IFS=$'\t' read -r n b; do
    [ -n "$n" ] || continue
    n=$((10#$n))
    [ -n "${taken[$n]:-}" ] || taken[$n]="$b"
    [ "$n" -gt "$basemax" ] && basemax=$n
  done < <(_mnr_names <<<"$bl" | sort -t $'\t' -k1,1n -k2,2)
  while IFS=$'\t' read -r n b; do
    [ -n "$n" ] || continue
    bnum+=("$n"); bname+=("$b")
  done < <(_mnr_names <<<"$al" | sort -t $'\t' -k1,1n -k2,2)
  [ "${#bname[@]}" -gt 0 ] || return 0
  # The first collision; everything before it keeps its number.
  local i first=-1 cur=$basemax v why=()
  for ((i = 0; i < ${#bname[@]}; i++)); do
    v=$((10#${bnum[$i]}))
    if [ -n "${taken[$v]:-}" ]; then
      why[$i]="${bnum[$i]} is taken on $label by ${taken[$v]}"
    elif [ -n "${used[$v]:-}" ]; then
      why[$i]="${bnum[$i]} is used twice in this PR (${used[$v]}, ${bname[$i]})"
    else
      why[$i]=""
    fi
    [ -z "${used[$v]:-}" ] && used[$v]="${bname[$i]}"
    if [ "$first" -lt 0 ] && [ -n "${why[$i]}" ]; then first=$i; fi
    if [ "$first" -lt 0 ]; then keep[$v]=1; [ "$v" -gt "$cur" ] && cur=$v; fi
  done
  [ "$first" -ge 0 ] || return 0
  # Numbers the merged tree holds that are not moving: skipped by the cursor.
  local -A held=()
  for v in "${!taken[@]}" "${!keep[@]}"; do held[$v]=1; done
  local rc=0 new nn
  for ((i = first; i < ${#bname[@]}; i++)); do
    b="${bname[$i]}"; w=${#bnum[$i]}
    [ -n "${why[$i]}" ] || why[$i]="${bnum[$i]} follows a renumbered file in this PR (order kept)"
    cur=$((cur + 1)); while [ -n "${held[$cur]:-}" ]; do cur=$((cur + 1)); done
    printf -v nn "%0${w}d" "$cur"
    if [ "${#nn}" -gt "$w" ]; then
      printf 'DECLINE\t%s\t-\t%s; no free number above %s for %s (width %s) — not renumbered\n' \
        "$b" "${why[$i]}" "$((cur - 1))" "$MNR_C_DIR/$b" "$w"
      rc=1; continue
    fi
    new="$nn${b#"${bnum[$i]}"}"
    held[$cur]=1
    f="$MNR_C_DIR"
    printf 'MOVE\t%s\t%s\t%s; this PR'"'"'s number is %s (%s -> %s)\n' "$b" "$new" "${why[$i]}" "$nn" "$f/$b" "$f/$new"
  done
  return "$rc"
}

# _mnr_rewrite <file> <map> <numbers:0|1> [<self-old> <self-new>] — the one
# perl pass over one file. <map> lines: S<TAB>old-stem<TAB>new-stem,
# N<TAB>old-digits<TAB>new-digits, L<TAB>old-int<TAB>new-int.
_mnr_rewrite() {
  MNR_MAPF="$2" MNR_NUMS="$3" MNR_PFX="$MNR_C_PREFIX" MNR_SELF_OLD="${4:-}" MNR_SELF_NEW="${5:-}" \
  MNR_SELF_LOLD="${6:-}" MNR_SELF_LNEW="${7:-}" perl -pi -e '
    BEGIN {
      open(my $fh, "<", $ENV{MNR_MAPF}) or die "map: $!";
      while (<$fh>) { chomp; my ($k, $o, $n) = split /\t/; $M{$k}{$o} = $n; }
      close $fh;
      if ($ENV{MNR_SELF_OLD} ne "") { $M{N}{$ENV{MNR_SELF_OLD}} = $ENV{MNR_SELF_NEW}; }
      if ($ENV{MNR_SELF_LOLD} ne "") { $M{L}{$ENV{MNR_SELF_LOLD}} = $ENV{MNR_SELF_LNEW}; }
      $sre = join "|", map { quotemeta } sort { length($b) <=> length($a) } keys %{ $M{S} || {} };
      $p = $ENV{MNR_PFX};
    }
    s/(?<![A-Za-z0-9_])($sre)(?![A-Za-z0-9_])/$M{S}{$1}/g if $sre ne "";
    if ($ENV{MNR_NUMS}) {
      s/migration:([0-9]+)(?![0-9])/exists $M{N}{$1} ? "migration:$M{N}{$1}" : $&/ge;
      s/(?<![A-Za-z0-9_])\Q$p\E([0-9]+)(?![0-9])/exists $M{N}{$1} ? "$p$M{N}{$1}" : $&/ge if $p ne "";
      s/(?<![0-9])([0-9]{6,})(?![0-9])/exists $M{L}{$1} ? $M{L}{$1} : $&/ge if $p ne "";
    }
  ' "$1"
}

# mnr_check <wt> <base-ref> <project> — the messages only, nothing changed.
#   rc 0 = no collision (or off), 1 = a collision (one line per moved file on
#   stdout), 2 = could not run.
mnr_check() {
  MNR_MODE=check mnr_fix "$@"
}

# mnr_fix <wt> <base-ref> <project> — renumber and commit once.
#   rc 0 = nothing to do (no output), or every move committed (one line per
#          move on stdout, written after the commit returned 0).
#   rc 1 = mode check with a collision, or a decline: the lines on stdout,
#          HEAD and the tree as they were.
#   rc 2 = could not run (one reason line); the tree is untouched.
mnr_fix() {
  local wt="${1:-}" base="${2:-}" project="${3:-}" plan prc pre
  [ -n "$wt" ] && [ -n "$base" ] || { echo "migration renumber: usage mnr_fix <wt> <base-ref> <project>"; return 2; }
  mnr_conf "$project"
  [ -n "$MNR_C_DIR" ] && [ "$MNR_C_MODE" != off ] || return 0
  plan=$(mnr_plan "$wt" "$base"); prc=$?
  [ "$prc" = 2 ] && { echo "migration renumber could not run: $plan"; return 2; }
  [ -n "$plan" ] || return 0
  if [ "$prc" = 1 ] || [ "$MNR_C_MODE" = check ]; then
    cut -f4- <<<"$plan"
    return 1
  fi
  pre=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { echo "migration renumber could not run: no HEAD in $wt"; return 2; }
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=no 2>/dev/null)" ] \
    || { echo "migration renumber could not run: the tree has uncommitted changes"; return 2; }
  local why; why=$(_mnr_apply "$wt" "$base" "$plan")
  if [ $? != 0 ]; then
    git -C "$wt" reset -q --hard "$pre" >/dev/null 2>&1
    echo "migration renumber failed and changed nothing: $why"
    return 1
  fi
  cut -f4- <<<"$plan"
  return 0
}

# _mnr_apply <wt> <base-ref> <plan> — the renames, the rewrite, the commit.
#   rc 0 only when the commit returned 0 and git lists every new path and no
#   old one. Prints a reason on failure; the caller resets.
_mnr_apply() {
  local wt="$1" base="$2" plan="$3" k o n map f mf lo ln
  local -A newpath=() selfold=() selfnew=() kept=()
  map=$(mktemp "${TMPDIR:-/tmp}/mnr-map.XXXXXX") || { echo "mktemp failed"; return 1; }
  local tr=""
  while IFS=$'\t' read -r k o n _; do
    [ "$k" = MOVE ] || continue
    printf 'S\t%s\t%s\n' "${o%.sql}" "${n%.sql}" >> "$map"
    printf 'N\t%s\t%s\n' "${o%%_*}" "${n%%_*}" >> "$map"
    if [ -n "$MNR_C_PREFIX" ]; then
      lo=$(mnr_lock_int "$MNR_C_PREFIX${o%%_*}") && ln=$(mnr_lock_int "$MNR_C_PREFIX${n%%_*}") \
        && printf 'L\t%s\t%s\n' "$lo" "$ln" >> "$map"
    fi
    newpath["$MNR_C_DIR/$o"]="$MNR_C_DIR/$n"
    selfold["$MNR_C_DIR/$n"]="${o%%_*}"; selfnew["$MNR_C_DIR/$n"]="${n%%_*}"
    tr+="Union-resolved: $MNR_C_DIR/$o -> $MNR_C_DIR/$n (BH-7365, migration renumbered)"$'\n'
  done <<<"$plan"
  # The branch's migrations that keep their number keep their number tokens.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -z "${newpath[$f]:-}" ] && kept["$f"]=1
  done < <(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" HEAD -- "$MNR_C_DIR/" 2>/dev/null)
  local added modified
  added=$(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" HEAD 2>/dev/null) \
    && modified=$(git -C "$wt" diff --no-renames --name-only --diff-filter=M "$base" HEAD 2>/dev/null) \
    || { rm -f "$map"; echo "git diff $base HEAD failed"; return 1; }
  for o in "${!newpath[@]}"; do
    git -C "$wt" mv "$o" "${newpath[$o]}" >/dev/null 2>&1 || { rm -f "$map"; echo "git mv $o failed"; return 1; }
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mf="${newpath[$f]:-$f}"
    [ -f "$wt/$mf" ] && grep -Iq . "$wt/$mf" 2>/dev/null || continue
    if [ -n "${kept[$f]:-}" ]; then
      _mnr_rewrite "$wt/$mf" "$map" 0 || { rm -f "$map"; echo "rewrite of $mf failed"; return 1; }
    elif [ -n "${selfold[$mf]:-}" ]; then
      lo=""; ln=""
      if [ -n "$MNR_C_PREFIX" ]; then
        lo=$(mnr_lock_int "$MNR_C_PREFIX${selfold[$mf]}") && ln=$(mnr_lock_int "$MNR_C_PREFIX${selfnew[$mf]}") || { lo=""; ln=""; }
      fi
      _mnr_rewrite "$wt/$mf" "$map" 1 "${selfold[$mf]}" "${selfnew[$mf]}" "$lo" "$ln" || { rm -f "$map"; echo "rewrite of $mf failed"; return 1; }
    else
      _mnr_rewrite "$wt/$mf" "$map" 1 || { rm -f "$map"; echo "rewrite of $mf failed"; return 1; }
    fi
  done <<<"$added"
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$wt/$f" ] && grep -Iq . "$wt/$f" 2>/dev/null || continue
    _mnr_rewrite "$wt/$f" "$map" 0 || { rm -f "$map"; echo "rewrite of $f failed"; return 1; }
  done <<<"$modified"
  rm -f "$map"
  # -u: tracked paths only. The conductor links an untracked node_modules into
  # the worktree, and that link must never ride into the commit.
  git -C "$wt" add -u -- . >/dev/null 2>&1 || { echo "git add failed"; return 1; }
  local short; short=$(git -C "$wt" rev-parse --short=8 "$base" 2>/dev/null)
  local -a id=()
  [ -n "${MC_GIT_NAME:-${HARNESS_MERGE_GIT_NAME:-}}" ] && id+=(-c "user.name=${MC_GIT_NAME:-$HARNESS_MERGE_GIT_NAME}")
  [ -n "${MC_GIT_EMAIL:-${HARNESS_GIT_EMAIL:-}}" ] && id+=(-c "user.email=${MC_GIT_EMAIL:-$HARNESS_GIT_EMAIL}")
  git -C "$wt" ${id[@]+"${id[@]}"} -c commit.gpgsign=false commit -q --no-verify \
      -m "BH-7365: renumber migration(s) past ${base#origin/} $short" -m "${tr%$'\n'}" >/dev/null 2>&1 \
    || { echo "the renumber commit failed"; return 1; }
  for o in "${!newpath[@]}"; do
    git -C "$wt" ls-files --error-unmatch "${newpath[$o]}" >/dev/null 2>&1 \
      && ! git -C "$wt" ls-files --error-unmatch "$o" >/dev/null 2>&1 \
      || { echo "after the commit git does not list ${newpath[$o]} in place of $o"; return 1; }
  done
  return 0
}
