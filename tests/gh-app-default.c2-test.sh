#!/bin/bash
# tests/gh-app-default.c2-test.sh — C2 (2026-09-24): a cron lane with no
# GH_TOKEN spends the GitHub App, not the operator's personal token.
#
# THE FINDING. Every box's gh keyring is logged in as operator, and the 48h ledger
# showed the lanes that never call gh_auth_for charging that PAT (`pat-default`):
# the blocked resolver ~12.5k calls, the tickets snapshot push ~8k, run-preplan
# ~4.5k, review-prs on most boxes. bin/ensure-box-gh-app-default.sh's GH_TOKEN
# snippet reaches interactive shells only, never cron.
#
# WHAT IS PINNED. bin/gh-ledger/gh — the first `gh` on every cron PATH — and
# gh_rest (bin/lib/gh-rest.sh) mint through bin/gh-token.sh when the caller holds
# no token and the target repo is a example-org one, so every lane defaults to the
# App without opting in:
#   1. a cron-shaped env (env -i: no profile, no .bashrc, GH_TOKEN unset) gets an
#      installation token on -R, a repos/ path, GraphQL owner/name and the cwd's
#      origin, and the ledger row names the App bucket, not pat-default;
#   2. what it must leave alone: a caller's own GH_TOKEN, a non-example-org or
#      unresolvable target, `gh auth token`, a mint that answered a PAT, an
#      unarmed box, the knob at 0, flags/gh-app-default-off, a call made from
#      inside a mint (GH_LEDGER_NO_APP — the recursion guard);
#   3. the escape: GH_USE_PAT=1 never mints and reads env/gh-pat when present;
#   4. gh_rest scopes the App token to its one call — the caller's shell has no
#      GH_TOKEN afterwards — and its own ledger row names the App bucket;
#   5. gh_ci_api's last rung asks the PAT (GH_USE_PAT=1) when the App read failed.
#
# Nothing touches the network: bin/gh-token.sh and the real gh are stubs.
# Run from anywhere: bash tests/gh-app-default.c2-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/gh-ledger" "$H/bin/lib" "$H/env" "$H/state/gh-app-tokens" "$H/flags" "$H/logs" \
         "$T/real" "$T/home" "$T/tmp" "$T/repo"
cp "$DIR/bin/gh-ledger/gh" "$H/bin/gh-ledger/gh"; chmod +x "$H/bin/gh-ledger/gh"
for f in gh-rest-ledger.sh gh-rest.sh gh-ci-read.sh deployment.sh; do cp "$DIR/bin/lib/$f" "$H/bin/lib/"; done
[ -r "$DIR/bin/lib/gh-app-default.sh" ] && cp "$DIR/bin/lib/gh-app-default.sh" "$H/bin/lib/"
: > "$H/env/github-app.env"
APPTOK="ghs_c2fixture0123456789"
# The token cache bin/gh-token.sh would have written: the ledger reads the
# installation id of the token in GH_TOKEN out of it (gh_quota_bucket).
jq -n --arg t "$APPTOK" '{repo:"example-org/x",token:$t,expires_at:"2099-01-01T00:00:00Z",installation_id:"4242"}' \
  > "$H/state/gh-app-tokens/example-org-x.json"

# bin/gh-token.sh — records its argv and the recursion marker, answers per mode.
cat > "$H/bin/gh-token.sh" <<STUB
#!/bin/bash
printf 'args=%s|noapp=%s\n' "\$*" "\${GH_LEDGER_NO_APP:-}" >> "$T/mints.txt"
case "\${TOKSTUB_MODE:-app}" in
  app)   printf '%s\n' "$APPTOK" ;;
  pat)   printf 'ghp_patfallback\n' ;;
  empty) exit 1 ;;
  hang)  sleep 30 & wait; printf '%s\n' "$APPTOK" ;;
esac
STUB
chmod +x "$H/bin/gh-token.sh"

# The real gh — records the token it was handed, prints a gh-shaped trace.
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
# The shim's one-off trace-format probe (`api rate_limit`) is not a call under test.
[ "$1 $2" = "api rate_limit" ] || printf 'argv=%s|tok=%s\n' "$*" "${GH_TOKEN:-}" >> "$GH_STUB_CALLS"
# GH_STUB_FAIL_APP=1: the App token is refused, any other identity answers (section 8).
if [ "${GH_STUB_FAIL_APP:-}" = 1 ]; then case "${GH_TOKEN:-}" in ghs_*) exit 1 ;; esac; fi
if [ "$1 $2" = "api -i" ]; then
  printf 'HTTP/2.0 200 OK\r\nx-ratelimit-remaining: 6100\r\nx-ratelimit-limit: 6600\r\nx-ratelimit-resource: core\r\n\r\n{"ok":true}'
  exit "${GH_STUB_RC:-0}"
fi
if [ "${GH_DEBUG:-}" = api ]; then
  cat >&2 <<'EOF'
* Request at 2026-09-24 21:00:00.000000 +0000 UTC m=+0.04
> GET /repos/example-org/x/pulls HTTP/1.1
< HTTP/2.0 200 OK
< X-Ratelimit-Limit: 6600
< X-Ratelimit-Remaining: 6000
< X-Ratelimit-Resource: core
< X-Ratelimit-Used: 600
* Request took 100ms
EOF
fi
echo OUT
exit "${GH_STUB_RC:-0}"
STUB
chmod +x "$T/real/gh"

git -C "$T/repo" init -q 2>/dev/null
git -C "$T/repo" remote add origin https://github.com/example-org/cwdrepo.git 2>/dev/null

# cronrun <cmd...> — the call as cron makes it: env -i, the shim first on PATH,
# no login profile and no GH_TOKEN. Extra env rides in CR_ENV ("K=V K=V").
cronrun() {
  : > "$T/calls.txt"; : > "$T/mints.txt"; rm -f "$H/state/gh-app-default.knobs"
  # shellcheck disable=SC2086
  (cd "$T/repo" && env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
     HARNESS="$H" HARNESS_ENV_DIR="$H/env" GH_STUB_CALLS="$T/calls.txt" ${CR_ENV:-} "$@") >/dev/null 2>"$T/err.txt"
}
tok_seen() { sed -n 's/.*|tok=//p' "$T/calls.txt" | tail -n 1; }
minted() { sed -n 's/^args=\([^|]*\)|.*/\1/p' "$T/mints.txt" | tail -n 1; }
ledger_buckets() { cat "$H"/state/gh-rest-ledger/*.tsv 2>/dev/null | awk -F'\t' '{print $10}' | sort -u | tr '\n' ' '; }

# ── 1. the cron-shaped env gets the App ─────────────────────────────────────
cronrun gh pr list -R example-org/x
[ "$(tok_seen)" = "$APPTOK" ] && ok || bad "1a: cron env, -R example-org/x: gh must run on the App token, saw '$(tok_seen)'"
[ "$(minted)" = "--min-life 600 example-org/x" ] && ok || bad "1b: the mint must be gh-token.sh --min-life 600 example-org/x, was '$(minted)'"
grep -q '|noapp=1$' "$T/mints.txt" && ok || bad "1c: the mint must carry GH_LEDGER_NO_APP=1 (recursion guard)"
B=$(ledger_buckets)
case "$B" in *app-4242*) ok ;; *) bad "1d: the ledger row must name the App bucket app-4242, got '$B'" ;; esac
case "$B" in *pat-default*) bad "1e: a call that ran on the App was ledgered as pat-default" ;; *) ok ;; esac

cronrun gh api repos/example-org/y/pulls/1
[ "$(minted)" = "--min-life 600 example-org/y" ] && ok || bad "1f: a repos/ path names the repo, minted '$(minted)'"
cronrun gh api graphql -f owner=example-org -f name=z -f 'query=query{x}'
[ "$(minted)" = "--min-life 600 example-org/z" ] && ok || bad "1g: GraphQL owner/name names the repo, minted '$(minted)'"
cronrun gh api graphql -f 'query=query{ repository(owner: "example-org", name: "q") { id } }'
[ "$(minted)" = "--min-life 600 example-org/q" ] && ok || bad "1h: repository(owner:,name:) in the query names the repo, minted '$(minted)'"
cronrun gh pr view 12
[ "$(minted)" = "--min-life 600 example-org/cwdrepo" ] && ok || bad "1i: no -R: the cwd's origin names the repo, minted '$(minted)'"
cronrun gh pr comment 5 --body https://github.com/Other/elsewhere/pull/1
[ "$(minted)" = "--min-life 600 example-org/cwdrepo" ] && ok || bad "1j: a URL in a --body value must not pick the repo, minted '$(minted)'"
cronrun gh pr view https://github.com/example-org/urlrepo/pull/3
[ "$(minted)" = "--min-life 600 example-org/urlrepo" ] && ok || bad "1k: a PR URL argument names the repo, minted '$(minted)'"
CR_ENV="GH_APP_DEFAULT_MIN_LIFE_S=1200" cronrun gh pr list -R example-org/x
[ "$(minted)" = "--min-life 1200 example-org/x" ] && ok || bad "1l: the min-life knob reaches the mint, was '$(minted)'"

# ── 2. what it must leave alone ─────────────────────────────────────────────
CR_ENV="GH_TOKEN=ghp_callerown" cronrun gh pr list -R example-org/x
[ "$(tok_seen)" = ghp_callerown ] && [ ! -s "$T/mints.txt" ] && ok || bad "2a: a caller's own GH_TOKEN is theirs (saw '$(tok_seen)', mints: $(wc -l < "$T/mints.txt"))"
cronrun gh api repos/operator/elsewhere
[ -z "$(tok_seen)" ] && [ ! -s "$T/mints.txt" ] && ok || bad "2b: a non-example-org owner keeps today's credential"
cronrun gh api user
[ -z "$(tok_seen)" ] && [ ! -s "$T/mints.txt" ] && ok || bad "2c: an unresolvable target keeps today's credential"
cronrun gh auth token
[ ! -s "$T/mints.txt" ] && ok || bad "2d: \`gh auth token\` must never mint (it is the PAT ladder's last rung)"
CR_ENV="TOKSTUB_MODE=pat" cronrun gh pr list -R example-org/x
[ -z "$(tok_seen)" ] && ok || bad "2e: a mint that answered a PAT must leave GH_TOKEN empty, saw '$(tok_seen)'"
scratch_rm "$H/state/gh-app-default.fail"   # 2e's failure stamp (section 6) would hold example-org/x for 60s
CR_ENV="GH_APP_DEFAULT=0" cronrun gh pr list -R example-org/x
[ -z "$(tok_seen)" ] && [ ! -s "$T/mints.txt" ] && ok || bad "2f: GH_APP_DEFAULT=0 is today's call"
touch "$H/flags/gh-app-default-off"
cronrun gh pr list -R example-org/x
[ -z "$(tok_seen)" ] && [ ! -s "$T/mints.txt" ] && ok || bad "2g: flags/gh-app-default-off is today's call"
rm -f "$H/flags/gh-app-default-off"
CR_ENV="GH_LEDGER_NO_APP=1" cronrun gh api repos/example-org/x
[ ! -s "$T/mints.txt" ] && ok || bad "2h: a call from inside a mint (GH_LEDGER_NO_APP=1) must never mint again"
mv "$H/env/github-app.env" "$H/env/github-app.env.off"
cronrun gh pr list -R example-org/x
[ ! -s "$T/mints.txt" ] && ok || bad "2i: an unarmed box (no env/github-app.env) must not even run gh-token.sh"
mv "$H/env/github-app.env.off" "$H/env/github-app.env"
CR_ENV="GH_APP_DEFAULT_OWNERS=acme,example-org" cronrun gh api repos/ACME/w
[ "$(minted)" = "--min-life 600 ACME/w" ] && ok || bad "2j: the owners knob is a case-insensitive list, minted '$(minted)'"

# ── 3. the escape hatch ─────────────────────────────────────────────────────
CR_ENV="GH_USE_PAT=1" cronrun gh api repos/example-org/x/hooks
[ -z "$(tok_seen)" ] && [ ! -s "$T/mints.txt" ] && ok || bad "3a: GH_USE_PAT=1 never mints (no env/gh-pat: the keyring, as before)"
printf '# the box PAT\nGH_TOKEN="ghp_filepat"\n' > "$H/env/gh-pat"; chmod 600 "$H/env/gh-pat"
CR_ENV="GH_USE_PAT=1" cronrun gh api repos/example-org/x/hooks
[ "$(tok_seen)" = ghp_filepat ] && [ ! -s "$T/mints.txt" ] && ok || bad "3b: GH_USE_PAT=1 reads env/gh-pat once the keyring is gone, saw '$(tok_seen)'"
rm -f "$H/env/gh-pat"

# ── 4. gh_rest: the App for one call, and an honest ledger row ──────────────
scratch_rm "$H/state/gh-rest-ledger"; : > "$T/calls.txt"; : > "$T/mints.txt"; rm -f "$H/state/gh-app-default.knobs"
OUT=$(cd "$T/repo" && env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
  HARNESS="$H" HARNESS_ENV_DIR="$H/env" GH_STUB_CALLS="$T/calls.txt" bash -c '
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    gh_rest GET repos/example-org/x/pulls/1 >/dev/null; rc=$?
    printf "rc=%s after=%s" "$rc" "${GH_TOKEN-<unset>}"' 2>/dev/null)
case "$OUT" in "rc=0 after=<unset>") ok ;; *) bad "4a: gh_rest must succeed and leave the caller with no GH_TOKEN, got '$OUT'" ;; esac
[ "$(tok_seen)" = "$APPTOK" ] && ok || bad "4b: gh_rest's request must go out on the App token, saw '$(tok_seen)'"
B=$(ledger_buckets)
case "$B" in *app-4242*) ok ;; *) bad "4c: gh_rest's ledger row must name app-4242, got '$B'" ;; esac
case "$B" in *pat-default*) bad "4d: gh_rest ledgered an App call as pat-default" ;; *) ok ;; esac

# ── 5. gh_ci_api: the PAT is the last rung, not the App twice ───────────────
: > "$T/calls.txt"; rm -f "$H/state/gh-app-default.knobs"
OUT=$(cd "$T/repo" && env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
  HARNESS="$H" HARNESS_ENV_DIR="$H/env" GH_STUB_CALLS="$T/calls.txt" GH_STUB_RC=1 bash -c '
    . "$HARNESS/bin/lib/gh-ci-read.sh" || exit 9
    GH_CI_READ_LOG=/dev/null gh_ci_api example-org/x "repos/example-org/x/actions/runners" >/dev/null; echo "rc=$? by=$GH_CI_READ_TOKEN"' 2>/dev/null)
N=$(wc -l < "$T/calls.txt" | tr -d ' ')
LASTTOK=$(tok_seen)
[ "$N" = 3 ] && [ -z "$LASTTOK" ] && ok || bad "5a: after the App read and the App retry fail, ONE read goes out with no App token (GH_USE_PAT), got $N calls, last tok '$LASTTOK' ($OUT)"

# ── 6. a failed mint is bounded and remembered (review of #2231) ────────────
# The mint sits in front of every cron gh call, so a hanging GitHub must cost
# one bounded wait, and then nothing for a minute: a per-slug failure stamp
# sends the next calls straight to today's credential.
scratch_rm "$H/state/gh-app-default.fail"
S0=$(date +%s)
CR_ENV="TOKSTUB_MODE=hang GH_APP_DEFAULT_MINT_TIMEOUT_S=2" cronrun gh pr list -R example-org/hang
S1=$(date +%s)
[ $((S1 - S0)) -lt 10 ] && ok || bad "6a: a hanging mint must be cut off by the mint timeout (took $((S1 - S0))s)"
[ -z "$(tok_seen)" ] && ok || bad "6b: a mint that timed out leaves the call on today's credential, saw '$(tok_seen)'"
ls "$H/state/gh-app-default.fail/" 2>/dev/null | grep -q hang && ok || bad "6c: a failed mint must leave a per-slug failure stamp"
# BH-6049: this call's mint timeout is 10 s, so a call that wrongly minted
# again would hang the full 10 s; the 5 s bound leaves room for a loaded runner.
# The knob cache would otherwise replay the first call's 2 s for 60 s.
rm -f "$H/state/gh-app-default.knobs"
S0=$(date +%s)
CR_ENV="TOKSTUB_MODE=hang GH_APP_DEFAULT_MINT_TIMEOUT_S=10" cronrun gh pr list -R example-org/hang
S1=$(date +%s)
[ ! -s "$T/mints.txt" ] && ok || bad "6d: inside the failure window the next call must not mint again"
[ $((S1 - S0)) -lt 5 ] && ok || bad "6e: inside the failure window the call falls back fast (took $((S1 - S0))s)"
cronrun gh pr list -R example-org/x
[ "$(tok_seen)" = "$APPTOK" ] && ok || bad "6f: the stamp is per slug — another repo still mints"
for f in "$H"/state/gh-app-default.fail/*; do printf '%s\n' "$(( $(date +%s) - 120 ))" > "$f"; done
cronrun gh pr list -R example-org/hang
[ -s "$T/mints.txt" ] && ok || bad "6g: once the failure window has passed the slug is minted for again"
scratch_rm "$H/state/gh-app-default.fail"
# The real minter's curls are bounded too: api_jwt and rate_log carry -m.
for fn in api_jwt rate_log; do
  body=$(sed -n "/^$fn() {/,/^}/p" "$DIR/bin/gh-token.sh")
  n_all=$(printf '%s\n' "$body" | grep -c 'curl ')
  n_m=$(grep -c 'curl -sS -m ' <<<"$body")
  [ "$n_all" -gt 0 ] && [ "$n_all" = "$n_m" ] && ok || bad "6h: every curl in gh-token.sh $fn must carry -m (bounded), $n_m of $n_all do"
done

# ── 7. the ledger switches do not bypass the identity (documented) ──────────
CR_ENV="GH_LEDGER_OFF=1" cronrun gh pr list -R example-org/x
[ "$(tok_seen)" = "$APPTOK" ] && ok || bad "7a: GH_LEDGER_OFF turns off the LEDGER, not the App identity (that is flags/gh-app-default-off)"
CR_ENV="GH_DEBUG=api" cronrun gh pr list -R example-org/x
[ "$(tok_seen)" = "$APPTOK" ] && ok || bad "7b: a caller's GH_DEBUG keeps its trace and still gets the App identity"

# ── 8. a fallback to the PAT is LOUD, once per slug per hour (lead review) ─
# A failed mint used to fall back silently: every caller drops gh-token.sh's
# stderr and the lib wrote nothing, so an expired App key or an uninstalled repo
# would quietly put the whole fleet back on the operator's PAT. Now a NEW failure stamp
# appends one ALERTS.log line naming the slug, rate-limited per slug by
# GH_APP_DEFAULT_ALERT_EVERY_S (default 3600), and gh_ci_api's PAT rung does the
# same. ALERTS.log is re-beaten by poll-commands.sh and bin/lib/alert-state.sh
# routes both lines to `warn` (the batched digest), never a page of its own.
AL="$H/logs/ALERTS.log"
alines() { grep -c "$1" "$AL" 2>/dev/null || true; }
: > "$AL"; scratch_rm "$H/state/gh-app-default.fail"; scratch_rm "$H/state/gh-app-default.alerted"
CR_ENV="TOKSTUB_MODE=empty" cronrun gh pr list -R example-org/alerty
[ "$(alines '\[gh-app-default\] APP MINT FAILED for example-org/alerty')" = 1 ] && ok \
  || bad "8a: a failed mint must append ONE ALERTS.log line naming the slug, got: $(cat "$AL" 2>/dev/null)"
grep -qE 'gh[spo]_[A-Za-z0-9]' "$AL" 2>/dev/null && bad "8b: a token value reached ALERTS.log" || ok
for f in "$H"/state/gh-app-default.fail/*; do printf '%s\n' "$(( $(date +%s) - 120 ))" > "$f"; done
CR_ENV="TOKSTUB_MODE=empty" cronrun gh pr list -R example-org/alerty
[ -s "$T/mints.txt" ] && [ "$(alines 'APP MINT FAILED for example-org/alerty')" = 1 ] && ok \
  || bad "8c: a second failure inside the hour mints again but does not alert again ($(alines 'APP MINT FAILED for example-org/alerty') lines)"
CR_ENV="TOKSTUB_MODE=empty" cronrun gh pr list -R example-org/other2
[ "$(alines 'APP MINT FAILED for example-org/other2')" = 1 ] && ok || bad "8d: the rate limit is per slug"
for f in "$H"/state/gh-app-default.fail/* "$H"/state/gh-app-default.alerted/*; do printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$f"; done
CR_ENV="TOKSTUB_MODE=empty" cronrun gh pr list -R example-org/alerty
[ "$(alines 'APP MINT FAILED for example-org/alerty')" = 2 ] && ok || bad "8e: after the hour the slug alerts again"
for f in "$H"/state/gh-app-default.fail/*; do printf '%s\n' "$(( $(date +%s) - 120 ))" > "$f"; done
for f in "$H"/state/gh-app-default.alerted/*; do printf '%s\n' "$(( $(date +%s) - 30 ))" > "$f"; done
CR_ENV="TOKSTUB_MODE=empty GH_APP_DEFAULT_ALERT_EVERY_S=10" cronrun gh pr list -R example-org/alerty
[ "$(alines 'APP MINT FAILED for example-org/alerty')" = 3 ] && ok || bad "8f: GH_APP_DEFAULT_ALERT_EVERY_S is the rate-limit knob"
grep -q '"GH_APP_DEFAULT_ALERT_EVERY_S"' "$DIR/catalog/lanes.d/_lib.gh-app-default.json" && ok \
  || bad "8g: the knob is registered in catalog/lanes.d/_lib.gh-app-default.json"
scratch_rm "$H/state/gh-app-default.fail"
# gh_ci_api's PAT rung: the App read and retry are refused, the PAT answers
: > "$AL"; : > "$T/calls.txt"; rm -f "$H/state/gh-app-default.knobs"
ci_pat() { (cd "$T/repo" && env -i PATH="$H/bin/gh-ledger:$T/real:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" \
  HARNESS="$H" HARNESS_ENV_DIR="$H/env" GH_STUB_CALLS="$T/calls.txt" GH_STUB_FAIL_APP=1 bash -c '
    . "$HARNESS/bin/lib/gh-ci-read.sh" || exit 9
    GH_CI_READ_LOG=/dev/null gh_ci_api example-org/cix "repos/example-org/cix/actions/runs" >/dev/null; echo "rc=$? by=$GH_CI_READ_TOKEN"' 2>/dev/null); }
OUT=$(ci_pat)
[ "$OUT" = "rc=0 by=pat" ] && ok || bad "8h: fixture: gh_ci_api must land on the PAT rung, got '$OUT'"
[ "$(alines '\[gh-ci-read\] PAT RUNG for example-org/cix')" = 1 ] && ok \
  || bad "8i: gh_ci_api taking the PAT rung must append one ALERTS.log line naming the slug, got: $(cat "$AL" 2>/dev/null)"
ci_pat >/dev/null
[ "$(alines 'PAT RUNG for example-org/cix')" = 1 ] && ok || bad "8j: the PAT-rung alert is rate-limited per slug"
# routed to warn by alert-state's shipped severity rules, not a page
mkdir -p "$T/as/flags"
for L in "[gh-app-default] APP MINT FAILED for example-org/alerty on hub: x" "[gh-ci-read] PAT RUNG for example-org/cix on hub: y"; do
  SEV=$(HARNESS="$T/as" bash -c '. "$1/bin/lib/alert-state.sh" 2>/dev/null; alert_state_route "$2" ""' _ "$DIR" "2026-09-24 12:00:00Z $L" 2>/dev/null)
  [ "$SEV" = warn ] && ok || bad "8k: alert-state must route '${L:0:40}…' to warn (the digest), got '$SEV'"
done

echo "gh-app-default.c2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
