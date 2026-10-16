#!/bin/bash
# tests/lane-cpu-sample.bh-6712-test.sh — the #6173 AC3 verdict of
# bin/lane-cpu-sample.sh (BH-6712): a default state-backup line under a
# strict 2% limit, and no temp file left on a SIGTERM during mktemp.
#
# Drives the REAL bin/lane-cpu-sample.sh against the committed fixtures,
# hand-written snapshot files (--diff) and fake /proc trees (--proc-root).
#   T1  AC (a): --diff of the two fixtures gives the per-lane share table.
#   T2  AC (b): only zstd under tar under state-backup moves; all of it counts
#       for state-backup, none for other.
#   T3  AC (c): a child seen in B and reaped in C counts once (25.0%).
#   T4  AC (d): with no flags, 1.9% PASS, 2.0% FAIL, 2.1% FAIL; 1.94% prints
#       1.9 and PASSes, 1.95% prints 2.0 and FAILs.
#   T5  defaults: --lane and --max-pct each work alone; --snapshot refuses
#       either one.
#   T6  the verdict line format; no "LCS lane=" line remains.
#   T7  a SIGTERM while the second mktemp runs leaves no temp file.
#   T8  docs/RESTORE.md names the operator command and both outcomes.
#   T9  a pid that vanishes (no stat, no cmdline) is skipped with no stderr
#       line: the 900 s doc run on the build box printed one per exited pid.
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LCS="$DIR/bin/lane-cpu-sample.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

# mkproc <root> <pid> <ppid> <utime> <stime> <comm> [argv...]
# Writes <root>/<pid>/stat in the kernel's layout (utime and stime are fields
# 14 and 15) and <root>/<pid>/cmdline NUL-separated.
# CUT and CST in the environment set cutime and cstime (fields 16 and 17).
mkproc() {
  local root="$1" pid="$2" ppid="$3" ut="$4" st="$5" comm="$6"; shift 6
  mkdir -p "$root/$pid"
  printf '%s (%s) S %s %s %s 0 -1 4194304 0 0 0 0 %s %s %s %s 20 0 1 0 100\n' \
    "$pid" "$comm" "$ppid" "$pid" "$pid" "$ut" "$st" "${CUT:-0}" "${CST:-0}" > "$root/$pid/stat"
  if [ $# -gt 0 ]; then printf '%s\0' "$@" > "$root/$pid/cmdline"; else : > "$root/$pid/cmdline"; fi
}

FA="$DIR/tests/fixtures/lcs-a.tsv"
FB="$DIR/tests/fixtures/lcs-b.tsv"

# ── T1 AC (a) ───────────────────────────────────────────────────────────────
out=$("$LCS" --diff "$FA" "$FB" 2>&1)
eq "T1 share table" "$(grep -v '^state-backup share=' <<<"$out")" \
  "$(printf '60.0\tmerge-conductor\n20.0\tother\n10.0\todd\n10.0\tstate-backup')"

# ── T2 AC (b) ───────────────────────────────────────────────────────────────
mkproc "$T/p2a" 1 0 0 0 systemd /sbin/init
mkproc "$T/p2a" 10 1 5 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p2a" 11 10 5 0 tar tar -cf - state
mkproc "$T/p2a" 12 11 5 0 zstd zstd -1 -T1
mkproc "$T/p2b" 1 0 0 0 systemd /sbin/init
mkproc "$T/p2b" 10 1 5 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p2b" 11 10 5 0 tar tar -cf - state
mkproc "$T/p2b" 12 11 14 0 zstd zstd -1 -T1
"$LCS" --snapshot --proc-root "$T/p2a" > "$T/2a.tsv"; eq "T2 snapshot A rc" "$?" 0
"$LCS" --snapshot --proc-root "$T/p2b" > "$T/2b.tsv"; eq "T2 snapshot B rc" "$?" 0
out=$("$LCS" --diff "$T/2a.tsv" "$T/2b.tsv" 2>&1)
eq "T2 only row is state-backup" "$(grep -v '^state-backup share=' <<<"$out")" "$(printf '100.0\tstate-backup')"
case "$out" in *"	other"*) bad "T2 zstd counted for other" ;; *) ok ;; esac

# ── T3 AC (c) ───────────────────────────────────────────────────────────────
mkproc "$T/p3a" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p3a" 11 10 0 0 tar tar -cf - state
mkproc "$T/p3a" 12 11 0 0 zstd zstd -1
mkproc "$T/p3a" 20 1 0 0 bash bash bin/merge-conductor.sh
mkproc "$T/p3b" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
mkproc "$T/p3b" 11 10 0 0 tar tar -cf - state
mkproc "$T/p3b" 12 11 100 0 zstd zstd -1
mkproc "$T/p3b" 20 1 150 0 bash bash bin/merge-conductor.sh
mkproc "$T/p3c" 10 1 0 0 bash bash /root/harness/bin/state-backup.sh
CUT=100 mkproc "$T/p3c" 11 10 0 0 tar tar -cf - state
mkproc "$T/p3c" 20 1 300 0 bash bash bin/merge-conductor.sh
for x in a b c; do "$LCS" --snapshot --proc-root "$T/p3$x" > "$T/3$x.tsv"; done
out=$("$LCS" --diff "$T/3a.tsv" "$T/3b.tsv" "$T/3c.tsv" --max-pct 30); rc=$?
eq "T3 reaped child counts once" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=25.0% PASS (limit 30%)|0"

# ── T4 AC (d): the strict 2% limit, no flags ───────────────────────────────
# limit_case <sb-ticks> <total>: state-backup gets <n> of <total> ticks.
limit_case() {
  printf '1\t0\t0\t-\n' > "$T/lA.tsv"
  printf '1\t0\t0\t-\n10\t1\t%s\tstate-backup\n20\t1\t%s\tmerge-conductor\n' "$1" $(($2 - $1)) > "$T/lB.tsv"
  "$LCS" --diff "$T/lA.tsv" "$T/lB.tsv"
}
for c in "19 1000 1.9% PASS 0" "20 1000 2.0% FAIL 1" "21 1000 2.1% FAIL 1" \
         "194 10000 1.9% PASS 0" "195 10000 2.0% FAIL 1"; do
  read -r n tot pct verdict want_rc <<<"$c"
  out=$(limit_case "$n" "$tot"); rc=$?
  eq "T4 $n of $tot" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=$pct $verdict (limit 2%)|$want_rc"
done

# ── T5 defaults ─────────────────────────────────────────────────────────────
out=$("$LCS" --diff "$FA" "$FB" 2>&1); rc=$?
eq "T5 no flags verdict" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 2%)|1"
out=$("$LCS" --diff "$FA" "$FB" --lane x 2>&1); rc=$?
eq "T5 --lane alone" "$(tail -n 1 <<<"$out")|$rc" "x share=0.0% PASS (limit 2%)|0"
out=$("$LCS" --diff "$FA" "$FB" --max-pct 3 2>&1); rc=$?
eq "T5 --max-pct alone" "$(tail -n 1 <<<"$out")|$rc" "state-backup share=10.0% FAIL (limit 3%)|1"
for args in "--snapshot --lane x" "--snapshot --max-pct 2"; do
  # shellcheck disable=SC2086
  "$LCS" $args >/dev/null 2>&1; eq "T5 [$args] rc" "$?" 64
done

# ── T6 format ───────────────────────────────────────────────────────────────
out=$("$LCS" --diff "$FA" "$FB" 2>&1)
[[ "$(tail -n 1 <<<"$out")" =~ ^state-backup\ share=[0-9]+\.[0-9]%\ (PASS|FAIL)\ \(limit\ 2%\)$ ]] \
  && ok || bad "T6 last line format: [$(tail -n 1 <<<"$out")]"
case "$out" in *"LCS lane="*) bad "T6 an LCS lane= line remains" ;; *) ok ;; esac

# ── T7 SIGTERM during the second mktemp ─────────────────────────────────────
# A mktemp shim first on PATH runs the real mktemp, prints the name, and on
# its second call holds until the test creates $T/release (at most 5 s): the
# file exists, and the script has not yet assigned its name. A TERM then must
# still leave no temp file.
REAL_MKTEMP=$(command -v mktemp)
mkdir -p "$T/shim" "$T/tmpd7"
cat > "$T/shim/mktemp" <<EOF
#!/bin/bash
n=\$(cat "$T/mkcount" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$T/mkcount"
f=\$("$REAL_MKTEMP" "\$@") || exit 1
echo "\$f"
[ "\$n" -ne 2 ] || for _ in \$(seq 1 100); do [ -e "$T/release" ] && break; sleep 0.05; done
EOF
chmod +x "$T/shim/mktemp"
mkproc "$T/p7" 1 0 0 0 systemd /sbin/init
PATH="$T/shim:$PATH" TMPDIR="$T/tmpd7" "$LCS" --seconds 30 --proc-root "$T/p7" >/dev/null 2>&1 &
pid=$!
nfiles() { local -a f=("$T"/tmpd7/*); [ -e "${f[0]}" ] || f=(); echo "${#f[@]}"; }
for _ in $(seq 1 100); do
  [ "$(nfiles)" -ge 2 ] && break
  sleep 0.05
done
eq "T7 two temp files before TERM" "$(nfiles)" 2
kill -TERM "$pid"; wait "$pid"; rc=$?
: > "$T/release"
eq "T7 SIGTERM rc" "$rc" 143
eq "T7 SIGTERM left no temp file" "$(ls -A "$T/tmpd7")" ""

# ── T8 docs ─────────────────────────────────────────────────────────────────
for s in 'bin/lane-cpu-sample.sh --seconds 900 --interval 5' 'minute 4' 'close ask 4' 'off the hub'; do
  grep -qF -- "$s" "$DIR/docs/RESTORE.md" && ok || bad "T8 docs/RESTORE.md lacks [$s]"
done

# ── T9 a vanished pid is skipped quietly ───────────────────────────────────
mkproc "$T/p9" 1 0 3 0 systemd /sbin/init
mkdir -p "$T/p9/77"
mkproc "$T/p9" 78 1 4 0 bash bash /root/harness/bin/state-backup.sh
rm -f "$T/p9/78/cmdline"
out=$("$LCS" --snapshot --proc-root "$T/p9" 2>"$T/9.err"); rc=$?
eq "T9 rc" "$rc" 0
eq "T9 rows" "$out" "$(printf '1\t0\t3\t-\t0\n78\t1\t4\t-\t0')"
eq "T9 no stderr" "$(cat "$T/9.err")" ""

echo "lane-cpu-sample.bh-6712: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
