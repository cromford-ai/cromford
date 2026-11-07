#!/bin/bash
# tests/triage-map-test.sh — bin/triage-map.sh renders the harness's own map from
# REAL sources, and its capability claims are probed, never assumed.
#
# What is actually at stake here. The map is injected into two autonomous triage
# lanes' prompts, so a wrong line is not a cosmetic bug: a stale FLEET row sends
# a lane ssh-ing at a box that no longer owns the project, and — the expensive
# one — a wrong CAPABILITIES line either sends it hunting a tool this host does
# not have (the 8-turn Railway dead end that motivated the whole change) or
# talks it out of a fix it could have made. Hence the two properties this file
# pins down: every fact is DERIVED (edit the source, the output moves), and a
# probe that cannot answer says UNKNOWN rather than guessing either way.
# Run from anywhere: tests/triage-map-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
MAP="$DIR/bin/triage-map.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/stub"
cp "$DIR/tests/fixtures/fleet-map.conf" "$T/fleet.conf"

# render against the fixture registry, with $T/stub first on PATH so a probe's
# answer can be flipped without touching the machine.
render() { FLEET_CONF="$T/fleet.conf" HARNESS=/root/harness PATH="$T/stub:$PATH" "$MAP" render 2>/dev/null; }

# ---------- 1. the fleet roster comes out of fleet.conf ----------------------
OUT=$(render)
grep -qF 'alpha-os | Acme/alpha-os | https://alpha.example/api/board | box-alpha' <<<"$OUT" \
  && ok || bad "alpha-os row not rendered from the fixture (got: $(grep -F 'alpha-os' <<<"$OUT"))"
# beta-os has no prod URL and no board prefix — it must say so, not concatenate "--"
grep -qF 'beta-os | Acme/beta-os | no board API' <<<"$OUT" \
  && ok || bad "beta-os boardless row mis-rendered (got: $(grep -F 'beta-os' <<<"$OUT"))"
# and its box comes from the explicit 6th column, not the naming convention
grep -qF 'beta-os | Acme/beta-os | no board API (see prompts/beta-os.md) | box-beta' <<<"$OUT" \
  && ok || bad "beta-os box column not honoured"
# the delimiter header and footer are what the lanes' prompts key on
grep -q '^=== HARNESS ORIENTATION' <<<"$OUT" && grep -q '^=== END HARNESS ORIENTATION ===$' <<<"$OUT" \
  && ok || bad "delimiter header/footer missing"
# the four sections all rendered
for S in FLEET GEOGRAPHY RECIPES CAPABILITIES; do
  grep -q "^$S" <<<"$OUT" || bad "section $S missing"
done
ok

# ---------- 2. DERIVED, not hardwired: edit the source, the output moves -----
# The whole doctrine is that a hand-written map goes stale and then lies. If the
# renderer had the roster baked in, everything above would still pass.
sed 's|Acme/alpha-os|Acme/alpha-renamed|' "$T/fleet.conf" > "$T/fleet.conf.new" && mv "$T/fleet.conf.new" "$T/fleet.conf"
OUT2=$(render)
grep -qF 'Acme/alpha-renamed' <<<"$OUT2" && ! grep -qF 'Acme/alpha-os' <<<"$OUT2" \
  && ok || bad "editing fleet.conf did not change the rendered roster — the map is hardwired"
# a project added to the registry appears without touching the renderer
printf 'gamma-os   Acme/gamma-os   https://gamma.example  /api/g  7 box-gamma\n' >> "$T/fleet.conf"
grep -qF 'gamma-os | Acme/gamma-os | https://gamma.example/api/g | box-gamma' <<<"$(render)" \
  && ok || bad "a new fleet.conf row did not appear in the map"

# ---------- 3. capability probes are probes ---------------------------------
# (a) presence axis. `railway` is the tool the 8-turn dead end went looking for.
unset RAILWAY_TOKEN
grep -q '^  CANNOT: railway' <<<"$(render)" \
  && ok || bad "railway absent + no token must render CANNOT (got: $(grep -i railway <<<"$(render)"))"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/railway"; chmod +x "$T/stub/railway"
OUT3=$(RAILWAY_TOKEN=tok render)
grep -q '^  CAN: railway' <<<"$OUT3" \
  && ok || bad "railway on PATH + token must flip to CAN (got: $(grep -i railway <<<"$OUT3"))"
rm -f "$T/stub/railway"

# (b) credential axis. gh is on this machine or it is not; either way the stub
# decides, and the two answers must differ.
printf '#!/bin/sh\nexit 0\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
grep -q '^  CAN: gh (CLI present, authed' <<<"$(render)" \
  && ok || bad "gh present + auth token exit 0 must render CAN"
printf '#!/bin/sh\nexit 1\n' > "$T/stub/gh"
GH_OUT=$(render)
grep -q '^  CANNOT: gh' <<<"$GH_OUT" \
  && ok || bad "gh's documented not-logged-in exit (1) must render CANNOT (got: $(grep -i ' gh ' <<<"$GH_OUT"))"

# ---------- 4. an inconclusive probe says UNKNOWN, never a false claim -------
# gh exiting something other than 0/1 means the probe failed, not that we are
# logged out. Rendering CANNOT there would talk the lane out of a PR lookup it
# can actually do; rendering CAN would send it at a 403. Only UNKNOWN is honest.
printf '#!/bin/sh\necho "unexpected garbage" >&2\nexit 42\n' > "$T/stub/gh"
UNK=$(render)
grep -q '^  UNKNOWN: gh (probe failed)' <<<"$UNK" \
  && ok || bad "a probe that errors must render UNKNOWN (got: $(grep -i 'gh' <<<"$UNK" | head -1))"
! grep -qE '^  (CAN|CANNOT): gh ' <<<"$UNK" \
  && ok || bad "an inconclusive gh probe must not ALSO render a CAN/CANNOT claim"
rm -f "$T/stub/gh"

# ---------- 5. a probe must read what its CONSUMER reads --------------------
# The fly lane is the worked example. bin/fly-api.sh:37-41 sources
# $HARNESS/env/fly.env and dereferences a per-app FLY_API_TOKEN_<PROJECT>; it
# never reads a bare FLY_API_TOKEN, and the triage lanes source only global.env.
# So probing the bare name renders CANNOT on a host whose fly pool works — and a
# false CANNOT is the harmful direction, because the block's whole contract is
# that a CANNOT is a settled dead end rather than "go check".
mkdir -p "$T/hp/env"
# flyctl is on the hub and not on a CI runner; stub it so these assertions are
# about the CREDENTIAL probe, which is the thing that was wrong.
printf '#!/bin/sh\nexit 0\n' > "$T/stub/fly"; chmod +x "$T/stub/fly"
render_h() { FLEET_CONF="$T/fleet.conf" HARNESS="$T/hp" PATH="$T/stub:$PATH" "$MAP" render 2>/dev/null; }
# A PATH with NO fly/flyctl on it at all, for the off-PATH assertions below.
# (This machine and the hub both have one somewhere; the fixture must not.)
render_bare() { FLEET_CONF="$T/fleet.conf" HARNESS="$T/hp" HOME="$T/home" PATH="/usr/bin:/bin" "$MAP" render 2>/dev/null; }
mkdir -p "$T/home"
rm -f "$T/hp/env/fly.env"
grep -q '^  CANNOT: fly' <<<"$(render_h)" \
  && ok || bad "no env/fly.env must render CANNOT for fly"
printf 'FLY_API_TOKEN_PROJECT_2_OS=fm2_redacted\n' > "$T/hp/env/fly.env"
FLYOUT=$(render_h)
grep -q '^  CAN: fly' <<<"$FLYOUT" \
  && ok || bad "env/fly.env with a per-app token must render CAN (got: $(grep -i ' fly ' <<<"$FLYOUT"))"
# the file existing is not enough — the consumer needs the per-app var
printf 'SOMETHING_ELSE=1\n' > "$T/hp/env/fly.env"
grep -q '^  CANNOT: fly' <<<"$(render_h)" \
  && ok || bad "an env/fly.env without a FLY_API_TOKEN_<PROJECT> line must render CANNOT"
# and a BARE FLY_API_TOKEN must not rescue it: nothing consumes that name
rm -f "$T/hp/env/fly.env"
grep -q '^  CANNOT: fly' <<<"$(FLY_API_TOKEN=bare render_h)" \
  && ok || bad "a bare FLY_API_TOKEN has no consumer and must not render CAN"

# The binary is PATH-BLIND, and the two arms are not the same capability.
# flyctl's installer puts it in ~/.fly/bin, which cron's PATH lacks — six scripts
# in this repo open with `export PATH="/root/.fly/bin:$PATH"` for exactly that
# reason. A `command -v` probe therefore said "no flyctl" on a host running a
# live fly pool, and ANDing that with the token arm produced a blanket CANNOT:
# a wrong dead end, which becomes a wrong escalation to the operator.
printf 'FLY_API_TOKEN_PROJECT_2_OS=fm2_redacted\n' > "$T/hp/env/fly.env"
mkdir -p "$T/home/.fly/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/home/.fly/bin/flyctl"; chmod +x "$T/home/.fly/bin/flyctl"
OFFP=$(render_bare)
grep -q '^  CAN: fly ' <<<"$OFFP" \
  && ok || bad "flyctl at ~/.fly/bin with tokens present must render CAN, not CANNOT (got: $(grep -i ' fly' <<<"$OFFP" | head -1))"
# the orientation value IS the path — a CAN that does not say where the binary
# is leaves the session to rediscover it, which is the turn this line exists to save
grep -qF "flyctl at $T/home/.fly/bin/flyctl" <<<"$OFFP" \
  && ok || bad "the off-PATH CAN line must NAME the full path (got: $(grep -i 'CAN: fly' <<<"$OFFP"))"
grep -q 'NOT on PATH' <<<"$OFFP" \
  && ok || bad "the off-PATH CAN line must say the binary is not on PATH"

# tokens but no binary anywhere: still CAN, because bin/fly-api.sh (machine
# start/stop/state) is pure curl + per-app token with zero flyctl references.
# The caveat names what is genuinely unavailable instead of denying the whole lane.
rm -rf "$T/home/.fly"
APIONLY=$(render_bare)
grep -q '^  CAN: fly API ' <<<"$APIONLY" \
  && ok || bad "tokens with no flyctl must still render CAN for the API path (got: $(grep -i ' fly' <<<"$APIONLY" | head -1))"
grep -q 'dispatch/pool/image ops that shell out to it are NOT available' <<<"$APIONLY" \
  && ok || bad "the API-only CAN must carry the caveat about flyctl-dependent ops"

# no tokens: CANNOT, and it is the TOKEN arm that says so — a binary cannot
# authenticate without one either, so this is the honest blanket case.
rm -f "$T/hp/env/fly.env"
mkdir -p "$T/home/.fly/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/home/.fly/bin/flyctl"; chmod +x "$T/home/.fly/bin/flyctl"
grep -q '^  CANNOT: fly (' <<<"$(render_bare)" \
  && ok || bad "no FLY_API_TOKEN_<PROJECT> must render CANNOT even with flyctl present"
rm -rf "$T/home/.fly"

# vercel: no script in this harness shells out to a vercel CLI or reads
# VERCEL_TOKEN. The real deploy path is a per-project DEPLOY_HOOK_URL, read by
# bin/deploy-verify.sh:29 and bin/deploy-train.sh:36 — so that is what is probed.
rm -f "$T/hp/env"/*.env
grep -q '^  CANNOT: vercel deploys' <<<"$(VERCEL_TOKEN=tok render_h)" \
  && ok || bad "VERCEL_TOKEN has no consumer and must not render CAN for deploys"
printf 'DEPLOY_HOOK_URL=https://api.vercel.com/v1/integrations/deploy/x\n' > "$T/hp/env/project-1.env"
grep -q '^  CAN: vercel deploys' <<<"$(render_h)" \
  && ok || bad "a project env with DEPLOY_HOOK_URL must render CAN for deploys"

# ---------- 6. the PROBE's own error path has the same three outcomes -------
# have_env_file used to report a grep that ERRORED as "absent" — a confident no
# from a probe that never answered. That is the identical defect the fly probe
# had, one call deeper: the only reason it was not a second wrong CANNOT is that
# grep rarely errors, and rarely is not never. A probe's error path needs the
# same three outcomes as the thing it probes.
#
# THE VECTOR MATTERS, and most candidates are wrong. It must be an unterminated
# bracket `[` — a hard regex error, exit 2 on BSD and GNU alike (POSIX requires
# >1 on error). NOT any old malformed pattern: BSD grep treats invalid
# REPETITION (`a\{2,1\}`) as a plain no-match, exit 1. Nor a directory in place
# of the file — also exit 1 on BSD. Either of those would make this assertion
# red on a Mac and green in CI, which is worse than not testing it at all.
# Verified on this machine: `[` -> 2, `a\{2,1\}` -> 1, directory -> 1.
#
# The probes are pulled out of the script (everything above its dispatch) and
# run for real, the same extract-and-execute idiom tests/triage-map-injection-
# test.sh uses — no reimplementation of the function under test.
python3 - "$MAP" "$T/probes.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(src[:src.index('case "${1:-render}"')])
PY
[ -s "$T/probes.sh" ] && ok || bad "could not extract the probe helpers from triage-map.sh"
printf 'FLY_API_TOKEN_PROJECT_2_OS=fm2_redacted\n' > "$T/hp/env/fly.env"
probe_with() {  # probe_with <pattern> -> yes|no|unknown
  bash -c 'set -uo pipefail; . "$1"; run_probe have_env_file "$2" "$3"' _ \
    "$T/probes.sh" "$T/hp/env/fly.env" "$1" 2>/dev/null
}
[ "$(probe_with '[')" = unknown ] \
  && ok || bad "an ERRORED probe must render UNKNOWN, not a confident absent — grep rc=2 is not 'the token is missing' (got: $(probe_with '['))"
# the two working answers must still work, or the hardening broke the probe
[ "$(probe_with '^FLY_API_TOKEN_')" = yes ] \
  && ok || bad "a matching pattern must still answer yes"
[ "$(probe_with '^NOT_A_REAL_VAR_')" = no ] \
  && ok || bad "a genuinely absent var must still answer no, not unknown"

# ---------- 7. contract: cheap, quiet, and never leaks a secret -------------
# It is rendered on every triage tick, so it may not be slow, and it prints into
# an LLM prompt, so it may not print a token. `gh auth token` is one of its
# probes — the output of that probe is discarded on purpose.
START=$(date +%s)
render >/dev/null
[ $(( $(date +%s) - START )) -le 2 ] && ok || bad "render must stay under a couple of seconds"
SECRET_OUT=$(GH_TOKEN=ghp_do_not_print SENTRY_API_TOKEN=sntrys_do_not_print HARNESS_SECRET=hs_do_not_print render)
! grep -qE 'ghp_do_not_print|sntrys_do_not_print|hs_do_not_print' <<<"$SECRET_OUT" \
  && ok || bad "a credential VALUE reached the rendered map"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
