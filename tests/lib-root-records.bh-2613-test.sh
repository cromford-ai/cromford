#!/bin/bash
# tests/lib-root-records.bh-2613-test.sh — BH-2613.4 (#2652). The account,
# model, fan-in and record libs resolve their root as HARNESS, then the
# caller's H, else NO root (docs/notes/2026-09-26-BH-2613-lib-root-resolution.md),
# and with no root they write nothing, read the absent answer and never build a
# path from an empty string. builds-of-record and restore-drill-orgo already
# read H first and keep it there (rule 1). The entry points that own the
# literal default for them: bin/lane-probe.sh, bin/file-health-ticket.sh.
#
# Every case runs in a fresh `bash -c` with HARNESS and H unset (or ONE of them
# set to a scratch root for the positive controls), cwd a scratch dir that holds
# decoy state/ and flags/ files, `set -eu`, and xtrace to its own file. As root
# the child drops to nobody, so a lib that still reaches the literal cannot
# write into a live harness on the box running this suite. Each case asserts:
#   - its printed answers and rcs (the absent answer, never a healthy one);
#   - it ran to its last line (a `set -e` caller is never exited);
#   - no new file anywhere under $T but the case's own allowed dirs, and no new
#     top-level entry in / (a path built from an empty root);
#   - its xtrace holds 0 occurrences of /root/harness and 0 paths built from an
#     empty root (/state/…, /logs/…, /flags/…).
#
#   A1  resolvers: pool-account's four print "" with no root, the scratch root
#       with HARNESS, and the same with only H
#   A2  no write, rc as before, under set -eu: one case per lib, each with a
#       HARNESS-only and an H-only positive control
#   A3  xtrace: 0 /root/harness in every case (checked inside run_case)
#   A4  backup-freshness: no root is `missing`, never `ok`, even with a fresh
#       state/backup-last.json in the cwd; a fresh stamp under a scratch root is
#       `ok` (positive control)
#   A5  verdict-parse: the same review reads the same word and rc with and
#       without a root, for APPROVE, BLOCK and no verdict (`unknown` rc 1)
#   A6  file-children: two no-root runs make 0 curl calls and record no child;
#       with a root, the second run of a filed spec makes no create POST; a
#       seeded ledger is never refiled, with or without a root
#   A7  entry points: bin/lane-probe.sh sets H from its own literal default and
#       bin/file-health-ticket.sh sets H, each before its lib is sourced
#
# The libs, by rooted path:
#   "$DIR/bin/lib/pool-account.sh" "$DIR/bin/lib/session-profile.sh"
#   "$DIR/bin/lib/lane-model.sh" "$DIR/bin/lib/fanin.sh" "$DIR/bin/lib/fc-board.sh"
#   "$DIR/bin/lib/file-children.sh" "$DIR/bin/lib/builds-of-record.sh"
#   "$DIR/bin/lib/backup-freshness.sh" "$DIR/bin/lib/restore-drill-orgo.sh"
#   "$DIR/bin/lib/verdict-parse.sh"
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd -P)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

LIBS=(
  "$DIR/bin/lib/pool-account.sh" "$DIR/bin/lib/session-profile.sh"
  "$DIR/bin/lib/lane-model.sh" "$DIR/bin/lib/fanin.sh" "$DIR/bin/lib/fc-board.sh"
  "$DIR/bin/lib/file-children.sh" "$DIR/bin/lib/builds-of-record.sh"
  "$DIR/bin/lib/backup-freshness.sh" "$DIR/bin/lib/restore-drill-orgo.sh"
  "$DIR/bin/lib/verdict-parse.sh"
)
for f in "${LIBS[@]}" "$DIR/bin/lane-probe.sh" "$DIR/bin/file-health-ticket.sh"; do
  [ -r "$f" ] || bad "missing $f"
done

# A private copy of bin/ and catalog/ the unprivileged child can read wherever
# the checkout lives. The libs are sourced from here, so their sibling sources
# (and verdict-parse's own catalog default) resolve too.
NB="$T/nb"; REPO="$NB"
mkdir -p "$T/traces" "$T/out" "$T/allowed" "$T/fx" "$T/home" "$T/tmp" "$T/cwd" "$T/stub" "$NB"
cp -r "$DIR/bin" "$DIR/catalog" "$NB/"
# Decoys in the cwd: a relative state/ or flags/ read must never answer.
mkdir -p "$T/cwd/state" "$T/cwd/flags"
printf '{"ts":"%s"}\n' "$(date -u +%Y%m%dT%H%M%SZ)" > "$T/cwd/state/backup-last.json"
touch "$T/cwd/flags/pool-account-routing-off" "$T/cwd/flags/state-backup-off"
# One scratch root per variable, so a HARNESS-only and an H-only run never
# share an answer.
for v in HARNESS H; do mkdir -p "$T/r-$v/env" "$T/r-$v/state"; done
ROOTLS=$(ls -A /)

unpriv() { "$@"; }
if [ "$(id -u)" = 0 ]; then
  if command -v setpriv >/dev/null 2>&1; then
    unpriv() { setpriv --reuid=65534 --regid=65534 --clear-groups -- "$@"; }
  else
    echo "SKIP: root without setpriv cannot drop to nobody, and a no-root run as root could write a live harness"
    exit 0
  fi
fi
# open_up — as root, every scratch path the nobody child reads or writes. chmod
# moves ctime only, so run_case's -newer (mtime) check is untouched.
open_up() {
  [ "$(id -u)" = 0 ] || return 0
  chmod o+x "$T"
  find "$T" -path "$NB" -prune -o -exec chmod a+rwX {} + 2>/dev/null
  chmod -R a+rX "$NB"
}
chmod -R a+rX "$NB"

# run_case <name> <body> [VAR=value …] — the body runs under set -eu + xtrace
# in a fresh bash with HARNESS/H unset (unless passed). Sets OUT and RC. The
# body must end with `echo END`.
run_case() {
  local name="$1" body="$2" tr hits new keep re
  shift 2
  tr="$T/traces/$name.trace"
  open_up
  touch "$T/marker"
  ( cd "$T/cwd" && unpriv env -u BASH_ENV -u HARNESS -u H -u _VP_WINDOW -u VERDICT_WINDOW_LINES \
      -u QUOTA_DIR -u POOL_TOKENS_DIR -u HARNESS_ENV_DIR \
      HOME="$T/home" TMPDIR="$T/tmp" REPO="$REPO" T="$T" PS4='+ ' "$@" \
      bash -c 'exec 9>"$0"; BASH_XTRACEFD=9; set -eu; set -x; '"$body" "$tr" ) \
    > "$T/out/$name" 2> "$T/out/$name.err"
  RC=$?
  OUT=$(cat "$T/out/$name")
  case "$OUT" in *END) ok ;; *) bad "$name did not run to its end (rc $RC): $OUT $(head -c 400 "$T/out/$name.err")" ;; esac
  # TRACE_SCOPE narrows the count to trace lines matching it, for a case that
  # sources a lib another BH-2613 slice owns (a2-verdict-window: lane-gate.sh);
  # TRACE_SCOPE=none is the one case whose root IS the literal (a1-chain).
  hits=0
  [ "${TRACE_SCOPE:-}" = none ] || hits=$(grep -e "${TRACE_SCOPE:-.}" "$tr" | grep -c '/root/harness')
  [ "$hits" = 0 ] && ok || bad "$name xtrace names /root/harness $hits time(s): $(grep -m3 '/root/harness' "$tr")"
  # A path built from an empty root: "$root/state/…" with root="" is /state/….
  # Caught in the trace so it fails even where the write itself would be refused.
  re="(^|[ =:'\"])/(state|logs|flags|builds|env|fly|cooldown|leases|pins|tokens\.d|fleet\.conf|bin/lib|bin/fleet-conf\.sh|bin/lane-alert\.sh)(/|\\$|'|\"| |$)"
  hits=$(grep -e "${TRACE_SCOPE:-.}" "$tr" | grep -cE "$re")
  [ "$hits" = 0 ] && ok || bad "$name built $hits path(s) from an empty root: $(grep -m3 -E "$re" "$tr")"
  # ALLOW_TMP=1: the case may leave files in its TMPDIR (lane-gate.sh's
  # harness-lanes-<uid> stamp cache in a2-verdict-window).
  keep="$T/none"; [ -n "${ALLOW_TMP:-}" ] && keep="$T/tmp"
  new=$(find "$T" \( -path "$T/traces" -o -path "$T/out" -o -path "$T/allowed" -o -path "$T/r-HARNESS" \
          -o -path "$T/r-H" -o -path "$T/h" -o -path "$keep" \) -prune \
          -o -newer "$T/marker" ! -path "$T" -print)
  [ -z "$new" ] && ok || bad "$name wrote under the scratch tree: $new"
  [ "$(ls -A /)" = "$ROOTLS" ] && ok || bad "$name created a top-level path: $(diff <(printf '%s\n' "$ROOTLS") <(ls -A /) | tail -n +2)"
}
has() { case "$OUT" in *"$1"*) ok ;; *) bad "$2: wanted '$1' in: $OUT" ;; esac; }
hasnt() { case "$OUT" in *"$1"*) bad "$2: did not want '$1' in: $OUT" ;; *) ok ;; esac; }

# ---- A1 resolvers -------------------------------------------------------------
# pool-account.sh pulls in three bin/ scripts when their functions are absent,
# and bin/account-pick.sh sets HARNESS="${HARNESS:-/root/harness}" itself (an
# entry point owning its default, rule 4). So the lib's OWN resolution is only
# visible with those seams already defined, the way every bin/ caller that
# sources account-pick.sh first presents them. A1-chain pins the other half:
# sourced alone, the root it sees is account-pick.sh's.
PA='accounts_load() { :; }; auth_fp_for_runner() { :; }; account_lease_claim() { return 2; }
_acct_pin_key() { printf "%s" "$1" | tr -c "A-Za-z0-9._-" _; }
. "$REPO/bin/lib/pool-account.sh"'
RES="$PA"'
echo "[$(_pa_h)] [$(_pa_quotadir)] [$(pool_account_tokens_dir)] [$(pool_account_lease_dir)]"
echo END'
run_case a1-noroot "$RES"
has "[] [] [] []" "A1 no root"
for v in HARNESS H; do
  R="$T/r-$v"
  run_case "a1-$v" "$RES" "$v=$R"
  has "[$R] [$R/state/quota] [$R/env/tokens.d] [$R/state/quota/leases]" "A1 $v only"
done
TRACE_SCOPE=none run_case a1-chain '. "$REPO/bin/lib/pool-account.sh"
echo "chain=[$(_pa_h)]"; echo END'
has "chain=[/root/harness]" "A1-chain pool-account sourced alone takes account-pick.sh's root"
# The explicit overrides still win with no root.
run_case a1-override "$RES" QUOTA_DIR="$T/allowed/q" POOL_TOKENS_DIR="$T/allowed/tk"
has "[] [$T/allowed/q] [$T/allowed/tk] [$T/allowed/q/leases]" "A1 QUOTA_DIR/POOL_TOKENS_DIR override"

# ---- A2 no write, one case per lib --------------------------------------------
run_case a2-pool-account "$PA"'
echo "max=$(pool_account_max_leases)"
rc=0; a=$(pool_account_armed) || rc=$?; echo "armed=$a rc=$rc"
rc=0; pool_account_token_x=$(_pa_token_read acct1) || rc=$?; echo "tok rc=$rc"
pool_account_cooldown acct1 refusal; echo "cool=$?"
pool_account_cooldown acct1 refusal "$(( $(date +%s) + 86400 ))"; echo "coolreset=$?"
echo "leases=$(pool_account_leases acct1)"
pool_account_prune; echo "prune=$?"
pool_account_release m1; echo "release=$?"
pool_account_unpin p K-1 acct1; echo "unpin=$?"
echo END' POOL_ACCOUNT_DB_LEASES=0
has "max=4" "A2 pool-account max leases falls back to 4"
has "armed=no_tokens_dir rc=1" "A2 pool-account no root is unarmed (the cwd flags/ decoy is not the kill switch)"
has "tok rc=1" "A2 pool-account token read"
has "cool=0" "A2 pool-account cooldown rc"
has "coolreset=0" "A2 pool-account reset cooldown rc"
has "leases=0" "A2 pool-account lease count"
has "unpin=0" "A2 pool-account unpin rc"
# Positive control: with a root the cooldown stamp lands under it. The fleet row
# (bin/lib/fleet-cooldown.sh, through bin/jobs-client.sh) is not this slice's,
# so its backend is off.
for v in HARNESS H; do
  run_case "a2-pool-account-$v" "$PA"'
pool_account_cooldown acct1 refusal; echo END' "$v=$T/r-$v" FLEET_COOLDOWN_DB=0
  [ -s "$T/r-$v/state/quota/cooldown/claude/acct1" ] && ok || bad "A2 pool-account with $v stamps the cooldown under it"
done

run_case a2-session-profile '. "$REPO/bin/lib/session-profile.sh"
_sp_log hello; echo "log=$?"
SESSION_PROFILE_STAGES=build session_profile_build build "$PWD"; echo "build=$?"
echo "active=$SP_ACTIVE args=${SP_ARGS[*]}"
echo END'
has "build=0" "A2 session-profile rc"
has "active=1 args=--exclude-dynamic-system-prompt-sections" "A2 session-profile applies without MCP files"
[ -z "$(find "$T" / -xdev -maxdepth 3 -name 'session-profile-mcp-*' -newer "$T/marker" 2>/dev/null)" ] && ok \
  || bad "A2 session-profile wrote an MCP file with no root"
for v in HARNESS H; do
  run_case "a2-session-profile-$v" '. "$REPO/bin/lib/session-profile.sh"
_sp_log hello; SESSION_PROFILE_STAGES=build session_profile_build build "$PWD"
echo "args=${SP_ARGS[*]}"; echo END' "$v=$T/r-$v"
  grep -q hello "$T/r-$v/logs/session-profile.log" 2>/dev/null && ok || bad "A2 session-profile with $v logs under it"
  has "--mcp-config $T/r-$v/state/session-profile-mcp-" "A2 session-profile with $v writes its MCP file under it"
done

# lane-model with its sibling hidden: fail closed, rc 75, no model guessed.
mkdir -p "$T/fx/iso/bin/lib"; cp "$DIR/bin/lib/lane-model.sh" "$T/fx/iso/bin/lib/"
LM='. "$T/fx/iso/bin/lib/lane-model.sh"
rc=0; _lane_model_load || rc=$?; echo "load=$rc"
rc=0; m=$(lane_model XX_MODEL codex.default) || rc=$?; echo "model=[$m] rc=$rc"
echo END'
run_case a2-lane-model "$LM"
has "load=75" "A2 lane-model load"
has "model=[] rc=75" "A2 lane-model fails closed"
for v in HARNESS H; do
  # The same missing resolver under a root: the same rc, and the alert lands there.
  run_case "a2-lane-model-$v" "$LM" "$v=$T/r-$v"
  has "model=[] rc=75" "A2 lane-model with $v and no resolver: same rc as no root"
  grep -q 'model-route.sh could not be loaded' "$T/r-$v/logs/ALERTS.log" 2>/dev/null && ok \
    || bad "A2 lane-model with $v alerts under it"
  # A resolver under the root is found through the root.
  mkdir -p "$T/r-$v/bin/lib"; printf 'model_for() { echo "stub-%s"; }\n' "$v" > "$T/r-$v/bin/lib/model-route.sh"
  run_case "a2-lane-model-$v-found" "$LM" "$v=$T/r-$v"
  has "model=[stub-$v] rc=0" "A2 lane-model with $v loads the root's resolver"
  rm -rf "$T/r-$v/bin"
done

printf 'E a\nE b\nA a done\n' > "$T/fx/ledger"
run_case a2-fanin '. "$REPO/bin/lib/fanin.sh"
fanin_begin lane1 scope1 "$T/allowed/fanin.log"; echo "begin=$? file=[${FANIN_FILE:-}]"
fanin_enumerate a; fanin_account a done
_fanin_report "$T/fx/ledger" lane1 scope1 "$T/allowed/fanin.log"; echo "report=$?"
_fanin_report "$T/fx/ledger" lane1 scope1 "$T/allowed/fanin.log" "(note)"; echo "orphan=$?"
echo END'
has "begin=0 file=[]" "A2 fanin opens no ledger"
has "report=0" "A2 fanin report rc"
grep -q 'FANIN lane1 scope1: enumerated 2 accounted 1' "$T/allowed/fanin.log" && ok || bad "A2 fanin still writes the caller's log"
grep -q 'ALERT FANIN lane1 scope1: .*missing: b (note)' "$T/allowed/fanin.log" && ok || bad "A2 fanin orphan line in the caller's log"
for v in HARNESS H; do
  run_case "a2-fanin-$v" '. "$REPO/bin/lib/fanin.sh"
fanin_begin lane1 scope1 "$T/allowed/fanin.log"; echo "file=[${FANIN_FILE:-}]"; echo END' "$v=$T/r-$v"
  has "file=[$T/r-$v/state/fanin/lane1/scope1." "A2 fanin with $v opens its ledger there"
done

BOR='. "$REPO/bin/lib/builds-of-record.sh"
rc=0; out=$(bor_local_dir 7) || rc=$?; echo "local=$rc [$out]"
bor_list() { printf "K-1\tp-K-1\t-\tts\tSUCCESS\t-\t1\n"; }
rc=0; out=$(bor_union p) || rc=$?; echo "union=$rc [$out]"
echo END'
run_case a2-builds-of-record "$BOR"
has "local=2 []" "A2 builds-of-record local dir not found"
has "union=0 [K-1	p-K-1" "A2 builds-of-record still prints the DB rows"
for v in HARNESS H; do
  mkdir -p "$T/r-$v/builds/pool-7"
  run_case "a2-builds-of-record-$v" "$BOR" "$v=$T/r-$v"
  has "local=0 [$T/r-$v/builds/pool-7]" "A2 builds-of-record with $v"
done

RDO='. "$REPO/bin/lib/restore-drill-orgo.sh"
orgo() { ORGO_HTTP=000; ORGO_BODY=""; return 1; }
rc=0; remote cid lbl true || rc=$?; echo "remote=$rc"
echo END'
run_case a2-restore-drill-orgo "$RDO"
has "remote=255" "A2 restore-drill-orgo rc unchanged"
for v in HARNESS H; do
  run_case "a2-restore-drill-orgo-$v" "$RDO" "$v=$T/r-$v"
  has "remote=255" "A2 restore-drill-orgo with $v: same rc"
  grep -qx 'lbl rc=255' "$T/r-$v/logs/restore-drill.log" 2>/dev/null && ok || bad "A2 restore-drill-orgo with $v logs under it"
done

run_case a2-verdict-alert '. "$REPO/bin/lib/verdict-parse.sh"
_vp_alert_unresolved; echo "alert=$?"
echo END'
has "alert=0" "A2 verdict-parse alert rc"
for v in HARNESS H; do
  run_case "a2-verdict-alert-$v" '. "$REPO/bin/lib/verdict-parse.sh"
_vp_alert_unresolved; echo END' "$v=$T/r-$v"
  grep -q 'VERDICT_WINDOW_LINES is unresolvable' "$T/r-$v/logs/ALERTS.log" 2>/dev/null && ok || bad "A2 verdict-parse with $v still alerts"
  [ -n "$(ls "$T/r-$v/flags/" 2>/dev/null | grep alerted-verdict-window-)" ] && ok || bad "A2 verdict-parse with $v stamps its flag"
done
# verdict_window sources lane-gate.sh, which #2649 converts; this slice owns the
# `lg=` choice, so only that line of the trace is held to 0.
TRACE_SCOPE='lg=' ALLOW_TMP=1 run_case a2-verdict-window '. "$REPO/bin/lib/verdict-parse.sh"
echo "window=$(verdict_window)"; echo END'
grep -q "lg=$NB/bin/lib/lane-gate.sh" "$T/traces/a2-verdict-window.trace" && ok \
  || bad "A2 verdict_window with no root reads the lib's own lane-gate: $(grep -m2 'lg=' "$T/traces/a2-verdict-window.trace")"

cat > "$T/fx/fleet.conf" <<'CONF'
ledger-os  example-org/ledger-os  https://ledger.example  /api/accounting/requests-board  3
CONF
mkdir -p "$T/fx/env" "$T/h/env"
for e in "$T/fx/env" "$T/h/env" "$T/r-HARNESS/env" "$T/r-H/env"; do
  printf 'LEDGER_API_BASE=https://ledger.example\nLEDGER_INTERNAL_API_TOKEN=tok-FIXTURE-2652\n' > "$e/ledger-os.env"
done
FBB='. "$REPO/bin/lib/file-children.sh"
rc=0; b=$(fc_board_base ledger-os) || rc=$?; echo "base=$rc [$b]"
echo END'
run_case a2-fc-board-base "$FBB" FLEET_CONF="$T/fx/fleet.conf"
has "base=1 []" "A2 fc_board_base fails closed with no root"
for v in HARNESS H; do
  run_case "a2-fc-board-base-$v" "$FBB" FLEET_CONF="$T/fx/fleet.conf" "$v=$T/r-$v"
  has "base=0 [https://ledger.example/api/accounting/requests-board]" "A2 fc_board_base with $v reads its env"
done

# ---- A4 backup-freshness ------------------------------------------------------
# The cwd holds a fresh state/backup-last.json: a relative read would say ok.
run_case a4-noroot '. "$REPO/bin/lib/backup-freshness.sh"
now=$(date +%s)
echo "age=$(bf_state_age "$(bf_facts_local)" "$now" | cut -f1)"
echo "age0=$(bf_state_age "$(bf_facts_local "")" "$now" | cut -f1)"
echo "rows=$(bf_rows "" "$now" | tr "\t\n" ",;")"
echo END'
has "age=missing" "A4 no root reads missing"
has "age0=missing" "A4 an empty positional root reads missing"
hasnt "=ok" "A4 no root never reads ok"
has "rows=box-hub,missing,;" "A4 bf_rows prints only the hub row, missing"
for v in HARNESS H; do
  printf '{"ts":"%s"}\n' "$(date -u +%Y%m%dT%H%M%SZ)" > "$T/r-$v/state/backup-last.json"
  run_case "a4-$v" '. "$REPO/bin/lib/backup-freshness.sh"
echo "age=$(bf_state_age "$(bf_facts_local "")" "$(date +%s)" | cut -f1)"; echo END' "$v=$T/r-$v"
  has "age=ok" "A4 positive control: a fresh stamp under $v is ok"
done
# With lane-switch.sh missing beside it, the lib's own lane_switch stub reads
# flags/ under the root it was handed, and a root without the flag is not off.
mkdir -p "$T/fx/bfiso/bin/lib" "$T/r-H/flags"; cp "$DIR/bin/lib/backup-freshness.sh" "$T/fx/bfiso/bin/lib/"
BFI='. "$T/fx/bfiso/bin/lib/backup-freshness.sh"
echo "off=[$(bf_facts_local | cut -f2)]"; echo END'
run_case a4-stub-noflag "$BFI" H="$T/r-H"
has "off=[]" "A4 lane_switch stub: no flag under H is not off"
touch "$T/r-H/flags/state-backup-off"
run_case a4-stub-flag "$BFI" H="$T/r-H"
has "off=[off]" "A4 lane_switch stub reads flags/ under H"
rm -f "$T/r-H/flags/state-backup-off"
# The positional root still comes first (rule 1).
run_case a4-positional '. "$REPO/bin/lib/backup-freshness.sh"
echo "age=$(bf_state_age "$(bf_facts_local "$T/r-H")" "$(date +%s)" | cut -f1)"; echo END'
has "age=ok" "A4 a positional root answers with no HARNESS/H"

# ---- A5 verdict-parse parity --------------------------------------------------
W=$(jq -r '.libs[]? | select(.id == "verdict-parse") | .knobs[]? | select(.env == "VERDICT_WINDOW_LINES") | .default // empty' \
      "$DIR/catalog/lanes.d/_lib.json")
printf 'Looks fine.\n\nVERDICT: APPROVE\n' > "$T/fx/approve.md"
printf 'Two problems.\n\nVERDICT: BLOCK\n' > "$T/fx/block.md"
printf 'I have thoughts but no verdict.\n' > "$T/fx/none.md"
VP='. "$REPO/bin/lib/verdict-parse.sh"
rc=0; w=$(verdict_parse "$T/fx/approve.md") || rc=$?; echo "a=$w/$rc"
rc=0; w=$(verdict_parse "$T/fx/block.md") || rc=$?; echo "b=$w/$rc"
rc=0; w=$(verdict_parse "$T/fx/none.md") || rc=$?; echo "n=$w/$rc"
echo END'
run_case a5-noroot "$VP" VERDICT_WINDOW_LINES="$W"
NOROOT=$OUT
has "a=APPROVE/0" "A5 approve with no root"
has "b=BLOCK/0" "A5 block with no root"
has "n=unknown/1" "A5 no verdict stays unknown with no root"
for v in HARNESS H; do
  run_case "a5-$v" "$VP" VERDICT_WINDOW_LINES="$W" "$v=$T/r-$v"
  [ "$OUT" = "$NOROOT" ] && ok || bad "A5 parity: $v '$OUT' vs no root '$NOROOT'"
done

# ---- A6 file-children twice ---------------------------------------------------
cat > "$T/stub/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
method=GET; url=""; k=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) shift ;;
    -H) case "$2" in Idempotency-Key:*) k="${2##*-}" ;; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
case "$method $url" in
  "GET "*/boards) printf '[{"id":"rb-1","capabilities":["dependencies"]}]\n' ;;
  "GET "*/tickets/*) printf '{"ticket":{"id":"cmParent01","key":"LG-9","priority":"high","status":"todo"}}\n' ;;
  "POST "*/boards/*/tickets) printf '{"ticket":{"id":"cmChild0%s","key":"LG-10%s"}}\n' "$k" "$k" ;;
  "POST "*/comments) printf '{"ok":true}\n' ;;
  "POST "*/move) printf '{"ticket":{"status":"in_progress"}}\n' ;;
  *) exit 22 ;;
esac
SH
chmod +x "$T/stub/curl"
SPEC='[{"title":"Types","body":"The export types.","after":[]},{"title":"Server","body":"The route.","after":[1]}]'
for b in nb pb; do mkdir -p "$T/allowed/$b"; printf '%s\n' "$SPEC" > "$T/allowed/$b/children.json"; done
FC='. "$REPO/bin/lib/file-children.sh"
rc=0; file_children ledger-os cmParent01 LG-9 "$B" "$B/children.json" || rc=$?; echo "run1=$rc"
rc=0; file_children ledger-os cmParent01 LG-9 "$B" "$B/children.json" || rc=$?; echo "run2=$rc"
echo END'
run_case a6-noroot "$FC" B="$T/allowed/nb" FLEET_CONF="$T/fx/fleet.conf" HARNESS_ENV_DIR="$T/fx/env" \
  PATH="$T/stub:$PATH" CURL_LOG="$T/allowed/curl-nb.log"
has "run1=1" "A6 no root fails closed (run 1)"
has "run2=1" "A6 no root fails closed (run 2)"
[ ! -s "$T/allowed/curl-nb.log" ] && ok || bad "A6 no root made curl calls: $(cat "$T/allowed/curl-nb.log")"
[ ! -s "$T/allowed/nb/children.txt" ] && ok || bad "A6 no root recorded a child"
run_case a6-root "$FC" B="$T/allowed/pb" FLEET_CONF="$T/fx/fleet.conf" HARNESS="$T/h" \
  PATH="$T/stub:$PATH" CURL_LOG="$T/allowed/curl-pb.log"
creates=$(grep -c -- '-X POST .*/boards/rb-1/tickets$' "$T/allowed/curl-pb.log")
[ "$creates" = 2 ] && ok || bad "A6 with a root the two runs create each child once, got $creates: $(cat "$T/allowed/curl-pb.log")"
[ "$(wc -l < "$T/allowed/pb/children.txt" 2>/dev/null)" = 2 ] && ok || bad "A6 with a root children.txt records 2"
[ -s "$T/allowed/pb/children-board.tsv" ] && ok || bad "A6 with a root the board ledger children-board.tsv is written"

# A seeded ledger (the build dir a filed run left behind): no root files nothing
# and changes nothing; H alone honours it and creates nothing either.
for v in none H; do
  s="$T/allowed/seed-$v"; mkdir -p "$s"
  cp "$T/allowed/pb/children.json" "$T/allowed/pb/children.txt" "$T/allowed/pb/children-board.tsv" "$s/"
  before=$(cat "$s/children.txt" "$s/children-board.tsv")
  if [ "$v" = none ]; then
    run_case a6-seed-noroot "$FC" B="$s" FLEET_CONF="$T/fx/fleet.conf" HARNESS_ENV_DIR="$T/fx/env" \
      PATH="$T/stub:$PATH" CURL_LOG="$T/allowed/curl-seed-$v.log"
    [ ! -s "$T/allowed/curl-seed-$v.log" ] && ok || bad "A6 seeded, no root: made curl calls: $(cat "$T/allowed/curl-seed-$v.log")"
  else
    run_case a6-seed-H "$FC" B="$s" FLEET_CONF="$T/fx/fleet.conf" H="$T/h" \
      PATH="$T/stub:$PATH" CURL_LOG="$T/allowed/curl-seed-$v.log"
    creates=$(grep -c -- '-X POST .*/boards/rb-1/tickets$' "$T/allowed/curl-seed-$v.log" 2>/dev/null)
    [ "${creates:-0}" = 0 ] && ok || bad "A6 seeded, H only: refiled $creates child(ren)"
  fi
  [ "$(cat "$s/children.txt" "$s/children-board.tsv")" = "$before" ] && ok || bad "A6 seeded ($v): the ledger changed"
done

# fc_file_board's own env read: with no root it resolves no board context (no
# base, so no token is read, not even through HARNESS_ENV_DIR) and sends
# nothing. BH-7919: the base and token come from tracker_context
# (bin/lib/tracker.sh), whose board arm refuses an empty root before it reads
# an env file; fc_board_base is no longer fc_file_board's seam.
mkdir -p "$T/allowed/fb"; printf '[{"title":"A","body":"a","after":[]}]\n' > "$T/allowed/fb/children.json"
run_case a2-fc-file-board '. "$REPO/bin/lib/file-children.sh"; . "$REPO/bin/lib/fc-board.sh"
FC_PROJECT=ledger-os FC_KEY=LG-9 FC_PARENT=cmParent01 FC_BUILD="$T/allowed/fb" FC_SPEC="$T/allowed/fb/children.json"
rc=0; fc_file_board || rc=$?; echo "board=$rc err=$FC_ERROR"
echo END' HARNESS_ENV_DIR="$T/fx/env" PATH="$T/stub:$PATH" CURL_LOG="$T/allowed/curl-fb.log"
has "board=1 err=no board base for ledger-os" "A2 fc_file_board with no root reads no board context"
[ ! -s "$T/allowed/curl-fb.log" ] && ok || bad "A2 fc_file_board with no root made curl calls"

# ---- A7 entry points (rule 4) -------------------------------------------------
# HARNESS_ENV_DIR points at an empty dir so neither script sources a real env.
# lane-probe rejects an unknown lane (exit 64) before it sources lane-model, so
# the run names a real lane in --endpoint mode: GROK_MODEL answers lane_model
# without loading a resolver, and a stub cred-probe lib whose claim refuses
# (rc 1, "already spent today") exits 0 before any inference.
mkdir -p "$T/fx/noenv"
cat > "$T/fx/cred-probe-stub.sh" <<'STUB'
cred_probe() { echo "NO_ENDPOINT stub"; return 4; }
cred_account_fp() { return 1; }
cred_inference_claim() { return 1; }
cred_inference_record() { return 0; }
STUB
open_up
( cd "$T/cwd" && unpriv env -u H -u HARNESS HOME="$T/home" HARNESS_ENV_DIR="$T/fx/noenv" PS4='+ ' \
    GROK_MODEL=stub-model CRED_PROBE_LIB="$T/fx/cred-probe-stub.sh" \
    bash -x "$NB/bin/lane-probe.sh" --endpoint grok ) > "$T/out/a7-lp" 2> "$T/traces/a7-lp.trace"
hn=$(grep -n '^+ H=/root/harness$' "$T/traces/a7-lp.trace" | head -1 | cut -d: -f1)
ln=$(grep -n '^+ \. .*/bin/lib/lane-model\.sh$' "$T/traces/a7-lp.trace" | head -1 | cut -d: -f1)
[ -n "$hn" ] && [ -n "$ln" ] && [ "$hn" -lt "$ln" ] && ok \
  || bad "A7 lane-probe sets H=/root/harness before sourcing lane-model (H at '${hn:-}', source at '${ln:-}')"
# file-health-ticket.sh's board-creds (a remainder lib) alerts under
# ${HARNESS:-/root/harness}, so the run gets a scratch HARNESS and the check is
# that the entry point hands it to H before sourcing file-children.
mkdir -p "$T/allowed/fh"; open_up
( cd "$T/cwd" && unpriv env -u H HARNESS="$T/allowed/fh" HOME="$T/home" HARNESS_ENV_DIR="$T/fx/noenv" PS4='+ ' \
    bash -x "$NB/bin/file-health-ticket.sh" bogus https://x.example https://pr.example ) \
  > "$T/out/a7-fh" 2> "$T/traces/a7-fh.trace"
hn=$(grep -n "^+ H=$T/allowed/fh\$" "$T/traces/a7-fh.trace" | head -1 | cut -d: -f1)
ln=$(grep -n '^+ \. .*/lib/file-children\.sh$' "$T/traces/a7-fh.trace" | head -1 | cut -d: -f1)
[ -n "$hn" ] && [ -n "$ln" ] && [ "$hn" -lt "$ln" ] && ok \
  || bad "A7 file-health-ticket sets H before sourcing file-children (H at '${hn:-}', source at '${ln:-}')"
grep -q '^FAIL' "$T/out/a7-fh" && ok || bad "A7 file-health-ticket with no env still refuses: $(cat "$T/out/a7-fh")"

echo "lib-root-records.bh-2613: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
