# >>> bake-evidence relay (BH-6259)
# The hub's pool-bake evidence (the `bake phases` lines of
# logs/fleet-propagate.log and the step timings of logs/fly-image-build/) exists
# only on the hub, and a cromford ticket about a slow bake is planned on a
# pool machine. bin/bake-evidence.sh prints a bounded digest of it, copied to
# /data/harness/state/bake-evidence.txt at dispatch. Only for the harness's own
# project: the pool's repo (POOL_SLUG, from bin/fleet-conf.sh) equals
# HARNESS_REPO (bin/lib/deployment.sh), so no project name is written here. Never
# fatal: no digest or a failed push costs the evidence, never the build.
push_bake_evidence() { # push_bake_evidence <machine-id>
  local mid="${1:-}" tmp rc=0 hrepo
  [ -n "$mid" ] && [ -n "${POOL_SLUG:-}" ] || return 0
  hrepo=$( . "$HARNESS/bin/lib/deployment.sh" 2>/dev/null && printf '%s' "${HARNESS_REPO:-}" )
  [ -n "$hrepo" ] && [ "${POOL_SLUG,,}" = "${hrepo,,}" ] || return 0
  [ -x "$HARNESS/bin/bake-evidence.sh" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/bake-ev-XXXX") || return 0
  HARNESS="$HARNESS" timeout 20 "$HARNESS/bin/bake-evidence.sh" > "$tmp" 2>/dev/null || rc=$?
  if [ "$rc" = 0 ] && [ -s "$tmp" ]; then
    if mput "$mid" "$tmp" /data/harness/state/bake-evidence.txt; then
      say "relayed the hub bake evidence to $mid"
    else
      say "$mid: bake-evidence push FAILED — this build plans without it"
    fi
  fi
  rm -f "$tmp"; return 0
}
# <<< bake-evidence relay

