#!/bin/bash
# tests/br-driver-unjoin.bh-8626-test.sh — BH-8626: two driver sections moved
# into bin/lib/br/ (datalane.sh, contested.sh), the five fit-to-ceiling call
# sites un-joined, and the driver well under the old 9055-line ceiling.
#
#   U1  no driver line is a `fi;`/`esac;` joined onto a `command -v` call (the
#       joined-to-fit shape). A fixture table proves the detector: each joined
#       shape is red, the near misses are green.
#   U2  the driver is <= 8555 lines (9055 - 500) and <= the `lines` ceiling row.
#   U3  the five call sites exist exactly once each, on their own line.
#   U4  bin/lib/br/datalane.sh and contested.sh, sourced alone in a clean bash,
#       define exactly their 8 and 5 names. The REAL driver runs one tick from a
#       scratch $HARNESS with rc 0 and sources both (canaries). With datalane.sh
#       removed the tick exits 1 and writes exactly one RESOLVER MODULE MISSING
#       line for it.
#   U5  every U4 name has a `mod` row in tests/br/expected-map.tsv and no
#       column-0 definition in the driver.
#
# Run from anywhere: tests/br-driver-unjoin.bh-8626-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

BR="$REPO/bin/blocked-resolver.sh"
MAP="$REPO/tests/br/expected-map.tsv"
CEIL="$REPO/tests/br/driver-ceiling.tsv"
DL_FNS="_br_dl_fetch_due _br_dl_fetch_miss br_data_lane_release br_data_lane_route br_dl_escalate br_dl_eval br_dl_rcr_bound br_dl_unbind"
CT_FNS="br_competitors br_contested_hold br_contested_sweep br_contested_withdraw br_release_hold"

# joined <file> — the lines that join a `fi`/`esac` onto a `command -v` call.
joined() { grep -nE '^[[:space:]]*(fi|esac);[[:space:]]*(if[[:space:]]+)?command -v' "$1"; }

# ── U1. the detector, then the driver ───────────────────────────────────────
TAB=$(printf '\t')
red_case() { printf '%s\n' "$1" > "$T/u1.sh"; joined "$T/u1.sh" >/dev/null && ok || bad "U1: detector missed a joined line: $1"; }
green_case() { printf '%s\n' "$1" > "$T/u1.sh"; joined "$T/u1.sh" >/dev/null && bad "U1: detector flagged a near miss: $1" || ok; }
red_case '  fi; command -v brnc_fix_exit >/dev/null 2>&1 && brnc_fix_exit "$p" && return 0'
red_case '  esac; command -v brnc_one_gate >/dev/null 2>&1 && brnc_one_gate "$p" && { br_reset_token; return 3; }'
red_case '      fi; command -v brnc_settle_pending >/dev/null 2>&1 && brnc_settle_pending "$p" >/dev/null ;;'
red_case '  fi; if command -v prh_gate >/dev/null 2>&1 && ! prh_gate "$p"; then br_reset_token; return 3; fi'
red_case "${TAB}esac; command -v x"
red_case 'fi;command -v x'
green_case 'done; unset _br_frags _br_of _br_o'
green_case '  fi'
green_case '  command -v brnc_x >/dev/null 2>&1 && y'
green_case '  # fi; command -v x'
J=$(joined "$BR")
[ -z "$J" ] && ok || bad "U1: the driver still joins call sites to fit the ceiling: $J"

# ── U2. the size ────────────────────────────────────────────────────────────
N=$(wc -l < "$BR")
MAXL=$(awk -F'\t' '$1=="lines"{print $2}' "$CEIL")
[ "$N" -le 8555 ] && ok || bad "U2: the driver is $N lines, want <= 8555 (9055 - 500)"
[ -n "$MAXL" ] && [ "$N" -le "$MAXL" ] && ok || bad "U2: the driver is $N lines, over the ceiling row '${MAXL:-none}'"

# ── U3. the five call sites, one line each ──────────────────────────────────
for f in brnc_settle_pending brnc_fix_exit brnc_queued_guard prh_gate brnc_one_gate; do
  C=$(grep -cE "^[[:space:]]+(if )?command -v $f " "$BR")
  [ "$C" = 1 ] && ok || bad "U3: want exactly one own-line 'command -v $f' call site in the driver, got $C"
done

# ── U4. what the modules define, and the real tick ──────────────────────────
defs() { bash -c 'b=$(declare -F | awk "{print \$3}"); . "$0" >/dev/null 2>&1 || exit 3
  comm -13 <(printf "%s\n" "$b" | sort) <(declare -F | awk "{print \$3}" | sort)' "$1" | tr '\n' ' ' | sed 's/ $//'; }
GOT=$(defs "$REPO/bin/lib/br/datalane.sh"); [ "$GOT" = "$DL_FNS" ] && ok || bad "U4: datalane.sh defines '$GOT', want '$DL_FNS'"
GOT=$(defs "$REPO/bin/lib/br/contested.sh"); [ "$GOT" = "$CT_FNS" ] && ok || bad "U4: contested.sh defines '$GOT', want '$CT_FNS'"

# tick <harness> — one real driver tick from a scratch harness; prints its rc.
mk_harness() {
  local H="$1" s f
  mkdir -p "$H/logs" "$H/state/merge-conductor" "$H/flags" "$H/locks" "$H/env" "$H/builds"
  for s in bin/blocked-resolver.sh bin/fleet-conf.sh bin/project-of.sh bin/alert-line.sh; do
    scratch_install_closure "$s" "$H" >/dev/null || bad "U4: could not install $s into $H"
  done
  printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
  : > "$H/env/global.env"
  for f in beat.sh agent-call.sh run-build.sh lane-alert.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
  done
  : > "$H/logs/ALERTS.log"
}
mkdir -p "$T/fakebin"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/gh"; printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
chmod +x "$T/fakebin/gh" "$T/fakebin/flock"
tick() {
  ( unset HARNESS; export PATH="$T/fakebin:$PATH" GH_TOKEN=""
    HARNESS="$1" FLEET_CONF="$1/fleet.conf" bash "$1/bin/blocked-resolver.sh" nosuchproject ) > "$1/lane.out" 2>&1
  echo $?
}
H="$T/h1"; mk_harness "$H"
[ -f "$H/bin/lib/br/datalane.sh" ] && [ -f "$H/bin/lib/br/contested.sh" ] && ok \
  || bad "U4: scratch_install_closure did not install bin/lib/br/datalane.sh and contested.sh"
for m in datalane contested; do
  [ -f "$H/bin/lib/br/$m.sh" ] && printf 'printf %%s canary > "%s/%s-sourced"\n' "$T" "$m" >> "$H/bin/lib/br/$m.sh"
done
RC=$(tick "$H")
[ "$RC" = 0 ] && ok || bad "U4: the driver tick exited $RC: $(tail -3 "$H/lane.out" | tr '\n' ' ')"
[ -s "$T/datalane-sourced" ] && [ -s "$T/contested-sourced" ] && ok || bad "U4: the driver tick did not source both datalane.sh and contested.sh"
grep -q 'RESOLVER MODULE MISSING' "$H/logs/ALERTS.log" && bad "U4: a tick with every module present wrote a refusal" || ok

H="$T/h2"; mk_harness "$H"; rm -f "$H/bin/lib/br/datalane.sh"
RC=$(tick "$H")
[ "$RC" = 1 ] && ok || bad "U4: a tick with no datalane.sh exited $RC, want 1"
N2=$(grep -c 'RESOLVER MODULE MISSING: bin/lib/br/datalane.sh' "$H/logs/ALERTS.log")
[ "$N2" = 1 ] && ok || bad "U4: a tick with no datalane.sh wrote $N2 'RESOLVER MODULE MISSING: bin/lib/br/datalane.sh' lines, want 1"

# ── U5. map rows, no inline copy ────────────────────────────────────────────
for pair in $(for f in $DL_FNS; do echo "datalane:$f"; done; for f in $CT_FNS; do echo "contested:$f"; done); do
  m=${pair%%:*}; f=${pair#*:}
  awk -F'\t' -v m="$m" -v f="$f" '$1==m && $2==f && $3=="mod"{found=1} END{exit !found}' "$MAP" && ok \
    || bad "U5: tests/br/expected-map.tsv has no '$m	$f	mod' row"
  grep -qE "^$f[(][)] [{]" "$BR" && bad "U5: bin/blocked-resolver.sh still defines $f inline" || ok
done

echo "br-driver-unjoin.bh-8626: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
