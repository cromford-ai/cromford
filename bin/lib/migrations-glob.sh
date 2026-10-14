#!/bin/bash
# bin/lib/migrations-glob.sh — where a project keeps its migration SQL.
# Sourced (by bin/hotfix-migrate.sh, bin/scope-gate.sh and the MIGF alert in the
# reviewed-merge sweep), never executed.
#
# THE KNOB. The settings row migrations_glob.<project> holds a glob of the form
# <dir>/*.sql. No row means the fleet default, scripts/migrations/*.sql, which is
# what every reader used as a literal before this file. There is no fleet-wide
# row: the code default IS the fleet value.
#   Set it: bin/jobs-client.sh setting-set migrations_glob.<project> 'prisma/sql/*.sql'
#
# mg_glob <project>   prints the glob and sets MG_GLOB and MG_SRC. rc 0 always:
#   project empty or `-`    default, MG_SRC=no-project, no lookup
#   no setting_get          default, MG_SRC=no-client (after one on-demand source
#                           of bin/jobs-client.sh)
#   setting_get rc 2        default, MG_SRC=default (no row: a real answer)
#   setting_get rc 1        default, MG_SRC=unreadable, one stderr line
#   a value that is not <dir>/*.sql in a plain relative path
#                           default, MG_SRC=invalid, one stderr line
#   a valid value           that value, MG_SRC=migrations_glob.<project>
# AN UNREADABLE ROW FALLS BACK TO THE DEFAULT, it does not hold. The default is
# what every project got before the knob existed, so a worker outage changes
# nothing for any project; holding instead would stop every project's hotfix
# for the length of the outage. The stderr line says so, so it is never silent.
# THE VALUE IS VALIDATED because it reaches a git pathspec in hotfix-migrate
# (which SQL may go toward a production apply) and an ERE in the other readers:
# relative, no `..`, each component [A-Za-z0-9_][A-Za-z0-9_.-]*, then /*.sql.
#
# mg_dir <project>           the glob minus its /*.sql
# mg_dir_ere <dir>           <dir> with `.` escaped for grep -E (safe: the charset
#                            above leaves `.` as the only ERE metacharacter)
# mg_first_named <project> <file>...
#                            the first <dir>/<name>.sql path named in the files
# mg_path_in <glob> <path>   rc 0 when <path> matches <glob> the way git's
#                            :(glob) pathspec does: `*` never crosses `/`. The
#                            merge conductor's proof gate (mc_hotfix_proof) uses
#                            it, so its FP covers exactly the files
#                            bin/hotfix-migrate.sh fingerprints.
MG_DEFAULT='scripts/migrations/*.sql'
MG_GLOB=""; MG_SRC=""

_mg_ensure_client() {
  local h pf
  command -v setting_get >/dev/null 2>&1 && return 0
  h="${HARNESS:-${H:-}}"
  [ -n "$h" ] && [ -r "$h/bin/jobs-client.sh" ] || return 1
  pf=$(set -o 2>/dev/null | awk '$1=="pipefail"{print $2}')
  # shellcheck disable=SC1091
  . "$h/bin/jobs-client.sh" >/dev/null 2>&1 || true
  [ "$pf" = off ] && set +o pipefail
  command -v setting_get >/dev/null 2>&1
}

_mg_valid() {
  grep -qxE '[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*/\*\.sql' <<<"$1" || return 1
  case "/$1/" in */../*) return 1 ;; esac
  return 0
}

mg_glob() {
  local p="${1:-}" key v rc=0
  MG_GLOB="$MG_DEFAULT"; MG_SRC=""
  case "$p" in ''|-) MG_SRC=no-project; printf '%s\n' "$MG_GLOB"; return 0 ;; esac
  key="migrations_glob.$p"
  if ! _mg_ensure_client; then
    MG_SRC=no-client; printf '%s\n' "$MG_GLOB"; return 0
  fi
  v=$(setting_get "$key") || rc=$?
  case "$rc" in
    0) v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
       if _mg_valid "$v"; then MG_GLOB="$v"; MG_SRC="$key"
       else MG_SRC=invalid
         echo "migrations-glob: $key='$v' is not <dir>/*.sql in a plain relative path; using $MG_DEFAULT" >&2
       fi ;;
    2) MG_SRC=default ;;
    *) MG_SRC=unreadable
       echo "migrations-glob: $key unreadable (setting_get rc $rc); using $MG_DEFAULT" >&2 ;;
  esac
  printf '%s\n' "$MG_GLOB"
}

mg_dir() {
  mg_glob "${1:-}" >/dev/null
  printf '%s\n' "${MG_GLOB%/\*.sql}"
}

mg_dir_ere() {
  printf '%s\n' "${1//./\\.}"
}

mg_first_named() {
  local p="${1:-}" ere
  shift
  ere=$(mg_dir_ere "$(mg_dir "$p")")
  grep -hoE "$ere/[^ \`\"]+\.sql" "$@" 2>/dev/null | head -1
}

mg_path_in() {
  local dir="${1%/\*.sql}" path="${2:-}" rest
  case "$path" in "$dir"/*.sql) ;; *) return 1 ;; esac
  rest="${path#"$dir"/}"
  case "$rest" in */*) return 1 ;; esac
  return 0
}
