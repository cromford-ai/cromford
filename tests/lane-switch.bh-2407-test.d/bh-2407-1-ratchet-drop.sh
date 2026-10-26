# RT1-RT3 — the ratchet's .drop floor, run as shipped (strict mode) over a
# hermetic tree that sits AT its floor. fixture.drop stacks on the tree's own.
R="$T/r"
srt_tree "$R" 3 || bad "RT0 srt_tree could not build the fixture tree"
ratchet() { srt_run "$R" > "$T/ratchet.out"; }

ratchet; RC=$?
eq "RT1 the tree at its floor passes ($(tail -1 "$T/ratchet.out"))" "$RC" "0"
printf ' 1 \n' > "$R/tests/switch-ratchet.d/fixture.drop"
ratchet; RC=$?
[ "$RC" -ne 0 ] && ok || bad "RT2 a drop of 1 with no read removed must fail (the tree must sit AT the effective floor)"
BARE_RE='\[ -[ef] [^]]*flags/[a-z0-9-]+-(off|disabled)[^]]*\]'
RF=$(grep -rlE "$BARE_RE" "$R/bin" | head -n 1)
[ -n "$RF" ] && ok || bad "RT2 no bare read in the fixture tree to remove"
sed -i -E "0,\#$BARE_RE#s##false#" "$RF"
ratchet; RC=$?
eq "RT2 drop 1 + one bare read removed passes ($(tail -3 "$T/ratchet.out" | tr '\n' ' '))" "$RC" "0"
for v in abc -1 1.5 ""; do
  printf '%s' "$v" > "$R/tests/switch-ratchet.d/fixture.drop"
  ratchet; RC=$?
  if [ "$RC" -ne 0 ] && grep -q '^FAIL: R0 .*fixture.drop' "$T/ratchet.out"; then ok
  else bad "RT3 a drop of '$v' must fail with an R0 line (rc=$RC): $(cat "$T/ratchet.out")"; fi
done

