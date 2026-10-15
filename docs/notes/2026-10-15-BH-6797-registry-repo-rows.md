# The registry guard maps repo slugs by exact rows (BH-6797)

Doc: MIRROR-NOTES, SELF-HOST

BH-6760 made the Cromford registry guard map a fleet name only by an exact
table row. It checked the project, box, board prefix and prod domain. It did
not check column 2 of the registry, the GitHub slug of each project. This
change adds that item.

## What changed

- `bin/share/mapping.py` has a new table `REPOS`: one row per slug in the
  committed registry (13 rows). Each right side is the text the sanitizer
  already gave that slug, so the mirror text does not change.
- `bin/share/sanitize.py` rule 4b, after the domains: each `REPOS` row
  rewrites its slug whole and case-sensitively,
  `(?<![\w-])<slug>(?![\w-])`. A glued, longer or other-case slug matches no
  row and keeps the later rules.
- `bin/share/registry_guard.py` reads `bin/fleet-conf.sh <p> repo` for each
  project (`read_repos`) and checks the item kind `repo`. A slug is mapped
  only when it is an exact `REPOS` key, or `repo:<slug>` is in
  `PUBLIC_REGISTRY`. An unmapped slug prints
  `registry-guard: unmapped repo <slug>`, and stderr prints
  `registry-guard: add to REPOS in bin/share/mapping.py: ("<slug>", "<its numbered form>")`.
  A repo read that fails is exit 2, the same as a failed prod read. A repo
  of `-` or empty is no item. `read_registry` keeps its 4-tuple.

## Count

`python3 bin/share/registry_guard.py --root . --fleet-conf fleet.conf` now
prints `registry-guard: 58 item(s), all mapped`: the 45 items of BH-6760 plus
13 repo slugs. The 45 in the BH-6494 note is a measurement on `607e412c29c0`
and stays as it was.

## A new client

A new fleet.conf row needs a `REPOS` row for its slug too, next to its
`PROJECTS`, `BOXES`, `DOMAINS` and `TICKET_PREFIXES` rows. Use the
numbered form, `example-org/project-<n>`.

Tests: `tests/share-registry-repo.bh-6797-test.sh`.
