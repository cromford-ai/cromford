# The call guard caps a build's plan, execute and fix across builds

Doc: CALL-GUARD

## What was wrong

The K3 call guard (`bin/lib/call-guard.sh`) counts paid calls per `(project, stage, fingerprint)`. The build's dispatcher `CC()` never set `AGENT_CALL_FP`, so plan, execute and fix got the fallback fingerprint `<ticket>:<HEAD>:p<prompt sha>`. Every plan and execute prompt embeds the build's own `$BUILD` dir. A new build of the same ticket was therefore new work to the guard, and the cap only caught repeats inside one build.

## What it does now

At plan time, `bin/lib/rb/plan.sh` computes one **build fingerprint** and writes it to `$BUILD/call-fp`:

```
<KEY>:th<first 16 hex of sha256(ticket title+body, thread signature)>:m<first 12 hex of origin/<BASE>>
```

- Title and body come from `$BUILD/ticket-meta.json`.
- The thread signature is `FP_BEFORE` on an in-app board. On a GitHub-issue project (board prefix `-`) it is `gh_rest GET repos/<repo>/issues/<n>/comments?per_page=100` projected to `[[id, updated_at], ...]`. A new comment or an edited comment moves it. Only a thread's first 100 comments are hashed.
- `call_guard_build_fp <key> <sha>` (material on stdin) builds the string. It prints nothing and returns 1 on an empty key, empty material, or a sha that is not at least 7 hex characters.

`CC()` passes it as `AGENT_CALL_FP`:

| stage | outfile | fingerprint |
|---|---|---|
| `plan` | `plan-run.txt` | the build fp |
| `execute` | `execute-run.txt` | the build fp |
| `fix` | any | `<build fp>:<outfile>:t<HEAD^{tree}, 12 hex>` |
| `plan` repairs (`plan-repair-run.txt`, `size-repair-run.txt`), every other stage | | nothing: the fallback |

The fix fingerprint carries the round and the tree, so the lens, merged and QA fix rounds of one build stay distinct, and a fix on changed code is new work. Repairs are left out so two repairs in one build cannot spend the next build's plan slots.

A resumed build reads `$BUILD/call-fp` back and keeps the fingerprint its plan was written under. A fresh plan rewrites it.

## When there is no build fingerprint

No `ticket-meta.json`, no thread signal (board outage, a gh_rest rc other than 0 such as 75, an unparseable comments body), or an `origin/<BASE>` that does not resolve: no `call-fp` file, one `pipeline.log` line `no stable call fp (<why>) — plan/execute/fix use the per-build fingerprint`, and those calls behave exactly as before.

## What that means for launchers

With the default `plan=3`, the fourth identical plan of an unchanged ticket on an unchanged main inside the 24h window is refused rc 74, which the plan stage turns into `BUILD_DEFERRED plan refused by the call-guard`. Any new comment, ticket edit or move of main clears it. The K values and stages are unchanged.

Tests: `tests/agent-call-call-guard.bh-2413-test.sh`.
