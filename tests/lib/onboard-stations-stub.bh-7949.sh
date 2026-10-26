# shellcheck shell=bash
# tests/lib/onboard-stations-stub.bh-7949.sh — a stub of bin/lib/onboard-stations.sh
# for tests/onboard-run.bh-7934-test.sh (ONBOARD_STATIONS_LIB points here).
# obs_register..obs_clone each append their name to $OBS_CALLS and print the
# globals they were given. Test knobs:
#   OBS_FAIL=<station>       that one prints $OBS_FAIL_LINE to stderr, returns 1
#   OBS_CANCEL_AT=<station>  that one cancels the running run through the
#                            worker's /__cancel test hook first
#   OBS_UNDEF=<station>      obs_<station> is not defined at all
_obs_stub() {
  local st="$1"
  echo "$st" >> "$OBS_CALLS"
  echo "obs_$st project=$PROJECT slug=$SLUG repo=$REPO box=$BOX prefix=$PREFIX base=$BASE prod=$PROD"
  if [ "${OBS_CANCEL_AT:-}" = "$st" ]; then curl -sS -X POST -d '{}' "$JOBS_URL/__cancel" >/dev/null; fi
  if [ "${OBS_FAIL:-}" = "$st" ]; then echo "${OBS_FAIL_LINE:-stub failure}" >&2; return 1; fi
  return 0
}
obs_register() { _obs_stub register; }
obs_prompt() { _obs_stub prompt; }
obs_label() { _obs_stub label; }
obs_box() { _obs_stub box; }
obs_clone() { _obs_stub clone; }
[ -z "${OBS_UNDEF:-}" ] || unset -f "obs_$OBS_UNDEF"
