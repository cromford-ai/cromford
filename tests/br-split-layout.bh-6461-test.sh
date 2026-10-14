#!/bin/bash
# tests/br-split-layout.bh-6461-test.sh — the per-ticket layout test for the
# BH-6461 slice of the bin/lib/br/ split: the ticket-key family moves out of
# bin/blocked-resolver.sh into bin/lib/br/keys.sh, byte for byte.
# tests/br-split-layout.bh-5241-test.sh (B1-B7) still judges the whole layout;
# this file pins what this slice adds and what #6461 carries over from #5241.
#
#   K1  each of the 9 key functions is defined in keys.sh exactly once and in
#       the driver zero times; the `br_fns` ceiling row is <= 150.
#   K2  the family answers through keys.sh alone, with inputs as the pipeline
#       produces them; the test corpus holds br_key_shape exactly once.
#   K3  the top-level module set == bin/lib/br/MODULES; no store.sh; no second
#       ladder or record layer (br_ladder_class, br_load: one top-level owner).
#   K4  no opt/ module defines a key name, and a seeded overlap is REPORTED by
#       name (report it, never hide it).
#   K5  the real driver ticks rc 0 from a scratch $HARNESS and sources keys.sh;
#       with keys.sh gone it refuses: rc 1 and exactly ONE ALERTS line.
#   K6  with BR_SPLIT_BASE=<rev>: the names that left the driver, less the
#       names a later top-level module now defines, are exactly the 9 key names,
#       and br_handoff_lines is still in the driver (one concern per PR).
#       Env-gated like B5: a later slice moves more on purpose.
#
# Run from anywhere: tests/br-split-layout.bh-6461-test.sh   (exit 0 = all pass)
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
KEYS="br_key_shape br_key_from_branch br_key_from_title br_key_from_dir br_ticket_key br_key_source_phrase br_derive_ticket_key br_nokey_alert br_key_in_only"
static_defs() { grep -oE '^br_[A-Za-z0-9_]*[(][)] [{]' "$1" | sed 's/[(].*//' | sort -u; }
ndefs() { grep -cE "^$1[(][)] [{]" "$2"; }

# ── K1. the key family lives in keys.sh only ────────────────────────────────
for n in $KEYS; do
  c=$(ndefs "$n" "$BRD/keys.sh" 2>/dev/null); [ "${c:-0}" = 1 ] && ok || bad "K1: $n is defined ${c:-0} times in bin/lib/br/keys.sh, want 1"
  c=$(ndefs "$n" "$BR"); [ "$c" = 0 ] && ok || bad "K1: $n is still defined in the driver ($c times)"
done
MAXF=$(awk -F'\t' '$1=="br_fns"{print $2}' "$CEIL")
[ -n "$MAXF" ] && [ "$MAXF" -le 150 ] && ok || bad "K1: the br_fns ceiling row is '${MAXF:-absent}', want <= 150"

# ── K2. the family answers through keys.sh alone ────────────────────────────
GOT=$(bash -c '. "$0"; br_ticket_key tproj - ticket/TK-775-r2 ""' "$BRD/keys.sh" 2>&1)
[ "$GOT" = "TK-775	branch" ] && ok || bad "K2: br_ticket_key on ticket/TK-775-r2 answered '$GOT', want 'TK-775<TAB>branch'"
GOT=$(bash -c '. "$0"; br_key_from_title "[TK-1617] x"' "$BRD/keys.sh" 2>&1)
[ "$GOT" = TK-1617 ] && ok || bad "K2: br_key_from_title '[TK-1617] x' answered '$GOT', want TK-1617"
GOT=$(bash -c '. "$0" || exit 9; br_key_shape fix/report-nav; echo "rc=$?"' "$BRD/keys.sh" 2>&1)
[ "$GOT" = rc=1 ] && ok || bad "K2: br_key_shape fix/report-nav answered '$GOT', want rc=1 and no key"
GOT=$(bash -c '. "$0"; br_key_source_phrase record' "$BRD/keys.sh" 2>&1)
[ "$GOT" = "the build record" ] && ok || bad "K2: br_key_source_phrase record answered '$GOT', want 'the build record'"
br_corpus "$REPO" "$T/br-corpus.sh" || bad "K2: br_corpus could not build the corpus"
c=$(ndefs br_key_shape "$T/br-corpus.sh"); [ "$c" = 1 ] && ok || bad "K2: the corpus defines br_key_shape $c times, want 1"

# ── K3. no recreated module, no second store ────────────────────────────────
HAVE=$(cd "$BRD" && LC_ALL=C ls -- *.sh | sed 's/\.sh$//' | sort)
WANT=$(grep -v '^#' "$BRD/MODULES" | sort)
[ -n "$HAVE" ] && [ "$HAVE" = "$WANT" ] && ok \
  || bad "K3: top-level modules ($(printf '%s' "$HAVE" | tr '\n' ' ')) are not bin/lib/br/MODULES ($(printf '%s' "$WANT" | tr '\n' ' '))"
[ ! -e "$BRD/store.sh" ] && ok || bad "K3: bin/lib/br/store.sh exists — the record layer is record.sh, not a second store"
for pair in br_ladder_class:ladder.sh br_load:record.sh; do
  n=${pair%%:*}; want=${pair#*:}
  owners=$(grep -lE "^${n}[(][)] [{]" "$BRD"/*.sh | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
  [ "$owners" = "$want " ] && ok || bad "K3: $n is defined in '$owners', want only $want"
done

# ── K4. opt/ overlap is reported, never hidden ──────────────────────────────
# opt_overlap <br-dir> — one line per key name an opt/ module defines.
opt_overlap() {
  local f n
  for f in "$1"/opt/*.sh; do
    [ -e "$f" ] || continue
    for n in $KEYS; do
      grep -qE "^[[:space:]]*(function[[:space:]]+)?${n}[[:space:]]*[(][)]" "$f" \
        && echo "overlap: $n is defined by keys.sh AND ${f##*/opt/}"
    done
  done
  return 0
}
ls "$BRD"/opt/*.sh >/dev/null 2>&1 && ok || bad "K4: bin/lib/br/opt/ has no modules — the check would be vacuous"
OUT=$(opt_overlap "$BRD"); [ -z "$OUT" ] && ok || bad "K4: $OUT"
S="$T/k4"; mkdir -p "$S"; cp -r "$BRD/." "$S/"
f=$(LC_ALL=C ls "$S"/opt/*.sh | head -1)
printf 'br_key_shape() { :; }\n' >> "$f"
OUT=$(opt_overlap "$S"); grep -q 'br_key_shape' <<<"$OUT" && ok \
  || bad "K4: a seeded br_key_shape in opt/${f##*/opt/} was not reported (got '$OUT')"

# ── K5. the production entry point, with and without keys.sh ───────────────
H="$T/h"
mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/env" "$H/builds" "$T/fakebin"
for s in bin/blocked-resolver.sh bin/fleet-conf.sh bin/project-of.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || bad "K5: could not install $s into the scratch harness"
done
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/gh" "$T/fakebin/flock"
printf 'printf %%s canary > "%s/keys-sourced"\n' "$T" >> "$H/bin/lib/br/keys.sh"
tick() {
  : > "$H/logs/ALERTS.log"
  ( unset HARNESS; export PATH="$T/fakebin:$PATH" GH_TOKEN=""
    HARNESS="$H" FLEET_CONF="$H/fleet.conf" bash "$H/bin/blocked-resolver.sh" nosuchproject ) > "$T/lane.out" 2>&1
}
tick; RC=$?
[ "$RC" -eq 0 ] && ok || bad "K5: the driver tick exited $RC: $(tail -3 "$T/lane.out" | tr '\n' ' ')"
[ -s "$T/keys-sourced" ] && ok || bad "K5: the driver tick never sourced bin/lib/br/keys.sh"
grep -q 'RESOLVER MODULE MISSING' "$H/logs/ALERTS.log" && bad "K5: a tick with every module present wrote a refusal" || ok
rm -f "$H/bin/lib/br/keys.sh"
tick; RC=$?
[ "$RC" -eq 1 ] && ok || bad "K5: a tick without keys.sh exited $RC, want 1 (refuse)"
c=$(grep -c 'RESOLVER MODULE MISSING: bin/lib/br/keys.sh' "$H/logs/ALERTS.log")
[ "$c" = 1 ] && ok || bad "K5: a tick without keys.sh wrote $c 'RESOLVER MODULE MISSING: bin/lib/br/keys.sh' lines, want 1"

# ── K6. one concern per PR ──────────────────────────────────────────────────
if [ -n "${BR_SPLIT_BASE:-}" ]; then
  if git -C "$REPO" show "$BR_SPLIT_BASE:bin/blocked-resolver.sh" > "$T/base-driver.sh" 2>/dev/null; then
    # A later slice moves more names on purpose (BH-6517: discovery.sh). A name
    # another top-level module now defines is that slice's move, not this one's;
    # a name that left the driver and landed nowhere still fails the pin.
    LATER=$(for f in "$BRD"/*.sh; do [ "${f##*/}" = keys.sh ] || static_defs "$f"; done | sort -u)
    LEFT=$(comm -23 <(static_defs "$T/base-driver.sh") <(static_defs "$BR") | comm -23 - <(printf '%s\n' "$LATER") | tr '\n' ' ')
    WANTK=$(printf '%s\n' $KEYS | sort | tr '\n' ' ')
    [ "$LEFT" = "$WANTK" ] && ok || bad "K6: left the driver: '$LEFT', want exactly the key family '$WANTK'"
    # Measure K6 against the BH-6461 base (BR_SPLIT_BASE=745d38551^1). BH-6517 moved
    # br_from_builds and br_from_rebuilds; br_handoff_lines is still in the driver.
    for n in br_handoff_lines; do
      [ "$(ndefs "$n" "$BR")" = 1 ] && ok || bad "K6: $n is no longer in the driver — discovery is a later slice"
    done
  else
    bad "K6: BR_SPLIT_BASE=$BR_SPLIT_BASE has no bin/blocked-resolver.sh"
  fi
fi

echo "br-split-layout.bh-6461: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
