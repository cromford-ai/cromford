# The self-host installer runs under macOS bash 3.2 (BH-5732)

Doc: SELF-HOST, spending-caps

## What changed

- `bin/selfhost-install.sh` has no associative array now. Stock macOS ships
  bash 3.2, which refused `declare -A` and then died on
  `SELFHOST_CF_ACCOUNT_ID: unbound variable` at the quickstart's step 4.
  - The settings are two parallel arrays, `S_K` and `S_V`. `s_idx` finds a key.
  - The ledger is one string of `provider<TAB>kind<TAB>name` lines.
  - The secret id lists are an indexed array parallel to `SEC_ORDER`.
  - Every array expansion uses the guard form `${x[@]+"${x[@]}"}`, because
    bash before 4.4 treats an empty array as unbound under `set -u`.
- The dry-run output is unchanged. It was compared byte for byte with the old
  script on 4 setting matrices, with and without `--state`, and on the template.
- `SELFHOST_CAPS_OFF=0` now means caps on, the same as blank. Other values
  except `1` are still refused, now with "blank, 0 or 1 only".

## How it is pinned

`tests/selfhost-install-bash32.bh-5732-test.sh` runs the BH-3565 bash 3.2 lint
over the script, and drives the dry-run under the running bash. If a real bash
3.2 is present (a Mac's `/bin/bash`, or `SELFHOST_BASH32=<path>`), it drives the
dry-run under that bash too. CI has no bash 3.2, so there the proof is the lint.

The re-exec route (find a bash 4 and run under it) was not chosen, so
`docs/quickstart.md` needs no bash requirement.
