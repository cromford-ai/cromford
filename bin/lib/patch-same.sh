# shellcheck shell=bash
# bin/lib/patch-same.sh — did a PR head move WITHOUT its own patch changing?
# (BH-2310, #2310). Sourced, never run.
#
# WHY. The merge conductor, review-prs.sh and review-autopilot.sh buy a Fable
# review (up to 400K context) whenever a PR's head moves past the head that was
# reviewed. Most moves are not changes: a rebase train, or a fix round that only
# ran `git merge origin/main`. The conductor's patch-id rebind
# (bin/lib/mc/settle.sh) catches a plain rebase. It CANNOT catch a main merge
# whenever main touched a line next to one of the PR's hunks: the whole-diff
# patch-id includes context lines, the merge moves the merge-base, and the id
# changes although not one of the PR's own lines did (seen on #2131,
# 2026-09-25). This file is the deterministic answer, pure git, no model:
#
#   patch_same <git-dir> <main-ref> <reviewed> <head>
#     rc 0 and prints HOW when <head> carries exactly the patch <reviewed>
#     carried. rc 1 otherwise, and on anything it cannot establish. HOW is one of:
#       identical   the same commit.
#       main-merge  <head> descends from <reviewed>, and every commit between
#                   them that is not on <main-ref> is a CLEAN MERGE: a merge
#                   commit whose tree is exactly `git merge-tree` of its
#                   parents, with no conflict. So nothing but main came in, and
#                   no hand resolution slipped in with it.
#       patch-id    `git patch-id --verbatim` of the diff from the merge-base with
#                   <main-ref> is equal: a rebase that carried the patch across
#                   byte for byte. VERBATIM, never --stable: --stable strips all
#                   whitespace, and indentation is code in Python and YAML, so
#                   `rm -rf $D/ cache` read as `rm -rf $D/cache` (#2386 review).
#
#   There is deliberately NO range-diff rung (#2386 review): `git range-diff`
#   pairs a 644 -> 755 mode change and a file -> symlink swap as `=`. The two
#   rungs above cover a main merge and a byte-exact rebase, which is #2310's goal.
#
#   patch_same_restamp <git-dir> <main-ref> <reviewed> <head>   (BH-9066)
#     rc 0 and prints `restamp-rebase` when <head> is <reviewed>'s patch,
#     carried to a newer main (a rebase), with its PR-added schema fragments
#     restamped: each worker/<w>/schema.d/<12-digit stamp><suffix>.sql the PR
#     adds since its merge-base renamed to a later stamp, every reference to the
#     old basename rewritten, and not one other byte changed. restamp_same
#     (bin/lib/schema-restamp.sh) needs <reviewed> to be an ancestor of <head>,
#     so a restamp after the conductor land-rebase or a fix-round rebase bought
#     a new review. This rung owns only that case: when <reviewed> IS an
#     ancestor of <head> (or ancestry cannot be read) it is rc 1, and
#     restamp_same's commit-by-commit proof decides. The rule, every step required:
#       - both heads add the same stamp fragments per worker, in LC_ALL=C
#         order: the same count, the same `-<key>-<name>.sql` suffix at each
#         index, each head stamp >= the reviewed one at that index, and at
#         least one stamp different (else the byte rungs own the answer);
#       - each fragment basename becomes a placeholder `@PS_STAMP_<w>_<i>@<suffix>`
#         (fixed strings, longest first) in the whole diff from the merge-base;
#         in a .harness/specs/<KEY>/plan.md hunk only, a `<placeholder>` or
#         12-digit stamp before a mapped suffix maps too (the BH-7120 rule);
#       - the normalized `--raw` summaries (modes, status, paths) are equal and
#         the normalized diffs have equal `git patch-id --verbatim` ids.
#     A binary file, a text that already holds `@PS_STAMP_`, a basename two
#     workers share, any git or python failure, or an empty diff is rc 1.
#     NNNN fragments and any other path shape are never mapped: a rename of
#     one stays a change. Whitespace and lockfile edits stay a change to this
#     rung (patch_same_semantic owns them, and never combined with a restamp).
#
#   patch_same_semantic <git-dir> <main-ref> <reviewed> <head>   (BH-9154)
#     rc 0 and prints `lockfile` or `whitespace` when the only bytes that differ
#     are in named lockfiles or are trailing end-of-line whitespace in a file
#     whose trailing whitespace is not content. The full rule is above the
#     function. The knobs are catalog/lanes.d/_lib.patch-same.json.
#
#   patch_same_review <git-dir> <main-ref> <reviewed> <head>   (BH-9066)
#     patch_same || restamp_same || patch_same_restamp || patch_same_semantic;
#     prints the rung name.
#     FOR REVIEW CALLERS ONLY ("is this the same REVIEWED work"). A restamp
#     moves the fragment in the composed schema order, so a caller that reuses a
#     CI or test RESULT (merge-push, builder-carry, gate-record, ci-merge-reuse,
#     rb/pr, gate 10, the failed-batch module) stays on byte patch_same.
#
#   patch_same_fetch <git-dir> <reviewed> <head> [<pr-number>]
#     `git fetch origin main <head>` (and <reviewed> when the remote still has
#     it), so that origin/main and both commits exist locally. rc 1 when <head>
#     is still missing after every try, and then patch_same must not be asked.
#     BH-7043: one failed combined fetch is not the end. It then fetches
#     <head> alone, then main alone (best-effort: a concurrent fetch can hold
#     the origin/main ref lock), then, with a numeric <pr-number>, the PR ref
#     +refs/pull/<n>/head:refs/remotes/origin/pr/<n>. Success is <head>
#     resolving to a commit, never a fetch rc alone. <reviewed> is fetched
#     only when it does not resolve (by sha, then the PR ref), still
#     best-effort. A head this process already fetched into <git-dir> is not
#     fetched again (_PS_FETCHED). On rc 1, PS_FETCH_ERR holds the first git
#     error line, `://user:pass@` redacted, cut to 160 bytes; on rc 0 it is
#     empty. PS_FETCH_MAIN is 1 when origin/main was fetched for <git-dir> in
#     this process, else 0: a "patch changed" answer over a stale origin/main
#     is not settled.
#
# CONSERVATIVE BY CONSTRUCTION. Every answer needs positive evidence: a real
# 40-hex sha from rev-parse, a merge-tree that reported NO conflict, a non-empty
# commit list. An empty answer, a stubbed or broken git, a missing object, or an
# octopus merge is rc 1, and the caller buys the review exactly as before. It can
# say "the same patch". It can never say "close enough".

_ps_sha() { # _ps_sha <git-dir> <rev> -> the full commit sha, rc 1 unless it is one
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

_ps_tree() { # _ps_tree <git-dir> <commit> -> its tree sha
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{tree}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

# _ps_clean_merge <git-dir> <commit> — rc 0 when <commit> is a two-parent merge
# whose recorded tree is exactly what git merges its parents to, with no conflict.
_ps_clean_merge() {
  local g="$1" c="$2" parents want got out
  parents=$(git -C "$g" rev-list --parents -n 1 "$c" 2>/dev/null) || return 1
  read -r _ p1 p2 extra <<<"$parents"
  [[ "${p1:-}" =~ ^[0-9a-f]{40}$ ]] && [[ "${p2:-}" =~ ^[0-9a-f]{40}$ ]] && [ -z "${extra:-}" ] || return 1
  want=$(_ps_tree "$g" "$c") || return 1
  # merge-tree --write-tree prints the tree on its first line and exits 0 only
  # when the merge was clean; a conflict is exit 1 and never a pass.
  out=$(git -C "$g" merge-tree --write-tree "$p1" "$p2" 2>/dev/null) || return 1
  got=$(head -1 <<<"$out")
  [[ "$got" =~ ^[0-9a-f]{40}$ ]] && [ "$got" = "$want" ]
}

_ps_main_merge() { # <git-dir> <main> <reviewed> <head>
  local g="$1" main="$2" rev="$3" head="$4" list c n=0
  git -C "$g" merge-base --is-ancestor "$rev" "$head" 2>/dev/null || return 1
  list=$(git -C "$g" rev-list "$head" "^$rev" "^$main" 2>/dev/null) || return 1
  for c in $list; do
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || return 1
    _ps_clean_merge "$g" "$c" || return 1
    n=$((n + 1))
  done
  # Nothing new that is not on main would mean the head is main's own history,
  # not a PR head that took main in. That is not this rule's shape.
  [ "$n" -gt 0 ]
}

_ps_patch_id() { # <git-dir> <main> <sha> -> the whole-diff patch-id
  local g="$1" base id
  base=$(git -C "$g" merge-base "$2" "$3" 2>/dev/null) || return 1
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 1
  id=$(git -C "$g" diff "$base" "$3" 2>/dev/null | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
  [[ "$id" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$id"
}

patch_same() {
  local g="$1" main="$2" rev head m pr ph
  [ -n "$g" ] && [ -n "$main" ] || return 1
  rev=$(_ps_sha "$g" "${3:-}") || return 1
  head=$(_ps_sha "$g" "${4:-}") || return 1
  m=$(_ps_sha "$g" "$main") || return 1
  if [ "$rev" = "$head" ]; then printf 'identical'; return 0; fi
  if _ps_main_merge "$g" "$m" "$rev" "$head"; then printf 'main-merge'; return 0; fi
  if pr=$(_ps_patch_id "$g" "$m" "$rev") && ph=$(_ps_patch_id "$g" "$m" "$head") && [ "$pr" = "$ph" ]; then
    printf 'patch-id'; return 0
  fi
  return 1
}

_ps_dir="${BASH_SOURCE[0]%/*}"
PS_FRAG_RE='^worker/[a-z0-9_-]+/schema\.d/[0-9]{12}-[A-Za-z0-9._-]+\.sql$'

# _ps_base <git-dir> <main> <sha> -> their merge-base, rc 1 unless 40-hex
_ps_base() {
  local b
  b=$(git -C "$1" merge-base "$2" "$3" 2>/dev/null) || return 1
  [[ "$b" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$b"
}

# _ps_frags <git-dir> <base> <sha> -> the stamp fragments <sha> adds since <base>, LC_ALL=C order
_ps_frags() {
  local out p
  out=$(git -C "$1" -c core.quotepath=off diff --no-renames --name-only --diff-filter=A "$2" "$3" -- 'worker/*/schema.d/*' 2>/dev/null) || return 1
  while IFS= read -r p; do
    if [[ "$p" =~ $PS_FRAG_RE ]]; then printf '%s\n' "$p"; fi
  done <<<"$out" | LC_ALL=C sort
}

# _ps_restamp_maps <reviewed-frags> <head-frags> <map-r> <map-h>
#   Writes `<dir><TAB><basename><TAB><placeholder>` per fragment for each head.
#   rc 1 unless the two lists pair up as a forward-only restamp (header).
_ps_restamp_maps() {
  local -a a=() b=()
  local i pa pb ba bb w pw="" n=0 moved=0
  [ -n "$1" ] && [ -n "$2" ] || return 1
  mapfile -t a <<<"$1"; mapfile -t b <<<"$2"
  [ "${#a[@]}" = "${#b[@]}" ] || return 1
  : > "$3" && : > "$4" || return 1
  for i in "${!a[@]}"; do
    pa=${a[$i]}; pb=${b[$i]}
    [ "${pa%/*}" = "${pb%/*}" ] || return 1
    ba=${pa##*/}; bb=${pb##*/}
    [ "${ba:12}" = "${bb:12}" ] || return 1
    if [[ "${bb:0:12}" < "${ba:0:12}" ]]; then return 1; fi
    [ "$ba" = "$bb" ] || moved=1
    w=${pa#worker/}; w=${w%%/*}
    [ "$w" = "$pw" ] || { pw=$w; n=0; }
    printf '%s\t%s\t@PS_STAMP_%s_%s@%s\n' "${pa%/*}" "$ba" "$w" "$n" "${ba:12}" >> "$3"
    printf '%s\t%s\t@PS_STAMP_%s_%s@%s\n' "${pb%/*}" "$bb" "$w" "$n" "${bb:12}" >> "$4"
    n=$((n + 1))
  done
  [ "$moved" = 1 ] || return 1
  # One basename, one placeholder: a basename two workers share is not mapped.
  [ -z "$(cut -f2 "$3" | LC_ALL=C sort | uniq -d)" ] && [ -z "$(cut -f2 "$4" | LC_ALL=C sort | uniq -d)" ]
}

# _ps_restamp_norm <git-dir> <main> <sha> <map-file> — the normalized diff text
#   of <sha> from its merge-base with <main>: `#raw <old-mode> <new-mode>
#   <status><TAB><path>` lines, then the patch with its `index` lines dropped,
#   every mapped basename (and the plan.md stamp rule) replaced. rc 1 on any
#   failure, a binary file, or an empty diff.
_ps_restamp_norm() {
  local g="$1" sha="$3" map="$4" base td rc=0
  base=$(_ps_base "$g" "$2" "$sha") || return 1
  td=$(mktemp -d "${TMPDIR:-/tmp}/ps-norm.XXXXXX") || return 1
  local -a gd=(git -C "$g" -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv)
  if "${gd[@]}" --numstat "$base" "$sha" > "$td/num" 2>/dev/null && [ -s "$td/num" ] \
     && ! grep -qE $'^-\t-\t' "$td/num" \
     && "${gd[@]}" --raw --no-abbrev "$base" "$sha" > "$td/raw" 2>/dev/null \
     && "${gd[@]}" --src-prefix=a/ --dst-prefix=b/ "$base" "$sha" > "$td/patch" 2>/dev/null; then
    python3 -I -c '
import re, sys
mapf, rawf, patchf = sys.argv[1:4]
m, tails = {}, []
for ln in open(mapf, encoding="utf-8"):
    ln = ln.rstrip("\n")
    if ln:
        d, o, p = ln.split("\t")
        m[o.encode()] = p.encode()
        tails.append((d.encode(), o[12:].encode(), p.encode()))
if not m:
    sys.exit(1)
raw, patch = open(rawf, "rb").read(), open(patchf, "rb").read()
if not patch or b"@PS_STAMP_" in raw or b"@PS_STAMP_" in patch:
    sys.exit(1)
rx = re.compile(b"|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)))
def sub(b):
    return rx.sub(lambda x: m[x.group(0)], b)
keys = [d + b"/" + sx for d, sx, _ in tails]
pl = [(re.compile(rb"(?<![A-Za-z0-9_./-])" + re.escape(d + b"/") + rb"(?:[0-9]{12}|<[^<>\s/]+>)" + re.escape(sx) + rb"(?![A-Za-z0-9_-])"), d + b"/" + p)
      for d, sx, p in tails if keys.count(d + b"/" + sx) == 1]
out = []
for ln in raw.split(b"\n"):
    if not ln:
        continue
    meta, tab, path = ln.partition(b"\t")
    f = meta.lstrip(b":").split(b" ")
    if not tab or len(f) != 5:
        sys.exit(1)
    out.append(b"#raw " + f[0] + b" " + f[1] + b" " + f[4] + b"\t" + sub(path))
planhdr = re.compile(rb"^diff --git a/\.harness/specs/[^/]+/plan\.md b/")
chunks, cur = [], []
for ln in patch.split(b"\n"):
    if ln.startswith(b"diff --git ") and cur:
        chunks.append(cur); cur = []
    cur.append(ln)
if cur:
    chunks.append(cur)
for c in chunks:
    t = b"\n".join(l for l in c if not l.startswith(b"index "))
    t = sub(t)
    if planhdr.match(c[0]):
        for prx, rep in pl:
            t = prx.sub(lambda x: rep, t)
    out.append(t)
sys.stdout.buffer.write(b"\n".join(out) + b"\n")
' "$map" "$td/raw" "$td/patch" 2>/dev/null || rc=1
  else
    rc=1
  fi
  rm -rf "$td"
  return "$rc"
}

# _ps_norm_id <normalized-file> -> the verbatim patch-id of its patch part
_ps_norm_id() {
  local id
  id=$(grep -av '^#raw ' "$1" | git patch-id --verbatim 2>/dev/null | cut -d' ' -f1)
  [[ "$id" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$id"
}

patch_same_restamp() {
  local g="${1:-}" main rev head br bh fr fh td rc=1 ir ih anc
  [ -n "$g" ] && [ -n "${2:-}" ] || return 1
  rev=$(_ps_sha "$g" "${3:-}") || return 1
  head=$(_ps_sha "$g" "${4:-}") || return 1
  main=$(_ps_sha "$g" "$2") || return 1
  [ "$rev" != "$head" ] || return 1
  # A descendant head is restamp_same's (bin/lib/schema-restamp.sh); only a
  # clear "not an ancestor" (rc 1, never a git error) is this rung's shape.
  git -C "$g" merge-base --is-ancestor "$rev" "$head" >/dev/null 2>&1; anc=$?
  [ "$anc" = 1 ] || return 1
  br=$(_ps_base "$g" "$main" "$rev") || return 1
  bh=$(_ps_base "$g" "$main" "$head") || return 1
  fr=$(_ps_frags "$g" "$br" "$rev") || return 1
  fh=$(_ps_frags "$g" "$bh" "$head") || return 1
  td=$(mktemp -d "${TMPDIR:-/tmp}/ps-restamp.XXXXXX") || return 1
  if _ps_restamp_maps "$fr" "$fh" "$td/map.r" "$td/map.h" \
     && _ps_restamp_norm "$g" "$main" "$rev" "$td/map.r" > "$td/n.r" \
     && _ps_restamp_norm "$g" "$main" "$head" "$td/map.h" > "$td/n.h" \
     && grep -a '^#raw ' "$td/n.r" > "$td/raw.r" && grep -a '^#raw ' "$td/n.h" > "$td/raw.h" \
     && cmp -s "$td/raw.r" "$td/raw.h" \
     && ir=$(_ps_norm_id "$td/n.r") && ih=$(_ps_norm_id "$td/n.h") && [ "$ir" = "$ih" ]; then
    rc=0
  fi
  rm -rf "$td"
  [ "$rc" = 0 ] || return 1
  printf 'restamp-rebase'
}

# _ps_knob <name> — a semantic-rung knob, or its code fallback. The rows are
#   catalog/lanes.d/_lib.patch-same.json; keep the fallbacks equal to their
#   defaults. Set and empty means empty (PATCH_SAME_LOCKFILES= turns the
#   lockfile rung off; PATCH_SAME_LOCK_HOSTS= allows no registry host).
_ps_knob() {
  case "$1" in
    PATCH_SAME_LOCKFILES) printf '%s' "${PATCH_SAME_LOCKFILES-package-lock.json}" ;;
    PATCH_SAME_LOCK_HOSTS) printf '%s' "${PATCH_SAME_LOCK_HOSTS-registry.npmjs.org}" ;;
    PATCH_SAME_WS_SIGNIFICANT) printf '%s' "${PATCH_SAME_WS_SIGNIFICANT-.py .yml .yaml .md .mk Makefile .patch .diff .tsv}" ;;
    *) return 1 ;;
  esac
}

PS_SAFE_PATH_RE='^[A-Za-z0-9._@+/-]+$'

# _ps_lock_paths <git-dir> <base> <sha> — one `<status><TAB><path>` line per
#   changed path whose basename is in PATCH_SAME_LOCKFILES. Paths come from
#   `git diff --name-status -z` (NUL split), never from diff header text. A
#   lockfile-named path outside PS_SAFE_PATH_RE (a space, a quote, a tab) is
#   rc 1: `x b/package-lock.json` is never read as a lockfile.
_ps_lock_paths() {
  local names st p b n
  names=$(_ps_knob PATCH_SAME_LOCKFILES)
  [ -n "$names" ] || return 0
  local -a f=()
  mapfile -d '' -t f < <(git -C "$1" -c core.quotepath=off diff --no-renames --name-status -z "$2" "$3" 2>/dev/null; printf 'END%s' "$?") || return 1
  [ "${#f[@]}" -ge 1 ] && [ "${f[-1]}" = END0 ] || return 1
  unset 'f[-1]'
  [ $(( ${#f[@]} % 2 )) = 0 ] || return 1
  for ((n = 0; n < ${#f[@]}; n += 2)); do
    st=${f[$n]}; p=${f[$((n + 1))]}; b=${p##*/}
    [[ " $names " == *" $b "* ]] || continue
    [[ "$p" =~ $PS_SAFE_PATH_RE ]] || return 1
    printf '%s\t%s\n' "$st" "$p"
  done
}

# _ps_path_diff <git-dir> <base> <sha> <path> — the diff of one path, `index`
#   lines dropped (they name blob shas, which differ across bases).
_ps_path_diff() {
  local out
  out=$(git -C "$1" -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv \
        --src-prefix=a/ --dst-prefix=b/ "$2" "$3" -- ":(literal)$4" 2>/dev/null) || return 1
  grep -av '^index ' <<<"$out" || true
}

# _ps_lock_pkgs <git-dir> <sha> <path> — the install set of one npm lockfile:
#   a sorted JSON array of {k, v: {version, resolved, integrity, link}}, one per
#   `packages` entry (v2/v3) and per nested `dependencies` entry (v1). These are
#   the fields that choose the code `npm ci` installs. rc 1 when the blob is
#   missing, is not JSON, or is not a package-lock.json.
_ps_lock_pkgs() {
  [ "${3##*/}" = package-lock.json ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  git -C "$1" cat-file blob "$2:$3" 2>/dev/null | jq -cS '
    def pick: {version, resolved, integrity, link};
    def deps($pre): to_entries[] | ("d:" + $pre + .key) as $k
      | {k: $k, v: (.value | pick)}, ((.value.dependencies // {}) | deps($k + "/"));
    if type != "object" then error("not a lockfile") else . end
    | [ ((.packages // {}) | to_entries[] | {k: ("p:" + .key), v: (.value | pick)}),
        ((.dependencies // {}) | deps("")) ] | sort_by(.k)' 2>/dev/null
}

# _ps_lock_same <git-dir> <reviewed> <head> <path> — rc 0 when the lockfile at
#   <path> installs the same code on both heads: the same entry keys, and the
#   same version, resolved, integrity and link for every entry. Every `resolved`
#   that is not a link must also be an https URL on a host in
#   PATCH_SAME_LOCK_HOSTS. So only a reorder or a metadata-only rewrite passes.
#   The commit author is never the permission.
_ps_lock_same() {
  local pr ph hosts r h ok
  pr=$(_ps_lock_pkgs "$1" "$2" "$4") && [ -n "$pr" ] || return 1
  ph=$(_ps_lock_pkgs "$1" "$3" "$4") && [ -n "$ph" ] || return 1
  [ "$pr" = "$ph" ] || return 1
  hosts=$(_ps_knob PATCH_SAME_LOCK_HOSTS)
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    ok=0
    for h in $hosts; do
      [[ "$r" == "https://$h/"* ]] && { ok=1; break; }
    done
    [ "$ok" = 1 ] || return 1
  done < <(jq -r '.[] | select(.v.link != true) | .v.resolved // empty' <<<"$ph" 2>/dev/null; printf '\n')
  # jq must read the array it just printed; a failure there is a refusal.
  jq -e 'type == "array"' <<<"$ph" >/dev/null 2>&1
}

# _ps_sem_norm <git-dir> <base> <sha> <exclude-pathspec...> — the normalized
#   diff text: every path outside PATCH_SAME_WS_SIGNIFICANT diffed with
#   --ignore-space-at-eol, every significant path diffed exactly, the given
#   pathspecs excluded, `index` lines dropped. rc 1 on any git failure, a
#   binary file, a bad knob entry, or a changed line whose trailing whitespace
#   follows a `\` (a line continuation: that space is code).
_ps_sem_norm() {
  local g="$1" base="$2" sha="$3" e full a b=""; shift 3
  local -a gd=(git -C "$g" -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/)
  local -a sig_in=() sig_ex=()
  for e in $(_ps_knob PATCH_SAME_WS_SIGNIFICANT); do
    [[ "$e" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    if [ "${e:0:1}" = . ]; then sig_in+=(":(glob)**/*$e"); sig_ex+=(":(exclude,glob)**/*$e")
    else sig_in+=(":(glob)**/$e"); sig_ex+=(":(exclude,glob)**/$e"); fi
  done
  e=$("${gd[@]}" --numstat "$base" "$sha" -- . "$@" 2>/dev/null) || return 1
  ! grep -qE $'^-\t-\t' <<<"$e" || return 1
  full=$("${gd[@]}" "$base" "$sha" -- . "$@" "${sig_ex[@]}" 2>/dev/null) || return 1
  ! grep -av -e '^+++ ' -e '^--- ' <<<"$full" | grep -aqE '^[-+].*\\[[:space:]]+$' || return 1
  a=$("${gd[@]}" --ignore-space-at-eol "$base" "$sha" -- . "$@" "${sig_ex[@]}" 2>/dev/null) || return 1
  if [ "${#sig_in[@]}" -gt 0 ]; then
    b=$("${gd[@]}" "$base" "$sha" -- "${sig_in[@]}" "$@" 2>/dev/null) || return 1
  fi
  # Inside a hunk of the ignore-space-at-eol part, a line still prints its
  # trailing whitespace; strip it there (never in a file header).
  a=$(awk '/^diff --git /{h=0} /^@@ /{h=1; print; next} h{c = substr($0, 1, 1); r = substr($0, 2); sub(/[ \t\r]+$/, "", r); $0 = c r} {print}' <<<"$a") || return 1
  printf '%s\n%s\n' "$a" "$b" | grep -av -e '^index ' -e '^$' || true
}

# _ps_cr_added <git-dir> <base> <sha> <exclude-pathspec...> — the count of
#   added lines that end in a CR. --ignore-space-at-eol hides a CR, so a head
#   that turns LF into CRLF (a shell script bash cannot run) would read as the
#   same patch; the caller refuses a head that adds more of them. rc 1 on a
#   git failure.
_ps_cr_added() {
  local g="$1" base="$2" sha="$3" d; shift 3
  d=$(git -C "$g" -c core.quotepath=off diff --no-renames --no-color --no-ext-diff --no-textconv "$base" "$sha" -- . "$@" 2>/dev/null) || return 1
  grep -av '^+++ ' <<<"$d" | grep -ac $'^+.*\r$' || [ "$?" = 1 ]
}

# _ps_sem_hdr <normalized-file> — its file and mode header lines (patch-id
#   ignores them, so a mode or type change is compared here).
_ps_sem_hdr() { grep -aE '^(diff --git |old mode |new mode |new file mode |deleted file mode )' "$1" || [ "$?" = 1 ]; }

# _ps_sem_id <normalized-file> — the verbatim patch-id, or `empty` for no diff.
_ps_sem_id() {
  local id
  [ -s "$1" ] || { printf 'empty'; return 0; }
  id=$(git patch-id --verbatim < "$1" 2>/dev/null | cut -d' ' -f1)
  [[ "$id" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$id"
}

# patch_same_semantic <git-dir> <main-ref> <reviewed> <head>   (BH-9154)
#   rc 0 and prints `lockfile` or `whitespace` when the two heads' diffs from
#   their merge-bases differ only in (a) lockfiles named in PATCH_SAME_LOCKFILES,
#   each with a byte-equal sibling package.json diff, status M (never added or
#   deleted), mode 100644, and the same install set on both heads
#   (_ps_lock_same: same packages, versions, resolved URLs and integrity, every
#   host in PATCH_SAME_LOCK_HOSTS); and/or (b) trailing
#   whitespace at end of line (CR included) in a file outside
#   PATCH_SAME_WS_SIGNIFICANT, never after a `\`, and never a head that adds
#   more CR-ended lines than the reviewed one did. Indentation, blank lines,
#   modes and types stay a change. `lockfile` when a lockfile differed, else
#   `whitespace`. Every unknown is rc 1.
patch_same_semantic() {
  local g="${1:-}" main rev head br bh lr lh p st d td rc=1 ir ih label=whitespace
  [ -n "$g" ] && [ -n "${2:-}" ] || return 1
  rev=$(_ps_sha "$g" "${3:-}") || return 1
  head=$(_ps_sha "$g" "${4:-}") || return 1
  main=$(_ps_sha "$g" "$2") || return 1
  [ "$rev" != "$head" ] || return 1
  br=$(_ps_base "$g" "$main" "$rev") || return 1
  bh=$(_ps_base "$g" "$main" "$head") || return 1
  lr=$(_ps_lock_paths "$g" "$br" "$rev") || return 1
  lh=$(_ps_lock_paths "$g" "$bh" "$head") || return 1
  local -a ex=()
  local -A seen=()
  while IFS=$'\t' read -r st p; do
    [ -n "$p" ] && [ -z "${seen[$p]:-}" ] || continue
    seen[$p]=1
    [ "$(_ps_path_diff "$g" "$br" "$rev" "$p")" != "$(_ps_path_diff "$g" "$bh" "$head" "$p")" ] || continue
    # A lockfile that differs: only a modified regular file, on both sides. An
    # added or deleted lockfile changes what `npm ci` installs.
    for d in "$lr" "$lh"; do
      st=$(awk -F'\t' -v p="$p" '$2 == p { print $1 }' <<<"$d")
      case "$st" in ''|M) ;; *) return 1 ;; esac
    done
    [ -z "$(git -C "$g" diff --raw --no-abbrev --no-renames "$bh" "$head" -- ":(literal)$p" 2>/dev/null | awk '$2 != "100644"')" ] || return 1
    d=${p%/*}; [ "$d" != "$p" ] && d="$d/package.json" || d=package.json
    [ "$(_ps_path_diff "$g" "$br" "$rev" "$d")" = "$(_ps_path_diff "$g" "$bh" "$head" "$d")" ] || return 1
    _ps_lock_same "$g" "$rev" "$head" "$p" || return 1
    ex+=(":(exclude,literal)$p"); label=lockfile
  done <<<"$lr"$'\n'"$lh"
  ir=$(_ps_cr_added "$g" "$br" "$rev" "${ex[@]}") && ih=$(_ps_cr_added "$g" "$bh" "$head" "${ex[@]}") || return 1
  [ "$ih" -le "$ir" ] || return 1
  td=$(mktemp -d "${TMPDIR:-/tmp}/ps-sem.XXXXXX") || return 1
  if _ps_sem_norm "$g" "$br" "$rev" "${ex[@]}" > "$td/n.r" \
     && _ps_sem_norm "$g" "$bh" "$head" "${ex[@]}" > "$td/n.h" \
     && _ps_sem_hdr "$td/n.r" > "$td/h.r" && _ps_sem_hdr "$td/n.h" > "$td/h.h" \
     && cmp -s "$td/h.r" "$td/h.h" \
     && ir=$(_ps_sem_id "$td/n.r") && ih=$(_ps_sem_id "$td/n.h") && [ "$ir" = "$ih" ]; then
    rc=0
  fi
  rm -rf "$td"
  [ "$rc" = 0 ] || return 1
  printf '%s' "$label"
}

patch_same_review() {
  local how
  if how=$(patch_same "$@"); then printf '%s' "$how"; return 0; fi
  command -v restamp_same >/dev/null 2>&1 || { [ -r "$_ps_dir/schema-restamp.sh" ] && . "$_ps_dir/schema-restamp.sh"; }
  if command -v restamp_same >/dev/null 2>&1 && how=$(restamp_same "$@"); then printf '%s' "$how"; return 0; fi
  if how=$(patch_same_restamp "$@"); then printf '%s' "$how"; return 0; fi
  if how=$(patch_same_semantic "$@"); then printf '%s' "$how"; return 0; fi
  return 1
}

declare -gA _PS_FETCHED=() _PS_MAIN_FETCHED=()
PS_FETCH_ERR=""; PS_FETCH_MAIN=0; _PS_ERR=""

# _ps_redact — stdin to stdout: the first line, credentials in a URL masked, 160 bytes.
_ps_redact() { head -n 1 | sed -E 's#://[^/@ ]+@#://***@#g' | head -c 160; }

# _ps_fetch <git-dir> <fetch args...> — one quiet `git fetch origin`; the first
#   failure's stderr is kept in _PS_ERR for PS_FETCH_ERR.
_ps_fetch() {
  local g="$1" e; shift
  e=$(git -C "$g" fetch -q origin "$@" 2>&1 >/dev/null) && return 0
  [ -n "$_PS_ERR" ] || _PS_ERR="${e:-git fetch origin $* failed with no message}"
  return 1
}

patch_same_fetch() { # <git-dir> <reviewed> <head> [<pr-number>]
  local g="$1" rev="${2:-}" head="${3:-}" pr="${4:-}" prref
  PS_FETCH_ERR=""; PS_FETCH_MAIN=0; _PS_ERR=""
  [ -d "$g/.git" ] || [ -f "$g/HEAD" ] || { PS_FETCH_ERR="no git dir at $g"; return 1; }
  [ -n "$head" ] || { PS_FETCH_ERR="no head sha"; return 1; }
  [[ "$pr" =~ ^[0-9]+$ ]] && prref="+refs/pull/$pr/head:refs/remotes/origin/pr/$pr" || prref=""
  if [ -z "${_PS_FETCHED[$g|$head]:-}" ] || ! _ps_sha "$g" "$head" >/dev/null; then
    if _ps_fetch "$g" main "$head"; then _PS_MAIN_FETCHED[$g]=1
    else
      _ps_fetch "$g" "$head"
      _ps_fetch "$g" main && _PS_MAIN_FETCHED[$g]=1
      if [ -n "$prref" ] && ! _ps_sha "$g" "$head" >/dev/null; then _ps_fetch "$g" "$prref"; fi
    fi
    if ! _ps_sha "$g" "$head" >/dev/null; then
      PS_FETCH_ERR=$(printf '%s\n' "${_PS_ERR:-$head is not a commit after the fetch}" | _ps_redact)
      [ -n "${_PS_MAIN_FETCHED[$g]:-}" ] && PS_FETCH_MAIN=1
      return 1
    fi
    _PS_FETCHED[$g|$head]=1
  fi
  # The reviewed sha may be gone from the remote (a force-push). In the main-merge
  # case it is an ancestor of <head> and arrived with it, so this is best-effort.
  if [ -n "$rev" ] && ! _ps_sha "$g" "$rev" >/dev/null; then
    _ps_fetch "$g" "$rev" || { [ -n "$prref" ] && _ps_fetch "$g" "$prref"; }
  fi
  [ -n "${_PS_MAIN_FETCHED[$g]:-}" ] && PS_FETCH_MAIN=1
  _PS_ERR=""
  return 0
}
