# BH-7934.1 owns this file
# shellcheck shell=bash
# bin/lib/onboard-stations.sh — the onboarding station functions, sourced by
# the onboarding runner (BH-7934.2). Empty until BH-7934.1 fills it.
#
# Interface, one function per station: obs_register, obs_prompt, obs_label,
# obs_box, obs_clone. Each reads the globals PROJECT SLUG REPO PROD BOX PREFIX
# BASE REGISTRY_SOURCE that bin/load-project.sh sets, prints its own lines,
# and returns non-zero on failure (never exit, so the runner records the step).
# The tracker station (used instead of label when the tracker is not
# github-issues) calls onb_tracker_check from bin/lib/hub-probes/tracker-test.sh
# and does not copy it.
