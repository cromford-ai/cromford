# Fixtures look fake on purpose; the builder runs the leak gate (BH-5789)

Doc: OPERATING

## What happened

PRs passed the builder and then failed the leak scan in a merge batch or a lead review: #5700 had 11
tailnet addresses in its fixtures, #5282 one, and #4967's token broke merge batch #5770 for 3 PRs. The
builder and review boxes had no gitleaks, so `tests/share-publish-clean.bh-795-test.sh` skipped its gate.

## What changed

1. **The rule (D64, and the plan contract's §8).** Fixture IPs are RFC 5737 (`192.0.2.x`,
   `198.51.100.x`, `203.0.113.x`). A fake token has `fixture` in its value. No tailnet or RFC1918
   address, real hostname or client name.
2. **The lint.** `bin/fixture-hygiene.sh check --tree . --base <ref>` reads the lines a diff adds to test
   files (`tests/**`, `worker/*/test/**`, untracked ones too) and flags a `100.64/10` address, an
   RFC1918 address, and a SECRET-bearing token or a `TOKEN=`/`SECRET=` literal with no `fixture`. A CIDR
   (an address followed by `/<bits>`) names a range and is not flagged. A line with
   `fixture-hygiene-allow: <reason>` is skipped. It is a delta row of `catalog/rules-pack.tsv`, so the
   rules pack runs it in the builder's verify step, in CI's lint job and in the lead review.
3. **gitleaks in every image.** The pool image (`fly/Dockerfile`, `bake-gitleaks`) and the builder and
   review boxes (`bin/bootstrap-machine.sh`) install the pin from `bin/lib/gitleaks-pin.sh`, sha256-checked.
4. **The verify step requires it.** `HARNESS_IMPACT_GATE_RUN` (`bin/lib/rb/gates.sh`) runs the rules pack
   and the impact gate with `GITLEAKS_REQUIRED=1`, so on a box without gitleaks the leak suite is red,
   never a skip.

## What usually lies

- A box bootstrapped before this has no gitleaks until `bin/bootstrap-machine.sh` runs again; its builds
  fail the leak gate until then. That is the point, and the fix is the bootstrap.
- The pool image picks gitleaks up on its next bake.
