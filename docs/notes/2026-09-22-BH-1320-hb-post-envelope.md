# BH-1320 — hb_post keeps the `.json` envelope when the review `.md` is missing

Doc: review-record-integrity

**What changed.** In the `# >>> rereview helpers` block of `bin/merge-conductor.sh`, `hb_post`'s missing-out-file branch now puts its empty stub in its own `mktemp -d` directory and copies the real `<outf>.json` beside it as `<stub>.json` when one exists. The posted PARSE_INCOMPLETE body therefore fences the envelope the lane actually wrote, and the log line names both paths and says whether the envelope was found.

- The stub is `$stubd/review.md` instead of a bare `mktemp` file, and the cleanup on the return path is `rm -rf "$stubd"`.
- The log clause is built in `envnote`: `; its envelope <outf>.json is beside it and rides in the comment` when `<outf>.json` is non-empty, `; no envelope at <outf>.json either` when it is not. The substring `is missing or unreadable` is unchanged — the BH-641 I2 case pins it.
- Nothing else moves. The body's first line is still `PARSE_INCOMPLETE: the review file is empty or missing — this lane produced no review text at all`, the caller's footer still rides, a failed post is still logged, and the envelope is NOT persisted into the build record.

**Why.** Carried from the BH-641 review (#665) as Important note I1. `rp_post` derives the envelope path as `"$out.json"` from the file it is handed (`bin/lib/review-post.sh:214`), so swapping in a bare stub pointed the renderer at `<stub>.json`, which never exists. The comment said `(no raw JSON envelope was written by the review lane)` while that envelope sat on disk beside the missing `.md` — a status string that rendered while false (D13), and the only surviving copy of the review lane's answer thrown away in the one case where the `.md` was already lost.

**The envelope is not written into the build record.** `rp_persist` deliberately returns before its `.json` copy when the `.md` is empty, so an earlier tick's `rereview-<head8>.md`/`.json` pair at this head is left alone. Copying the new `.json` in on its own would split that pair into an old review next to a new envelope, which is worse evidence than leaving it where it is; the log line names `<outf>.json` so an operator can open it.

**Edge cases.** An empty `<outf>.json` is treated as no envelope (`-s`, not `-f`) and the body says so truthfully. A failed `mktemp -d` leaves `outf` as the missing path and falls through to the footer-only post exactly as before. A failed `cp` leaves the body saying there was no envelope, but the log line has already named where it is.

**What it touches.** `bin/merge-conductor.sh` (`hb_post`), `tests/review-record-integrity-test.sh` (section 1, the `envonly` case next to the BH-641 I2 case it extends), `docs/verification-map/review-record-integrity.md`.
