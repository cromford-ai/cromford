#!/bin/bash
# bin/lib/train-shape.sh — WHAT A MERGE TRAIN LOOKS LIKE, in ONE place.
# Sourced, never executed.
#
#   train_is_train <title> <head-ref>   rc 0 = this PR is a merge train
#
# WHY ONE PLACE (BH-1428, from the review of #1422). This repo opens trains in
# two shapes and they are NOT the same words:
#
#   bin/batch-resolve.sh   branch `batch/<project>/<UTC stamp>-<pid>-<n>`
#                          title  `batch(<project>): land N approved siblings as
#                                  one train`
#   the union merge train  branch `train/…`, title `merge train: N approved PRs`
#
# bin/test-impact.sh already knew BOTH title spellings — BH-1203 specified
# "merge train" and the PR bin/batch-resolve.sh actually opens says `batch(`, so
# matching one spelling left every real train on a partial CI corpus. BH-1313's
# merge-method rule then learned only the OTHER pair, so a batch train
# squash-merged: its members' commits never reached main, merged-by-ancestry
# never became true, and every member had to be closed by hand. Two recognisers
# that disagree is the bug both times, so there is now one function and both
# callers ask it.
#
# PREFIX, NEVER SUBSTRING. `Revert "merge train: …"` is not a train, `retrain:`
# is not a train, and `feature/train-schedule` is not a train — each would be a
# merge commit nobody asked for. The title test is anchored and
# case-insensitive (a human-typed title is not reliably cased); the ref test is
# an exact path prefix, because a branch name is not typed by a human.
[ -n "${_TRAIN_SHAPE_LOADED:-}" ] && return 0
_TRAIN_SHAPE_LOADED=1

train_is_train() { # train_is_train <title> <head-ref>
  grep -qiE '^[[:space:]]*(merge train|batch\()' <<<"${1:-}" && return 0
  case "${2:-}" in
    train/*|batch/*) return 0 ;;
  esac
  return 1
}
