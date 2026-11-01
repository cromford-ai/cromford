# shellcheck shell=bash
# owner: BH-7939.1
# bin/lib/vendor/fly-machines.sh — the fly-machines seam. BH-7939.1 adds its calls here.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1

# fly_machines_run_help <timeout_s> — print the help text of `fly machine run`
# (BH-8640: the pool's --rootfs-size flag probe). The flyctl binary is
# ${FLY:-fly}; the call is cut after <timeout_s> seconds (the caller's knob).
# In fake mode the answer is the seeded string `fly-machines.run_help` and no
# CLI runs. rc 2 bad vendor mode, rc 70 an unseeded fake, else the CLI's rc.
fly_machines_run_help() {
  local to="${1:-20}" mode out
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    out=$(vendor_fake fly-machines run_help) || return 70
    jq -r . <<<"$out"
    return 0
  fi
  vendor_call_log fly-machines run-help
  timeout "$to" "${FLY:-fly}" machine run --help 2>/dev/null
}
