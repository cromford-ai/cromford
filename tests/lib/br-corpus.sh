# tests/lib/br-corpus.sh — the resolver's source as ONE file, for the suites
# that extract a br_* function by name (awk/sed `^name() {` … `^}`) and drive it.
# Sourced, never executed. Not a suite: tests/*.sh does not glob tests/lib/.
#
# WHY (BH-5241). Those suites read bin/blocked-resolver.sh. The bin/lib/br/
# split moves functions out of it one concern per PR, and a function that moved
# is no longer in the file they read. The corpus is the driver FIRST, then each
# top-level module in bin/lib/br/MODULES order, so an extraction finds a moved
# function in its module and a still-dark function (inline AND in a module) in
# the driver, exactly as before. Each later slice changes nothing here.
# shellcheck shell=bash

br_corpus() { # br_corpus <repo-root> <out-file> — rc 1 when the driver or a module is unreadable
  local root="$1" out="$2" m mods
  [ -r "$root/bin/blocked-resolver.sh" ] || return 1
  if [ -r "$root/bin/lib/br/MODULES" ]; then
    mods=$(grep -v '^#' "$root/bin/lib/br/MODULES" | sed 's|.*|bin/lib/br/&.sh|')
  else
    mods=$(cd "$root" && LC_ALL=C ls bin/lib/br/*.sh 2>/dev/null)
  fi
  cat "$root/bin/blocked-resolver.sh" > "$out" || return 1
  for m in $mods; do
    cat "$root/$m" >> "$out" || return 1
  done
}
