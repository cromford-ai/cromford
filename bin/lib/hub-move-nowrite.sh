#!/bin/bash
# bin/lib/hub-move-nowrite.sh — the no-write mode of bin/hub-move.sh tick: a
# PATH shim directory that lets reads through and refuses each write a guarded
# binary makes when it is called by name (BH-7715).
#
# Sourced. One function:
#   hmn_make_dir <dir>
#       write <dir>/.hmn-dispatch and one symlink per guarded name into <dir>,
#       then print `PATH=<dir>:$PATH` on stdout. rc 2 on an empty dir or a dir
#       that cannot be written.
#
# Each guarded call appends one TSV line to $HUB_MOVE_NOWRITE_LOG (default
# <dir>/nowrite.log): `<epoch>\t<name>\t<allow|refuse>\t<argv>`. A refusal
# prints `hub-move nowrite: refused <name> <verb>` on stderr and exits 75. It
# never runs the real binary. An allowed call execs the first <name> on PATH
# that is not in <dir>. No real binary = rc 127, as a shell would answer.
#
# Decision rule (docs/notes/2026-10-20-BH-7715-hub-move.md has the table):
#   gh      allow: api with no -X/--method other than GET/HEAD and no
#                  -f/-F/--field/--raw-field/--input; pr view|list|diff|checks|
#                  status; issue view|list; run view|list; repo view; auth status.
#           refuse: everything else.
#   curl    allow: no -X/--request other than GET/HEAD and no -d/--data*/-F/
#                  --form*/--json/-T/--upload-file. refuse: everything else.
#   git     refuse: push, send-email, remote set-url. allow: everything else.
#   flyctl, fly  allow: status, machine list|status, apps list, volumes list,
#                  version. refuse: everything else.
#   rsync   allow: no operand of the form host:path. refuse: any such operand.
#   wrangler, ssh, scp, claude, codex: refuse always.
#   aws, npx: refuse always (lead BLOCK #3203 on #7757). bin/state-backup.sh
#           runs `aws s3api` on every hub tick and would write the live backup
#           bucket; bin/harness-sync.sh runs `npx --yes wrangler`, which never
#           calls the wrangler shim.
#
# Not a sandbox: the shim sees only a binary called BY NAME through PATH. A
# binary called by its absolute path, or a script that resets PATH, walks past
# it (bin/hub-move.sh sets FLEET_PROPAGATE_PATH for the one lane that resets
# PATH). bin/lane-shims/_fence.sh is a different tool: it guards only the five
# iron laws and fails open, so it is not a no-write mode.

HMN_NAMES="gh curl git flyctl fly rsync wrangler ssh scp claude codex aws npx"

hmn_make_dir() {
  local dir="${1:-}" n
  [ -n "$dir" ] || { echo "hmn_make_dir: no dir" >&2; return 2; }
  mkdir -p "$dir" 2>/dev/null || { echo "hmn_make_dir: cannot create $dir" >&2; return 2; }
  dir=$(cd "$dir" && pwd) || return 2
  _hmn_dispatcher "$dir" > "$dir/.hmn-dispatch.tmp" 2>/dev/null \
    && chmod 755 "$dir/.hmn-dispatch.tmp" \
    && mv -f "$dir/.hmn-dispatch.tmp" "$dir/.hmn-dispatch" \
    || { echo "hmn_make_dir: cannot write $dir/.hmn-dispatch" >&2; return 2; }
  for n in $HMN_NAMES; do
    ln -sfn .hmn-dispatch "$dir/$n" || return 2
  done
  printf 'PATH=%s:%s\n' "$dir" "$PATH"
}

# _hmn_dispatcher <dir> — the dispatcher script text, with <dir> baked in.
_hmn_dispatcher() {
  printf '#!/bin/bash\nHMN_DIR=%q\n' "$1"
  cat <<'DISPATCH'
set -u
name=$(basename "$0")
log="${HUB_MOVE_NOWRITE_LOG:-$HMN_DIR/nowrite.log}"

# decide <argv...> — print the refused verb and return 1, or return 0.
decide() {
  local a m verb
  case "$name" in
    gh)
      verb="${1:-}"
      case "$verb" in
        api)
          shift
          while [ $# -gt 0 ]; do
            a="$1"
            case "$a" in
              -X|--method) m=$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')
                           case "$m" in GET|HEAD) ;; *) echo "api -X $m"; return 1 ;; esac; shift ;;
              -X*) m=$(printf '%s' "${a#-X}" | tr '[:lower:]' '[:upper:]')
                   case "$m" in GET|HEAD) ;; *) echo "api -X $m"; return 1 ;; esac ;;
              --method=*) m=$(printf '%s' "${a#--method=}" | tr '[:lower:]' '[:upper:]')
                          case "$m" in GET|HEAD) ;; *) echo "api -X $m"; return 1 ;; esac ;;
              -f|-F|--field|--raw-field|--input|-f*|-F*|--field=*|--raw-field=*|--input=*)
                echo "api $a"; return 1 ;;
            esac
            shift
          done
          return 0 ;;
        pr)    case "${2:-}" in view|list|diff|checks|status) return 0 ;; esac ;;
        issue) case "${2:-}" in view|list) return 0 ;; esac ;;
        run)   case "${2:-}" in view|list) return 0 ;; esac ;;
        repo)  case "${2:-}" in view) return 0 ;; esac ;;
        auth)  case "${2:-}" in status) return 0 ;; esac ;;
      esac
      echo "$verb ${2:-}"; return 1 ;;
    curl)
      while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
          -X|--request) m=$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')
                        case "$m" in GET|HEAD) ;; *) echo "-X $m"; return 1 ;; esac; shift ;;
          -X*) m=$(printf '%s' "${a#-X}" | tr '[:lower:]' '[:upper:]')
               case "$m" in GET|HEAD) ;; *) echo "-X $m"; return 1 ;; esac ;;
          --request=*) m=$(printf '%s' "${a#--request=}" | tr '[:lower:]' '[:upper:]')
                       case "$m" in GET|HEAD) ;; *) echo "-X $m"; return 1 ;; esac ;;
          --data|--data*|--form|--form*|--json|--json=*|--upload-file|--upload-file=*)
            echo "$a"; return 1 ;;
          --*) ;;
          -?*)
            # Short flags may be joined (-sd x, -sXPOST): read them one by one.
            local i c rest
            for (( i=1; i<${#a}; i++ )); do
              c="${a:i:1}"
              case "$c" in
                d|F|T) echo "-$c"; return 1 ;;
                X) rest="${a:i+1}"; [ -n "$rest" ] || { rest="${2:-}"; shift; }
                   m=$(printf '%s' "$rest" | tr '[:lower:]' '[:upper:]')
                   case "$m" in GET|HEAD) ;; *) echo "-X $m"; return 1 ;; esac
                   break ;;
              esac
            done ;;
        esac
        shift
      done
      return 0 ;;
    git)
      # Skip global options to reach the verb (-C <dir>, -c <k=v>, --git-dir=...).
      while [ $# -gt 0 ]; do
        case "$1" in
          -C|-c|--git-dir|--work-tree|--namespace) shift 2 ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      case "${1:-}" in
        push|send-email) echo "$1"; return 1 ;;
        remote) case "${2:-}" in set-url) echo "remote set-url"; return 1 ;; esac ;;
      esac
      return 0 ;;
    flyctl|fly)
      case "${1:-}" in
        status|version) return 0 ;;
        machine|machines|m) case "${2:-}" in list|ls|status) return 0 ;; esac ;;
        apps|app) case "${2:-}" in list|ls) return 0 ;; esac ;;
        volumes|volume|vol) case "${2:-}" in list|ls) return 0 ;; esac ;;
      esac
      echo "${1:-} ${2:-}"; return 1 ;;
    rsync)
      for a in "$@"; do
        case "$a" in
          -*) ;;
          *:*) case "${a%%:*}" in */*) ;; *) echo "remote $a"; return 1 ;; esac ;;
        esac
      done
      return 0 ;;
    *)
      echo "${1:-}"; return 1 ;;
  esac
}

verb=$(decide "$@"); rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\t%s\trefuse\t%s\n' "$(date +%s)" "$name" "$*" >> "$log" 2>/dev/null
  echo "hub-move nowrite: refused $name $verb" >&2
  exit 75
fi
printf '%s\t%s\tallow\t%s\n' "$(date +%s)" "$name" "$*" >> "$log" 2>/dev/null

# The real binary: the first <name> on PATH outside the shim dir.
IFS=: read -r -a dirs <<<"${PATH:-}"
for d in "${dirs[@]}"; do
  [ -n "$d" ] || continue
  [ "$(cd "$d" 2>/dev/null && pwd)" = "$HMN_DIR" ] && continue
  if [ -x "$d/$name" ] && [ ! -d "$d/$name" ]; then exec "$d/$name" "$@"; fi
done
echo "hub-move nowrite: $name: command not found" >&2
exit 127
DISPATCH
}
