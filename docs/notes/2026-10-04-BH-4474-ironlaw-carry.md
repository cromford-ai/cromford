# BH-4474: an iron-law acceptance carries to a new head when the hits are unchanged

Doc: MERGE-CONDUCTOR

**Why.** An adjudicated ACCEPT is the file `<rec>/iron-law-accepted-<head>`,
bound to one sha. A push that never touches the flagged line (a merge of main, a
fixture fix, a renumber) still moves the head, so the PR re-parked on the same
false positive and bought another adjudication. #4044 and #4142 did this three
times on 2026-10-04.

**What changed.**

- New `bin/lib/ironlaw-carry.sh`. It fingerprints every hit in a diff as
  `(rule, file, sha1 of the flagged line)`. The line is hashed with its leading
  `+` and surrounding whitespace removed, so a moved or re-indented line keeps
  its fingerprint and a changed character does not. Rules are
  `redflag:<matched token>` for the inline pattern and `check:<slug>` for a
  `bin/checks-run.sh` CHECK-HIT. The scope is the sweep's skip set, the wider
  of the two scans, so the fingerprinted set is never smaller than either
  gate's count.
- `bin/blocked-resolver.sh`, iron-law ACCEPT arm: after it writes the marker, it
  writes one jobs-ledger row per distinct fingerprint of the diff it judged.
  There is no new file state.
  - `kind` = `ironlaw-accept`
  - `key` = `<owner/repo lowercased>#<pr>|<sha1(rule TAB path TAB contenthash)>`
  - `status` = `accepted`
  - `detail` = `{"sha","rule","path","n"}`, where `n` is how many copies of that
    line the accepted set held

  It logs `recorded N hit fingerprint(s) for carry`, or
  `carry NOT recorded (<why>) — the next head re-adjudicates`. A REJECT or a
  no-verdict run records nothing.
- `bin/merge-conductor.sh` and `bin/merge-sweep.sh`: a head with hits and no
  per-head marker asks `ilc_covered`. Each gate then logs one of three lines:
  - `iron-law: carried acceptance from <old sha> — …, not parking`, and the hit
    count is zeroed
  - `iron-law: carry refused on <head> — new or changed hit(s): <rule> <path> (new or changed|more copies than accepted)`,
    naming only the uncovered hits, and the PR parks exactly as before
  - `iron-law: carry UNVERIFIABLE on <head> (<why>) — parking as before`

**Fail-closed rules.** It carries only when every current fingerprint has a row
for THIS PR with `n` at least the current count. The PR is part of the key, so
an acceptance never crosses PRs or repos. Each of these parks:
- a ledger outage
- an unparseable row
- `bin/checks-run.sh` rc 2, or a crashed check
- a CHECK-HIT that resolves to no added line
- more than `ILC_MAX_HITS` hits (default 50)
- a fingerprinted set smaller than the scan's count

The per-head marker is still the same-head fast path, and a carried head gets no
marker. The family carry in `bin/lib/br/opt/family.sh` writes no fingerprint
rows, so a family-carried PR's next head is adjudicated as before.

**Look at it.** `GET /api/ledger?kind=ironlaw-accept` lists the rows.
`tests/mc/iron-law-carry.bh-4474-test.sh` drives the resolver, the conductor and
the sweep against a stub ledger.
