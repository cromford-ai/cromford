#!/bin/bash
# shellcheck shell=bash
# bin/lib/hub-probes/repo-detect-extra.sh — BH-7997 (BH-7935 wave 2): the seam
# where more repo facts join the repo-detect line. Sourced by repo-detect.sh.
# hp_repo_detect_extra <owner/repo> prints one JSON object; it is merged over
# the base facts. Until the owner adds facts it prints {}.
# owner BH-7935.1
hp_repo_detect_extra() { echo '{}'; }
