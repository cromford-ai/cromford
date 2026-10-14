# A HOLD that lands after a train opened ejects that member (BH-1934)

Doc: MERGE-TRAINS

## What changed

- `bin/batch-resolve.sh` asked the HOLD and lead-fence questions
  (`br_member_fenced`, BH-1630) only when it picked train members. A HOLD, or a
  withdrawn lead MERGE row, that landed after the train opened did not pull the
  member out, and `bin/merge-queue.sh` (which reads no member fence) landed the
  train with it inside.
- The settle pass now asks first, in `settle_train`'s open arm, through the new
  `fence_eject`. For a fenced member it re-forms the same PR without it
  (`reform_train … fenced`, one unit of `BATCH_REFORM_MAX`). When a re-form
  cannot happen (a gated pass, a spent or zero budget, no member left, a union
  that will not build or verify, a refused push) it closes the train, releases
  every member, deletes the branch and records the train `abandoned` with an
  `ejected: #<n>` detail.
- `reform_train`'s member loop asks the same question on every trigger
  (`dirty`, `behind`, `fenced`), so a dirty or behind re-form never rebuilds a
  union around a held member.
- Nobody is excluded: an ejected member is not written to `red.txt` or
  `abandoned.txt`, so a RESUME (or a new lead row) is all it needs to ride
  again. An unreadable fence fails closed and ejects the same way. A refused
  close releases nothing and the next pass retries. No alert is raised.
- `br_member_fenced` moved, unchanged, from the `# >>> block gate` section to
  just above `settle_trains`, because the settle pass is called at top level
  before that section is defined.

Pinned by `tests/batch-resolve-hold-eject.bh-1934-test.sh`.
