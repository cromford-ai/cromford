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
#   migration_renumber.open_prs[.<project>]     MNR_OPEN_PRS     1 = open PRs join TAKEN; else off
#   migration_renumber.open_prs_max             MNR_OPEN_PRS_MAX open PRs read, 1..1000 (default 200)
#
# THE RULE. A migration is a name in <dir>/ (one level) that matches
# ^[0-9]+_[a-z0-9_]+\.sql$. TAKEN = the numbers of <base-ref>'s migrations.
# BRANCH = the migrations the branch ADDED (`--diff-filter=A`, `--no-renames`),
# sorted by (number, name). The first BRANCH file whose number is TAKEN, or is
# the number of an earlier BRANCH file, is the first collision. Files before it
# keep their number (a free number below main's highest is legal). That file
# and every BRANCH file after it move, in order, to the next numbers above
# max(main's highest, the highest kept BRANCH number, every open PR's number
# when open_prs is on). The digit width stays.
#
# OPEN PRS (BH-7398, open_prs on). The migrations each open PR ADDED (from its
# merge base with <base-ref>) are TAKEN too, except: the PR whose head is the
# self branch, a PR of the same ticket (`ticket/<key>(-r<n>)?`), and a file
# with the same name as one the branch added (a stacked child). With a known
# self PR only an open PR with a LOWER number makes a number taken: the older
# PR keeps it and the newer one moves. Before the PR exists every open PR
# counts. A read that fails (no slug, the list, the fetch) prints one stderr
# line and the check runs against <base-ref> only.
#
# QUEUED PRS (BH-7671). An open PR IN the merge queue (a label named
# $MC_MERGIFY_LABEL (default merge-queue), `queued` or `checking`, and no
# `dequeued` label: mc_queue_state's label rule) lands first, so it takes its
# numbers whatever its PR number. The self-branch, same-ticket and same-name
# exclusions still apply. MNR_HEAD=<sha> makes the check read that commit in
# place of HEAD (the conductor checks a head with no worktree), and
# MNR_OPEN_QUEUED_ONLY=1 lists and fetches only the queued PRs.
#
# THE REFERENCES. One pass per file, so a chain (0213 -> 0235 while the
# branch's own 0235 -> 0236) never moves a reference twice:
#   every text file the branch added or modified: the old stem `0213_x`
#     (bounded by a char outside [A-Za-z0-9_]) becomes `0235_x`.
#   every text file the branch added, except a kept migration of the branch:
#     `migration:0213`, `<prefix>0213` and the lock key (the integer of the
#     ASCII bytes of `<prefix>0213`) become the new number's forms. A modified
#     file keeps them: there the number can name main's own file.
#   the moved file itself, and every added file that is not a migration and
#     names the old stem: the bare number `0213` (bounded by a char outside
#     [A-Za-z0-9_]: RAISE text, a test's '0213: ...') becomes `0235`.
#
# LOCK NOTES. mnr_lock_notes reports a branch-added migration whose advisory
# lock calls take a `<prefix>NNNN` key that is not its own and never its own.
# Report only: a shared key (project-6's mk0003) is legal.
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
  MNR_C_MODE=off; MNR_C_PREFIX=""; MNR_C_OPEN_ON=0; MNR_C_OPEN_MAX=200
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
  local o="${MNR_OPEN_PRS-}"
  [ -n "$o" ] || o=$(_mnr_knob open_prs "$p")
  case "$o" in
    1) MNR_C_OPEN_ON=1 ;;
    ''|0) ;;
    *) echo "migration renumber: migration_renumber.open_prs '$o' is not 0|1 — open PRs are not read" >&2 ;;
  esac
  o="${MNR_OPEN_PRS_MAX:-}"
  [ -n "$o" ] || o=$(_mnr_knob open_prs_max "")
  if [ -n "$o" ]; then
    if [[ "$o" =~ ^[0-9]{1,4}$ ]] && [ "$((10#$o))" -ge 1 ] && [ "$((10#$o))" -le 1000 ]; then
      MNR_C_OPEN_MAX=$((10#$o))
    else
      echo "migration renumber: migration_renumber.open_prs_max '$o' is not 1..1000 — read as 200" >&2
    fi
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

# _mnr_open_taken <wt> <base-ref> <self-branch> — after mnr_conf. Sets
# MNR_C_OPEN to one "<number>\t<basename>\t<pr>\t<queued 0|1>" row per
# migration an open PR ADDED (the self branch and PRs of the same ticket left
# out; with MNR_OPEN_QUEUED_ONLY=1, every PR not queued too). Runs in the
# caller's shell, never in $( ): GH_REST_REASON must reach the case below.
# rc 0 = read (MNR_C_OPEN may be empty), 2 = not read (MNR_OPEN_WHY). The
# fetched refs live under refs/mnr-open/<ns>/ and are dropped on every path.
_mnr_open_taken() {
  local wt="$1" base="$2" self="$3" url slug lf list rc=0 kl nums n r ns lib
  local -a specs=()
  MNR_C_OPEN=""; MNR_OPEN_WHY=""
  # The configured url, not `git remote get-url` (that applies insteadOf). It
  # can carry a token: it is parsed here and never printed.
  url=$(git -C "$wt" config --get remote.origin.url 2>/dev/null) || url=""
  if [[ "$url" =~ github\.com[:/]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]]; then
    slug="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  else
    MNR_OPEN_WHY="no repo slug"; return 2
  fi
  if ! command -v gh_rest_pr_list_all >/dev/null 2>&1; then
    lib="$(dirname "${BASH_SOURCE[0]}")/gh-rest-list.sh"
    # shellcheck source=bin/lib/gh-rest-list.sh
    [ -r "$lib" ] && . "$lib" 2>/dev/null
  fi
  command -v gh_rest_pr_list_all >/dev/null 2>&1 || { MNR_OPEN_WHY="no REST lib"; return 2; }
  lf=$(mktemp "${TMPDIR:-/tmp}/mnr-prs.XXXXXX") || { MNR_OPEN_WHY="no scratch file"; return 2; }
  gh_rest_pr_list_all "$slug" open "$MNR_C_OPEN_MAX" > "$lf" || rc=$?
  list=$(cat "$lf"); rm -f "$lf"
  if [ "$rc" != 0 ]; then
    case "$rc:${GH_REST_REASON:-}" in
      75:rate*|75:quota*) MNR_OPEN_WHY="rate limited" ;;
      44:*) MNR_OPEN_WHY="repo not found" ;;
      *) MNR_OPEN_WHY="GitHub did not answer (rc $rc${GH_REST_REASON:+, ${GH_REST_REASON}})" ;;
    esac
    return 2
  fi
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || { MNR_OPEN_WHY="the PR list is not an array"; return 2; }
  # The ticket key of the self branch: ticket/<key>(-r<n>)? (pc_pr_hits' rule).
  kl=""
  [[ "$self" =~ ^ticket/([a-z0-9]+-[0-9]+)(-r[0-9]+)?$ ]] && kl="${BASH_REMATCH[1]}"
  local qrows qo=0 ql="${MC_MERGIFY_LABEL:-merge-queue}" q
  [ "${MNR_OPEN_QUEUED_ONLY:-}" = 1 ] && qo=1
  qrows=$(printf '%s' "$list" | jq -r --arg self "$self" --arg kl "$kl" --arg ql "$ql" --argjson qo "$qo" '
    .[] | select(.number != null)
    | (.head.ref // "") as $h
    | select($self == "" or $h != $self)
    | select(($kl != "" and ($h | test("^ticket/" + $kl + "(-r[0-9]+)?$"))) | not)
    | ([(.labels // [])[] | (.name // "")]) as $l
    | (if ($l | index("dequeued")) == null and ([$l[] | select(. == $ql or . == "queued" or . == "checking")] | length) > 0
       then 1 else 0 end) as $q
    | select($qo == 0 or $q == 1)
    | "\(.number) \($q)"' 2>/dev/null)
  local -A qof=()
  nums=""
  while read -r n q; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    nums+="$n "; qof[$n]="${q:-0}"
  done <<<"$qrows"
  ns=$(printf '%s' "${self:-build}" | tr -c 'A-Za-z0-9-' '-')"-${BASHPID:-$$}"
  for n in $nums; do
    case "$n" in ''|*[!0-9]*) continue ;; esac
    specs+=("+refs/pull/$n/head:refs/mnr-open/$ns/pr/$n")
  done
  [ "${#specs[@]}" -gt 0 ] || return 0
  if ! timeout 120 git -C "$wt" fetch --quiet --no-tags origin "${specs[@]}" >/dev/null 2>&1; then
    _mnr_drop_refs "$wt" "$ns"; MNR_OPEN_WHY="fetch failed"; return 2
  fi
  local rows="" v b
  for n in $nums; do
    r="refs/mnr-open/$ns/pr/$n"
    git -C "$wt" rev-parse -q --verify "$r" >/dev/null 2>&1 || continue
    while IFS=$'\t' read -r v b; do
      [ -n "$b" ] && rows+="$v"$'\t'"$b"$'\t'"$n"$'\t'"${qof[$n]:-0}"$'\n'
    done < <(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base...$r" -- "$MNR_C_DIR/" 2>/dev/null | _mnr_names)
  done
  _mnr_drop_refs "$wt" "$ns"
  MNR_C_OPEN="${rows%$'\n'}"
  return 0
}

_mnr_drop_refs() { # _mnr_drop_refs <wt> <namespace>
  local r
  for r in $(git -C "$1" for-each-ref --format='%(refname)' "refs/mnr-open/$2/" 2>/dev/null); do
    git -C "$1" update-ref -d "$r" 2>/dev/null
  done
}

# mnr_plan <wt> <base-ref> [<self-pr>] — after mnr_conf (and _mnr_open_taken,
# whose MNR_C_OPEN rows join TAKEN). Prints one row per moved file:
#   MOVE<TAB><old-name><TAB><new-name><TAB><message>
#   DECLINE<TAB><old-name><TAB>-<TAB><message>
# rc 0 = nothing declined (zero rows = no collision), 1 = a decline, 2 = could
# not run (the base ref does not resolve, or a git read failed).
mnr_plan() {
  local wt="$1" base="$2" label="${2#origin/}" sp="${3:-}" bl al n b w f pr
  local -A taken=() used=() keep=() openby=() openpr=() bset=() onum=()
  local -a bnum=() bname=()
  git -C "$wt" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || { echo "the base ref $base does not resolve"; return 2; }
  bl=$(git -C "$wt" ls-tree --name-only "$base" -- "$MNR_C_DIR/" 2>/dev/null) || { echo "git ls-tree $base failed"; return 2; }
  local hd="${MNR_HEAD:-HEAD}"
  al=$(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" "$hd" -- "$MNR_C_DIR/" 2>/dev/null) || { echo "git diff $base $hd failed"; return 2; }
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
  # Open PRs (BH-7398): a row is skipped when it is this branch's own file.
  # With a self PR, only a lower PR number takes a number (the older keeps it),
  # unless the row's PR is queued (BH-7671): it lands first, so it always takes.
  # Every open number, taken or not, is held: a move never lands on one.
  case "$sp" in *[!0-9]*) sp="" ;; esac
  local openmax=0
  for b in "${bname[@]}"; do bset[$b]=1; done
  local q
  while IFS=$'\t' read -r n b pr q; do
    [ -n "$n" ] && [ -n "$b" ] && [ -z "${bset[$b]:-}" ] || continue
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    n=$((10#$n)); onum[$n]=1
    [ "$n" -gt "$openmax" ] && openmax=$n
    [ "$q" = 1 ] || [ -z "$sp" ] || [ "$pr" -lt "$sp" ] || continue
    if [ -z "${openpr[$n]:-}" ] || [ "$pr" -lt "${openpr[$n]}" ]; then
      openpr[$n]=$pr
      if [ "$q" = 1 ]; then openby[$n]="queued PR #$pr ($b)"; else openby[$n]="open PR #$pr ($b)"; fi
    fi
  done <<<"${MNR_C_OPEN:-}"
  # The first collision; everything before it keeps its number.
  local i first=-1 cur=$basemax v why=()
  for ((i = 0; i < ${#bname[@]}; i++)); do
    v=$((10#${bnum[$i]}))
    if [ -n "${taken[$v]:-}" ]; then
      why[$i]="${bnum[$i]} is taken on $label by ${taken[$v]}"
    elif [ -n "${openby[$v]:-}" ]; then
      why[$i]="${bnum[$i]} is taken by ${openby[$v]}"
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
  for v in "${!taken[@]}" "${!keep[@]}" "${!onum[@]}"; do held[$v]=1; done
  [ "$openmax" -gt "$cur" ] && cur=$openmax
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

# _mnr_rewrite <file> <map> <numbers:0|1> [<self-old> <self-new> <self-lold>
# <self-lnew> [<bare>]] — the one perl pass over one file. <map> lines:
# S<TAB>old-stem<TAB>new-stem, N<TAB>old-digits<TAB>new-digits,
# L<TAB>old-int<TAB>new-int. <bare> is "old=new[,old=new...]": the bare number
# forms (kind B) this file gets. Every form is one alternation of ONE
# substitution, so a token is replaced once and never read again (a chain
# 0213 -> 0235 while 0235 -> 0236 cannot move a reference twice).
_mnr_rewrite() {
  MNR_MAPF="$2" MNR_NUMS="$3" MNR_PFX="$MNR_C_PREFIX" MNR_SELF_OLD="${4:-}" MNR_SELF_NEW="${5:-}" \
  MNR_SELF_LOLD="${6:-}" MNR_SELF_LNEW="${7:-}" MNR_BARE="${8:-}" perl -pi -e '
    BEGIN {
      open(my $fh, "<", $ENV{MNR_MAPF}) or die "map: $!";
      while (<$fh>) { chomp; my ($k, $o, $n) = split /\t/; $M{$k}{$o} = $n; }
      close $fh;
      if ($ENV{MNR_SELF_OLD} ne "") { $M{N}{$ENV{MNR_SELF_OLD}} = $ENV{MNR_SELF_NEW}; }
      if ($ENV{MNR_SELF_LOLD} ne "") { $M{L}{$ENV{MNR_SELF_LOLD}} = $ENV{MNR_SELF_LNEW}; }
      for (split /,/, $ENV{MNR_BARE}) { my ($o, $n) = split /=/; $M{B}{$o} = $n if $o ne ""; }
      sub alt { join "|", map { quotemeta } sort { length($b) <=> length($a) || $a cmp $b } keys %{ $_[0] || {} } }
      $p = $ENV{MNR_PFX};
      my @r; my $a;
      $a = alt($M{S}); push @r, "(?<![A-Za-z0-9_])(?<S>$a)(?![A-Za-z0-9_])" if $a ne "";
      if ($ENV{MNR_NUMS}) {
        $a = alt($M{N});
        if ($a ne "") {
          push @r, "migration:(?<N>$a)(?![0-9])";
          push @r, "(?<![A-Za-z0-9_])\Q$p\E(?<P>$a)(?![0-9])" if $p ne "";
        }
        $a = alt($M{L}); push @r, "(?<![0-9])(?<L>$a)(?![0-9])" if $a ne "" && $p ne "";
      }
      $a = alt($M{B}); push @r, "(?<![A-Za-z0-9_])(?<B>$a)(?![A-Za-z0-9_])" if $a ne "";
      $re = @r ? join("|", @r) : "";
    }
    s/$re/defined $+{S} ? $M{S}{$+{S}} : defined $+{N} ? "migration:$M{N}{$+{N}}" : defined $+{P} ? "$p$M{N}{$+{P}}" : defined $+{L} ? $M{L}{$+{L}} : $M{B}{$+{B}}/ge if $re ne "";
  ' "$1"
}

# _mnr_lock_str <int> — the ASCII string whose bytes are <int> (the inverse of
# mnr_lock_int). rc 1 when a byte is not printable ASCII.
_mnr_lock_str() {
  local v="${1:-}" s="" c
  [[ "$v" =~ ^[1-9][0-9]{0,18}$ ]] || return 1
  v=$((10#$v))
  while [ "$v" -gt 0 ]; do
    c=$((v % 256)); v=$((v / 256))
    [ "$c" -ge 33 ] && [ "$c" -le 126 ] || return 1
    s="$(printf "\\$(printf '%03o' "$c")")$s"
  done
  printf '%s\n' "$s"
}

# mnr_lock_notes <wt> <base-ref> <project> — one line per branch-added
# migration whose pg_advisory_(xact_)lock calls (outside `--` comments) take a
# <prefix>NNNN key but never the file's own <prefix><its number>. Report only:
# a shared key is legal (project-6's mk0003), a stale one is not, and no rule
# can tell them apart. Off when the dir or the prefix is empty. Always rc 0.
mnr_lock_notes() {
  local wt="${1:-}" base="${2:-}" n b f own k str foreign
  mnr_conf "${3:-}" 2>/dev/null
  [ -n "$MNR_C_DIR" ] && [ "$MNR_C_MODE" != off ] && [ -n "$MNR_C_PREFIX" ] || return 0
  while IFS=$'\t' read -r n b; do
    [ -n "$b" ] || continue
    f="$MNR_C_DIR/$b"
    [ -f "$wt/$f" ] || continue
    own=$(mnr_lock_int "$MNR_C_PREFIX$n") || continue
    foreign=""
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      if [ "$k" = "$own" ]; then foreign=""; break; fi
      [ -n "$foreign" ] && continue
      str=$(_mnr_lock_str "$k") || continue
      [[ "$str" =~ ^${MNR_C_PREFIX}[0-9]+$ ]] && foreign="$str ($k)"
    done < <(perl -ne 's/--.*//; while (/pg_advisory_(?:xact_)?lock\s*\(\s*([0-9]+)\s*\)/g) { print "$1\n" }' "$wt/$f" 2>/dev/null)
    [ -n "$foreign" ] && printf '%s takes lock %s, not its own %s (%s): a shared lock is legal, a stale one is not\n' \
      "$f" "$foreign" "$MNR_C_PREFIX$n" "$own"
  done < <(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" HEAD -- "$MNR_C_DIR/" 2>/dev/null | _mnr_names | sort -t $'\t' -k1,1n -k2,2)
  return 0
}

# mnr_check <wt> <base-ref> <project> [<self-branch> [<self-pr>]] — the
# messages only, nothing changed.
#   rc 0 = no collision (or off), 1 = a collision (one line per moved file on
#   stdout), 2 = could not run.
mnr_check() {
  MNR_MODE=check mnr_fix "$@"
}

# mnr_fix <wt> <base-ref> <project> [<self-branch> [<self-pr>]] — renumber and
# commit once. <self-branch> and <self-pr> (digits; anything else = none) feed
# the open-PR read when migration_renumber.open_prs is on.
#   rc 0 = nothing to do (no output), or every move committed (one line per
#          move on stdout, written after the commit returned 0).
#   rc 1 = mode check with a collision, or a decline: the lines on stdout,
#          HEAD and the tree as they were.
#   rc 2 = could not run (one reason line); the tree is untouched.
mnr_fix() {
  local wt="${1:-}" base="${2:-}" project="${3:-}" sb="${4:-}" sp="${5:-}" plan prc pre
  [ -n "$wt" ] && [ -n "$base" ] || { echo "migration renumber: usage mnr_fix <wt> <base-ref> <project> [<self-branch> [<self-pr>]]"; return 2; }
  mnr_conf "$project"
  [ -n "$MNR_C_DIR" ] && [ "$MNR_C_MODE" != off ] || return 0
  # MNR_HEAD is for a check only: a fix commits on HEAD, so it plans on HEAD.
  [ "$MNR_C_MODE" = check ] || local MNR_HEAD=HEAD
  MNR_C_OPEN=""
  if [ "$MNR_C_OPEN_ON" = 1 ] && [ -n "$(git -C "$wt" diff --no-renames --name-only --diff-filter=A "$base" "${MNR_HEAD:-HEAD}" -- "$MNR_C_DIR/" 2>/dev/null)" ]; then
    _mnr_open_taken "$wt" "$base" "$sb" \
      || echo "migration renumber: open PRs not read ($MNR_OPEN_WHY) — main only" >&2
  fi
  plan=$(mnr_plan "$wt" "$base" "$sp"); prc=$?
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
  local wt="$1" base="$2" plan="$3" k o n map f mf lo ln bare
  local -A newpath=() selfold=() selfnew=() kept=() stemb=()
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
    stemb["${o%.sql}"]="${o%%_*}=${n%%_*}"
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
      _mnr_rewrite "$wt/$mf" "$map" 1 "${selfold[$mf]}" "${selfnew[$mf]}" "$lo" "$ln" "${selfold[$mf]}=${selfnew[$mf]}" \
        || { rm -f "$map"; echo "rewrite of $mf failed"; return 1; }
    else
      # The bare number moves only where the file names the moved stem: a
      # bare 0213 elsewhere can mean main's own 0213.
      bare=""
      for o in "${!stemb[@]}"; do
        grep -Eq "(^|[^A-Za-z0-9_])$o([^A-Za-z0-9_]|\$)" "$wt/$mf" 2>/dev/null && bare+="${bare:+,}${stemb[$o]}"
      done
      _mnr_rewrite "$wt/$mf" "$map" 1 "" "" "" "" "$bare" || { rm -f "$map"; echo "rewrite of $mf failed"; return 1; }
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
