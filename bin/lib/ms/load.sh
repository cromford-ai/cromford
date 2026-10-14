#!/bin/bash
# shellcheck shell=bash
# bin/lib/ms/load.sh — loads the merge-sweep modules through the module map.
# No "# module:" header: this is the bootstrap, not a module. It lives in ms/
# beside a symlink to ../module-map.sh, so a scratch copy of ms/ carries the
# loader too. Order: ms/MODULES, or the module headers when MODULES is absent.
# shellcheck source=bin/lib/module-map.sh
. "${BASH_SOURCE[0]%/*}/module-map.sh" || return 1
mm_load "${BASH_SOURCE[0]%/*}"
