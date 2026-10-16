#!/bin/bash
# bin/decompose-lint.sh — owns-overlap warning over the filed child bodies of
# one split (BH-6384). A WARNING, NOT A GATE: rc is 0 on every input except a
# usage error (rc 2).
#
# Usage: decompose-lint.sh <id>=<body-file> [<id>=<body-file>...]
#   Give the children in filing order. <id> is the child's key or number (the
#   line of children.txt); a body is the filed markdown, or the board lane's
#   HTML (children/child-<n>.html), which is read back to plain lines first.
#
# What it reads from each body:
#   Owns: <path>, <path>           the paths the child owns (the filer writes it
#                                  from the spec's `owns` field)
#   DEPENDS: <target> hard — ...   a hard link to an earlier child
#   Blocked-by: <t> (hard), ...    the same, on the board lane's text line
#
# Two children A (earlier) and B (later) overlap when a path of one equals a
# path of the other, or one is a directory prefix of the other (`src/x/` vs
# `src/x/a.ts`; `src/x.ts` vs `src/x.tsx` is not an overlap). The overlap is
# linked, and silent, when B carries a hard link whose target is A's id, or
# A's id's numeric suffix (`TK-142` -> `142`, matched whole, so `#14` never
# links `142`).
#
# Output, one line each:
#   DECOMPOSE_LINT owns-overlap <path> <idA> <idB>   an unlinked overlap
#   DECOMPOSE_LINT no-owns <id>                      a child it could not judge
#   DECOMPOSE_LINT ok <n> children                   every pair compared, none
#                                                    unlinked, nobody skipped
set -u
[ "$#" -ge 1 ] || { echo "usage: decompose-lint.sh <id>=<body-file> [<id>=<body-file>...]" >&2; exit 2; }
for a in "$@"; do
  case "$a" in *=*) [ -n "${a%%=*}" ] || { echo "decompose-lint: empty id in '$a'" >&2; exit 2; } ;;
    *) echo "decompose-lint: '$a' is not <id>=<body-file>" >&2; exit 2 ;; esac
done

# _plain <file> — the body as plain lines. The board lane's HTML is one <p> per
# paragraph with <br> between lines and &amp;/&lt;/&gt; escaped (fc-board.sh's
# _fcb_html); markdown passes through unchanged.
_plain() {
  sed -e 's#<br>#\n#g' -e 's#</\{0,1\}p>##g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' "$1"
}

IDS=(); OWNS=(); LINKS=(); SKIPPED=0
for a in "$@"; do
  id="${a%%=*}"; f="${a#*=}"
  body=""
  [ -r "$f" ] && body=$(_plain "$f")
  owns=$(printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Owns:[[:space:]]*//p' \
         | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d' | LC_ALL=C sort -u)
  links=$( { printf '%s\n' "$body" | sed -nE 's/^[[:space:]]*DEPENDS:[[:space:]]*#?([^[:space:]]+)[[:space:]]+hard([^[:alnum:]].*)?$/\1/p'
             printf '%s\n' "$body" | sed -n 's/^[[:space:]]*Blocked-by:[[:space:]]*//p' | tr ',' '\n' \
               | sed -nE 's/^[[:space:]]*#?([^[:space:]]+)[[:space:]]*\(hard\).*$/\1/p'
           } | LC_ALL=C sort -u)
  if [ -z "$owns" ]; then
    echo "DECOMPOSE_LINT no-owns $id"
    SKIPPED=$((SKIPPED + 1))
  fi
  IDS+=("$id"); OWNS+=("$owns"); LINKS+=("$links")
done

# _overlap <p> <q> — rc 0 when the two paths name the same file or one is a
# directory (trailing /) that holds the other.
_overlap() {
  [ "$1" = "$2" ] && return 0
  case "$1" in */) case "$2" in "$1"*) return 0 ;; esac ;; esac
  case "$2" in */) case "$1" in "$2"*) return 0 ;; esac ;; esac
  return 1
}

# _linked <links-of-B> <idA> — rc 0 when B names A as a hard blocker.
_linked() {
  local suf
  suf=$(printf '%s' "$2" | sed -nE 's/^.*[^0-9]([0-9]+)$/\1/p')
  grep -qxF -- "$2" <<<"$1" && return 0
  [ -n "$suf" ] && grep -qxF -- "$suf" <<<"$1" && return 0
  return 1
}

HITS=0; n=${#IDS[@]}
a=0
while [ "$a" -lt "$n" ]; do
  b=$((a + 1))
  while [ "$b" -lt "$n" ]; do
    if [ -n "${OWNS[a]}" ] && [ -n "${OWNS[b]}" ] && ! _linked "${LINKS[b]}" "${IDS[a]}"; then
      while IFS= read -r p; do
        while IFS= read -r q; do
          if _overlap "$p" "$q"; then
            # The longer path is the file both sides touch.
            [ "${#q}" -gt "${#p}" ] && hit="$q" || hit="$p"
            echo "DECOMPOSE_LINT owns-overlap $hit ${IDS[a]} ${IDS[b]}"
            HITS=$((HITS + 1))
          fi
        done <<<"${OWNS[b]}"
      done <<<"${OWNS[a]}"
    fi
    b=$((b + 1))
  done
  a=$((a + 1))
done
[ "$HITS" -eq 0 ] && [ "$SKIPPED" -eq 0 ] && echo "DECOMPOSE_LINT ok $n children"
exit 0
