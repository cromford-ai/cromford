# One vendor fake switch: HARNESS_VENDOR_FAKE; the BH-7974 name is a retired alias (BH-8555)

Doc: SECRETS-ENVELOPE

The scalable-tests rule (BH-7563) asks for one way to turn on a vendor fake. Two names existed:
`HARNESS_VENDOR_FAKE` with fixtures in `tests/fixtures/vendor-fake` (BH-7965, on main, read by 5 seams) and
`HARNESS_VENDOR_MODE` with fakes in `tests/fakes/vendor` (BH-7974, #7985, merged 2026-10-27 while this change was in the merge queue). The keeper is
`HARNESS_VENDOR_FAKE`, because more seams read it.

## What changed

- `vendor_fake_on` in `bin/lib/vendor/_common.sh` is the only reader of the switch. `vendor_main` calls it.
- `HARNESS_VENDOR_FAKE`: unset, empty or `0` is real; `1` is fake. Any other value (`yes`, `true`, ` 1`)
  fails closed: the seam prints `vendor-probe: unknown fake switch value` and exits 99 with no call. Before
  this change, such a value meant real mode.
- `HARNESS_VENDOR_MODE` is a retired alias for one release, read only inside `vendor_fake_on`. `fake` turns
  on fake mode and prints one deprecation line; `real` or empty has no say; any other value exits 99. Fake
  mode wins when either name says fake. Remove the alias in the next release.
- `tests/vendor-fake-switch.bh-8555-test.sh` runs on every diff (always-run, whole tree). It refuses
  `HARNESS_VENDOR_MODE`, a bare `VENDOR_FAKE_DIR` and `tests/fakes/vendor` outside the alias block,
  `docs/notes/`, `.harness/specs/` and one marked line in `docs/SECRETS-ENVELOPE.md`.
- `tests/vendor-fake-budget.bh-8555-test.sh` asserts 0 vendor calls under the alias, under a typo value and
  with both names set.

#7985 merged on main before this change, so this change also moves its files to the one switch:
`bin/lib/vendor/seam.sh` `vendor_mode` now calls `vendor_fake_on` (sourced from `_common.sh`), so the
Telegram, fly-machines and tailscale seams read `HARNESS_VENDOR_FAKE` and the alias exactly as the probe
seams do. `vendor_fake` reads `HARNESS_VENDOR_FAKE_DIR`, default `tests/fixtures/vendor-fake`, and
`tests/fakes/vendor/telegram.json` moved there with its content unchanged. An unseeded fake method is
still rc 70. An unknown switch value is rc 2 with `vendor-mode: unknown fake switch value '<v>'`. The
BH-7939, BH-7974 and BH-8541 suites, the Telegram contract suite and
`docs/verification-map/entries/vendor-seams.md` use the one switch.
