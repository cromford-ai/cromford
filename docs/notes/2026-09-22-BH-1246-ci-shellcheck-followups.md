# BH-1246 — ci-shellcheck follow-ups from the #1240 review

Follow-ups to the BH-1200 ShellCheck cache work.

## What changed

1. `bin/ci-shellcheck.sh:29-41` — rewrote the "WHY PER-FILE CACHING IS SOUND"
   comment to state the real rule: the cache is sound at `--severity=error`
   because no error-level ShellCheck check depends on definitions imported from
   a sourced file. The previous claim that per-file mode cannot follow `source`
   directives was false; ShellCheck does follow sourced files that are also on
   the command line, but the per-file caching key is still safe at error
   severity. Warning-level checks such as SC2128 do depend on sourced
   definitions, which is why the lint job stays at error severity.

2. `tests/ci-shellcheck-cross-file.bh-1246-test.sh` — added a sourcer+lib
   canary that goes red if a future severity bump makes per-file caching
   silently drop cross-file findings. It proves SC2128 appears in full warning
   mode, is dropped in per-file warning mode, and that no cross-file error
   appears at the script's error severity.

3. `tests/ci-shellcheck-cache.bh-1200-test.sh` — updated the header and block-F
   comments to match the corrected rule.

4. `docs/CI-RUNNERS.md:343-347` — corrected the matching paragraph and noted the
   canary.

5. `.github/workflows/harness-ci.yml:95-99` — changed the `actions/cache` path
   from the whole `${{ runner.temp }}/bh-shellcheck-cache` directory to only
   `${{ runner.temp }}/bh-shellcheck-cache/results` and
   `${{ runner.temp }}/bh-shellcheck-cache/fatal`, so the ~16 MB ShellCheck
   binary is no longer saved in every cache entry. Added a post-shellcheck step
   that prints `du -sb` of the results and bin directories so the PR's CI run
   reports the before/after cache composition.

6. `docs/verification-map/entries/BH-1200.md` — updated the entry to state that
   the cached path is findings only and that the new canary guards the
   per-file assumption.

## Why

The #1240 review found two problems in the BH-1200 merge:

- The documentation claimed per-file ShellCheck cannot follow `source`
  directives, which is not true; the real safety argument is about error
  severity.
- The CI cache was saving the whole `${{ runner.temp }}/bh-shellcheck-cache`
  directory, including the downloaded 16 MB ShellCheck binary, bloating cache
  entries and churn against the repo's 10 GB GitHub Actions cache cap.

Doc: CI-RUNNERS.md, bin/ci-shellcheck.sh
