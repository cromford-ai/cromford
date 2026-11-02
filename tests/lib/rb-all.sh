# tests/lib/rb-all.sh — the pipeline as ONE text, whatever state the split is in.
# Sourced by the suites that READ bin/run-build.sh, never executed. Not a suite:
# tests/*.sh does not glob tests/lib/.
#
# WHY FLATTEN AND NOT CONCATENATE (BH-478). The driver is being split into stage
# modules under bin/lib/rb/, one part at a time. Fifty-odd suites read the
# driver as a single file — some extract a block by its markers, some compare
# line numbers between two blocks, some count strings across the whole text. If
# they read the driver plus a pile of modules, the answer would depend on the
# order the parts of the split happened to merge. Flattening puts every moved
# body back exactly where its call site is, so the text these suites read is the
# pipeline in its ORIGINAL order at every state of the split: none moved, some
# moved, all moved. No merge order among the later parts can turn a suite red.
#
# The module list is read off the driver's own RB_MODULES= line, so the driver
# stays the single source of truth for which files hold stage bodies.
#
# The grammar, from the seam contract: a stage entry is `rb_<name>() {` at
# column 0 in one of the modules, closed by `} # end rb_<name>` at column 0, and
# the driver calls it as a line that is exactly `rb_<name>`. Anything else — a
# call with arguments, an indented call, a comment, an assignment — is not a
# call site and copies through untouched. A bare call no module defines copies
# through too: the flatten never invents text it cannot find.
#
# A module that OPENS a stage function and never closes it is an error, not a
# body that runs to EOF. Copying the rest of the module in would hand every
# reader suite a pipeline text nobody wrote, and the suites would report their
# own findings about it; so the flatten says which module and which function on
# stderr, removes the half-written output, and returns non-zero.
#
# A gates.d fragment call site (BH-8930) inside a stage body — a line that is
# exactly `. "$RB_GATES_D/<slug>.sh"`, slug [a-z0-9-]+ — is replaced by the
# fragment's marked block, from its `# >>> ` line through the matching `# <<< `
# line, so the text is the one the block had inline. A fragment that is missing
# or never closes its block is the same kind of error as an unclosed stage:
# stderr names the module, the call line and the fragment, and rb_all returns 1
# with no output file.
#
# No trap, no clock, no mktemp: the caller passes the output path out of its own
# scratch tree and owns its lifetime.
# shellcheck shell=bash

rb_all() { # rb_all <repo-dir> <out-file>  -> prints <out-file>; the pipeline as ONE text
  local repo="$1" out="$2" drv="$1/bin/run-build.sh" RB_MODULES="" line name mod hit
  eval "$(grep -m1 '^RB_MODULES=' "$drv")"
  : > "$out"
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^rb_[a-z_]+$ ]]; then
      name=$line; hit=""
      for mod in $RB_MODULES; do
        [ -r "$repo/bin/lib/rb/$mod.sh" ] || continue
        grep -q "^${name}() {\$" "$repo/bin/lib/rb/$mod.sh" || continue
        awk -v n="$name" -v gd="$repo/bin/lib/rb/gates.d" -v mod="bin/lib/rb/$mod.sh" '
              $0==n"() {"      { f=1; opened=1; next }
              $0=="} # end "n  { closed=1; exit }
              f && /^\. "\$RB_GATES_D\/[a-z0-9-]+\.sh"$/ {
                frag=$0; sub(/^\. "\$RB_GATES_D\//, "", frag); sub(/"$/, "", frag)
                in_=0; done_=0; blk=""
                while ((getline fl < (gd "/" frag)) > 0) {
                  if (!in_ && fl ~ /^# >>> /) { in_=1; blk=substr(fl, 7) }
                  if (in_) print fl
                  if (in_ && fl == "# <<< " blk) { done_=1; break }
                }
                close(gd "/" frag)
                if (!done_) {
                  print "rb_all: " mod " " n " calls [" $0 "] but bin/lib/rb/gates.d/" frag " is missing or never closes its block" > "/dev/stderr"
                  bad=1; exit 4
                }
                next
              }
              f
              END              { if (bad) exit 4; if (opened && !closed) exit 3 }' \
              "$repo/bin/lib/rb/$mod.sh" >> "$out"
        case $? in
          0) ;;
          4) rm -f "$out"; return 1 ;;
          *) echo "rb_all: bin/lib/rb/$mod.sh opens $name but never closes it" >&2
             rm -f "$out"; return 1 ;;
        esac
        hit=1; break
      done
      [ -n "$hit" ] || printf '%s\n' "$line" >> "$out"
    else
      printf '%s\n' "$line" >> "$out"
    fi
  done < "$drv"
  printf '%s\n' "$out"
}
