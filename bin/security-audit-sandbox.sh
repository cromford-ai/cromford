#!/bin/bash
# bin/security-audit-sandbox.sh — the OS sandbox that bin/security-audit.sh
# gives the security-audit skill for target-code execution (BH-7910).
#
# usage: security-audit-sandbox.sh --detect
#        security-audit-sandbox.sh --describe <mode>
#        security-audit-sandbox.sh <mode> <scratch> -- <cmd> [args...]
#
#   --detect     print the best mode this box has, in this order:
#                docker   (`docker info` rc 0)
#                unshare-n (`unshare -n true` or `unshare -rn true` rc 0)
#                none
#   --describe   print the exact controls of a mode, and what it does not do
#   <mode> ...   run one command in that mode, with cwd = <scratch>
#                docker:    docker run --rm --network none --memory <mem>k
#                           --cpus <cpus> --read-only --tmpfs /tmp
#                           -v <scratch>:/work -w /work <image> <cmd>
#                           (image: SA_SANDBOX_IMAGE, else sandbox_image in
#                           catalog/security-audit.conf)
#                unshare-n: a new network namespace (no network), env -i with
#                           PATH and HOME=<scratch> only, ulimit -v <mem> KiB,
#                           -t <cpu_s> s CPU, -f <file_kb> KiB file size
#                The caps are the conf keys sandbox_memory_kb (4194304),
#                sandbox_cpus (2), sandbox_cpu_s (1800) and sandbox_file_kb
#                (1048576); the value in brackets is the fallback when the
#                conf has no such key. SA_CONF names another conf.
#                none:      refuses (rc 3) and runs nothing
# Exit: the command's own rc; 2 usage; 3 mode none or a mode this box lacks.
# --detect uses shell builtins only, so a test can drive it with PATH stubs.
set -uo pipefail

SELF="${0%/*}"; [ "$SELF" != "$0" ] || SELF=.
CONF="${SA_CONF:-$SELF/../catalog/security-audit.conf}"

# shellcheck source=bin/lib/security-audit.sh
. "$SELF/lib/security-audit.sh" || { echo "security-audit-sandbox: cannot load bin/lib/security-audit.sh" >&2; exit 2; }

# load_caps — the caps from the conf keys; each literal is only the documented
# fallback of its key. Not run by --detect, which stays on shell builtins.
load_caps() {
  MEM_KB=$(sa_conf_get "$CONF" sandbox_memory_kb) || MEM_KB=4194304
  CPUS=$(sa_conf_get "$CONF" sandbox_cpus) || CPUS=2
  CPU_S=$(sa_conf_get "$CONF" sandbox_cpu_s) || CPU_S=1800
  FILE_KB=$(sa_conf_get "$CONF" sandbox_file_kb) || FILE_KB=1048576
}

usage() { sed -n '/^# usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; }

_docker_ok() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# _unshare_flags — "-n" or "-rn" (the box's root may lack CAP_SYS_ADMIN in its
# own namespace but may map itself in a new user namespace); rc 1 when neither.
_unshare_flags() {
  command -v unshare >/dev/null 2>&1 || return 1
  if unshare -n true >/dev/null 2>&1; then printf '%s' "-n"; return 0; fi
  if unshare -rn true >/dev/null 2>&1; then printf '%s' "-rn"; return 0; fi
  return 1
}

detect() {
  if _docker_ok; then echo docker; return 0; fi
  if _unshare_flags >/dev/null; then echo unshare-n; return 0; fi
  echo none
}

describe() {
  load_caps
  case "${1:-}" in
    docker) cat <<TXT
docker: network off (--network none), memory ${MEM_KB} KiB, ${CPUS} cpus, read-only root filesystem, /tmp is a tmpfs, the only writable mount is the scratch clone at /work. The environment is the image's own, nothing from this box.
TXT
      ;;
    unshare-n) cat <<TXT
unshare-n: network off (a new network namespace with only a down loopback), environment cleared (env -i, PATH and HOME=<scratch> only), ulimit -v ${MEM_KB} KiB memory, -t ${CPU_S} s CPU, -f ${FILE_KB} KiB per file. It does NOT make the rest of the filesystem read-only: a command can write outside the scratch clone with this box's file permissions.
TXT
      ;;
    none) cat <<'TXT'
none: the skill keeps leads at needs_validation and executes nothing; a valid pilot outcome, not a failure
TXT
      ;;
    *) echo "security-audit-sandbox: unknown mode '${1:-}'" >&2; return 2 ;;
  esac
}

run_in() { # run_in <mode> <scratch> -- <cmd...>
  local mode="$1" scratch="$2" image flags
  shift 2
  [ "${1:-}" = "--" ] || { usage >&2; return 2; }
  shift
  [ "$#" -gt 0 ] && [ -d "$scratch" ] || { usage >&2; return 2; }
  scratch=$(cd "$scratch" && pwd)
  load_caps
  case "$mode" in
    docker)
      _docker_ok || { echo "security-audit-sandbox: docker is not usable here" >&2; return 3; }
      image="${SA_SANDBOX_IMAGE:-}"
      [ -n "$image" ] || image=$(sa_conf_get "$CONF" sandbox_image)
      [ -n "$image" ] || { echo "security-audit-sandbox: no sandbox_image" >&2; return 2; }
      docker run --rm --network none --memory "${MEM_KB}k" --cpus "$CPUS" --read-only --tmpfs /tmp \
        -v "$scratch:/work" -w /work "$image" "$@"
      ;;
    unshare-n)
      flags=$(_unshare_flags) || { echo "security-audit-sandbox: unshare -n is not usable here" >&2; return 3; }
      ( cd "$scratch" || exit 2
        ulimit -v "$MEM_KB" -t "$CPU_S" -f "$FILE_KB" || exit 2
        exec env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$scratch" unshare "$flags" -- "$@" )
      ;;
    none)
      describe none >&2; return 3 ;;
    *) usage >&2; return 2 ;;
  esac
}

case "${1:-}" in
  --detect) detect ;;
  --describe) describe "${2:-}" ;;
  -h|--help) usage ;;
  docker|unshare-n|none) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; run_in "$@" ;;
  *) usage >&2; exit 2 ;;
esac
