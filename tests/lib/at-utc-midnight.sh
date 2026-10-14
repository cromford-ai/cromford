#!/bin/bash
# tests/lib/at-utc-midnight.sh — run one suite as if it started just before
# 00:00Z. The repro tool for the day-stamp straddle (BH-6052).
#
# Usage:  tests/lib/at-utc-midnight.sh <suite> [lead_s]
#
# It puts a `date` shim first on PATH and runs `bash <suite>`. The shim clock
# starts <lead_s> seconds (default 10, so 23:59:50Z) before the next 00:00Z and
# then moves at real speed. The tool exits with the suite's own exit code.
#
# The shim moves only a plain read of now: `date`, `date -u`, `date +FMT`,
# `date -Iseconds`. A call with -d/--date, -r/--reference, -f/--file or
# -s/--set goes to the real date unchanged.
#
# Known limit: a relative `-d '5 days ago'`, and any clock read that is not the
# `date` command (printf %()T, python, node), see the real clock. A suite whose
# day read goes through one of those is not proven by this tool. A suite that
# rebuilds PATH from scratch does not see the shim at all.
#
# The offset is AT_MIDNIGHT_OFF (seconds, exported). It is also written into the
# shim, so a child that drops the environment still gets the same clock.
set -uo pipefail

suite=${1:-}
lead=${2:-10}
if [ -z "$suite" ] || [ ! -f "$suite" ]; then
  echo "usage: tests/lib/at-utc-midnight.sh <suite> [lead_s]" >&2
  exit 2
fi
case "$lead" in ''|*[!0-9]*) echo "at-utc-midnight: lead_s must be a whole number of seconds" >&2; exit 2 ;; esac

real_date=$(type -P date) || { echo "at-utc-midnight: no date on PATH" >&2; exit 2; }
now=$("$real_date" -u +%s) || exit 2
next=$(( (now / 86400 + 1) * 86400 ))
AT_MIDNIGHT_OFF=$(( next - lead - now ))
export AT_MIDNIGHT_OFF

shim=$(mktemp -d "${TMPDIR:-/tmp}/at-utc-midnight.XXXXXX") || exit 2
trap 'rm -rf "$shim"' EXIT

cat > "$shim/date" <<EOF
#!/bin/bash
# date shim from tests/lib/at-utc-midnight.sh: now + AT_MIDNIGHT_OFF.
real=$real_date
for a in "\$@"; do
  case "\$a" in
    -d|--date*|-r|--reference*|-f|--file*|-s|--set*) exec "\$real" "\$@" ;;
    --*) ;;
    -*)
      # A short-option cluster (-ud, -us). The text after -I is its argument
      # (-Iseconds), so it is not read as more options.
      opts=\${a#-}; opts=\${opts%%I*}
      case "\$opts" in *[drfs]*) exec "\$real" "\$@" ;; esac
      ;;
  esac
done
n=\$("\$real" +%s) || exit 1
exec "\$real" -d "@\$(( n + \${AT_MIDNIGHT_OFF:-$AT_MIDNIGHT_OFF} ))" "\$@"
EOF
chmod +x "$shim/date"

PATH="$shim:$PATH" bash "$suite"
exit $?
