# shellcheck shell=bash
# tests/lib/warmup-guard.bh-9783.sh — sourced, not run. BH-9783: the R0
# predicate of tests/fly-boot-api-key.bh-9718-test.sh.
#
# warmup_guard_ok <runner-file>: rc 0 when, inside `warm_up() {` .. `^}` of
# the file, the line right after the first line that is exactly `  load_env`
# is the APIKEY_MISSING guard (it holds `APIKEY_MISSING:-}" ] ||` and
# `return 1`). Rc 1 for no warm_up, no load_env, no guard, or a guard (or a
# blank line) anywhere else. A `local` line or a comment above load_env does
# not matter: only the line after load_env is read.
warmup_guard_ok() {
  local f="${1:-}"
  [ -r "$f" ] || return 1
  sed -n '/^warm_up() {/,/^}/p' "$f" | awk '
    after { nxt = $0; got = 1; exit }
    $0 == "  load_env" { after = 1 }
    END {
      if (!got) exit 1
      if (index(nxt, "APIKEY_MISSING:-}\" ] ||") && index(nxt, "return 1")) exit 0
      exit 1
    }'
}
