# >>> bundle reason (BH-4859)
# pool_bundle_reason <rc> <stderr> -> ONE line saying why fly-envbundle.sh
# failed: its last FATAL message, else its last non-empty line, else that it
# said nothing. Control characters go (a tab or newline would split the queue
# row's reason), it is cut to 240 chars, and anything shaped like a credential
# is withheld. The bundler's die lines name variables, hosts and paths, never
# values; this is the backstop so a future one cannot leak into a queue row.
pool_bundle_reason() {
  local rc="${1:-1}" err="${2:-}" why
  why=$(printf '%s\n' "$err" | grep 'FATAL:' | tail -n 1 | sed 's/^.*FATAL: //')
  [ -n "$why" ] || why=$(printf '%s\n' "$err" | grep -v '^[[:space:]]*$' | tail -n 1)
  why=$(printf '%s' "$why" | tr -d '\000-\037' | cut -c1-240)
  [ -n "$why" ] || why="fly-envbundle.sh exited rc $rc and printed no reason"
  if grep -Eq 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|sk-ant-|sk-or-|=[A-Za-z0-9_./+-]{32,}' <<<"$why"; then
    why="reason withheld: the bundler's output looked like a credential"
  fi
  printf '%s\n' "$why"
}
# <<< bundle reason

