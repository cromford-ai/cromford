#!/bin/bash
# tests/br-split-layout.bh-6517-test.sh — the per-ticket layout test for the
# BH-6517 slice (C0) of the bin/lib/br/ split: the build-record discovery
# sources move out of bin/blocked-resolver.sh into bin/lib/br/discovery.sh,
# byte for byte. tests/br-split-layout.bh-5241-test.sh (B1-B7) still judges the
# whole layout; this file pins what this slice adds.
#
#   D1  each of the 6 discovery functions is defined in discovery.sh exactly
#       once and in the driver zero times; the `br_fns` ceiling row is <= 144.
#   D2  discovery.sh answers alone, with inputs as the pipeline produces them;
#       the test corpus holds br_from_builds exactly once.
#   D3  br_candidates keeps its source order: rebuilds conductor queue builds
#       reviews, then the opt/ external source only when it is installed.
#   D4  no opt/ module defines a discovery name, and a seeded overlap is
#       REPORTED by name; D4b: the top-level module set == MODULES, no store.sh.
#   D5  the real driver ticks rc 0 from a scratch $HARNESS and sources
#       discovery.sh; with discovery.sh gone it refuses: rc 1 and ONE ALERTS line.
#   D6  with BR_SPLIT_BASE=<rev>: the names that left the driver are exactly the
#       6, and the conductor hand-off sources and br_from_reviews are still in
#       the driver (C1 and reviews are later slices). Env-gated like B5.
#
# Run from anywhere: tests/br-split-layout.bh-6517-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# shellcheck source=tests/lib/br-corpus.sh
. "$(dirname "$0")/lib/br-corpus.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BR="$REPO/bin/blocked-resolver.sh"
BRD="$REPO/bin/lib/br"
CEIL="$REPO/tests/br/driver-ceiling.tsv"
DISC="br_from_queue br_from_builds br_rebuild_outcome br_rebuild_artifact br_from_rebuilds br_candidates"
static_defs() { grep -oE '^br_[A-Za-z0-9_]*[(][)] [{]' "$1" | sed 's/[(].*//' | sort -u; }
ndefs() { grep -cE "^$1[(][)] [{]" "$2"; }

# ── D1. the discovery sources live in discovery.sh only ────────────────────
for n in $DISC; do
  c=$(ndefs "$n" "$BRD/discovery.sh" 2>/dev/null); [ "${c:-0}" = 1 ] && ok || bad "D1: $n is defined ${c:-0} times in bin/lib/br/discovery.sh, want 1"
  c=$(ndefs "$n" "$BR"); [ "$c" = 0 ] && ok || bad "D1: $n is still defined in the driver ($c times)"
done
MAXF=$(awk -F'\t' '$1=="br_fns"{print $2}' "$CEIL")
[ -n "$MAXF" ] && [ "$MAXF" -le 144 ] && ok || bad "D1: the br_fns ceiling row is '${MAXF:-absent}', want <= 144"

# ── D2. discovery.sh answers alone ──────────────────────────────────────────
GOT=$(bash -c '. "$0"; br_rebuild_outcome "BUILD_DEAD x"' "$BRD/discovery.sh" 2>&1)
[ "$GOT" = rebuild-build-dead ] && ok || bad "D2: br_rebuild_outcome 'BUILD_DEAD x' answered '$GOT', want rebuild-build-dead"
GOT=$(bash -c '. "$0"; br_rebuild_outcome "PR_CREATED https://github.com/o/r/pull/1"' "$BRD/discovery.sh" 2>&1)
[ "$GOT" = rebuild-landed ] && ok || bad "D2: br_rebuild_outcome PR_CREATED answered '$GOT', want rebuild-landed"
GOT=$(bash -c '. "$0" || exit 9; br_rebuild_outcome BUILD_DEFERRED; echo "rc=$?"' "$BRD/discovery.sh" 2>&1)
[ "$GOT" = "
rc=0" ] && ok || bad "D2: br_rebuild_outcome BUILD_DEFERRED answered '$GOT', want an empty word (not mine)"
GOT=$(bash -c '. "$0"; br_rebuild_artifact "PLAN_BLOCKED see /root/harness/builds/x/plan.md" PLAN_BLOCKED' "$BRD/discovery.sh" 2>&1)
[ "$GOT" = /root/harness/builds/x/plan.md ] && ok || bad "D2: br_rebuild_artifact with a 'see' path answered '$GOT'"
GOT=$(bash -c '. "$0"; br_rebuild_artifact REVIEW_BLOCKED REVIEW_BLOCKED' "$BRD/discovery.sh" 2>&1)
[ "$GOT" = review.md ] && ok || bad "D2: br_rebuild_artifact REVIEW_BLOCKED answered '$GOT', want review.md"
br_corpus "$REPO" "$T/br-corpus.sh" || bad "D2: br_corpus could not build the corpus"
c=$(ndefs br_from_builds "$T/br-corpus.sh"); [ "$c" = 1 ] && ok || bad "D2: the corpus defines br_from_builds $c times, want 1"

# ── D3. br_candidates keeps its source order ────────────────────────────────
STUBS='br_from_rebuilds() { echo rebuilds; }; br_from_conductor() { echo conductor; }
br_from_queue() { echo queue; }; br_from_builds() { echo builds; }; br_from_reviews() { echo reviews; }'
GOT=$(bash -c '. "$0"; eval "$1"; br_candidates' "$BRD/discovery.sh" "$STUBS" 2>&1 | tr '\n' ' ')
[ "$GOT" = "rebuilds conductor queue builds reviews " ] && ok \
  || bad "D3: br_candidates called '$GOT', want 'rebuilds conductor queue builds reviews '"
GOT=$(bash -c '. "$0"; eval "$1"; br_opt_external_candidates() { echo external; }; br_candidates' \
  "$BRD/discovery.sh" "$STUBS" 2>&1 | tr '\n' ' ')
[ "$GOT" = "rebuilds conductor queue builds reviews external " ] && ok \
  || bad "D3: with the external source installed br_candidates called '$GOT', want external last"

# ── D4. opt/ overlap is reported, never hidden ──────────────────────────────
# opt_overlap <br-dir> — one line per discovery name an opt/ module defines.
opt_overlap() {
  local f n
  for f in "$1"/opt/*.sh; do
    [ -e "$f" ] || continue
    for n in $DISC; do
      grep -qE "^[[:space:]]*(function[[:space:]]+)?${n}[[:space:]]*[(][)]" "$f" \
        && echo "overlap: $n is defined by discovery.sh AND ${f##*/opt/}"
    done
  done
  return 0
}
ls "$BRD"/opt/*.sh >/dev/null 2>&1 && ok || bad "D4: bin/lib/br/opt/ has no modules — the check would be vacuous"
OUT=$(opt_overlap "$BRD"); [ -z "$OUT" ] && ok || bad "D4: $OUT"
S="$T/d4"; mkdir -p "$S"; cp -r "$BRD/." "$S/"
f=$(LC_ALL=C ls "$S"/opt/*.sh | head -1)
printf 'br_from_queue() { :; }\n' >> "$f"
OUT=$(opt_overlap "$S"); grep -q 'br_from_queue' <<<"$OUT" && ok \
  || bad "D4: a seeded br_from_queue in opt/${f##*/opt/} was not reported (got '$OUT')"
# D4b. no recreated module, no second store
HAVE=$(cd "$BRD" && LC_ALL=C ls -- *.sh | sed 's/\.sh$//' | sort)
WANT=$(grep -v '^#' "$BRD/MODULES" | sort)
[ -n "$HAVE" ] && [ "$HAVE" = "$WANT" ] && ok \
  || bad "D4b: top-level modules ($(printf '%s' "$HAVE" | tr '\n' ' ')) are not bin/lib/br/MODULES ($(printf '%s' "$WANT" | tr '\n' ' '))"
[ ! -e "$BRD/store.sh" ] && ok || bad "D4b: bin/lib/br/store.sh exists — the record layer is record.sh, not a second store"

# ── D5. the production entry point, with and without discovery.sh ──────────
H="$T/h"
mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
for s in bin/blocked-resolver.sh bin/fleet-conf.sh bin/project-of.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "D5: could not install $s into the scratch harness"
done
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/gh" "$T/fakebin/flock"
[ -r "$H/bin/lib/br/discovery.sh" ] && ok || bad "D5: the scratch install has no bin/lib/br/discovery.sh"
printf 'printf %%s canary > "%s/discovery-sourced"\n' "$T" >> "$H/bin/lib/br/discovery.sh"
tick() {
  : > "$H/logs/ALERTS.log"
  ( unset HARNESS; export PATH="$T/fakebin:$PATH" GH_TOKEN=""
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/blocked-resolver.sh" nosuchproject ) > "$T/lane.out" 2>&1
}
tick; RC=$?
[ "$RC" -eq 0 ] && ok || bad "D5: the driver tick exited $RC: $(tail -3 "$T/lane.out" | tr '\n' ' ')"
[ -s "$T/discovery-sourced" ] && ok || bad "D5: the driver tick never sourced bin/lib/br/discovery.sh"
grep -q 'RESOLVER MODULE MISSING' "$H/logs/ALERTS.log" && bad "D5: a tick with every module present wrote a refusal" || ok
rm -f "$H/bin/lib/br/discovery.sh"
tick; RC=$?
[ "$RC" -eq 1 ] && ok || bad "D5: a tick without discovery.sh exited $RC, want 1 (refuse)"
c=$(grep -c 'RESOLVER MODULE MISSING: bin/lib/br/discovery.sh' "$H/logs/ALERTS.log")
[ "$c" = 1 ] && ok || bad "D5: a tick without discovery.sh wrote $c 'RESOLVER MODULE MISSING: bin/lib/br/discovery.sh' lines, want 1"

# ── D6. one concern per PR ──────────────────────────────────────────────────
if [ -n "${BR_SPLIT_BASE:-}" ]; then
  if git -C "$REPO" show "$BR_SPLIT_BASE:bin/blocked-resolver.sh" > "$T/base-driver.sh" 2>/dev/null; then
    LEFT=$(comm -23 <(static_defs "$T/base-driver.sh") <(static_defs "$BR") | tr '\n' ' ')
    WANTD=$(printf '%s\n' $DISC | sort | tr '\n' ' ')
    [ "$LEFT" = "$WANTD" ] && ok || bad "D6: left the driver: '$LEFT', want exactly the discovery sources '$WANTD'"
    for n in br_from_conductor br_handoff_lines br_handoff_rows br_conductor_emit br_from_reviews; do
      [ "$(ndefs "$n" "$BR")" = 1 ] && ok || bad "D6: $n is no longer in the driver — C1 and reviews are later slices"
    done
  else
    bad "D6: BR_SPLIT_BASE=$BR_SPLIT_BASE has no bin/blocked-resolver.sh"
  fi
fi

echo "br-split-layout.bh-6517: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
