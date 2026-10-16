Resolve the conflict only. Make no other change.

Keep the intent of both sides. The merged-in side is origin/main, which is reviewed and merged, or, for a stacked PR, the parent PR's branch, which this PR builds on. This branch's side is what the plan below asked for.

Read the merged-in side's diff below. It shows what that side changed in each conflicted file since the merge base. Keep that change, and put this branch's change on top of it.

Do not edit a file that is not in the list of conflicted paths. Do not weaken, skip or delete a test.

When every conflicted path is resolved, `git add` each resolved file and commit the merge.
