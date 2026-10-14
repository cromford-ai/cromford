# BH-4987: a new lane knob is its own file, catalog/lanes.d/<owner>.knobs.d/<ENV>.json

Doc: docs/OPERATING.md

What changed: a knob lived only inside the one `knobs` array of a lane file
(`catalog/lanes.d/<lane>.json`) or of a lib in `_lib.json` / `_lib.<x>.json`.
Every new knob was an append to that array. Two builds that each added a knob
to the same lane both edited its last element, and git reported a conflict.

A new knob on an existing lane or lib is now a new file:

- `catalog/lanes.d/<lane-id>.knobs.d/<ENV>.json` for a lane;
- `catalog/lanes.d/_lib.<lib-id>.knobs.d/<ENV>.json` for a lib.

The file holds ONE knob object, the same shape as an inline knob. Its `.env`
is the file name without `.json`, and it matches `^[A-Z][A-Z0-9_]*$`. The name
is the env, not `NNNN-<name>`: two branches that pick the same number get an
add/add conflict, and an env is unique per owner anyway.

`bin/lanes-build.sh` composes the fragments. It appends them to the owner's
`knobs` after the inline knobs, in `LC_ALL=C` order of file name. An owner with
no `knobs` key gets one. With no fragments the composition is byte for byte
what it was. The existing inline knobs did not move.

The composer refuses (rc 1, one stderr line that names the file):

- a `*.knobs.d/` dir with no owner lane or lib;
- a file in it that is not `<ENV>.json`, or that is not one JSON object;
- an `.env` that is not the file name;
- an env that the owner already has inline.

`--check` composes twice, so it also refuses a bad fragment. It still fails
when `catalog/lanes.json` is tracked (BH-1247).

Readers did not change. They read the composed `catalog/lanes.json` through
`lanes_json_path`. `_lr_hash` in `bin/lib/lanes-registry.sh` now also hashes
the names and contents of the `*.knobs.d/` dirs, so a second fragment in an
existing dir re-renders the registry. `load_registered` in
`bin/config-inventory.py` reads the fragments too, so a fragment env is
ALREADY_REGISTERED.

`bin/lanes-knob-lint.sh --base <ref> [root]` is a new rules-pack component
(`lanes-knob-delta`). It is rc 1 when the diff from the fork adds an env to the
inline `knobs` of a lane or lib that existed at the fork. Each finding names
the fragment path to use. A new lane, a new lib, an edit of an existing knob
and a move to a fragment are not findings. If the fork has no
`bin/lanes-knob-lint.sh`, the lint prints `skipped` and is rc 0, so a branch
that has not taken main since this change is not judged by it.

Suite: `tests/lanes-knob-fragments.bh-4987-test.sh`.
